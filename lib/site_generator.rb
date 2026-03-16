# frozen_string_literal: true

require "erb"
require "date"
require "time"
require "yaml"
require "fileutils"
require_relative "loggable"
require_relative "language_names"
require_relative "audio_assembler"
require_relative "episode_filtering"

class SiteGenerator
  include Loggable

  SUFFIXES = [""] + ("a".."z").to_a
  TEMPLATES_DIR = File.join(__dir__, "templates")

  def initialize(config:, base_url: nil, clean: false, logger: nil)
    @logger = logger
    @config = config
    @base_url = (base_url || config.base_url)&.chomp("/")
    @clean = clean

    @output_dir = File.join(File.dirname(config.episodes_dir), "site")
    @episodes_dir = config.episodes_dir
    @podcast_name = File.basename(File.dirname(config.episodes_dir))
    @languages = config.languages
    @site_config = config.respond_to?(:site_config) ? config.site_config : {}
    @site_css_path = config.respond_to?(:site_css_path) ? config.site_css_path : nil
    @favicon_path = config.respond_to?(:favicon_path) ? config.favicon_path : nil
    @title_map, @timestamp_map, @duration_map = build_history_maps
  end

  def generate
    if @clean && Dir.exist?(@output_dir)
      FileUtils.rm_rf(@output_dir)
      log("Cleaned #{@output_dir}")
    end

    FileUtils.mkdir_p(@output_dir)
    install_css

    @languages.each do |lang_entry|
      code = lang_entry["code"]
      generate_for_language(code)
    end

    log("Site generated at #{@output_dir}")
    @output_dir
  end

  private

  def install_css
    src = File.join(TEMPLATES_DIR, "style.css")
    dst = File.join(@output_dir, "style.css")
    FileUtils.cp(src, dst)

    if @site_css_path
      FileUtils.cp(@site_css_path, File.join(@output_dir, "custom.css"))
    end

    if @favicon_path
      @favicon_filename = File.basename(@favicon_path)
      FileUtils.cp(@favicon_path, File.join(@output_dir, @favicon_filename))
    end
  end

  def generate_for_language(lang_code)
    episodes = scan_episodes(lang_code)
    lang_dir = lang_code == primary_language ? @output_dir : File.join(@output_dir, lang_code)
    episodes_html_dir = File.join(lang_dir, "episodes")
    FileUtils.mkdir_p(episodes_html_dir)

    # Depth for CSS/audio path resolution
    is_primary = lang_code == primary_language
    css_path = is_primary ? "style.css" : "../style.css"

    lang_nav = build_lang_nav(lang_code)

    # Build episode list data
    episode_list = episodes.map do |ep|
      page_name = "#{ep[:basename]}.html"
      {
        title: ep[:title],
        date: ep[:date].strftime("%B %d, %Y"),
        duration: ep[:duration] ? format_duration(ep[:duration]) : nil,
        audio_url: audio_url(ep[:filename], is_primary),
        page_path: "episodes/#{page_name}"
      }
    end

    # Render index
    index_html = render_layout(
      lang: lang_code,
      page_title: @config.title,
      css_path: css_path,
      languages: lang_nav,
      feed_url: feed_url(lang_code),
      content: render_template("index.erb",
        podcast_title: @config.title,
        podcast_description: @config.description,
        cover_url: cover_url(is_primary),
        episodes: episode_list,
        site_config: @site_config,
        feed_url: feed_url(lang_code)
      )
    )
    File.write(File.join(lang_dir, "index.html"), index_html)

    # Render episode pages
    episodes.each do |ep|
      page_name = "#{ep[:basename]}.html"
      ep_html = render_layout(
        lang: lang_code,
        page_title: "#{ep[:title]} — #{@config.title}",
        css_path: is_primary ? "../style.css" : "../../style.css",
        languages: build_lang_nav_episode(lang_code, ep),
        feed_url: feed_url(lang_code),
        content: render_template("episode.erb",
          episode_title: ep[:title],
          episode_date: ep[:date].strftime("%B %d, %Y"),
          episode_duration: ep[:duration] ? format_duration(ep[:duration]) : nil,
          audio_url: audio_url_from_episode_page(ep[:filename], is_primary),
          transcript_html: parse_transcript_html(ep[:transcript_path]),
          index_path: is_primary ? "../index.html" : "../../#{lang_code}/index.html",
          site_config: @site_config
        )
      )
      File.write(File.join(episodes_html_dir, page_name), ep_html)
    end

    log("  #{lang_code}: #{episodes.length} episodes")
  end

  # --- Episode scanning ---

  def scan_episodes(lang_code)
    EpisodeFiltering.episodes_for_language(@episodes_dir, lang_code)
      .sort
      .reverse
      .filter_map { |path| build_episode(path, lang_code) }
  end

  def build_episode(mp3_path, lang_code)
    filename = File.basename(mp3_path)
    basename = File.basename(mp3_path, ".mp3")

    date_match = filename.match(/(\d{4}-\d{2}-\d{2})/)
    return nil unless date_match

    date = Date.parse(date_match[1]) rescue nil
    return nil unless date

    # Find transcript or script
    transcript_path = find_transcript(basename)

    title = @title_map[filename] || extract_title_from_file(transcript_path) || "#{@config.title} — #{date.strftime('%B %d, %Y')}"

    {
      filename: filename,
      basename: basename,
      date: date,
      title: title,
      duration: @duration_map[filename],
      transcript_path: transcript_path
    }
  end

  def find_transcript(basename)
    %w[_transcript.md _script.md].each do |suffix|
      path = File.join(@episodes_dir, "#{basename}#{suffix}")
      return path if File.exist?(path)
    end
    nil
  end

  def extract_title_from_file(path)
    return nil unless path && File.exist?(path)

    first_line = File.foreach(path).first
    first_line&.strip&.sub(/^#\s+/, "")
  end

  # --- History maps (same logic as RssGenerator) ---

  def build_history_maps
    history_path = @config.history_path
    empty = [{}, {}, {}]
    return empty unless history_path && File.exist?(history_path)

    entries = YAML.load_file(history_path) rescue nil
    return empty unless entries.is_a?(Array)

    by_date = {}
    entries.each do |entry|
      date = entry["date"]
      next unless date
      (by_date[date] ||= []) << entry
    end

    title_map = {}
    timestamp_map = {}
    duration_map = {}

    by_date.each do |date, date_entries|
      date_entries.each_with_index do |entry, idx|
        suffix = SUFFIXES[idx] || idx.to_s
        filename = "#{@podcast_name}-#{date}#{suffix}.mp3"
        title_map[filename] = entry["title"] if entry["title"]
        timestamp_map[filename] = entry["timestamp"] if entry["timestamp"]
        duration_map[filename] = entry["duration"] if entry["duration"]

        # Map language-suffixed filenames for non-primary languages
        @languages.each do |lang_entry|
          code = lang_entry["code"]
          next if code == "en"

          lang_filename = "#{@podcast_name}-#{date}#{suffix}-#{code}.mp3"
          lang_script = File.join(@episodes_dir, "#{@podcast_name}-#{date}#{suffix}-#{code}_script.md")
          if File.exist?(lang_script)
            translated_title = File.read(lang_script)[/^# (.+)$/, 1]
            title_map[lang_filename] = translated_title if translated_title
          end
          title_map[lang_filename] ||= entry["title"] if entry["title"]
          timestamp_map[lang_filename] = entry["timestamp"] if entry["timestamp"]
          duration_map[lang_filename] = entry["duration"] if entry["duration"]
        end
      end
    end

    [title_map, timestamp_map, duration_map]
  end

  # --- Transcript parsing ---

  def parse_transcript_html(path)
    return nil unless path && File.exist?(path)

    text = File.read(path)

    body = if text.include?("## Transcript")
      text.split("## Transcript", 2).last
    else
      # Script: strip title line + optional description line
      text.sub(/\A#[^\n]*\n+/, "")
    end

    # Split off ## Vocabulary section if present
    transcript_body, vocab_body = split_vocabulary_section(body)

    # Build lemma lookup from vocabulary section (for linking bold words)
    vocab_lemmas = parse_vocab_lemmas(vocab_body) if vocab_body

    # Convert markdown sections and paragraphs to HTML
    paragraphs = transcript_body.strip.split(/\n{2,}/).map do |block|
      block = block.strip
      if block.start_with?("## ")
        "<h2>#{escape_html(block.sub(/^## /, ""))}</h2>"
      elsif block.match?(/\A- \[.+\]\(.+\)/)
        # Markdown link list (e.g. "## More info" sources)
        items = block.split("\n").map do |line|
          line = line.strip.sub(/^- /, "")
          linkify_markdown(line)
        end
        "<ul>\n#{items.map { |i| "<li>#{i}</li>" }.join("\n")}\n</ul>"
      else
        html = escape_html(block)
        html = linkify_vocab_words(html, vocab_lemmas) if vocab_lemmas
        "<p>#{html}</p>"
      end
    end

    result = paragraphs.join("\n")
    result += "\n" + render_vocabulary_html(vocab_body) if vocab_body
    result
  end

  def escape_html(text)
    text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  def linkify_markdown(text)
    text.gsub(/\[([^\]]+)\]\(([^)]+)\)/) do
      title = escape_html(Regexp.last_match(1))
      url = escape_html(Regexp.last_match(2))
      "<a href=\"#{url}\" target=\"_blank\" rel=\"noopener\">#{title}</a>"
    end
  end

  # --- Vocabulary helpers ---

  def split_vocabulary_section(body)
    if body.include?("## Vocabulary")
      parts = body.split("## Vocabulary", 2)
      [parts[0], parts[1]]
    else
      [body, nil]
    end
  end

  # Parses vocabulary markdown to extract word→lemma mappings for linking.
  # Returns hash: { "word_downcase" => "lemma" }
  def parse_vocab_lemmas(vocab_body)
    lemmas = {}
    vocab_body.scan(/\*\*(\w+)\*\*\s*\(/).each do |match|
      lemma = match[0]
      lemmas[lemma.downcase] = lemma
    end

    # Also extract "Original: word" references
    vocab_body.scan(/_Original:\s*(\w+)_/).each do |match|
      word = match[0]
      # Find the lemma this original belongs to — scan backward for the preceding **lemma**
      # Use a more targeted regex
      vocab_body.scan(/\*\*(\w+)\*\*.*?_Original:\s*#{Regexp.escape(word)}_/) do
        lemmas[word.downcase] = Regexp.last_match(1)
      end
    end

    lemmas.empty? ? nil : lemmas
  end

  # Wraps **bold** words (escaped as &ast;&ast; after escape_html) with vocab anchor links.
  def linkify_vocab_words(html, vocab_lemmas)
    # After escape_html, **word** becomes **word** (asterisks aren't HTML-special)
    html.gsub(/\*\*([^*]+)\*\*/) do
      word = Regexp.last_match(1)
      lemma = vocab_lemmas[word.downcase] || word.downcase
      anchor = vocab_anchor(lemma)
      "<a href=\"##{anchor}\" class=\"vocab-word\">#{word}</a>"
    end
  end

  def vocab_anchor(lemma)
    "vocab-#{lemma.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')}"
  end

  def render_vocabulary_html(vocab_body)
    lines = ["<div class=\"vocabulary\">", "<h2>Vocabulary</h2>"]
    current_level = nil

    vocab_body.each_line do |line|
      line = line.strip
      next if line.empty?

      if line.match?(/\A\*\*[A-Z]\d\*\*\z/)
        # Level header like **B1**
        lines << "</dl>" if current_level
        current_level = line.gsub("**", "")
        lines << "<h3>#{escape_html(current_level)}</h3>"
        lines << "<dl>"
      elsif line.start_with?("- **") && current_level
        # Vocabulary entry: - **lemma** (pos) — translation. definition _Original: word_
        if line =~ /\A- \*\*(.+?)\*\*\s*\(([^)]+)\)\s*(?:—\s*(.+))?\z/
          lemma = Regexp.last_match(1)
          pos = Regexp.last_match(2)
          rest = Regexp.last_match(3) || ""

          anchor = vocab_anchor(lemma)

          # Split rest into translation/definition and original
          original = nil
          if rest =~ /(.+?)\s*_Original:\s*(.+?)_\s*\z/
            rest = Regexp.last_match(1).strip
            original = Regexp.last_match(2).strip
          end

          dt = "<dt id=\"#{anchor}\"><strong>#{escape_html(lemma)}</strong> <span class=\"pos\">(#{escape_html(pos)})</span></dt>"
          dd_parts = []
          dd_parts << escape_html(rest) unless rest.empty?
          dd_parts << "<span class=\"original\">#{escape_html(original)}</span>" if original
          dd = "<dd>#{dd_parts.join(' ')}</dd>"

          lines << dt
          lines << dd
        end
      end
    end

    lines << "</dl>" if current_level
    lines << "</div>"
    lines.join("\n")
  end

  # --- URL helpers ---

  def primary_language
    @languages.first["code"]
  end

  def audio_url(filename, is_primary)
    if @base_url
      "#{@base_url}/episodes/#{filename}"
    elsif is_primary
      "../episodes/#{filename}"
    else
      "../../episodes/#{filename}"
    end
  end

  def audio_url_from_episode_page(filename, is_primary)
    if @base_url
      "#{@base_url}/episodes/#{filename}"
    elsif is_primary
      "../../episodes/#{filename}"
    else
      "../../../episodes/#{filename}"
    end
  end

  def cover_url(is_primary)
    return nil unless @config.image

    if @base_url
      "#{@base_url}/#{@config.image}"
    elsif is_primary
      "../#{@config.image}"
    else
      "../../#{@config.image}"
    end
  end

  def feed_url(lang_code)
    return nil unless @base_url

    if lang_code == primary_language
      "#{@base_url}/feed.xml"
    else
      "#{@base_url}/feed-#{lang_code}.xml"
    end
  end

  # --- Language navigation ---

  def build_lang_nav(current_code)
    @languages.map do |lang_entry|
      code = lang_entry["code"]
      is_primary = code == primary_language
      is_current_primary = current_code == primary_language

      index_path = if code == current_code
        nil
      elsif is_primary && !is_current_primary
        "../index.html"
      elsif !is_primary && is_current_primary
        "#{code}/index.html"
      else
        "../#{code}/index.html"
      end

      { code: code, name: LANGUAGE_NAMES[code] || code.upcase, index_path: index_path }
    end
  end

  def build_lang_nav_episode(current_code, episode)
    @languages.map do |lang_entry|
      code = lang_entry["code"]
      is_primary = code == primary_language
      is_current_primary = current_code == primary_language

      # Derive the episode basename for the target language
      base = episode[:basename]
      if current_code != "en"
        # Strip current language suffix to get the English base
        base = base.sub(/-#{current_code}$/, "")
      end
      target_basename = code == "en" ? base : "#{base}-#{code}"

      index_path = if code == current_code
        nil
      elsif is_primary && !is_current_primary
        "../episodes/#{target_basename}.html"
      elsif !is_primary && is_current_primary
        "../#{code}/episodes/#{target_basename}.html"
      else
        "../../#{code}/episodes/#{target_basename}.html"
      end

      { code: code, name: LANGUAGE_NAMES[code] || code.upcase, index_path: index_path }
    end
  end

  # --- Duration formatting ---

  def format_duration(seconds)
    minutes = (seconds / 60).to_i
    secs = (seconds % 60).to_i
    format("%d:%02d", minutes, secs)
  end

  # --- ERB rendering ---

  def render_template(template_name, **locals)
    path = File.join(TEMPLATES_DIR, template_name)
    template = ERB.new(File.read(path), trim_mode: "<>")
    b = binding
    locals.each { |k, v| b.local_variable_set(k, v) }
    template.result(b)
  end

  def render_layout(lang:, page_title:, css_path:, languages:, feed_url:, content:)
    custom_css_rel = @site_css_path ? css_path.sub("style.css", "custom.css") : nil
    favicon_rel = @favicon_filename ? css_path.sub("style.css", @favicon_filename) : nil
    footer_text = escape_html(@site_config.fetch(:footer, "Generated by podgen"))

    render_template("layout.erb",
      lang: lang,
      page_title: page_title,
      css_path: css_path,
      custom_css_path: custom_css_rel,
      favicon_path: favicon_rel,
      languages: languages,
      feed_url: feed_url,
      content: content,
      site_config: @site_config,
      footer_text: footer_text
    )
  end
end
