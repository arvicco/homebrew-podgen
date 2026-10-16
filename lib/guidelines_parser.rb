# frozen_string_literal: true

require_relative "time_value"

# Parses guidelines.md sections into structured config hashes.
# Extracted from PodcastConfig to isolate parsing logic.
class GuidelinesParser
  def initialize(text, podcast_dir:)
    @text = text.gsub(/<!--.*?-->/m, "")
    @podcast_dir = podcast_dir
    @warnings = []
  end

  # Every memoized section reader. A reader that appends warnings but is
  # missing here would make those warnings invisible to early consumers —
  # keep this list in sync with the public accessors below.
  SECTION_READERS = %i[
    podcast_section audio_section image_section sources site_config
    lingq_config youtube_config twitter_config links_config
    vocabulary_config translation_glossary languages transcription_engines
  ].freeze

  # Warnings are appended during lazy section parsing, so prime every
  # memoized section before reading — otherwise a consumer that checks
  # warnings before touching the sections sees an empty list.
  def warnings
    prime!
    @warnings
  end

  # A section that raises (malformed value) becomes a warning here so that
  # `podgen validate` reports instead of crashing; the exception still
  # surfaces at real section access since failures aren't memoized.
  def prime!
    return self if @primed
    @primed = true
    SECTION_READERS.each do |reader|
      public_send(reader)
    rescue => e # skippable: recorded as a warning; real section access raises again
      @warnings << "#{reader}: unparseable — #{e.class}: #{e.message}"
    end
    self
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
    return @lingq_config if defined?(@lingq_config)
    @lingq_config = parse_lingq_section
  end

  def youtube_config
    return @youtube_config if defined?(@youtube_config)
    @youtube_config = parse_youtube_section
  end

  def twitter_config
    return @twitter_config if defined?(@twitter_config)
    @twitter_config = parse_twitter_section
  end

  def links_config
    return @links_config if defined?(@links_config)
    @links_config = parse_links_section
  end

  def vocabulary_config
    return @vocabulary_config if defined?(@vocabulary_config)
    @vocabulary_config = parse_vocabulary_section
  end

  def translation_glossary
    @translation_glossary ||= parse_translation_glossary_section
  end

  def languages
    @languages ||= podcast_section[:languages] || parse_language_section
  end

  # Engine codes EngineManager understands (lib/transcription/engine_manager.rb
  # REGISTRY). Mirrored here so the parser can validate config without
  # requiring the transcription layer; update both when adding an engine.
  KNOWN_ENGINE_CODES = %w[open elab groq].freeze

  def transcription_engines
    @transcription_engines ||= begin
      engines = audio_section[:engines] || parse_transcription_engine_section
      (engines - KNOWN_ENGINE_CODES).each do |code|
        @warnings << "Transcription Engine: unknown engine code '#{code}' (known: #{KNOWN_ENGINE_CODES.join(", ")})"
      end
      engines
    end
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
    return value if value.match?(%r{\Ahttps?://}i) # Q-50: URLs are not file paths
    File.join(@podcast_dir, value)
  end

  def sanitize_css(value)
    value.gsub(/[;{}]/, "")
  end

  # One parsed top-level list item of a section: the cleaned item text, the
  # key/value split on its first colon (value nil for a bare "- key"), and the
  # cleaned texts of the more-indented items nested under it.
  SectionItem = Struct.new(:text, :key, :value, :subs)

  BULLET = /\A([ \t]*)([-*])[ \t]+(\S.*?)\s*\z/
  # " # note" — whitespace on both sides, so "#ff0000", "#hashtag" and URL
  # fragments ("feed#section") survive.
  INLINE_COMMENT = /\s+#(?:\s.*)?\z/
  # Markdown autolink with identical halves ("[url](url)", what editors like
  # Cursor produce on paste) — unwrapped to the bare url.
  AUTOLINK = %r{\[([a-z][a-z0-9+.-]*://[^\]\s]+)\]\(\1\)}i

  # The single list walker behind every section parser (P4-7). Returns nil
  # when the section is missing, otherwise its top-level items in order.
  # Any indentation and extra spaces after "-" are accepted; an item more
  # indented than the preceding top-level item is a sub-item of it;
  # non-bullet lines are skipped. A "* " bullet is not an item: it is
  # dropped silently together with anything nested under it.
  def section_items(heading)
    body = extract_section(heading)
    return nil unless body

    items = []
    top_indent = nil
    parent = nil
    body.each_line do |line|
      match = line.match(BULLET)
      next unless match

      text = clean_item(match[3])
      next if text.empty?

      indent = match[1].length
      if top_indent && indent > top_indent
        parent&.subs&.push(text)
      else
        top_indent = indent
        parent = nil
        next if match[2] == "*"

        key, value = text.split(":", 2)
        parent = SectionItem.new(text, key.strip, value&.strip, [])
        items << parent
      end
    end
    items
  end

  def clean_item(text)
    text.sub(INLINE_COMMENT, "").gsub(AUTOLINK, '\1').strip
  end

  def warn_sub_items(heading, item)
    item.subs.each do |sub|
      @warnings << "#{heading}: nested item '- #{sub}' under '- #{item.text}' is ignored (this entry takes no sub-items)"
    end
  end

  def warn_missing_value(heading, item)
    @warnings << "#{heading}: '- #{item.key}' is missing a value (expected '- #{item.key}: <value>'); ignored"
  end

  # Shared iterator for flat key-value sections.
  # Yields (key, value) for each "- key: value" item; a bare "- key" is
  # warned about and skipped, nested items are warned about and ignored.
  # Returns nil when the section is missing, otherwise the accumulated config hash.
  def parse_kv_section(heading)
    items = section_items(heading)
    return nil unless items

    config = {}
    items.each do |item|
      warn_sub_items(heading, item)
      next warn_missing_value(heading, item) if item.value.nil?

      result = yield(item.key, item.value)
      config.merge!(result) if result
    end
    config
  end

  # --- Section parsers ---

  def parse_podcast_section
    items = section_items("Podcast")
    return {} unless items

    config = {}
    items.each do |item|
      next warn_missing_value("Podcast", item) if item.value.nil?

      if item.key == "language" && item.value.empty?
        item.subs.each do |entry|
          config[:languages] ||= []
          config[:languages] << parse_language_entry(entry)
        end
      elsif item.key == "language"
        # Inline `- language: es` — a single-language podcast (P7-6).
        warn_sub_items("Podcast", item)
        config[:languages] = [parse_language_entry(item.value)]
      else
        warn_sub_items("Podcast", item)
        config[item.key.to_sym] = item.value unless item.value.empty?
      end
    end

    config
  end

  def parse_audio_section
    items = section_items("Audio")
    return {} unless items

    config = {}
    items.each do |item|
      if item.key == "engine" && item.value&.empty?
        item.subs.each do |entry|
          config[:engines] ||= []
          config[:engines] << entry
        end
        next
      end

      warn_sub_items("Audio", item)
      if item.value.nil?
        (item.key == "autotrim") ? config[:autotrim] = true : warn_missing_value("Audio", item)
        next
      end
      next if item.value.empty?

      case item.key
      when "skip"
        config[:skip] = TimeValue.parse(item.value)
      when "cut"
        config[:cut] = TimeValue.parse(item.value)
      when "autotrim"
        config[:autotrim] = true
      else
        config[item.key.to_sym] = item.value
      end
    end

    config
  end

  def parse_image_section
    parse_kv_section("Image") do |key, value|
      case key
      when "cover"                       then { cover: value }
      when "image"                       then { image: value }
      when "base_image"                  then { base_image: resolve_path(value) }
      when "font"                        then { font: value }
      when "font_color"                  then { font_color: value }
      when "font_size"                   then { font_size: value.to_i }
      when "width", "text_width"         then { width: value.to_i }
      when "gravity", "text_gravity"     then { gravity: value }
      when "x_offset", "text_x_offset"   then { x_offset: value.to_i }
      when "y_offset", "text_y_offset"   then { y_offset: value.to_i }
      when "auto_cover_min_bytes"        then { auto_cover_min_bytes: value.to_i }
      when "auto_cover_min_score"        then { auto_cover_min_score: value.to_i }
      when "auto_cover_candidates"       then { auto_cover_candidates: value.to_i }
      when "auto_cover_model"            then { auto_cover_model: value }
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
      when "playback_speed"
        { playback_speed: value.to_f }
      when "show_duration", "show_transcript"
        { key.to_sym => value != "false" }
      end
    end || {}
  end

  def parse_language_section
    default = [{ "code" => "en" }]

    items = section_items("Language")
    return default unless items

    languages = items.map do |item|
      warn_sub_items("Language", item)
      parse_language_entry(item.text)
    end

    languages.empty? ? default : languages
  end

  # Parses a single language list entry into a config hash.
  # Supports inline options after voice_id, e.g.:
  #   "en"                                     → { "code" => "en" }
  #   "es: VOICE_ES"                           → { "code" => "es", "voice_id" => "VOICE_ES" }
  #   "jp: VOICE_JP translator: openai"        → adds "translator" => "openai"
  #   "jp: VOICE_JP translation_model: gpt-5"  → adds "translation_model" => "gpt-5"
  LANGUAGE_INLINE_KEYS = %w[translator translation_model].freeze

  def parse_language_entry(entry)
    return { "code" => entry } unless entry.include?(":")

    code, rest = entry.split(":", 2).map(&:strip)
    config = { "code" => code }
    return config if rest.nil? || rest.empty?

    parts = rest.split(/\s+(?=[a-z_]\w*:)/, -1)
    # First part is voice_id only when it doesn't itself look like a key:value
    # pair (a URL's "scheme://" colon doesn't count).
    if parts.first && !(parts.first.include?(":") && !parts.first.match?(%r{\A[a-z][a-z0-9+.-]*://}i))
      voice_id = parts.shift
      config["voice_id"] = voice_id unless voice_id.empty?
    end

    parts.each do |part|
      k, v = part.split(":", 2)
      next unless k && v
      k = k.strip
      v = v.strip
      config[k] = v if LANGUAGE_INLINE_KEYS.include?(k)
    end

    config
  end

  def parse_transcription_engine_section
    default = ["open"]

    items = section_items("Transcription Engine")
    return default unless items

    engines = items.map do |item|
      warn_sub_items("Transcription Engine", item)
      item.text
    end

    engines.empty? ? default : engines
  end

  def parse_lingq_section
    config = parse_kv_section("LingQ") do |key, value|
      case key
      when "token"       then { token: value }
      when "collection"  then { collection: value.to_i }
      when "level"       then { level: value.to_i }
      when "tags"        then { tags: value.split(",").map(&:strip) }
      when "image"       then { image: resolve_path(value) }
      when "base_image"  then { base_image: resolve_path(value) }
      when "font"                      then { font: value }
      when "font_color"                then { font_color: value }
      when "font_size"                 then { font_size: value.to_i }
      when "width", "text_width"       then { width: value.to_i }
      when "gravity", "text_gravity"   then { gravity: value }
      when "x_offset", "text_x_offset" then { x_offset: value.to_i }
      when "y_offset", "text_y_offset" then { y_offset: value.to_i }
      when "accent"                    then { accent: value }
      when "status"                    then { status: value }
      end
    end
    return nil if config.nil? || config.empty?
    config
  end

  def parse_youtube_section
    config = parse_kv_section("YouTube") do |key, value|
      case key
      when "playlist"  then { playlist: value }
      when "privacy"   then { privacy: value } if %w[public unlisted private].include?(value)
      when "category"  then { category: value }
      when "tags"      then { tags: value.split(",").map(&:strip) }
      end
    end
    return nil if config.nil? || config.empty?
    config
  end

  def parse_twitter_section
    config = parse_kv_section("Twitter") do |key, value|
      case key
      when "template"  then { template: value }
      when "since"     then { since: value.to_i }
      when "languages"
        normalized = value.split(",").map { |c| c.strip.downcase }.reject(&:empty?)
        next nil if normalized.empty?
        # "all" disables filtering — every configured language gets announced
        next { languages: :all } if normalized.include?("all")
        { languages: normalized }
      end
    end
    return nil if config.nil? || config.empty?
    config
  end

  # Parses ## Translation Glossary into { "jp" => { "Bitcoin" => "ビットコイン", ... }, "es" => {...} }.
  # Format:
  #   ## Translation Glossary
  #   - jp:
  #     - Bitcoin: ビットコイン
  #     - mining: マイニング
  #   - es:
  #     - mining: minería
  def parse_translation_glossary_section
    items = section_items("Translation Glossary")
    return {} unless items

    glossary = {}
    flat_entries = 0
    items.each do |item|
      if item.value&.empty? && item.key.match?(/\A[a-z]{2,3}\z/i)
        lang = item.key.downcase
        glossary[lang] ||= {}
        item.subs.each do |entry|
          # Split on the FIRST colon — translations may themselves contain colons.
          next unless entry.include?(":")
          term, translation = entry.split(":", 2).map(&:strip)
          glossary[lang][term] = translation if !term.empty? && translation && !translation.empty?
        end
        next
      end

      warn_sub_items("Translation Glossary", item)
      if item.value.nil?
        warn_missing_value("Translation Glossary", item)
      elsif !item.value.empty?
        # Flat `- term: translation` line at top level — no language wrapper.
        # Counted whether or not the rest of the section parses correctly,
        # so a partial slip-up under a valid language doesn't get masked.
        flat_entries += 1
      end
    end

    if flat_entries > 0
      @warnings << "Translation Glossary: #{flat_entries} top-level entry/entries ignored — " \
                   "entries must be nested under a language code (e.g. `- jp:` then indented `  - term: translation`)."
    end

    glossary
  end

  def parse_vocabulary_section
    config = parse_kv_section("Vocabulary") do |key, value|
      case key
      when "level"
        level = value.upcase
        { level: level } if %w[A1 A2 B1 B2 C1 C2].include?(level)
      when "max"
        { max: value.to_i } if value.to_i > 0
      when "frequency"
        { frequency: value } if %w[common uncommon rare literary archaic].include?(value)
      when "similar"
        { similar: value }
      when "target"
        { target: value }
      when "priority"
        { priority: value } if %w[hardest frequent balanced].include?(value)
      when "filter"
        { filter: value }
      end
    end
    return nil if config.nil? || config.empty?
    config
  end

  def parse_links_section
    config = parse_kv_section("Links") do |key, value|
      case key
      when "show"     then { show: value == "true" }
      when "position" then %w[bottom inline].include?(value) ? { position: value } : nil
      when "title"    then { title: value }
      when "max"      then value.to_i > 0 ? { max: value.to_i } : nil
      end
    end
    config&.dig(:show) ? config : nil
  end

  def parse_sources_section
    default = { "exa" => true }

    items = section_items("Sources")
    return default unless items

    sources = {}
    items.each do |item|
      if item.value.nil?
        # "- name" — enabled with defaults
        warn_sub_items("Sources", item)
        sources[item.key] = true
      elsif item.value.empty?
        # "- name:" with a sub-list to follow
        sources[item.key] = item.subs.map { |value| parse_source_item(item.key, value) }
      else
        # "- name: val1, val2" inline comma-separated
        warn_sub_items("Sources", item)
        sources[item.key] = item.value.split(",").map(&:strip)
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
      when "tag" then options[:tag] = v
      when "weight" then options[:weight] = v.to_i
      when "font" then options[:font] = v
      when "font_color" then options[:font_color] = v
      when "font_size" then options[:font_size] = v.to_i
      when "width", "text_width" then options[:width] = v.to_i
      when "gravity", "text_gravity" then options[:gravity] = v
      when "x_offset", "text_x_offset" then options[:x_offset] = v.to_i
      when "y_offset", "text_y_offset" then options[:y_offset] = v.to_i
      end
    end

    return url if options.empty?

    { url: url }.merge(options)
  end
end
