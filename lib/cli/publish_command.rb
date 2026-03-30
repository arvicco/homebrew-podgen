# frozen_string_literal: true

require "open3"
require "optparse"
require "yaml"
require "fileutils"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "cli", "rss_command")
require_relative File.join(root, "lib", "site_generator")
require_relative File.join(root, "lib", "upload_tracker")

module PodgenCLI
  class PublishCommand
    include PodcastCommand
    REQUIRED_ENV = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET].freeze

    def initialize(args, options)
      @options = options
      OptionParser.new do |opts|
        opts.on("--lingq", "Publish to LingQ instead of R2") { @options[:lingq] = true }
        opts.on("--youtube", "Publish to YouTube") { @options[:youtube] = true }
        opts.on("--force", "Re-upload even if already tracked") { @options[:force] = true }
        opts.on("--newest", "Publish newest episodes first") { @options[:newest] = true }
        opts.on("--dry-run", "Show what would be published") { @options[:dry_run] = true }
      end.parse!(args)
      @podcast_name = args.shift
      @episode_id = args.shift # optional: e.g. "2026-03-31" or "2026-03-31b"
    end

    def run
      code = require_podcast!("publish")
      return code if code

      load_config!

      # Regenerate RSS feed and static site before publishing
      regenerate_rss
      regenerate_site

      if @options[:lingq] || @options[:youtube]
        code = publish_to_lingq if @options[:lingq]
        yt_code = publish_to_youtube if @options[:youtube]
        code || yt_code || 0
      else
        publish_to_r2
      end
    end

    private

    def regenerate_rss
      rss_opts = { verbosity: @options[:verbosity] }
      rss = RssCommand.new([@podcast_name], rss_opts)
      rss.run
    end

    def regenerate_site
      generator = SiteGenerator.new(config: @config, clean: true)
      generator.generate
    rescue => e
      $stderr.puts "Warning: site generation failed: #{e.message}" if @options[:verbosity] == :verbose
    end

    def publish_to_r2
      unless rclone_available?
        $stderr.puts "rclone is not installed. Install with: brew install rclone"
        return 2
      end

      missing = REQUIRED_ENV.select { |var| ENV[var].nil? || ENV[var].empty? }
      unless missing.empty?
        $stderr.puts "Missing required environment variables: #{missing.join(', ')}"
        $stderr.puts "Set them in .env or podcasts/#{@podcast_name}/.env"
        return 2
      end

      source_dir = File.dirname(@config.episodes_dir) # output/<podcast>/
      bucket = ENV["R2_BUCKET"]
      dest = "r2:#{bucket}/#{@config.name}/"

      # Only sync public-facing files (mp3, html transcripts, feed xml, cover, site)
      includes = [
        "episodes/*.mp3",
        "episodes/*.html",
        "feed.xml",
        "feed-*.xml",
        "site/*.html",
        "site/**/*.html",
        "site/**/*_cover.*",
        "site/style.css",
        "site/custom.css",
        "site/favicon.*"
      ]
      includes << @config.image if @config.image

      args = ["rclone", "sync", source_dir, dest]
      includes.each { |f| args.push("--include", f) }
      args.push("--dry-run") if @options[:dry_run]
      args.push("-v") if @options[:verbosity] == :verbose
      args.push("--progress") unless @options[:verbosity] == :quiet

      rclone_env = {
        "RCLONE_CONFIG_R2_TYPE" => "s3",
        "RCLONE_CONFIG_R2_PROVIDER" => "Cloudflare",
        "RCLONE_CONFIG_R2_ACCESS_KEY_ID" => ENV["R2_ACCESS_KEY_ID"],
        "RCLONE_CONFIG_R2_SECRET_ACCESS_KEY" => ENV["R2_SECRET_ACCESS_KEY"],
        "RCLONE_CONFIG_R2_ENDPOINT" => ENV["R2_ENDPOINT"],
        "RCLONE_CONFIG_R2_ACL" => "private"
      }

      puts "Syncing #{source_dir} → #{dest}" unless @options[:verbosity] == :quiet
      puts "(dry run)" if @options[:dry_run] && @options[:verbosity] != :quiet

      success = system(rclone_env, *args)

      unless success
        $stderr.puts "rclone failed."
        return 1
      end

      unless @options[:verbosity] == :quiet
        if @config.base_url
          puts "Feed URL: #{@config.base_url}/feed.xml"
          puts "Site URL: #{@config.base_url}/site/index.html"
        else
          puts "Done. Set base_url in guidelines.md to see feed URL."
        end
      end

      0
    end

    def publish_to_lingq
      unless @config.lingq_enabled?
        $stderr.puts "LingQ not configured. Add ## LingQ section with collection to guidelines.md and set LINGQ_API_KEY."
        return 2
      end

      unless @config.transcription_language
        $stderr.puts "Transcription language not configured. Add language to ## Audio section in guidelines.md."
        return 2
      end

      lc = @config.lingq_config
      collection = lc[:collection]
      episodes = scan_episodes
      uploaded = @options[:force] ? {} : upload_tracker.entries_for(:lingq, collection)

      pending = episodes.reject { |ep| uploaded.key?(ep[:base_name]) }

      if pending.empty?
        puts "All episodes already uploaded to LingQ collection #{collection}." unless @options[:verbosity] == :quiet
        return 0
      end

      puts "#{pending.length} episode(s) to upload to LingQ collection #{collection}" unless @options[:verbosity] == :quiet

      if @options[:dry_run]
        pending.each { |ep| puts "  would upload: #{ep[:base_name]}" } unless @options[:verbosity] == :quiet
        puts "(dry run)" unless @options[:verbosity] == :quiet
        return 0
      end

      require_relative File.join(File.expand_path("../..", __dir__), "lib", "agents", "lingq_agent")
      require_relative File.join(File.expand_path("../..", __dir__), "lib", "agents", "cover_agent")

      agent = LingQAgent.new(api_key: @config.lingq_config&.[](:token))
      language = @config.transcription_language

      pending.each do |ep|
        title, description, transcript = parse_transcript(ep[:transcript_path])
        image_path = find_episode_cover(ep[:base_name]) || generate_cover_image(title, description: description)

        puts "  uploading: #{ep[:base_name]} — \"#{title}\"" unless @options[:verbosity] == :quiet

        lesson_id = agent.upload(
          title: title,
          text: transcript,
          audio_path: ep[:mp3_path],
          language: language,
          collection: collection,
          level: lc[:level],
          tags: lc[:tags],
          image_path: image_path,
          accent: lc[:accent],
          status: lc[:status],
          description: description
        )

        upload_tracker.record(:lingq, collection, ep[:base_name], lesson_id)

        puts "  ✓ #{ep[:base_name]} → lesson #{lesson_id}" unless @options[:verbosity] == :quiet
      rescue => e
        $stderr.puts "  ✗ #{ep[:base_name]} failed: #{e.message}"
        # Continue with remaining episodes
      ensure
        cleanup_cover(image_path)
      end

      0
    end

    def publish_to_youtube
      unless @config.youtube_enabled?
        $stderr.puts "YouTube not configured. Add ## YouTube section to guidelines.md and set YOUTUBE_CLIENT_ID/YOUTUBE_CLIENT_SECRET."
        return 2
      end

      yt_config = @config.youtube_config
      playlist = yt_config[:playlist] || "default"
      language = @config.transcription_language || "en"

      episodes = scan_episodes
      uploaded = @options[:force] ? {} : upload_tracker.entries_for(:youtube, playlist)
      pending = episodes.reject { |ep| uploaded.key?(ep[:base_name]) }

      if pending.empty?
        puts "All episodes already uploaded to YouTube#{yt_config[:playlist] ? " playlist #{yt_config[:playlist]}" : ""}." unless @options[:verbosity] == :quiet
        return 0
      end

      puts "#{pending.length} episode(s) to upload to YouTube" unless @options[:verbosity] == :quiet

      if @options[:dry_run]
        pending.each { |ep| puts "  would upload: #{ep[:base_name]}" } unless @options[:verbosity] == :quiet
        puts "(dry run)" unless @options[:verbosity] == :quiet
        return 0
      end

      # Lazy require to avoid loading google-apis gems unless YouTube is used
      require_relative File.join(File.expand_path("../..", __dir__), "lib", "youtube_uploader")
      require_relative File.join(File.expand_path("../..", __dir__), "lib", "subtitle_generator")
      require_relative File.join(File.expand_path("../..", __dir__), "lib", "video_generator")

      uploader = YouTubeUploader.new

      pending.each do |ep|
        title, description, _transcript = parse_transcript(ep[:transcript_path])
        episodes_dir = @config.episodes_dir

        # Generate timestamps via retranscription if missing, then SRT
        ts_path = File.join(episodes_dir, "#{ep[:base_name]}_timestamps.json")
        retranscribe_for_timestamps(ep[:mp3_path], ts_path, ep[:base_name]) unless File.exist?(ts_path)
        srt_path = File.join(episodes_dir, "#{ep[:base_name]}.srt")
        SubtitleGenerator.generate_srt(ts_path, srt_path) if File.exist?(ts_path) && !File.exist?(srt_path)

        # Generate video if not already present
        video_path = File.join(episodes_dir, "#{ep[:base_name]}.mp4")
        unless File.exist?(video_path)
          cover_path = find_episode_cover(ep[:base_name])
          unless cover_path
            $stderr.puts "  ✗ #{ep[:base_name]} skipped: no cover image found"
            next
          end
          puts "  generating video #{ep[:base_name]}..." unless @options[:verbosity] == :quiet
          VideoGenerator.new.generate(ep[:mp3_path], cover_path, video_path)
        end

        puts "  uploading: #{ep[:base_name]} — \"#{title}\"" unless @options[:verbosity] == :quiet

        video_id = uploader.upload_video(
          video_path,
          title: title,
          description: description.to_s,
          language: language,
          privacy: yt_config[:privacy] || "unlisted",
          category: yt_config[:category] || "27",
          tags: yt_config[:tags] || []
        )

        uploader.upload_captions(video_id, srt_path, language: language) if File.exist?(srt_path)
        uploader.add_to_playlist(video_id, yt_config[:playlist]) if yt_config[:playlist]

        upload_tracker.record(:youtube, playlist, ep[:base_name], video_id)

        puts "  ✓ #{ep[:base_name]} → https://youtu.be/#{video_id}" unless @options[:verbosity] == :quiet
      rescue Google::Apis::ClientError => e
        $stderr.puts "  ✗ #{ep[:base_name]} failed: #{e.message}"
        if e.message.include?("uploadLimitExceeded") || e.message.include?("quotaExceeded")
          $stderr.puts "  YouTube quota exceeded — stopping batch. Retry after quota resets."
          break
        end
      rescue => e
        $stderr.puts "  ✗ #{ep[:base_name]} failed: #{e.message}"
      end

      0
    end

    # Scans episodes dir for mp3 files that have matching transcripts.
    # Returns array of { base_name:, mp3_path:, transcript_path: } sorted chronologically.
    # When @episode_id is set, filters to matching episodes only.
    def scan_episodes
      episodes_dir = @config.episodes_dir
      return [] unless Dir.exist?(episodes_dir)

      all = Dir.glob(File.join(episodes_dir, "*.mp3"))
        .sort
        .filter_map do |mp3_path|
          base_name = File.basename(mp3_path, ".mp3")
          transcript_path = File.join(episodes_dir, "#{base_name}_transcript.md")
          next unless File.exist?(transcript_path)

          { base_name: base_name, mp3_path: mp3_path, transcript_path: transcript_path }
        end

      all.reverse! if @options[:newest]

      return all unless @episode_id

      matched = all.select { |ep| ep[:base_name].end_with?(@episode_id) }
      if matched.empty?
        $stderr.puts "No episode found matching '#{@episode_id}'"
      end
      matched
    end

    # Parses a transcript markdown file.
    # Returns [title, description, transcript_text]
    def parse_transcript(path)
      content = File.read(path)
      lines = content.lines

      # Title from first line: "# Title"
      title = lines.first&.strip&.sub(/^#\s+/, "") || "Untitled"

      # Find ## Transcript heading
      transcript_idx = lines.index { |l| l.strip.match?(/^## Transcript/) }

      if transcript_idx
        # Description is between title and ## Transcript (skip blank lines)
        desc_lines = lines[1...transcript_idx].map(&:strip).reject(&:empty?)
        description = desc_lines.join("\n")
        description = nil if description.empty?

        # Transcript text is everything after ## Transcript, excluding ## Vocabulary
        transcript = lines[(transcript_idx + 1)..].join
        transcript = transcript.split("## Vocabulary", 2).first.strip
      else
        description = nil
        transcript = lines[1..].join.strip
      end

      [title, description, transcript]
    end

    # Check for a per-episode cover saved by generate --image
    def find_episode_cover(base_name)
      pattern = File.join(@config.episodes_dir, "#{base_name}_cover.*")
      covers = Dir.glob(pattern)
      covers.first
    end

    def generate_cover_image(title, description: nil)
      return @config.cover_static_image unless @config.cover_generation_enabled?

      base_image = @config.cover_base_image

      cover_path = File.join(Dir.tmpdir, "podgen_cover_publish_#{Process.pid}.jpg")

      agent = CoverAgent.new
      agent.generate(
        title: title,
        base_image: base_image,
        output_path: cover_path,
        options: @config.cover_options
      )

      cover_path
    rescue => e
      $stderr.puts "  Warning: cover generation failed: #{e.message} (using static image)" if @options[:verbosity] == :verbose
      @config.cover_static_image
    end

    def cleanup_cover(image_path)
      return unless image_path
      return unless image_path.start_with?(Dir.tmpdir)

      File.delete(image_path) if File.exist?(image_path)
    rescue # rubocop:disable Lint/SuppressedException
    end

    # Retranscribe a final MP3 to generate timestamps for old episodes
    # that were created before timestamp persistence was added.
    def retranscribe_for_timestamps(mp3_path, ts_path, base_name)
      language = @config.transcription_language
      unless language
        puts "  ⚠ #{base_name}: no transcription language configured, skipping subtitles" unless @options[:verbosity] == :quiet
        return
      end

      engine_code = pick_timestamp_engine
      unless engine_code
        puts "  ⚠ #{base_name}: no transcription engine configured, skipping subtitles" unless @options[:verbosity] == :quiet
        return
      end

      puts "  transcribing #{base_name} for subtitles (#{engine_code})..." unless @options[:verbosity] == :quiet

      require_relative File.join(File.expand_path("../..", __dir__), "lib", "transcription", "engine_manager")
      require_relative File.join(File.expand_path("../..", __dir__), "lib", "timestamp_persister")

      manager = Transcription::EngineManager.new(
        engine_codes: [engine_code],
        language: language,
        target_language: @config.target_language
      )
      result = manager.transcribe(mp3_path)
      segments, engine_code = TimestampPersister.extract_segments(result, engine_codes: [engine_code])

      if segments && !segments.empty?
        TimestampPersister.persist(
          segments: segments,
          engine: engine_code,
          intro_duration: 0.0,
          output_path: ts_path
        )
      else
        puts "  ⚠ #{base_name}: transcription returned no segments" unless @options[:verbosity] == :quiet
      end
    rescue => e
      # Non-fatal: video uploads proceed without subtitles
      $stderr.puts "  ⚠ #{base_name}: retranscription failed (#{e.message}), uploading without subtitles"
    end

    # Pick the best transcription engine for timestamps.
    # Groq has word-level, ElevenLabs has word-level, OpenAI has segment-level.
    TIMESTAMP_ENGINE_PRIORITY = %w[groq elab open].freeze

    def pick_timestamp_engine
      configured = @config.transcription_engines
      TIMESTAMP_ENGINE_PRIORITY.find { |e| configured.include?(e) } || configured.first
    end

    def upload_tracker
      @upload_tracker ||= UploadTracker.for_config(@config)
    end

    def rclone_available?
      _out, _err, status = Open3.capture3("rclone", "--version")
      status.success?
    rescue Errno::ENOENT
      false
    end
  end
end
