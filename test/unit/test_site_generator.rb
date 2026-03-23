# frozen_string_literal: true

require_relative "../test_helper"
require "site_generator"

class TestSiteGenerator < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("site_test")
    @podcast_dir = File.join(@dir, "mypod")
    @episodes_dir = File.join(@podcast_dir, "episodes")
    @history_path = File.join(@podcast_dir, "history.yml")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- scan_episodes ---

  def test_scan_episodes_finds_mp3s_for_english
    create_mp3("mypod-2026-01-15.mp3")
    create_mp3("mypod-2026-01-16.mp3")
    create_mp3("mypod-2026-01-16-es.mp3")

    gen = build_generator
    episodes = gen.send(:scan_episodes, "en")

    assert_equal 2, episodes.length
    # Reverse chronological
    assert_equal "mypod-2026-01-16.mp3", episodes.first[:filename]
  end

  def test_scan_episodes_finds_mp3s_for_non_english
    create_mp3("mypod-2026-01-15.mp3")
    create_mp3("mypod-2026-01-15-es.mp3")

    gen = build_generator(languages: [{ "code" => "en" }, { "code" => "es" }])
    episodes = gen.send(:scan_episodes, "es")

    assert_equal 1, episodes.length
    assert_equal "mypod-2026-01-15-es.mp3", episodes.first[:filename]
  end

  def test_scan_episodes_skips_concat_files
    create_mp3("mypod-2026-01-15.mp3")
    create_mp3("mypod-2026-01-15_concat.mp3")

    gen = build_generator
    episodes = gen.send(:scan_episodes, "en")
    assert_equal 1, episodes.length
  end

  # --- build_episode ---

  def test_build_episode_uses_history_title
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "My Title", "duration" => 120.0 }])

    gen = build_generator
    ep = gen.send(:build_episode, File.join(@episodes_dir, "mypod-2026-01-15.mp3"), "en")

    assert_equal "My Title", ep[:title]
    assert_in_delta 120.0, ep[:duration]
  end

  def test_build_episode_falls_back_to_transcript_title
    create_mp3("mypod-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"), "# Transcript Title\n\n## Transcript\n\nBody.")

    gen = build_generator
    ep = gen.send(:build_episode, File.join(@episodes_dir, "mypod-2026-01-15.mp3"), "en")

    assert_equal "Transcript Title", ep[:title]
  end

  def test_build_episode_falls_back_to_date_title
    create_mp3("mypod-2026-01-15.mp3")

    gen = build_generator
    ep = gen.send(:build_episode, File.join(@episodes_dir, "mypod-2026-01-15.mp3"), "en")

    assert_includes ep[:title], "January 15, 2026"
  end

  # --- parse_transcript_html ---

  def test_parse_transcript_html_with_transcript_section
    path = File.join(@episodes_dir, "test.md")
    File.write(path, "# Title\n\nDescription\n\n## Transcript\n\nFirst para.\n\nSecond para.")

    gen = build_generator
    html = gen.send(:parse_transcript_html, path)

    assert_includes html, "<p>First para.</p>"
    assert_includes html, "<p>Second para.</p>"
    refute_includes html, "Title"
    refute_includes html, "Description"
  end

  def test_parse_transcript_html_with_script_sections
    path = File.join(@episodes_dir, "test.md")
    File.write(path, "# Episode Title\n\n## Opening\n\nHello world.\n\n## Main\n\nContent here.")

    gen = build_generator
    html = gen.send(:parse_transcript_html, path)

    assert_includes html, "<h2>Opening</h2>"
    assert_includes html, "<p>Hello world.</p>"
    assert_includes html, "<h2>Main</h2>"
  end

  def test_parse_transcript_html_escapes_html
    path = File.join(@episodes_dir, "test.md")
    File.write(path, "# Title\n\n## Transcript\n\nText with <script>alert('xss')</script> inside.")

    gen = build_generator
    html = gen.send(:parse_transcript_html, path)

    refute_includes html, "<script>"
    assert_includes html, "&lt;script&gt;"
  end

  def test_parse_transcript_html_renders_more_info_links
    path = File.join(@episodes_dir, "test.md")
    File.write(path, "# Title\n\n## Opening\n\nHello world.\n\n## More info\n\n- [GPT-5 launches](https://example.com/gpt5)\n- [Bitcoin surges](https://example.com/btc)")

    gen = build_generator
    html = gen.send(:parse_transcript_html, path)

    assert_includes html, "<h2>More info</h2>"
    assert_includes html, '<a href="https://example.com/gpt5" target="_blank" rel="noopener">GPT-5 launches</a>'
    assert_includes html, '<a href="https://example.com/btc" target="_blank" rel="noopener">Bitcoin surges</a>'
    assert_includes html, "<ul>"
    assert_includes html, "<li>"
  end

  def test_parse_transcript_html_returns_nil_for_missing_file
    gen = build_generator
    assert_nil gen.send(:parse_transcript_html, nil)
    assert_nil gen.send(:parse_transcript_html, "/nonexistent.md")
  end

  # --- generate ---

  def test_generate_creates_site_directory
    create_mp3("mypod-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_script.md"), "# Test Episode\n\nBody text.")
    write_history([{ "date" => "2026-01-15", "title" => "Test Episode", "duration" => 90.0 }])

    gen = build_generator
    output = gen.generate

    assert Dir.exist?(output)
    assert File.exist?(File.join(output, "index.html"))
    assert File.exist?(File.join(output, "style.css"))
    assert File.exist?(File.join(output, "episodes", "mypod-2026-01-15.html"))
  end

  def test_generate_index_contains_episode
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "My Episode", "duration" => 90.0 }])

    gen = build_generator
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_includes index, "My Episode"
    assert_includes index, "<audio"
    assert_includes index, "mypod-2026-01-15.mp3"
  end

  def test_generate_episode_page_has_transcript
    create_mp3("mypod-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"), "# Ep Title\n\n## Transcript\n\nThe full text.")
    write_history([{ "date" => "2026-01-15", "title" => "Ep Title" }])

    gen = build_generator
    gen.generate

    page = File.read(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15.html"))
    assert_includes page, "Ep Title"
    assert_includes page, "<p>The full text.</p>"
    assert_includes page, "<audio"
  end

  def test_generate_multi_language
    create_mp3("mypod-2026-01-15.mp3")
    create_mp3("mypod-2026-01-15-es.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15-es_script.md"), "# Titulo\n\nContenido.")
    write_history([{ "date" => "2026-01-15", "title" => "English Title", "duration" => 60.0 }])

    gen = build_generator(languages: [{ "code" => "en" }, { "code" => "es" }])
    gen.generate

    site_dir = File.join(@podcast_dir, "site")

    # Primary language at root
    assert File.exist?(File.join(site_dir, "index.html"))
    assert File.exist?(File.join(site_dir, "episodes", "mypod-2026-01-15.html"))

    # Secondary language in subdirectory
    assert File.exist?(File.join(site_dir, "es", "index.html"))
    assert File.exist?(File.join(site_dir, "es", "episodes", "mypod-2026-01-15-es.html"))

    # Language switcher present
    index = File.read(File.join(site_dir, "index.html"))
    assert_includes index, "lang-switcher"
    assert_includes index, "English"
    assert_includes index, "Spanish"
  end

  def test_generate_with_base_url_uses_absolute_audio_urls
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator(base_url: "https://example.com/mypod")
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_includes index, "https://example.com/mypod/episodes/mypod-2026-01-15.mp3"
  end

  def test_generate_without_base_url_uses_relative_paths
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_includes index, "../episodes/mypod-2026-01-15.mp3"
  end

  def test_generate_clean_removes_existing_site
    site_dir = File.join(@podcast_dir, "site")
    FileUtils.mkdir_p(site_dir)
    File.write(File.join(site_dir, "stale.html"), "old")

    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator(clean: true)
    gen.generate

    refute File.exist?(File.join(site_dir, "stale.html"))
    assert File.exist?(File.join(site_dir, "index.html"))
  end

  # --- format_duration ---

  def test_format_duration
    gen = build_generator
    assert_equal "3:05", gen.send(:format_duration, 185.7)
    assert_equal "0:00", gen.send(:format_duration, 0)
    assert_equal "10:00", gen.send(:format_duration, 600)
  end

  # --- language nav ---

  def test_single_language_no_switcher
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    refute_includes index, "lang-switcher"
  end

  # --- site customization ---

  def test_generate_with_accent_injects_css_vars
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator(site_config: { accent: "#e11d48" })
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_includes index, "--accent: #e11d48"
  end

  def test_generate_with_dark_overrides
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator(site_config: { accent_dark: "#fb7185", bg_dark: "#1c1917" })
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_includes index, "prefers-color-scheme: dark"
    assert_includes index, "--accent: #fb7185"
    assert_includes index, "--bg: #1c1917"
  end

  def test_generate_custom_footer
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator(site_config: { footer: "Built with love" })
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_includes index, "Built with love"
    refute_includes index, "Generated by podgen"
  end

  def test_generate_footer_with_markdown_link
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator(site_config: { footer: "Built by [Fulgur](https://fulgur.ventures)" })
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_includes index, '<a href="https://fulgur.ventures" target="_blank" rel="noopener">Fulgur</a>'
    refute_includes index, "[Fulgur]"
  end

  def test_generate_description_with_markdown_link
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator(description: "A podcast by [Us](https://example.com)")
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_includes index, '<a href="https://example.com" target="_blank" rel="noopener">Us</a>'
    refute_includes index, "[Us]"
  end

  def test_generate_description_with_ampersand_in_markdown_link
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator(description: "By [A & B](https://example.com)")
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_includes index, ">A &amp; B</a>"
    refute_includes index, "&amp;amp;"
  end

  def test_generate_hides_duration
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test", "duration" => 90.0 }])

    gen = build_generator(site_config: { show_duration: false })
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    refute_includes index, "1:30"

    page = File.read(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15.html"))
    refute_includes page, "1:30"
  end

  def test_generate_hides_transcript
    create_mp3("mypod-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"), "# Title\n\n## Transcript\n\nThe text.")
    write_history([{ "date" => "2026-01-15", "title" => "Title" }])

    gen = build_generator(site_config: { show_transcript: false })
    gen.generate

    page = File.read(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15.html"))
    refute_includes page, "The text."
    refute_includes page, "class=\"transcript\""
  end

  def test_generate_copies_custom_css
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    custom_css = File.join(@dir, "site.css")
    File.write(custom_css, ".custom { color: red; }")

    gen = build_generator(site_css_path: custom_css)
    gen.generate

    site_dir = File.join(@podcast_dir, "site")
    assert File.exist?(File.join(site_dir, "custom.css"))

    index = File.read(File.join(site_dir, "index.html"))
    assert_includes index, "custom.css"
  end

  def test_generate_custom_css_gets_own_hash
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    custom_css = File.join(@dir, "site.css")
    File.write(custom_css, ".custom { color: red; }")

    gen = build_generator(site_css_path: custom_css)
    gen.generate

    site_dir = File.join(@podcast_dir, "site")
    index = File.read(File.join(site_dir, "index.html"))
    # custom.css hash should differ from style.css hash (different content)
    style_match = index.match(/style\.css\?v=([0-9a-f]{8})/)
    custom_match = index.match(/custom\.css\?v=([0-9a-f]{8})/)
    assert style_match, "Expected style.css with version hash"
    assert custom_match, "Expected custom.css with version hash"
    refute_equal style_match[1], custom_match[1], "Hashes should differ for different files"
  end

  def test_generate_copies_favicon
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    favicon = File.join(@dir, "favicon.ico")
    File.write(favicon, "icon-data")

    gen = build_generator(favicon_path: favicon)
    gen.generate

    site_dir = File.join(@podcast_dir, "site")
    assert File.exist?(File.join(site_dir, "favicon.ico"))

    index = File.read(File.join(site_dir, "index.html"))
    assert_includes index, 'rel="icon"'
    assert_includes index, "favicon.ico"
  end

  # --- CSS cache-busting ---

  def test_generate_adds_css_version_hash
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator
    gen.generate

    site_dir = File.join(@podcast_dir, "site")
    index = File.read(File.join(site_dir, "index.html"))
    assert_match(/style\.css\?v=[0-9a-f]{8}/, index)

    episode = File.read(Dir.glob(File.join(site_dir, "episodes", "*.html")).first)
    assert_match(/style\.css\?v=[0-9a-f]{8}/, episode)
  end

  # --- vocabulary section ---

  def test_parse_transcript_html_renders_vocabulary_section
    path = File.join(@episodes_dir, "test.md")
    File.write(path, <<~MD)
      # Title

      ## Transcript

      On je **razglasil** novico.

      ## Vocabulary

      - **razglasiti** (C1 v.) *razglasil* — to announce, proclaim. To declare publicly.
    MD

    gen = build_generator
    html = gen.send(:parse_transcript_html, path)

    # Vocabulary section rendered as flat list
    assert_includes html, '<div class="vocabulary">'
    assert_includes html, "<h2>Vocabulary</h2>"
    refute_includes html, "<h3>"
    assert_includes html, "razglasiti"
    assert_includes html, "<dl>"

    # Bold words in transcript linked to vocabulary
    assert_includes html, 'class="vocab-word"'
    assert_includes html, 'href="#vocab-razglasiti"'
  end

  def test_parse_transcript_html_without_vocabulary_unchanged
    path = File.join(@episodes_dir, "test.md")
    File.write(path, "# Title\n\n## Transcript\n\nSimple text.")

    gen = build_generator
    html = gen.send(:parse_transcript_html, path)

    assert_includes html, "<p>Simple text.</p>"
    refute_includes html, "vocabulary"
  end

  def test_audio_elements_use_preload_metadata
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_includes index, 'preload="metadata"'
    refute_includes index, 'preload="none"'

    page = File.read(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15.html"))
    assert_includes page, 'preload="metadata"'
  end

  def test_generate_no_style_tag_when_no_site_config
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator
    gen.generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    refute_includes index, "<style>"
  end

  # --- find_transcript ---

  def test_find_transcript_prefers_transcript_md
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"), "# T")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_script.md"), "# S")

    gen = build_generator
    result = gen.send(:find_transcript, "mypod-2026-01-15")

    assert_includes result, "_transcript.md"
  end

  def test_find_transcript_falls_back_to_script_md
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_script.md"), "# S")

    gen = build_generator
    result = gen.send(:find_transcript, "mypod-2026-01-15")

    assert_includes result, "_script.md"
  end

  def test_find_transcript_returns_nil_when_missing
    gen = build_generator
    result = gen.send(:find_transcript, "mypod-2026-01-15")

    assert_nil result
  end

  # --- extract_title_from_file ---

  def test_extract_title_from_file_returns_title
    path = File.join(@episodes_dir, "test.md")
    File.write(path, "# My Title\n\nBody text.")

    gen = build_generator
    assert_equal "My Title", gen.send(:extract_title_from_file, path)
  end

  def test_extract_title_from_file_nil_path
    gen = build_generator
    assert_nil gen.send(:extract_title_from_file, nil)
  end

  def test_extract_title_from_file_missing_file
    gen = build_generator
    assert_nil gen.send(:extract_title_from_file, "/nonexistent.md")
  end

  # --- URL helpers ---

  def test_audio_url_with_base_url
    gen = build_generator(base_url: "https://example.com/pod")
    assert_equal "https://example.com/pod/episodes/test.mp3", gen.send(:audio_url, "test.mp3", true)
  end

  def test_audio_url_primary_without_base_url
    gen = build_generator
    assert_equal "../episodes/test.mp3", gen.send(:audio_url, "test.mp3", true)
  end

  def test_audio_url_secondary_without_base_url
    gen = build_generator
    assert_equal "../../episodes/test.mp3", gen.send(:audio_url, "test.mp3", false)
  end

  def test_cover_url_with_base_url
    gen = build_generator(base_url: "https://example.com/pod")
    gen.instance_variable_get(:@config).image = "cover.jpg"
    assert_equal "https://example.com/pod/cover.jpg", gen.send(:cover_url, true)
  end

  def test_cover_url_nil_when_no_image
    gen = build_generator
    assert_nil gen.send(:cover_url, true)
  end

  def test_feed_url_primary_language
    gen = build_generator(base_url: "https://example.com/pod")
    assert_equal "https://example.com/pod/feed.xml", gen.send(:feed_url, "en")
  end

  def test_feed_url_secondary_language
    gen = build_generator(base_url: "https://example.com/pod")
    assert_equal "https://example.com/pod/feed-es.xml", gen.send(:feed_url, "es")
  end

  def test_feed_url_nil_without_base_url
    gen = build_generator
    assert_nil gen.send(:feed_url, "en")
  end

  # --- language nav ---

  def test_build_lang_nav_single_language
    gen = build_generator
    nav = gen.send(:build_lang_nav, "en")

    assert_equal 1, nav.length
    assert_equal "en", nav.first[:code]
    assert_nil nav.first[:index_path] # Current language, no link
  end

  def test_build_lang_nav_multi_language
    gen = build_generator(languages: [{ "code" => "en" }, { "code" => "es" }])
    nav = gen.send(:build_lang_nav, "en")

    assert_equal 2, nav.length
    en_entry = nav.find { |e| e[:code] == "en" }
    es_entry = nav.find { |e| e[:code] == "es" }
    assert_nil en_entry[:index_path]
    assert_equal "es/index.html", es_entry[:index_path]
  end

  private

  def create_mp3(name)
    path = File.join(@episodes_dir, name)
    File.write(path, "x" * 1000)
    path
  end

  def write_history(entries)
    File.write(@history_path, entries.to_yaml)
  end

  FakeConfig = Struct.new(:episodes_dir, :languages, :base_url, :history_path, :title, :description, :image, :site_config, :site_css_path, :favicon_path, keyword_init: true)

  def build_generator(languages: nil, base_url: nil, clean: false, site_config: nil, site_css_path: nil, favicon_path: nil, description: "A test podcast")
    languages ||= [{ "code" => "en" }]
    config = FakeConfig.new(
      episodes_dir: @episodes_dir,
      languages: languages,
      base_url: base_url,
      history_path: @history_path,
      title: "My Podcast",
      description: description,
      image: nil,
      site_config: site_config || {},
      site_css_path: site_css_path,
      favicon_path: favicon_path
    )

    SiteGenerator.new(config: config, base_url: base_url, clean: clean)
  end
end
