# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require "optparse"
require "fileutils"
require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "logger")
require_relative File.join(root, "lib", "agents", "translation_agent")
require_relative File.join(root, "lib", "agents", "tts_agent")
require_relative File.join(root, "lib", "audio_assembler")
require_relative File.join(root, "lib", "rss_generator")

module PodgenCLI
  class TranslateCommand
    def initialize(args, options)
      @options = options
      @last_n = nil
      @lang_filter = nil

      OptionParser.new do |opts|
        opts.on("--last N", Integer, "Only translate the N most recent episodes") { |n| @last_n = n }
        opts.on("--lang LANG", "Only translate to this language (e.g. it)") { |l| @lang_filter = l }
        opts.on("--dry-run", "Show what would be translated") { @options[:dry_run] = true }
      end.parse!(args)

      @podcast_name = args.shift
    end

    def run
      unless @podcast_name
        available = PodcastConfig.available
        $stderr.puts "Usage: podgen translate <podcast>"
        $stderr.puts
        if available.any?
          $stderr.puts "Available podcasts:"
          available.each { |name| $stderr.puts "  - #{name}" }
        end
        return 2
      end

      config = PodcastConfig.new(@podcast_name)
      config.load_env!

      logger = PodcastAgent::Logger.new(log_path: config.log_path(Date.today), verbosity: @options[:verbosity])
      logger.log("Translate started for '#{@podcast_name}'")

      # Resolve target languages (exclude English)
      languages = config.languages.reject { |l| l["code"] == "en" }

      if @lang_filter
        languages = languages.select { |l| l["code"] == @lang_filter }
        if languages.empty?
          $stderr.puts "Language '#{@lang_filter}' not found in config. Available: #{config.languages.map { |l| l['code'] }.join(', ')}"
          return 2
        end
      end

      if languages.empty?
        $stderr.puts "No non-English languages configured for '#{@podcast_name}'"
        return 2
      end

      # Discover English episodes with _script.md files
      episodes = discover_episodes(config.episodes_dir)
      if episodes.empty?
        logger.log("No English episodes found in #{config.episodes_dir}")
        return 0
      end

      # Apply --last N limit
      episodes = episodes.last(@last_n) if @last_n

      # Find pending translations
      pending = pending_translations(episodes, languages, config.episodes_dir)

      if pending.empty?
        logger.log("All episodes already translated")
        return 0
      end

      if @options[:dry_run]
        logger.log("Pending translations for #{@podcast_name}:")
        pending.each { |p| logger.log("  #{p[:basename]} \u2192 #{p[:lang_code]}") }
        logger.log("#{pending.length} episode(s) to translate")
        return 0
      end

      # Run translation pipeline
      translated = 0
      failed = 0
      intro_path = File.join(config.podcast_dir, "intro.mp3")
      outro_path = File.join(config.podcast_dir, "outro.mp3")

      pending.each_with_index do |item, idx|
        logger.phase_start("Translate #{item[:basename]} → #{item[:lang_code]}")
        begin
          translate_episode(
            script_path: item[:script_path],
            basename: item[:basename],
            lang_code: item[:lang_code],
            voice_id: item[:voice_id],
            episodes_dir: config.episodes_dir,
            intro_path: intro_path,
            outro_path: outro_path,
            podcast_title: config.title,
            author: config.author,
            pronunciation_pls_path: config.pronunciation_pls_path,
            logger: logger
          )
          translated += 1
          logger.phase_end("Translate #{item[:basename]} → #{item[:lang_code]}")
          logger.log("Done (#{idx + 1}/#{pending.length})")
        rescue => e
          failed += 1
          logger.error("Translation failed for #{item[:basename]} → #{item[:lang_code]}: #{e.message}")
          logger.error(e.backtrace.first) if @options[:verbosity] == :verbose
        end
      end

      logger.log("Translated #{translated} episode(s), #{failed} failed")

      # Regenerate RSS feeds
      regenerate_rss(config, logger)

      translated > 0 ? 0 : 1
    end

    private

    # Finds English episodes that have both _script.md and .mp3 files.
    # Excludes language-suffixed scripts (e.g. *-it_script.md) and
    # orphaned scripts without a corresponding English MP3.
    def discover_episodes(episodes_dir)
      Dir.glob(File.join(episodes_dir, "*_script.md"))
        .reject { |f| File.basename(f).match?(/-[a-z]{2}_script\.md$/) }
        .select { |f| File.exist?(f.sub(/_script\.md$/, ".mp3")) }
        .sort
        .map do |path|
          basename = File.basename(path, "_script.md")
          { script_path: path, basename: basename }
        end
    end

    # Returns array of { script_path:, basename:, lang_code:, voice_id: }
    # for episodes that don't yet have a translated MP3.
    def pending_translations(episodes, languages, episodes_dir)
      pending = []
      episodes.each do |ep|
        languages.each do |lang|
          lang_code = lang["code"]
          mp3_path = File.join(episodes_dir, "#{ep[:basename]}-#{lang_code}.mp3")
          next if File.exist?(mp3_path)

          pending << {
            script_path: ep[:script_path],
            basename: ep[:basename],
            lang_code: lang_code,
            voice_id: lang["voice_id"]
          }
        end
      end
      pending
    end

    def translate_episode(script_path:, basename:, lang_code:, voice_id:, episodes_dir:, intro_path:, outro_path:, podcast_title:, author:, pronunciation_pls_path: nil, logger: nil)
      script = parse_script(script_path)

      # Translate
      translator = TranslationAgent.new(target_language: lang_code, logger: logger)
      lang_script = translator.translate(script)

      # Save translated script
      lang_script_path = File.join(episodes_dir, "#{basename}-#{lang_code}_script.md")
      save_script(lang_script, lang_script_path)

      # TTS
      tts_agent = TTSAgent.new(logger: logger, voice_id_override: voice_id, pronunciation_pls_path: pronunciation_pls_path)
      audio_paths = tts_agent.synthesize(lang_script[:segments])

      # Assemble
      output_path = File.join(episodes_dir, "#{basename}-#{lang_code}.mp3")
      assembler = AudioAssembler.new(logger: logger)
      assembler.assemble(audio_paths, output_path, intro_path: intro_path, outro_path: outro_path,
        metadata: { title: lang_script[:title], artist: author })

      # Cleanup TTS temp files
      audio_paths.each { |p| File.delete(p) if File.exist?(p) }
    end

    def parse_script(path)
      content = File.read(path)
      title = content[/^# (.+)$/, 1]
      segments = []
      content.scan(/^## (.+?)\n\n(.*?)(?=\n## |\z)/m) do |name, text|
        segments << { name: name.strip, text: text.strip }
      end
      { title: title, segments: segments }
    end

    def save_script(script, path)
      File.open(path, "w") do |f|
        f.puts "# #{script[:title]}"
        f.puts
        script[:segments].each do |seg|
          f.puts "## #{seg[:name]}"
          f.puts
          f.puts seg[:text]
          f.puts
        end
      end
    end

    def regenerate_rss(config, logger)
      logger.log("Regenerating RSS feeds...")

      # Convert markdown transcripts to HTML for podcast apps
      RssGenerator.convert_transcripts(config.episodes_dir)

      base_url = config.base_url
      feed_paths = []

      config.languages.each do |lang|
        lang_code = lang["code"]
        feed_path = lang_code == "en" ? config.feed_path : config.feed_path.sub(/\.xml$/, "-#{lang_code}.xml")

        generator = RssGenerator.new(
          episodes_dir: config.episodes_dir,
          feed_path: feed_path,
          title: config.title,
          description: config.description,
          author: config.author,
          language: lang_code,
          base_url: base_url,
          image: config.image,
          history_path: config.history_path,
          logger: logger
        )
        generator.generate
        feed_paths << feed_path
      end

      feed_paths.each { |fp| logger.log("Feed: #{fp}") }
    end

  end
end
