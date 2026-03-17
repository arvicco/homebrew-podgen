# frozen_string_literal: true

require "yaml"
require "date"
require_relative "episode_filtering"

# Validates podcast configuration and output.
# Returns structured results (passes, warnings, errors) for programmatic use.
# Used by ValidateCommand (CLI) and available for testing/CI integration.
class PodcastValidator
  KNOWN_SOURCES = %w[exa hackernews rss claude_web bluesky x].freeze

  Result = Struct.new(:passes, :warnings, :errors, keyword_init: true) do
    def ok? = errors.empty?
    def clean? = errors.empty? && warnings.empty?
  end

  # Validate a podcast config. Returns a Result.
  def self.validate(config)
    v = new(config)
    v.run
  end

  def initialize(config)
    @config = config
    @passes = []
    @warnings = []
    @errors = []
  end

  def run
    check_guidelines
    check_episodes
    check_transcripts
    check_feed
    check_cover
    check_base_url
    check_history
    check_image_config

    if @config.type == "language"
      check_language_pipeline
    else
      check_news_pipeline
    end

    check_orphans

    Result.new(passes: @passes, warnings: @warnings, errors: @errors)
  end

  private

  def check_guidelines
    unless File.exist?(@config.guidelines_path)
      @errors << "Guidelines: guidelines.md not found"
      return
    end

    text = @config.guidelines

    required = %w[Format Tone]
    required << "Topics" if @config.type == "news"

    missing = required.select { |s| !text.match?(/^## #{Regexp.escape(s)}\b/m) }
    if missing.empty?
      @passes << "Guidelines: all required sections present"
    else
      @errors << "Guidelines: missing required sections: #{missing.join(', ')}"
    end

    @config.sources.each_key do |key|
      unless KNOWN_SOURCES.include?(key)
        @warnings << "Guidelines: unrecognized source '#{key}'"
      end
    end

    if @config.type == "news" && File.exist?(@config.queue_path)
      begin
        data = YAML.load_file(@config.queue_path)
        unless data.is_a?(Hash) && data["topics"].is_a?(Array)
          @warnings << "Guidelines: queue.yml has unexpected format"
        end
      rescue => e
        @warnings << "Guidelines: queue.yml parse error: #{e.message}"
      end
    end
  end

  def check_episodes
    episodes_dir = @config.episodes_dir
    unless Dir.exist?(episodes_dir)
      @warnings << "Episodes: directory not found (no episodes generated yet?)"
      return
    end

    mp3s = EpisodeFiltering.all_episodes(episodes_dir)

    if mp3s.empty?
      @warnings << "Episodes: no MP3 files found"
      return
    end

    zero_byte = mp3s.select { |f| File.size(f) == 0 }
    unless zero_byte.empty?
      @errors << "Episodes: #{zero_byte.length} zero-byte MP3 file#{'s' unless zero_byte.length == 1}"
    end

    name_pattern = /^#{Regexp.escape(@config.name)}-\d{4}-\d{2}-\d{2}[a-z]?(-[a-z]{2})?\.mp3$/
    bad_names = mp3s.reject { |f| File.basename(f).match?(name_pattern) }
    unless bad_names.empty?
      @warnings << "Episodes: #{bad_names.length} file#{'s' unless bad_names.length == 1} with unexpected naming"
    end

    total_size = mp3s.sum { |f| File.size(f) rescue 0 }
    avg_size = total_size / mp3s.length
    @passes << "Episodes: #{mp3s.length} MP3 files (#{format_size(avg_size)} avg)"
  end

  def check_transcripts
    episodes_dir = @config.episodes_dir
    return unless Dir.exist?(episodes_dir)

    mp3s = EpisodeFiltering.all_episodes(episodes_dir)
    return if mp3s.empty?

    missing_md = 0
    missing_html = 0

    mp3s.each do |mp3|
      base = File.basename(mp3, ".mp3")
      has_md = File.exist?(File.join(episodes_dir, "#{base}_script.md")) ||
               File.exist?(File.join(episodes_dir, "#{base}_transcript.md"))
      has_html = File.exist?(File.join(episodes_dir, "#{base}_script.html")) ||
                 File.exist?(File.join(episodes_dir, "#{base}_transcript.html"))
      missing_md += 1 unless has_md
      missing_html += 1 unless has_html
    end

    if missing_md == 0
      @passes << "Transcripts: #{mp3s.length}/#{mp3s.length} episodes have transcripts"
    else
      @warnings << "Transcripts: #{missing_md}/#{mp3s.length} episodes missing transcript/script"
    end

    if missing_html > 0
      @warnings << "Transcripts: #{missing_html} episodes missing HTML version (run podgen rss)"
    end
  end

  def check_feed
    unless File.exist?(@config.feed_path)
      @warnings << "Feed: feed.xml not found (run podgen rss)"
      return
    end

    require "rexml/document"
    begin
      doc = REXML::Document.new(File.read(@config.feed_path))
      items = doc.elements.to_a("//item")

      mp3_count = EpisodeFiltering.english_episodes(@config.episodes_dir).length

      if items.length == mp3_count
        @passes << "Feed: well-formed XML, #{items.length} episodes"
      elsif items.length > 0
        @warnings << "Feed: #{items.length} episodes in feed vs #{mp3_count} MP3s (stale feed?)"
      else
        @warnings << "Feed: well-formed XML but no episodes"
      end
    rescue REXML::ParseException => e
      @errors << "Feed: XML parse error: #{e.message.lines.first&.strip}"
    end

    if @config.languages.length > 1
      @config.languages.each do |lang|
        code = lang["code"]
        next if code == "en"
        lang_feed = @config.feed_path.sub(/\.xml$/, "-#{code}.xml")
        unless File.exist?(lang_feed)
          @warnings << "Feed: missing feed-#{code}.xml for language '#{code}'"
        end
      end
    end
  end

  def check_cover
    unless @config.image
      @warnings << "Cover: no image configured in guidelines"
      return
    end

    output_dir = File.dirname(@config.episodes_dir)
    output_cover = File.join(output_dir, @config.image)
    source_cover = File.join(@config.podcast_dir, @config.image)

    if File.exist?(output_cover)
      size = File.size(output_cover)
      if size < 10_000
        @warnings << "Cover: #{@config.image} is very small (#{format_size(size)})"
      elsif size > 5_000_000
        @warnings << "Cover: #{@config.image} is very large (#{format_size(size)})"
      else
        @passes << "Cover: #{@config.image} (#{format_size(size)})"
      end
    elsif File.exist?(source_cover)
      @warnings << "Cover: #{@config.image} only in podcasts/ dir (run podgen rss to copy)"
    else
      @errors << "Cover: #{@config.image} not found"
    end
  end

  def check_base_url
    unless @config.base_url
      @warnings << "Base URL: not configured"
      return
    end

    if @config.base_url.match?(%r{^https?://})
      @passes << "Base URL: #{@config.base_url}"
    else
      @errors << "Base URL: '#{@config.base_url}' does not start with http:// or https://"
    end
  end

  def check_history
    unless File.exist?(@config.history_path)
      @warnings << "History: history.yml not found"
      return
    end

    begin
      entries = YAML.load_file(@config.history_path)
      unless entries.is_a?(Array)
        @errors << "History: unexpected format (expected array)"
        return
      end

      bad_entries = entries.reject { |e|
        e.is_a?(Hash) && e["date"] && e["title"] && e["topics"]
      }
      unless bad_entries.empty?
        @warnings << "History: #{bad_entries.length} entries missing date/title/topics"
      end

      if Dir.exist?(@config.episodes_dir)
        mp3_count = EpisodeFiltering.english_episodes(@config.episodes_dir).length

        if entries.length == mp3_count
          @passes << "History: #{entries.length} entries"
        else
          @warnings << "History: entry count (#{entries.length}) differs from episode count (#{mp3_count})"
        end
      else
        @passes << "History: #{entries.length} entries"
      end
    rescue => e
      @errors << "History: parse error: #{e.message}"
    end
  end

  def check_image_config
    checked = false

    base_image = @config.cover_base_image
    if base_image && base_image != :auto
      checked = true
      if File.exist?(base_image)
        @passes << "Image: base_image exists (#{File.basename(base_image)})"
      else
        @errors << "Image: base_image not found: #{base_image}"
      end
    end

    rss_feeds = @config.sources["rss"]
    if rss_feeds.is_a?(Array)
      rss_feeds.each do |feed|
        next unless feed.is_a?(Hash) && feed[:base_image]
        checked = true
        if File.exist?(feed[:base_image])
          @passes << "Image: per-feed base_image exists (#{File.basename(feed[:base_image])})"
        else
          url = feed[:url] || "unknown"
          @errors << "Image: per-feed base_image not found for #{url}: #{feed[:base_image]}"
        end
      end
    end

    @passes << "Image: no base_image paths to check" unless checked
  end

  def check_language_pipeline
    engines = @config.transcription_engines
    if engines.empty?
      @warnings << "Language: no transcription engines configured"
    else
      @passes << "Language: engines #{engines.join(', ')}"
    end

    if engines.length >= 2 && engines.include?("groq")
      tails_dir = File.join(File.dirname(@config.episodes_dir), "tails")
      unless Dir.exist?(tails_dir)
        @warnings << "Language: tails/ directory missing (expected for multi-engine+groq)"
      end
    end

    if @config.lingq_config
      lc = @config.lingq_config
      if lc[:image] && !File.exist?(lc[:image])
        @warnings << "LingQ: image file not found: #{lc[:image]}"
      end
      if lc[:base_image] && !File.exist?(lc[:base_image])
        @warnings << "LingQ: base_image file not found: #{lc[:base_image]}"
      end
    end
  end

  def check_news_pipeline
    if File.exist?(@config.queue_path)
      @passes << "News: queue.yml present"
    else
      @warnings << "News: queue.yml not found (no fallback topics)"
    end
  end

  def check_orphans
    episodes_dir = @config.episodes_dir
    return unless Dir.exist?(episodes_dir)

    mp3_bases = Dir.glob(File.join(episodes_dir, "*.mp3"))
      .reject { |f| File.basename(f).include?("_concat") }
      .map { |f| File.basename(f, ".mp3") }
      .to_set

    orphan_texts = Dir.glob(File.join(episodes_dir, "*_{transcript,script}.{md,html}"))
      .select { |f|
        base = File.basename(f).sub(/_(transcript|script)\.(md|html)$/, "")
        !mp3_bases.include?(base)
      }

    unless orphan_texts.empty?
      @warnings << "Orphans: #{orphan_texts.length} transcript/script file#{'s' unless orphan_texts.length == 1} without matching MP3"
    end

    concat_files = Dir.glob(File.join(episodes_dir, "*_concat*"))
    unless concat_files.empty?
      @warnings << "Orphans: #{concat_files.length} stale _concat file#{'s' unless concat_files.length == 1}"
    end
  end

  def format_size(bytes)
    if bytes >= 1_000_000_000
      format("%.1f GB", bytes / 1_000_000_000.0)
    elsif bytes >= 1_000_000
      format("%.1f MB", bytes / 1_000_000.0)
    elsif bytes >= 1_000
      format("%d KB", (bytes / 1_000.0).round)
    else
      "#{bytes} B"
    end
  end
end
