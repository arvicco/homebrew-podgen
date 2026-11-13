# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fakes"
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

    # P1-15: "-es" is a language suffix only because es is configured
    gen = build_generator(languages: [{ "code" => "en" }, { "code" => "es" }])
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

  def test_build_episode_prefers_transcript_title_over_history
    create_mp3("mypod-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"), "# Transcript Title\n\n## Transcript\n\nBody.")
    write_history([{ "date" => "2026-01-15", "title" => "History Title", "duration" => 120.0 }])

    gen = build_generator
    ep = gen.send(:build_episode, File.join(@episodes_dir, "mypod-2026-01-15.mp3"), "en")

    assert_equal "Transcript Title", ep[:title]
    assert_in_delta 120.0, ep[:duration]
  end

  def test_build_episode_language_variant_uses_language_duration
    create_mp3("mypod-2026-01-15-es.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "History Title", "duration" => 120.0,
                     "languages" => { "es" => { "duration" => 140.0 } } }])

    gen = build_generator(languages: [{ "code" => "en" }, { "code" => "es" }])
    ep = gen.send(:build_episode, File.join(@episodes_dir, "mypod-2026-01-15-es.mp3"), "es")

    assert_in_delta 140.0, ep[:duration]
  end

  def test_build_episode_falls_back_to_history_title
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "History Title" }])

    gen = build_generator
    ep = gen.send(:build_episode, File.join(@episodes_dir, "mypod-2026-01-15.mp3"), "en")

    assert_equal "History Title", ep[:title]
  end

  def test_build_episode_correct_title_with_scrapped_episodes
    # History has 3 entries for same date, but middle episode was scrapped (no MP3)
    create_mp3("mypod-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"), "# First\n\n## Transcript\n\nBody.")
    # mypod-2026-01-15a.mp3 was scrapped — no file
    create_mp3("mypod-2026-01-15b.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15b_transcript.md"), "# Third\n\n## Transcript\n\nBody.")
    write_history([
      { "date" => "2026-01-15", "title" => "First" },
      { "date" => "2026-01-15", "title" => "Second (scrapped)" },
      { "date" => "2026-01-15", "title" => "Third" }
    ])

    gen = build_generator
    ep_b = gen.send(:build_episode, File.join(@episodes_dir, "mypod-2026-01-15b.mp3"), "en")

    # Must get title from transcript, not from history index (which would give "Third" for index 2 = suffix "b")
    assert_equal "Third", ep_b[:title]
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
    html, _langs = gen.send(:parse_transcript_html, path)

    assert_includes html, "<p>First para.</p>"
    assert_includes html, "<p>Second para.</p>"
    refute_includes html, "Title"
    refute_includes html, "Description"
  end

  def test_parse_transcript_html_with_script_sections
    path = File.join(@episodes_dir, "test.md")
    File.write(path, "# Episode Title\n\n## Opening\n\nHello world.\n\n## Main\n\nContent here.")

    gen = build_generator
    html, _langs = gen.send(:parse_transcript_html, path)

    assert_includes html, "<h2>Opening</h2>"
    assert_includes html, "<p>Hello world.</p>"
    assert_includes html, "<h2>Main</h2>"
  end

  def test_parse_transcript_html_escapes_html
    path = File.join(@episodes_dir, "test.md")
    File.write(path, "# Title\n\n## Transcript\n\nText with <script>alert('xss')</script> inside.")

    gen = build_generator
    html, _langs = gen.send(:parse_transcript_html, path)

    refute_includes html, "<script>"
    assert_includes html, "&lt;script&gt;"
  end

  def test_parse_transcript_html_renders_more_info_links
    path = File.join(@episodes_dir, "test.md")
    File.write(path, "# Title\n\n## Opening\n\nHello world.\n\n## More info\n\n- [GPT-5 launches](https://example.com/gpt5)\n- [Bitcoin surges](https://example.com/btc)")

    gen = build_generator
    html, _langs = gen.send(:parse_transcript_html, path)

    assert_includes html, "<h2>More info</h2>"
    assert_includes html, '<a href="https://example.com/gpt5" target="_blank" rel="noopener">GPT-5 launches</a>'
    assert_includes html, '<a href="https://example.com/btc" target="_blank" rel="noopener">Bitcoin surges</a>'
    assert_includes html, "<ul>"
    assert_includes html, "<li>"
  end

  # P17-3 (Q-135): a URL with parentheses and a title with brackets, as
  # ScriptRenderer writes them, render as whole links on the site.
  def test_parse_transcript_html_links_paren_url_and_bracketed_title_from_script_renderer
    require "script_renderer"
    sources = ScriptRenderer.render_sources([
      {title: "Ruby", url: "https://en.wikipedia.org/wiki/Ruby_(programming_language)"},
      {title: "[Video] Rails 8", url: "https://example.com/rails8"}
    ])
    path = File.join(@episodes_dir, "test.md")
    File.write(path, "# Title\n\n## Opening\n\nHello.\n\n## More info\n\n#{sources}")

    html, _langs = build_generator.send(:parse_transcript_html, path)

    assert_includes html, '<a href="https://en.wikipedia.org/wiki/Ruby_(programming_language)" target="_blank" rel="noopener">Ruby</a>'
    assert_includes html, '<a href="https://example.com/rails8" target="_blank" rel="noopener">[Video] Rails 8</a>'
    refute_includes html, "language)</li>", "no stray paren after the link"
  end

  # P18-8 (4): a `"` in the url cannot close the href attribute.
  def test_linkify_markdown_quote_in_url_cannot_close_href
    html = build_generator.send(:linkify_markdown, '[A](https://a.com/x"onmouseover="y)')
    assert_equal '<a href="https://a.com/x&quot;onmouseover=&quot;y" target="_blank" rel="noopener">A</a>', html
  end

  def test_parse_transcript_html_returns_nil_for_missing_file
    gen = build_generator
    html, langs = gen.send(:parse_transcript_html, nil)
    assert_nil html
    assert_nil langs
    html, langs = gen.send(:parse_transcript_html, "/nonexistent.md")
    assert_nil html
    assert_nil langs
  end

  # --- generate ---

  def test_generate_writes_pages_through_atomic_writer
    create_mp3("mypod-2026-01-15.mp3")
    create_mp3("mypod-2026-01-15-es.mp3")
    write_history([{"date" => "2026-01-15", "title" => "Ep"}])
    site = File.join(@podcast_dir, "site")

    written = record_atomic_writes { build_generator(languages: [{"code" => "en"}, {"code" => "es"}]).generate }

    assert_equal [
      File.join(site, "index.html"), File.join(site, "episodes", "mypod-2026-01-15.html"),
      File.join(site, "es", "index.html"), File.join(site, "es", "episodes", "mypod-2026-01-15-es.html")
    ], written
    assert File.read(File.join(site, "index.html")).end_with?("</html>\n")
    assert_empty Dir.glob(File.join(site, "**", "*.tmp.*"))
  end

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

    # Language switcher present, with native-script names
    index = File.read(File.join(site_dir, "index.html"))
    assert_includes index, "lang-switcher"
    assert_includes index, "English"
    assert_includes index, "Español"     # native, not "Spanish"
    refute_includes index, "Spanish"
  end

  def test_lang_switcher_uses_native_script_names
    create_mp3("mypod-2026-01-15.mp3")
    create_mp3("mypod-2026-01-15-jp.mp3")
    create_mp3("mypod-2026-01-15-it.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15-jp_script.md"), "# T\n\nC.")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15-it_script.md"), "# T\n\nC.")
    write_history([{ "date" => "2026-01-15", "title" => "Test", "duration" => 60.0 }])

    build_generator(languages: [{ "code" => "en" }, { "code" => "jp" }, { "code" => "it" }]).generate

    site_dir = File.join(@podcast_dir, "site")
    en_index = File.read(File.join(site_dir, "index.html"))
    en_episode = File.read(File.join(site_dir, "episodes", "mypod-2026-01-15.html"))

    [en_index, en_episode].each do |html|
      assert_includes html, "日本語", "expected native Japanese name"
      assert_includes html, "Italiano", "expected native Italian name"
      refute_includes html, "Japanese", "should not show English name 'Japanese'"
      refute_includes html, ">Italian<", "should not show English name 'Italian'"
    end
  end

  def test_episode_lang_switcher_links_resolve_both_directions
    create_mp3("mypod-2026-01-15.mp3")
    create_mp3("mypod-2026-01-15-es.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15-es_script.md"), "# Titulo\n\nContenido.")
    write_history([{ "date" => "2026-01-15", "title" => "English Title", "duration" => 60.0 }])

    build_generator(languages: [{ "code" => "en" }, { "code" => "es" }]).generate

    site_dir = File.join(@podcast_dir, "site")

    # EN episode (primary) → ES button: relative path resolves under es/episodes/
    en_html = File.read(File.join(site_dir, "episodes", "mypod-2026-01-15.html"))
    assert_includes en_html, %{href="../es/episodes/mypod-2026-01-15-es.html"}

    # ES episode (non-primary) → EN button: must include `../../` to escape
    # both episodes/ and es/, otherwise the link resolves inside /es/episodes/.
    es_html = File.read(File.join(site_dir, "es", "episodes", "mypod-2026-01-15-es.html"))
    assert_includes es_html, %{href="../../episodes/mypod-2026-01-15.html"}
    refute_includes es_html, %{href="../episodes/mypod-2026-01-15.html"},
      "../episodes/ would resolve to /es/episodes/ — wrong directory"
  end

  def test_episode_lang_switcher_greys_out_when_target_episode_missing
    # English episode exists but Spanish translation hasn't been produced yet.
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "English Title", "duration" => 60.0 }])

    build_generator(languages: [{ "code" => "en" }, { "code" => "es" }]).generate

    en_html = File.read(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15.html"))
    # Spanish button should render as a non-clickable span, not an <a>
    assert_includes en_html, %{<span class="unavailable"}
    assert_includes en_html, "Español"
    refute_includes en_html, %{href="../es/episodes/mypod-2026-01-15-es.html"}
  end

  def test_episode_lang_switcher_keeps_link_when_both_languages_present
    create_mp3("mypod-2026-01-15.mp3")
    create_mp3("mypod-2026-01-15-es.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15-es_script.md"), "# T\n\nC.")
    write_history([{ "date" => "2026-01-15", "title" => "English Title", "duration" => 60.0 }])

    build_generator(languages: [{ "code" => "en" }, { "code" => "es" }]).generate

    en_html = File.read(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15.html"))
    refute_includes en_html, %{<span class="unavailable"}
    assert_includes en_html, %{href="../es/episodes/mypod-2026-01-15-es.html"}
  end

  def test_episode_lang_switcher_per_episode_partial_translations
    # 3 langs configured (en, jp, it). Episode A has en+it, episode B has en+jp+it.
    # Switcher should reflect ACTUAL per-episode availability, not the podcast-level config.
    create_mp3("mypod-2026-01-15.mp3")
    create_mp3("mypod-2026-01-15-it.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15-it_script.md"), "# T\n\nC.")
    create_mp3("mypod-2026-01-16.mp3")
    create_mp3("mypod-2026-01-16-jp.mp3")
    create_mp3("mypod-2026-01-16-it.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-16-jp_script.md"), "# T\n\nC.")
    File.write(File.join(@episodes_dir, "mypod-2026-01-16-it_script.md"), "# T\n\nC.")
    write_history([
      { "date" => "2026-01-15", "title" => "Ep A", "duration" => 60.0 },
      { "date" => "2026-01-16", "title" => "Ep B", "duration" => 60.0 }
    ])

    build_generator(languages: [{ "code" => "en" }, { "code" => "jp" }, { "code" => "it" }]).generate

    site_dir = File.join(@podcast_dir, "site")

    # Episode A: jp not produced → greyed; it produced → linked.
    a_en = File.read(File.join(site_dir, "episodes", "mypod-2026-01-15.html"))
    assert_match(/<span class="unavailable"[^>]*>日本語<\/span>/, a_en)
    assert_includes a_en, %{href="../it/episodes/mypod-2026-01-15-it.html"}

    # Episode B: both translations exist → both linked, no unavailable spans.
    b_en = File.read(File.join(site_dir, "episodes", "mypod-2026-01-16.html"))
    refute_includes b_en, %{<span class="unavailable"}
    assert_includes b_en, %{href="../jp/episodes/mypod-2026-01-16-jp.html"}
    assert_includes b_en, %{href="../it/episodes/mypod-2026-01-16-it.html"}
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
    assert_equal ["site"], Dir.children(@podcast_dir).grep(/\Asite/), "no .tmp./.old. leftovers"
  end

  def test_generate_clean_failure_on_second_language_keeps_live_site
    site_dir = File.join(@podcast_dir, "site")
    FileUtils.mkdir_p(site_dir)
    File.write(File.join(site_dir, "index.html"), "live")

    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator(languages: [{ "code" => "en" }, { "code" => "es" }], clean: true)
    real = gen.method(:generate_for_language)
    failing = ->(code) { (code == "es") ? raise("render failed") : real.call(code) }
    gen.stub :generate_for_language, failing do
      assert_raises(RuntimeError) { gen.generate }
    end

    assert_equal "live", File.read(File.join(site_dir, "index.html"))
    assert_equal ["site"], Dir.children(@podcast_dir).grep(/\Asite/), "the temp dir is removed"
  end

  # CRPR: live moved aside, then the swap-in rename fails -> live is restored.
  def test_generate_clean_failed_swap_rename_restores_live_site
    site_dir = File.join(@podcast_dir, "site")
    FileUtils.mkdir_p(site_dir)
    File.write(File.join(site_dir, "index.html"), "live")

    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Test" }])

    gen = build_generator(clean: true)
    real_rename = File.method(:rename)
    calls = 0
    failing = lambda do |src, dst|
      calls += 1
      raise Errno::EACCES, dst if calls == 2
      real_rename.call(src, dst)
    end
    File.stub(:rename, failing) do
      assert_raises(Errno::EACCES) { gen.generate }
    end

    assert_equal "live", File.read(File.join(site_dir, "index.html"))
    assert_equal ["site"], Dir.children(@podcast_dir).grep(/\Asite/), "no .tmp./.old. leftovers"
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
    refute_includes index, '<nav class="lang-switcher">'
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
    html, langs = gen.send(:parse_transcript_html, path)

    # Single-language: no vocab_languages
    assert_nil langs

    # Vocabulary section rendered as flat list
    assert_includes html, '<div class="vocabulary" id="vocabulary">'
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
    html, langs = gen.send(:parse_transcript_html, path)

    assert_includes html, "<p>Simple text.</p>"
    refute_includes html, "vocabulary"
    assert_nil langs
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

  # --- episode cover ---

  def test_episode_page_shows_cover_when_present
    create_mp3("mypod-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"), "# Ep\n\n## Transcript\n\nText.")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_cover.jpg"), "fake image data")
    write_history([{ "date" => "2026-01-15", "title" => "Ep" }])

    gen = build_generator
    gen.generate

    page = File.read(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15.html"))
    assert_includes page, 'class="episode-cover"'
    assert_includes page, 'src="mypod-2026-01-15_cover.jpg"'

    # Cover file copied to site
    assert File.exist?(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15_cover.jpg"))
  end

  # --- title escaping (P19-1) ---

  def test_generate_plain_title_renders_unchanged_markup
    create_mp3("mypod-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"), "# Plain Title\n\n## Transcript\n\nText.")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_cover.jpg"), "fake image data")
    write_history([{ "date" => "2026-01-15", "title" => "Plain Title" }])

    build_generator(image: "cover.jpg").generate

    page = File.read(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15.html"))
    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_includes page, "<title>Plain Title — My Podcast</title>"
    assert_includes page, 'alt="Plain Title">'
    assert_includes page, "<h1>Plain Title</h1>"
    assert_includes index, "<title>My Podcast</title>"
    assert_includes index, 'alt="My Podcast">'
    assert_includes index, "<h1>My Podcast"
    assert_includes index, 'href="episodes/mypod-2026-01-15.html">Plain Title</a>'
  end

  def test_generate_title_with_markup_characters_is_escaped_on_page_and_index
    create_mp3("mypod-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"), "# A \"b\" <i> & c\n\n## Transcript\n\nText.")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_cover.jpg"), "fake image data")
    write_history([{ "date" => "2026-01-15", "title" => "ignored" }])

    build_generator(title: "Pod <b> & \"Co\"", image: "cover.jpg").generate

    page = File.read(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15.html"))
    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_includes page, "<title>A \"b\" &lt;i&gt; &amp; c — Pod &lt;b&gt; &amp; \"Co\"</title>"
    assert_includes page, 'alt="A &quot;b&quot; &lt;i&gt; &amp; c">'
    assert_includes page, "<h1>A \"b\" &lt;i&gt; &amp; c</h1>"
    assert_includes index, "<title>Pod &lt;b&gt; &amp; \"Co\"</title>"
    assert_includes index, 'alt="Pod &lt;b&gt; &amp; &quot;Co&quot;">'
    assert_includes index, "<h1>Pod &lt;b&gt; &amp; \"Co\""
    assert_includes index, 'href="episodes/mypod-2026-01-15.html">A "b" &lt;i&gt; &amp; c</a>'
    refute_includes page, "<i>"
    refute_includes index, "<i>"
    refute_includes index, "<b>"
  end

  def test_generate_history_title_with_ampersand_is_escaped_on_language_page
    create_mp3("mypod-2026-01-15.mp3")
    create_mp3("mypod-2026-01-15-es.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Tom & Jerry <x>" }])

    build_generator(languages: [{ "code" => "en" }, { "code" => "es" }]).generate

    es_index = File.read(File.join(@podcast_dir, "site", "es", "index.html"))
    es_page = File.read(File.join(@podcast_dir, "site", "es", "episodes", "mypod-2026-01-15-es.html"))
    assert_includes es_index, ">Tom &amp; Jerry &lt;x&gt;</a>"
    assert_includes es_page, "<h1>Tom &amp; Jerry &lt;x&gt;</h1>"
  end

  def test_episode_page_no_cover_when_absent
    create_mp3("mypod-2026-01-15.mp3")
    write_history([{ "date" => "2026-01-15", "title" => "Ep" }])

    gen = build_generator
    gen.generate

    page = File.read(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15.html"))
    refute_includes page, "episode-cover"
  end

  # --- vocabulary link ---

  def test_episode_page_shows_vocab_link_when_vocabulary_present
    create_mp3("mypod-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"),
      "# Ep\n\n## Transcript\n\nHe **razglasil** it.\n\n## Vocabulary\n\n- **razglasiti** (C1 v.) *razglasil* — to announce")
    write_history([{ "date" => "2026-01-15", "title" => "Ep" }])

    gen = build_generator
    gen.generate

    page = File.read(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15.html"))
    assert_includes page, 'href="#vocabulary"'
    assert_includes page, "Vocabulary"
  end

  def test_episode_page_no_vocab_link_when_no_vocabulary
    create_mp3("mypod-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"), "# Ep\n\n## Transcript\n\nPlain text.")
    write_history([{ "date" => "2026-01-15", "title" => "Ep" }])

    gen = build_generator
    gen.generate

    page = File.read(File.join(@podcast_dir, "site", "episodes", "mypod-2026-01-15.html"))
    refute_includes page, 'href="#vocabulary"'
  end

  # --- find_episode_cover ---

  def test_find_episode_cover_returns_path_when_exists
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_cover.jpg"), "img")
    gen = build_generator
    result = gen.send(:find_episode_cover, "mypod-2026-01-15")
    assert_includes result, "mypod-2026-01-15_cover.jpg"
  end

  def test_find_episode_cover_returns_nil_when_missing
    gen = build_generator
    assert_nil gen.send(:find_episode_cover, "mypod-2026-01-15")
  end

  # --- wide_image? ---

  def test_wide_image_returns_true_for_landscape
    skip_unless_command("magick")
    gen = build_generator
    img_path = File.join(@episodes_dir, "wide.jpg")
    system("magick", "-size", "200x100", "xc:white", img_path)
    assert gen.send(:wide_image?, img_path)
  end

  def test_wide_image_returns_false_for_square
    skip_unless_command("magick")
    gen = build_generator
    img_path = File.join(@episodes_dir, "square.jpg")
    system("magick", "-size", "100x100", "xc:white", img_path)
    refute gen.send(:wide_image?, img_path)
  end

  def test_wide_image_returns_false_for_portrait
    skip_unless_command("magick")
    gen = build_generator
    img_path = File.join(@episodes_dir, "tall.jpg")
    system("magick", "-size", "100x200", "xc:white", img_path)
    refute gen.send(:wide_image?, img_path)
  end

  def test_wide_image_returns_false_for_missing_file
    gen = build_generator
    refute gen.send(:wide_image?, "/nonexistent/image.jpg")
  end

  # --- transcript_has_vocabulary? ---

  def test_transcript_has_vocabulary_true
    path = File.join(@episodes_dir, "test.md")
    File.write(path, "# Title\n\n## Transcript\n\nText.\n\n## Vocabulary\n\n- word")
    gen = build_generator
    assert gen.send(:transcript_has_vocabulary?, path)
  end

  def test_transcript_has_vocabulary_false
    path = File.join(@episodes_dir, "test.md")
    File.write(path, "# Title\n\n## Transcript\n\nText only.")
    gen = build_generator
    refute gen.send(:transcript_has_vocabulary?, path)
  end

  def test_transcript_has_vocabulary_nil_path
    gen = build_generator
    refute gen.send(:transcript_has_vocabulary?, nil)
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

  def test_feed_url_sl_primary_en_is_translated_feed
    gen = build_generator(languages: [{ "code" => "sl" }, { "code" => "en" }], base_url: "https://example.com/pod")
    assert_equal "https://example.com/pod/feed.xml", gen.send(:feed_url, "sl")
    assert_equal "https://example.com/pod/feed-en.xml", gen.send(:feed_url, "en")
  end

  def test_initialize_sl_primary_maps_en_variant_duration
    write_history([{ "date" => "2026-01-15", "title" => "Epizoda", "duration" => 60.0,
                     "languages" => { "en" => { "duration" => 125.0 } } }])
    gen = build_generator(languages: [{ "code" => "sl" }, { "code" => "en" }])
    durations = gen.instance_variable_get(:@duration_map)
    assert_equal 125.0, durations["mypod-2026-01-15-en.mp3"]
    refute durations.key?("mypod-2026-01-15-sl.mp3")
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

  # --- index paging (P20-8): characterisation of the pre-change list ---

  # The episode list a 12-episode show rendered BEFORE the index paging change
  # (captured at master 6ff249c). Paging may only add loading="lazy" to it.
  INDEX_12_EPISODES_LIST = <<~HTML
    <ul class="episode-list">
      <li class="episode-item">
        <div class="episode-content">
          <div class="episode-meta">January 12, 2026 &middot; 12:07 <select class="speed-selector"></select></div>
          <a class="episode-title" href="episodes/mypod-2026-01-12.html">Episode 12</a>
          <audio controls preload="metadata" src="https://ex.com/pod/episodes/mypod-2026-01-12.mp3"></audio>
        </div>
      </li>
      <li class="episode-item">
        <a href="episodes/mypod-2026-01-11.html"><img class="episode-thumb" src="episodes/mypod-2026-01-11_cover.jpg" alt=""></a>
        <div class="episode-content">
          <div class="episode-meta">January 11, 2026 &middot; 11:07 <select class="speed-selector"></select></div>
          <a class="episode-title" href="episodes/mypod-2026-01-11.html">Episode 11</a>
          <audio controls preload="metadata" src="https://ex.com/pod/episodes/mypod-2026-01-11.mp3"></audio>
        </div>
      </li>
      <li class="episode-item">
        <div class="episode-content">
          <div class="episode-meta">January 10, 2026 &middot; 10:07 <select class="speed-selector"></select></div>
          <a class="episode-title" href="episodes/mypod-2026-01-10.html">Episode 10</a>
          <audio controls preload="metadata" src="https://ex.com/pod/episodes/mypod-2026-01-10.mp3"></audio>
        </div>
      </li>
      <li class="episode-item">
        <a href="episodes/mypod-2026-01-09.html"><img class="episode-thumb" src="episodes/mypod-2026-01-09_cover.jpg" alt=""></a>
        <div class="episode-content">
          <div class="episode-meta">January 09, 2026 &middot; 9:07 <select class="speed-selector"></select></div>
          <a class="episode-title" href="episodes/mypod-2026-01-09.html">Episode 9</a>
          <audio controls preload="metadata" src="https://ex.com/pod/episodes/mypod-2026-01-09.mp3"></audio>
        </div>
      </li>
      <li class="episode-item">
        <div class="episode-content">
          <div class="episode-meta">January 08, 2026 &middot; 8:07 <select class="speed-selector"></select></div>
          <a class="episode-title" href="episodes/mypod-2026-01-08.html">Episode 8</a>
          <audio controls preload="metadata" src="https://ex.com/pod/episodes/mypod-2026-01-08.mp3"></audio>
        </div>
      </li>
      <li class="episode-item">
        <a href="episodes/mypod-2026-01-07.html"><img class="episode-thumb" src="episodes/mypod-2026-01-07_cover.jpg" alt=""></a>
        <div class="episode-content">
          <div class="episode-meta">January 07, 2026 &middot; 7:07 <select class="speed-selector"></select></div>
          <a class="episode-title" href="episodes/mypod-2026-01-07.html">Episode 7</a>
          <audio controls preload="metadata" src="https://ex.com/pod/episodes/mypod-2026-01-07.mp3"></audio>
        </div>
      </li>
      <li class="episode-item">
        <div class="episode-content">
          <div class="episode-meta">January 06, 2026 &middot; 6:07 <select class="speed-selector"></select></div>
          <a class="episode-title" href="episodes/mypod-2026-01-06.html">Episode 6</a>
          <audio controls preload="metadata" src="https://ex.com/pod/episodes/mypod-2026-01-06.mp3"></audio>
        </div>
      </li>
      <li class="episode-item">
        <a href="episodes/mypod-2026-01-05.html"><img class="episode-thumb" src="episodes/mypod-2026-01-05_cover.jpg" alt=""></a>
        <div class="episode-content">
          <div class="episode-meta">January 05, 2026 &middot; 5:07 <select class="speed-selector"></select></div>
          <a class="episode-title" href="episodes/mypod-2026-01-05.html">Tom &amp; Jerry &lt;5&gt;</a>
          <audio controls preload="metadata" src="https://ex.com/pod/episodes/mypod-2026-01-05.mp3"></audio>
        </div>
      </li>
      <li class="episode-item">
        <div class="episode-content">
          <div class="episode-meta">January 04, 2026 &middot; 4:07 <select class="speed-selector"></select></div>
          <a class="episode-title" href="episodes/mypod-2026-01-04.html">Episode 4</a>
          <audio controls preload="metadata" src="https://ex.com/pod/episodes/mypod-2026-01-04.mp3"></audio>
        </div>
      </li>
      <li class="episode-item">
        <a href="episodes/mypod-2026-01-03.html"><img class="episode-thumb" src="episodes/mypod-2026-01-03_cover.jpg" alt=""></a>
        <div class="episode-content">
          <div class="episode-meta">January 03, 2026 <select class="speed-selector"></select></div>
          <a class="episode-title" href="episodes/mypod-2026-01-03.html">Episode 3</a>
          <audio controls preload="metadata" src="https://ex.com/pod/episodes/mypod-2026-01-03.mp3"></audio>
        </div>
      </li>
      <li class="episode-item">
        <div class="episode-content">
          <div class="episode-meta">January 02, 2026 &middot; 2:07 <select class="speed-selector"></select></div>
          <a class="episode-title" href="episodes/mypod-2026-01-02.html">Episode 2</a>
          <audio controls preload="metadata" src="https://ex.com/pod/episodes/mypod-2026-01-02.mp3"></audio>
        </div>
      </li>
      <li class="episode-item">
        <a href="episodes/mypod-2026-01-01.html"><img class="episode-thumb" src="episodes/mypod-2026-01-01_cover.jpg" alt=""></a>
        <div class="episode-content">
          <div class="episode-meta">January 01, 2026 &middot; 1:07 <select class="speed-selector"></select></div>
          <a class="episode-title" href="episodes/mypod-2026-01-01.html">Episode 1</a>
          <audio controls preload="metadata" src="https://ex.com/pod/episodes/mypod-2026-01-01.mp3"></audio>
        </div>
      </li>
    </ul>
  HTML

  def test_generate_index_12_episodes_list_matches_pre_paging_markup
    write_paging_fixture

    build_generator(base_url: "https://ex.com/pod").generate

    assert_equal INDEX_12_EPISODES_LIST, index_episode_list.gsub(' loading="lazy"', "")
  end

  # --- index paging (P20-8) ---

  def test_generate_index_30_episodes_renders_12_players_and_defers_18
    write_paging_fixture(older: 18)

    build_generator(base_url: "https://ex.com/pod").generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_equal 12, index.scan("<audio").size
    assert_equal 18, index.scan("data-audio=").size
    assert_equal 18, index.scan('<li class="episode-item" hidden').size
    assert_equal 1, index.scan('<button class="show-more"').size
    assert_includes index, "Show more episodes (18 remaining)"
  end

  def test_generate_index_deferred_item_has_links_and_data_but_no_media
    write_paging_fixture(older: 1)
    File.write(File.join(@episodes_dir, "mypod-2025-12-01_cover.jpg"), "img")

    build_generator(base_url: "https://ex.com/pod").generate

    hidden = index_episode_list[%r{  <li class="episode-item" hidden.*?</li>\n}m]
    assert_includes hidden, 'data-audio="https://ex.com/pod/episodes/mypod-2025-12-01.mp3"'
    assert_includes hidden, 'data-thumb="episodes/mypod-2025-12-01_cover.jpg"'
    assert_includes hidden, 'href="episodes/mypod-2025-12-01.html">Old 1</a>'
    assert_includes hidden, "December 01, 2025 &middot; 0:30"
    assert_includes hidden, '<select class="speed-selector"></select>'
    refute_includes hidden, "<audio"
    refute_includes hidden, "<img"
  end

  def test_generate_index_with_deferred_items_keeps_first_12_markup
    write_paging_fixture(older: 2)

    build_generator(base_url: "https://ex.com/pod").generate

    item = %r{  <li class="episode-item">\n.*?</li>\n}m
    shown = index_episode_list.gsub(' loading="lazy"', "").scan(item)
    assert_equal INDEX_12_EPISODES_LIST.scan(item), shown
  end

  def test_generate_index_12_or_fewer_episodes_has_no_show_more
    write_paging_fixture

    build_generator(base_url: "https://ex.com/pod").generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    refute_includes index, "show-more"
    refute_includes index, "data-audio="
    refute_includes index, "<noscript>"
  end

  def test_generate_index_episodes_key_sets_page_size
    write_paging_fixture(older: 18)

    build_generator(base_url: "https://ex.com/pod", site_config: {index_episodes: 5}).generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    assert_equal 5, index.scan("<audio").size
    assert_equal 25, index.scan("data-audio=").size
    assert_includes index, "Show more episodes (25 remaining)"
    assert_includes index, 'data-batch="5"'
  end

  def test_generate_index_every_episode_thumb_is_lazy
    write_paging_fixture

    build_generator(base_url: "https://ex.com/pod").generate

    thumbs = File.read(File.join(@podcast_dir, "site", "index.html")).scan(/<img class="episode-thumb"[^>]*>/)
    assert_equal 6, thumbs.size
    assert(thumbs.all? { |t| t.include?('loading="lazy"') }, thumbs.inspect)
  end

  def test_generate_index_deferred_items_have_noscript_feed_line
    write_paging_fixture(older: 1)

    build_generator(base_url: "https://ex.com/pod").generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    noscript = index[%r{<noscript>.*?</noscript>}m]
    assert noscript, "noscript line expected"
    assert_includes noscript, 'href="https://ex.com/pod/feed.xml"'
  end

  def test_generate_stylesheet_keeps_deferred_items_hidden_over_flex_display
    write_paging_fixture

    build_generator.generate

    css = File.read(File.join(@podcast_dir, "site", "style.css"))
    assert_includes css, ".episode-item[hidden] { display: none; }"
  end

  def test_generate_index_reveal_script_builds_lazy_media
    write_paging_fixture(older: 1)

    build_generator(base_url: "https://ex.com/pod").generate

    index = File.read(File.join(@podcast_dir, "site", "index.html"))
    script = index[%r{<script>(?:(?!</script>).)*show-more.*?</script>}m]
    assert script, "reveal script expected"
    assert_includes script, "data-audio"
    assert_includes script, "data-thumb"
    assert_includes script, "'lazy'"
    assert_includes script, "'none'"
    assert_includes script, "playbackRate"
  end

  private

  # Episodes 2026-01-01..12 (odd days carry a cover, day 3 has no duration,
  # day 5 has markup characters) plus `older` episodes dated December 2025.
  def write_paging_fixture(older: 0)
    rows = (1..older).map do |d|
      date = format("2025-12-%02d", d)
      create_mp3("mypod-#{date}.mp3")
      {"date" => date, "title" => "Old #{d}", "duration" => 30.0}
    end
    (1..12).each do |d|
      date = format("2026-01-%02d", d)
      create_mp3("mypod-#{date}.mp3")
      File.write(File.join(@episodes_dir, "mypod-#{date}_cover.jpg"), "img") if d.odd?
      row = {"date" => date, "title" => ((d == 5) ? "Tom & Jerry <#{d}>" : "Episode #{d}")}
      row["duration"] = 60.0 * d + 7 unless d == 3
      rows << row
    end
    write_history(rows)
  end

  def index_episode_list(path = File.join(@podcast_dir, "site", "index.html"))
    File.read(path)[%r{<ul class="episode-list">.*?</ul>\n}m]
  end

  def create_mp3(name)
    path = File.join(@episodes_dir, name)
    File.write(path, "x" * 1000)
    path
  end

  def write_history(entries)
    File.write(@history_path, entries.to_yaml)
  end

  FakeConfig = Struct.new(:episodes_dir, :languages, :base_url, :history_path, :title, :description, :image, :site_config, :site_css_path, :favicon_path, keyword_init: true)

  def build_generator(languages: nil, base_url: nil, clean: false, site_config: nil, site_css_path: nil, favicon_path: nil, description: "A test podcast", title: "My Podcast", image: nil)
    languages ||= [{ "code" => "en" }]
    config = FakeConfig.new(
      episodes_dir: @episodes_dir,
      languages: languages,
      base_url: base_url,
      history_path: @history_path,
      title: title,
      description: description,
      image: image,
      site_config: site_config || {},
      site_css_path: site_css_path,
      favicon_path: favicon_path
    )

    SiteGenerator.new(config: config, base_url: base_url, clean: clean)
  end
end
