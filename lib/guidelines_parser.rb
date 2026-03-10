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
    body = extract_section("Image")
    return {} unless body

    config = {}
    body.each_line do |line|
      if line.match?(/^- \S/)
        item = line.strip.sub(/^- /, "")
        if item.include?(":")
          key, value = item.split(":", 2)
          key = key.strip
          value = value.strip
          case key
          when "cover"        then config[:cover] = value
          when "image"        then config[:image] = value
          when "base_image"   then config[:base_image] = resolve_path(value)
          when "font"         then config[:font] = value
          when "font_color"   then config[:font_color] = value
          when "font_size"    then config[:font_size] = value.to_i
          when "text_width"   then config[:text_width] = value.to_i
          when "text_gravity"  then config[:text_gravity] = value
          when "text_x_offset" then config[:text_x_offset] = value.to_i
          when "text_y_offset" then config[:text_y_offset] = value.to_i
          end
        end
      end
    end
    config
  end

  def parse_site_section
    body = extract_section("Site")
    return {} unless body

    config = {}
    body.each_line do |line|
      if line.match?(/^- \S/)
        item = line.strip.sub(/^- /, "")
        if item.include?(":")
          key, value = item.split(":", 2)
          key = key.strip
          value = value.strip
          case key
          when "accent", "accent_dark", "bg", "bg_dark"
            config[key.to_sym] = sanitize_css(value)
          when "radius", "max_width"
            config[key.to_sym] = sanitize_css(value)
          when "footer"
            config[:footer] = value
          when "show_duration", "show_transcript"
            config[key.to_sym] = value != "false"
          end
        end
      end
    end
    config
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
    body = extract_section("LingQ")
    return nil unless body

    config = {}
    body.each_line do |line|
      line = line.strip
      next unless line.start_with?("- ")

      entry = line.sub(/^- /, "").strip
      next unless entry.include?(":")

      key, value = entry.split(":", 2).map(&:strip)
      case key
      when "collection"
        config[:collection] = value.to_i
      when "level"
        config[:level] = value.to_i
      when "tags"
        config[:tags] = value.split(",").map(&:strip)
      when "image"
        config[:image] = resolve_path(value)
      when "base_image"
        config[:base_image] = resolve_path(value)
      when "font"
        config[:font] = value
      when "font_color"
        config[:font_color] = value
      when "font_size"
        config[:font_size] = value.to_i
      when "text_width"
        config[:text_width] = value.to_i
      when "text_gravity"
        config[:text_gravity] = value
      when "text_x_offset"
        config[:text_x_offset] = value.to_i
      when "text_y_offset"
        config[:text_y_offset] = value.to_i
      when "accent"
        config[:accent] = value
      when "status"
        config[:status] = value
      end
    end

    config.empty? ? nil : config
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
