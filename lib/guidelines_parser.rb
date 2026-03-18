# frozen_string_literal: true

require_relative "time_value"

# Parses guidelines.md sections into structured config hashes.
# Extracted from PodcastConfig to isolate parsing logic.
class GuidelinesParser
  def initialize(text, podcast_dir:)
    @text = text.gsub(/<!--.*?-->/m, "")
    @podcast_dir = podcast_dir
  end

  def podcast_section
    @podcast_section ||= parse_podcast_section
  end

  def audio_section
    @audio_section ||= parse_audio_section
  end

  def image_section
    @image_section ||= parse_image_section
  end

  def sources
    @sources ||= parse_sources_section
  end

  def site_config
    @site_config ||= parse_site_section
  end

  def lingq_config
    @lingq_config ||= parse_lingq_section
  end

  def links_config
    @links_config ||= parse_links_section
  end

  def vocabulary_config
    @vocabulary_config ||= parse_vocabulary_section
  end

  def languages
    @languages ||= podcast_section[:languages] || parse_language_section
  end

  def transcription_engines
    @transcription_engines ||= audio_section[:engines] || parse_transcription_engine_section
  end

  # Extracts the first line of content under a ## heading
  def extract_heading(heading)
    match = @text.match(/^## #{Regexp.escape(heading)}\s*\n(.+?)(?:\n|$)/)
    match ? match[1].strip : nil
  end

  # Comment-stripped guidelines text (for external consumers like ScriptAgent)
  def text
    @text
  end

  private

  # Extracts the body text under a ## heading, up to the next heading or EOF.
  def extract_section(heading)
    match = @text.match(/^## #{Regexp.escape(heading)}\s*\n(.*?)(?=^## |\z)/m)
    match ? match[1] : nil
  end

  def resolve_path(value)
    return value if value.start_with?("/")
    File.join(@podcast_dir, value)
  end

  def sanitize_css(value)
    value.gsub(/[;{}]/, "")
  end

  # Shared iterator for flat key-value sections.
  # Yields (key, value) for each "- key: value" line.
  # Returns nil when the section is missing, otherwise the accumulated config hash.
  def parse_kv_section(heading)
    body = extract_section(heading)
    return nil unless body

    config = {}
    body.each_line do |line|
      next unless line.match?(/^- \S/)
      item = line.strip.sub(/^- /, "")
      if item.include?(":")
        key, value = item.split(":", 2)
        result = yield(key.strip, value.strip)
        config.merge!(result) if result
      else
        result = yield(item.strip, nil)
        config.merge!(result) if result
      end
    end
    config
  end

  # --- Section parsers ---

  def parse_podcast_section
    body = extract_section("Podcast")
    return {} unless body

    config = {}
    current_key = nil

    body.each_line do |line|
      if line.match?(/^- \S/)
        item = line.strip.sub(/^- /, "")
        if item.include?(":")
          key, value = item.split(":", 2)
          key = key.strip
          value = value.strip
          if value.empty?
            current_key = key
          else
            current_key = nil
            config[key.to_sym] = value
          end
        end
      elsif current_key == "language" && line.match?(/^\s+- \S/)
        entry = line.strip.sub(/^- /, "").strip
        config[:languages] ||= []
        if entry.include?(":")
          code, voice_id = entry.split(":", 2).map(&:strip)
          config[:languages] << { "code" => code, "voice_id" => voice_id }
        else
          config[:languages] << { "code" => entry }
        end
      end
    end

    config
  end

  def parse_audio_section
    body = extract_section("Audio")
    return {} unless body

    config = {}
    current_key = nil

    body.each_line do |line|
      if line.match?(/^- \S/)
        item = line.strip.sub(/^- /, "")
        if item.include?(":")
          key, value = item.split(":", 2)
          key = key.strip
          value = value.strip
          if value.empty?
            current_key = key
          else
            current_key = nil
            case key
            when "skip"
              config[:skip] = TimeValue.parse(value)
            when "cut"
              config[:cut] = TimeValue.parse(value)
            when "autotrim"
              config[:autotrim] = true
            else
              config[key.to_sym] = value
            end
          end
        elsif item.strip == "autotrim"
          config[:autotrim] = true
        end
      elsif current_key == "engine" && line.match?(/^\s+- \S/)
        entry = line.strip.sub(/^- /, "").strip
        config[:engines] ||= []
        config[:engines] << entry unless entry.empty?
      end
    end

    config
  end

  def parse_image_section
    parse_kv_section("Image") do |key, value|
      case key
      when "cover"         then { cover: value }
      when "image"         then { image: value }
      when "base_image"    then { base_image: resolve_path(value) }
      when "font"          then { font: value }
      when "font_color"    then { font_color: value }
      when "font_size"     then { font_size: value.to_i }
      when "text_width"    then { text_width: value.to_i }
      when "text_gravity"  then { text_gravity: value }
      when "text_x_offset" then { text_x_offset: value.to_i }
      when "text_y_offset" then { text_y_offset: value.to_i }
      end
    end || {}
  end

  def parse_site_section
    parse_kv_section("Site") do |key, value|
      case key
      when "accent", "accent_dark", "bg", "bg_dark", "radius", "max_width"
        { key.to_sym => sanitize_css(value) }
      when "footer"
        { footer: value }
      when "show_duration", "show_transcript"
        { key.to_sym => value != "false" }
      end
    end || {}
  end

  def parse_language_section
    default = [{ "code" => "en" }]

    body = extract_section("Language")
    return default unless body

    languages = []
    body.each_line do |line|
      line = line.strip
      next unless line.start_with?("- ")

      entry = line.sub(/^- /, "").strip
      if entry.include?(":")
        code, voice_id = entry.split(":", 2).map(&:strip)
        languages << { "code" => code, "voice_id" => voice_id }
      else
        languages << { "code" => entry }
      end
    end

    languages.empty? ? default : languages
  end

  def parse_transcription_engine_section
    default = ["open"]

    body = extract_section("Transcription Engine")
    return default unless body

    engines = []
    body.each_line do |line|
      line = line.strip
      next unless line.start_with?("- ")

      code = line.sub(/^- /, "").strip
      engines << code unless code.empty?
    end

    engines.empty? ? default : engines
  end

  def parse_lingq_section
    config = parse_kv_section("LingQ") do |key, value|
      case key
      when "collection"  then { collection: value.to_i }
      when "level"       then { level: value.to_i }
      when "tags"        then { tags: value.split(",").map(&:strip) }
      when "image"       then { image: resolve_path(value) }
      when "base_image"  then { base_image: resolve_path(value) }
      when "font"        then { font: value }
      when "font_color"  then { font_color: value }
      when "font_size"   then { font_size: value.to_i }
      when "text_width"  then { text_width: value.to_i }
      when "text_gravity" then { text_gravity: value }
      when "text_x_offset" then { text_x_offset: value.to_i }
      when "text_y_offset" then { text_y_offset: value.to_i }
      when "accent"      then { accent: value }
      when "status"      then { status: value }
      end
    end
    return nil if config.nil? || config.empty?
    config
  end

  def parse_vocabulary_section
    config = parse_kv_section("Vocabulary") do |key, value|
      case key
      when "level"
        level = value.upcase
        { level: level } if %w[A1 A2 B1 B2 C1 C2].include?(level)
      end
    end
    return nil if config.nil? || config.empty?
    config
  end

  def parse_links_section
    config = parse_kv_section("Links") do |key, value|
      case key
      when "show" then { show: value == "true" }
      end
    end
    config&.dig(:show) ? config : nil
  end

  def parse_sources_section
    default = { "exa" => true }

    body = extract_section("Sources")
    return default unless body

    sources = {}
    current_key = nil

    body.each_line do |line|
      # Top-level item: "- name", "- name:", or "- name: val1, val2"
      if line.match?(/^- \S/)
        item = line.strip.sub(/^- /, "")
        if item.include?(":")
          key, value = item.split(":", 2)
          current_key = key.strip
          inline = value.strip
          if inline.empty?
            # "- name:" with sub-list to follow
            sources[current_key] = []
          else
            # "- name: val1, val2" inline comma-separated
            current_key = nil
            sources[key.strip] = inline.split(",").map(&:strip)
          end
        else
          current_key = nil
          sources[item] = true
        end
      # Sub-item: "  - value" (indented under a key with colon)
      elsif current_key && line.match?(/^\s+- \S/)
        value = line.strip.sub(/^- /, "")
        sources[current_key] << parse_source_item(current_key, value)
      end
    end

    sources.empty? ? default : sources
  end

  # Parses inline key-value options from a source sub-item.
  # "https://example.com/feed skip: 38 cut: 10" → { url: "https://...", skip: 38.0, cut: 10.0 }
  # "https://example.com/feed autotrim" → { url: "https://...", autotrim: true }
  # "https://example.com/feed" → "https://example.com/feed" (plain string, backward compatible)
  # Only applies to "rss" sources; other sources return the value as-is.
  def parse_source_item(source_key, value)
    return value unless source_key == "rss"

    # Check for inline options: "URL key: val ..." or "URL flag ..."
    # Split on whitespace before "key:" or known bare flags (autotrim)
    # Use [a-z_] to avoid matching min:sec timestamps like "1:20"
    parts = value.split(/\s+(?=[a-z_]\w*:|\bautotrim\b)/, -1)
    return value if parts.length == 1

    url = parts.shift
    options = {}
    parts.each do |part|
      # Handle bare flags (no colon)
      if part.strip == "autotrim"
        options[:autotrim] = true
        next
      end
      k, v = part.split(":", 2)
      next unless k && v
      k = k.strip
      v = v.strip
      case k
      when "skip" then options[:skip] = TimeValue.parse(v)
      when "cut" then options[:cut] = TimeValue.parse(v)
      when "autotrim" then options[:autotrim] = true
      when "base_image" then options[:base_image] = resolve_path(v)
      when "image" then options[:image] = v
      end
    end

    return url if options.empty?

    { url: url }.merge(options)
  end
end
