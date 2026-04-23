# frozen_string_literal: true

require_relative "../test_helper"
require "rss_generator"

class TestRssGenerator < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rss_test")
    @episodes_dir = File.join(@dir, "episodes")
    @feed_path = File.join(@dir, "feed.xml")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- convert_transcripts ---

  def test_convert_transcripts_creates_html_from_transcript_md
    md = File.join(@episodes_dir, "test-2026-01-01_transcript.md")
    File.write(md, "# Title\n\nSome intro\n\n## Transcript\n\nFirst paragraph.\n\nSecond paragraph.")

    RssGenerator.convert_transcripts(@episodes_dir)

    html_path = md.sub(/\.md$/, ".html")
    assert File.exist?(html_path), "HTML file should be created"
    html = File.read(html_path)
    assert_includes html, "<p>First paragraph.</p>"
    assert_includes html, "<p>Second paragraph.</p>"
    refute_includes html, "Title"
  end

  def test_convert_transcripts_creates_html_from_script_md
    md = File.join(@episodes_dir, "test-2026-01-01_script.md")
    File.write(md, "# Episode Title\n\nMeta line\n\nContent here.\n\nMore content.")

    RssGenerator.convert_transcripts(@episodes_dir)

    html_path = md.sub(/\.md$/, ".html")
    assert File.exist?(html_path)
    html = File.read(html_path)
    assert_includes html, "<p>Content here.</p>"
  end

  def test_convert_transcripts_skips_up_to_date_html
    md = File.join(@episodes_dir, "test-2026-01-01_transcript.md")
    File.write(md, "# T\n\n## Transcript\n\nOld text.")
    RssGenerator.convert_transcripts(@episodes_dir)

    html_path = md.sub(/\.md$/, ".html")
    first_content = File.read(html_path)

    # Touch HTML to be newer — should skip
    sleep 0.05
    File.write(html_path, first_content)
    File.write(md, "# T\n\n## Transcript\n\nNew text.")
    # Make md older than html
    File.utime(Time.now - 10, Time.now - 10, md)

    RssGenerator.convert_transcripts(@episodes_dir)
    assert_equal first_content, File.read(html_path), "Should not rewrite up-to-date HTML"
  end

  def test_convert_transcripts_escapes_html_entities
    md = File.join(@episodes_dir, "test-2026-01-01_transcript.md")
    File.write(md, "# Title\n\n## Transcript\n\nUse <script> & \"quotes\".")

    RssGenerator.convert_transcripts(@episodes_dir)

    html = File.read(md.sub(/\.md$/, ".html"))
    assert_includes html, "&lt;script&gt;"
    assert_includes html, "&amp;"
    refute_includes html, "<script>"
  end

  def test_convert_transcripts_strips_vocabulary_section
    md = File.join(@episodes_dir, "test-2026-01-01_transcript.md")
    File.write(md, <<~MD)
      # Title

      ## Transcript

      The **word** is here.

      ## Vocabulary

      **B1**
      - **word** (noun) — translation. definition
    MD

    RssGenerator.convert_transcripts(@episodes_dir)

    html = File.read(md.sub(/\.md$/, ".html"))
    # Vocabulary section should be completely stripped for podcast apps
    refute_includes html, "Vocabulary", "Vocabulary section should not appear in RSS transcript"
    refute_includes html, "translation", "Vocabulary entries should not appear in RSS transcript"
    refute_includes html, "<dt", "Vocabulary HTML should not appear in RSS transcript"
  end

  def test_convert_transcripts_unbolds_vocab_words
    md = File.join(@episodes_dir, "test-2026-01-01_transcript.md")
    File.write(md, <<~MD)
      # Title

      ## Transcript

      The **beseda** is here.

      ## Vocabulary

      **B1**
      - **beseda** (noun) — word. a unit of language
    MD

    RssGenerator.convert_transcripts(@episodes_dir)

    html = File.read(md.sub(/\.md$/, ".html"))
    # Bold markers should be removed, word kept as plain text
    assert_includes html, "The beseda is here.", "Vocab words should appear as plain text"
    refute_includes html, "**beseda**", "Bold markers should be removed"
    refute_includes html, "vocab-beseda", "No vocab anchors in RSS transcript"
  end

  def test_convert_transcripts_renders_markdown_links
    md = File.join(@episodes_dir, "test-2026-01-01_script.md")
    File.write(md, "# Title\n\nMeta\n\n## More info\n\n- [Example](https://example.com)\n- [Other](https://other.com)")

    RssGenerator.convert_transcripts(@episodes_dir)

    html = File.read(md.sub(/\.md$/, ".html"))
    assert_includes html, '<a href="https://example.com"'
    assert_includes html, "Example</a>"
  end

  # --- scan_episodes ---

  def test_scan_episodes_finds_mp3s_with_dates
    create_mp3("test-2026-01-15.mp3", 1000)
    create_mp3("test-2026-01-16.mp3", 2000)

    gen = build_generator(language: "en")
    episodes = gen.send(:scan_episodes)

    assert_equal 2, episodes.length
    # Reverse chronological
    assert_equal "test-2026-01-16.mp3", episodes.first[:filename]
    assert_equal 2000, episodes.first[:size]
  end

  def test_scan_episodes_filters_by_language
    create_mp3("test-2026-01-15.mp3", 1000)
    create_mp3("test-2026-01-15-es.mp3", 1000)
    create_mp3("test-2026-01-15-fr.mp3", 1000)

    en_gen = build_generator(language: "en")
    assert_equal 1, en_gen.send(:scan_episodes).length

    es_gen = build_generator(language: "es")
    assert_equal 1, es_gen.send(:scan_episodes).length
    assert_equal "test-2026-01-15-es.mp3", es_gen.send(:scan_episodes).first[:filename]
  end

  def test_scan_episodes_skips_concat_files
    create_mp3("test-2026-01-15.mp3", 1000)
    create_mp3("test-2026-01-15_concat.mp3", 500)

    gen = build_generator(language: "en")
    episodes = gen.send(:scan_episodes)
    assert_equal 1, episodes.length
  end

  def test_scan_episodes_skips_files_without_dates
    create_mp3("test-nodatehere.mp3", 1000)

    gen = build_generator(language: "en")
    assert_empty gen.send(:scan_episodes)
  end

  # --- matches_language? (now in EpisodeFiltering module) ---

  def test_matches_language_english_no_suffix
    assert EpisodeFiltering.matches_language?("test-2026-01-15", "en")
    refute EpisodeFiltering.matches_language?("test-2026-01-15-es", "en")
  end

  def test_matches_language_non_english
    assert EpisodeFiltering.matches_language?("test-2026-01-15-es", "es")
    refute EpisodeFiltering.matches_language?("test-2026-01-15", "es")
    refute EpisodeFiltering.matches_language?("test-2026-01-15-fr", "es")
  end

  # --- format_duration ---

  def test_format_duration_from_duration_map
    gen = build_generator
    gen.instance_variable_set(:@duration_map, { "test-2026-01-15.mp3" => 185.7 })

    ep = { filename: "test-2026-01-15.mp3", path: "/fake.mp3", size: 100_000 }
    assert_equal "3:05", gen.send(:format_duration, ep)
  end

  def test_format_duration_fallback_to_size_estimate
    gen = build_generator
    gen.instance_variable_set(:@duration_map, {})

    # 192kbps = 24000 bytes/sec. 240000 bytes = 10 seconds
    ep = { filename: "test.mp3", path: "/nonexistent.mp3", size: 240_000 }
    assert_equal "0:10", gen.send(:format_duration, ep)
  end

  # --- build_history_maps ---

  def test_build_history_maps_from_yaml
    history_path = File.join(@dir, "history.yml")
    File.write(history_path, [
      { "date" => "2026-01-15", "title" => "Episode One", "duration" => 120.5, "timestamp" => "2026-01-15T06:00:00+00:00" },
      { "date" => "2026-01-15", "title" => "Episode Two", "duration" => 200.0 }
    ].to_yaml)

    # The podcast name comes from parent of episodes_dir
    podcast_dir = File.join(@dir, "mypod")
    ep_dir = File.join(podcast_dir, "episodes")
    FileUtils.mkdir_p(ep_dir)

    gen = RssGenerator.new(
      episodes_dir: ep_dir,
      feed_path: @feed_path,
      history_path: history_path
    )

    title_map = gen.instance_variable_get(:@title_map)
    duration_map = gen.instance_variable_get(:@duration_map)
    timestamp_map = gen.instance_variable_get(:@timestamp_map)

    assert_equal "Episode One", title_map["mypod-2026-01-15.mp3"]
    assert_equal "Episode Two", title_map["mypod-2026-01-15a.mp3"]
    assert_in_delta 120.5, duration_map["mypod-2026-01-15.mp3"]
    assert_equal "2026-01-15T06:00:00+00:00", timestamp_map["mypod-2026-01-15.mp3"]
  end

  def test_build_history_maps_handles_missing_file
    gen = build_generator(history_path: "/nonexistent.yml")
    assert_empty gen.instance_variable_get(:@title_map)
  end

  def test_build_history_maps_handles_corrupted_yaml
    history_path = File.join(@dir, "history.yml")
    File.write(history_path, "not: a: valid: yaml: [")

    gen = build_generator(history_path: history_path)
    assert_empty gen.instance_variable_get(:@title_map)
  end

  # --- build_feed ---

  def test_generate_produces_valid_rss
    create_mp3("test-2026-01-15.mp3", 5000)

    history_path = File.join(@dir, "history.yml")
    # Use the parent dir name as podcast name
    File.write(history_path, [
      { "date" => "2026-01-15", "title" => "My Episode", "duration" => 60.0, "timestamp" => "2026-01-15T08:30:00+01:00" }
    ].to_yaml)

    gen = RssGenerator.new(
      episodes_dir: @episodes_dir,
      feed_path: @feed_path,
      title: "Test Pod",
      author: "Tester",
      language: "en",
      base_url: "https://example.com/test",
      history_path: history_path
    )

    path = gen.generate
    assert File.exist?(path)

    xml = File.read(path)
    assert_includes xml, "<title>Test Pod</title>"
    assert_includes xml, "<itunes:author>Tester</itunes:author>"
    assert_includes xml, "<language>en</language>"
    assert_includes xml, "audio/mpeg"
    assert_includes xml, "https://example.com/test/episodes/"
  end

  def test_generate_uses_date_fallback_when_no_timestamp
    create_mp3("test-2026-03-01.mp3", 1000)

    gen = build_generator(language: "en")
    gen.generate

    xml = File.read(@feed_path)
    assert_includes xml, "06:00:00"
  end

  def test_generate_pubdate_uses_episode_date_not_processing_timestamp
    # Episode date is 2026-01-15 but was processed on 2026-04-23
    create_mp3("test-2026-01-15.mp3", 1000)
    history_path = File.join(@dir, "history.yml")
    File.write(history_path, [
      { "date" => "2026-01-15", "title" => "Backfilled Episode",
        "timestamp" => "2026-04-23T22:42:39+02:00" }
    ].to_yaml)

    podcast_dir = File.join(@dir, "test")
    ep_dir = File.join(podcast_dir, "episodes")
    FileUtils.mkdir_p(ep_dir)
    FileUtils.cp(File.join(@episodes_dir, "test-2026-01-15.mp3"), ep_dir)

    feed = File.join(@dir, "pubdate_feed.xml")
    gen = RssGenerator.new(
      episodes_dir: ep_dir,
      feed_path: feed,
      title: "Test",
      language: "en",
      history_path: history_path
    )
    gen.generate

    xml = File.read(feed)
    # pubDate must contain Jan 2026, NOT Apr 2026
    assert_match(/15 Jan 2026/, xml)
    refute_match(/23 Apr 2026/, xml.split("lastBuildDate").last)
  end

  def test_generate_includes_transcript_link
    create_mp3("test-2026-01-15.mp3", 1000)
    File.write(File.join(@episodes_dir, "test-2026-01-15_transcript.html"), "<html></html>")

    gen = build_generator(language: "en", base_url: "https://example.com")
    gen.generate

    xml = File.read(@feed_path)
    assert_includes xml, "podcast:transcript"
    assert_includes xml, "test-2026-01-15_transcript.html"
  end

  def test_generate_with_image
    create_mp3("test-2026-01-15.mp3", 1000)

    gen = build_generator(language: "en", base_url: "https://example.com", image: "cover.jpg")
    gen.generate

    xml = File.read(@feed_path)
    assert_includes xml, "https://example.com/cover.jpg"
    assert_includes xml, "itunes:image"
  end

  # --- Non-English language maps ---

  def test_build_history_maps_for_non_english
    history_path = File.join(@dir, "history.yml")
    File.write(history_path, [
      { "date" => "2026-01-15", "title" => "English Title", "duration" => 60.0 }
    ].to_yaml)

    podcast_dir = File.join(@dir, "mypod")
    ep_dir = File.join(podcast_dir, "episodes")
    FileUtils.mkdir_p(ep_dir)

    # Create a translated script with a title line
    File.write(File.join(ep_dir, "mypod-2026-01-15-es_script.md"), "# Título en Español\n\nContent")

    gen = RssGenerator.new(
      episodes_dir: ep_dir,
      feed_path: @feed_path,
      language: "es",
      history_path: history_path
    )

    title_map = gen.instance_variable_get(:@title_map)
    assert_equal "Título en Español", title_map["mypod-2026-01-15-es.mp3"]
  end

  # --- RSS XML structure ---

  def test_generate_rss_has_channel_element
    create_mp3("test-2026-01-15.mp3", 1000)
    gen = build_generator(language: "en", base_url: "https://example.com")
    gen.generate

    xml = File.read(@feed_path)
    assert_includes xml, "<channel>"
    assert_includes xml, "</channel>"
  end

  def test_generate_rss_has_item_with_enclosure
    create_mp3("test-2026-01-15.mp3", 5000)
    gen = build_generator(language: "en", base_url: "https://example.com")
    gen.generate

    xml = File.read(@feed_path)
    assert_includes xml, "<item>"
    assert_includes xml, "<enclosure"
    assert_includes xml, "type='audio/mpeg'"
  end

  def test_generate_empty_episodes_produces_valid_feed
    gen = build_generator(language: "en", base_url: "https://example.com")
    gen.generate

    xml = File.read(@feed_path)
    assert_includes xml, "<rss"
    assert_includes xml, "<channel>"
    refute_includes xml, "<item>"
  end

  def test_generate_title_from_history_in_item
    create_mp3("test-2026-01-15.mp3", 1000)
    history_path = File.join(@dir, "history.yml")
    File.write(history_path, [
      { "date" => "2026-01-15", "title" => "Custom Title", "duration" => 60.0 }
    ].to_yaml)

    podcast_dir = File.join(@dir, "test")
    ep_dir = File.join(podcast_dir, "episodes")
    FileUtils.mkdir_p(ep_dir)
    FileUtils.cp(File.join(@episodes_dir, "test-2026-01-15.mp3"), ep_dir)

    feed = File.join(@dir, "custom_feed.xml")
    gen = RssGenerator.new(
      episodes_dir: ep_dir,
      feed_path: feed,
      title: "My Pod",
      language: "en",
      base_url: "https://example.com",
      history_path: history_path
    )
    gen.generate

    xml = File.read(feed)
    assert_includes xml, "<title>Custom Title</title>"
  end

  def test_generate_prefers_transcript_title_over_history
    create_mp3("test-2026-01-15.mp3", 1000)
    history_path = File.join(@dir, "history.yml")
    File.write(history_path, [
      { "date" => "2026-01-15", "title" => "History Title" }
    ].to_yaml)

    podcast_dir = File.join(@dir, "test")
    ep_dir = File.join(podcast_dir, "episodes")
    FileUtils.mkdir_p(ep_dir)
    FileUtils.cp(File.join(@episodes_dir, "test-2026-01-15.mp3"), ep_dir)
    File.write(File.join(ep_dir, "test-2026-01-15_transcript.md"), "# Transcript Title\n\n## Transcript\n\nBody.")

    feed = File.join(@dir, "title_feed.xml")
    gen = RssGenerator.new(
      episodes_dir: ep_dir,
      feed_path: feed,
      title: "My Pod",
      language: "en",
      base_url: "https://example.com",
      history_path: history_path
    )
    gen.generate

    xml = File.read(feed)
    assert_includes xml, "<title>Transcript Title</title>"
    refute_includes xml, "History Title"
  end

  def test_generate_correct_title_with_scrapped_episodes
    # 3 history entries, middle episode scrapped
    create_mp3("test-2026-01-15.mp3", 1000)
    create_mp3("test-2026-01-15b.mp3", 1000)

    history_path = File.join(@dir, "history.yml")
    File.write(history_path, [
      { "date" => "2026-01-15", "title" => "First" },
      { "date" => "2026-01-15", "title" => "Second (scrapped)" },
      { "date" => "2026-01-15", "title" => "Third" }
    ].to_yaml)

    podcast_dir = File.join(@dir, "test")
    ep_dir = File.join(podcast_dir, "episodes")
    FileUtils.mkdir_p(ep_dir)
    FileUtils.cp(File.join(@episodes_dir, "test-2026-01-15.mp3"), ep_dir)
    FileUtils.cp(File.join(@episodes_dir, "test-2026-01-15b.mp3"), ep_dir)
    File.write(File.join(ep_dir, "test-2026-01-15_transcript.md"), "# First\n\n## Transcript\n\nBody.")
    File.write(File.join(ep_dir, "test-2026-01-15b_transcript.md"), "# Third\n\n## Transcript\n\nBody.")

    feed = File.join(@dir, "scrap_feed.xml")
    gen = RssGenerator.new(
      episodes_dir: ep_dir,
      feed_path: feed,
      title: "My Pod",
      language: "en",
      base_url: "https://example.com",
      history_path: history_path
    )
    gen.generate

    xml = File.read(feed)
    # test-2026-01-15b.mp3 should get "Third" from transcript, not "Third" from history index 2
    # (which maps to suffix "b" correctly here, but would break if "a" was scrapped instead)
    assert_includes xml, "<title>Third</title>"
    refute_includes xml, "Second (scrapped)"
  end

  def test_generate_description_in_channel
    create_mp3("test-2026-01-15.mp3", 1000)
    gen = RssGenerator.new(
      episodes_dir: @episodes_dir,
      feed_path: @feed_path,
      title: "Pod",
      description: "A great podcast about things",
      language: "en",
      base_url: "https://example.com"
    )
    gen.generate

    xml = File.read(@feed_path)
    assert_includes xml, "A great podcast about things"
  end

  def test_generate_description_strips_markdown_links
    create_mp3("test-2026-01-15.mp3", 1000)
    gen = RssGenerator.new(
      episodes_dir: @episodes_dir,
      feed_path: @feed_path,
      title: "Pod",
      description: "Built by [Fulgur Ventures](https://fulgur.ventures)",
      language: "en",
      base_url: "https://example.com"
    )
    gen.generate

    xml = File.read(@feed_path)
    assert_includes xml, "Built by Fulgur Ventures"
    refute_includes xml, "[Fulgur"
    refute_includes xml, "fulgur.ventures"
  end

  def test_generate_missing_base_url_uses_relative
    create_mp3("test-2026-01-15.mp3", 1000)
    gen = build_generator(language: "en")
    gen.generate

    xml = File.read(@feed_path)
    # Without base_url, should still produce a feed but URLs will be relative
    assert_includes xml, "<rss"
  end

  # --- strip_markdown_links ---

  def test_strip_markdown_links_removes_link_syntax
    gen = build_generator
    result = gen.send(:strip_markdown_links, "Read [this article](https://example.com) now")
    assert_equal "Read this article now", result
  end

  def test_strip_markdown_links_handles_multiple_links
    gen = build_generator
    result = gen.send(:strip_markdown_links, "[A](url1) and [B](url2)")
    assert_equal "A and B", result
  end

  def test_strip_markdown_links_passes_through_plain_text
    gen = build_generator
    result = gen.send(:strip_markdown_links, "No links here")
    assert_equal "No links here", result
  end

  # --- extract_title_from_episode ---

  def test_extract_title_from_episode_reads_transcript
    File.write(File.join(@episodes_dir, "test-2026-01-01_transcript.md"),
      "# Episode Title\n\nDescription\n\n## Transcript\n\nBody")

    gen = build_generator
    title = gen.send(:extract_title_from_episode, "test-2026-01-01.mp3")
    assert_equal "Episode Title", title
  end

  def test_extract_title_from_episode_falls_back_to_script
    File.write(File.join(@episodes_dir, "test-2026-01-01_script.md"),
      "# Script Title\n\nContent here")

    gen = build_generator
    title = gen.send(:extract_title_from_episode, "test-2026-01-01.mp3")
    assert_equal "Script Title", title
  end

  def test_extract_title_from_episode_returns_nil_when_no_file
    gen = build_generator
    title = gen.send(:extract_title_from_episode, "nonexistent-2026-01-01.mp3")
    assert_nil title
  end

  private

  def create_mp3(name, size)
    path = File.join(@episodes_dir, name)
    File.write(path, "x" * size)
    path
  end

  def build_generator(language: "en", base_url: nil, image: nil, history_path: nil)
    RssGenerator.new(
      episodes_dir: @episodes_dir,
      feed_path: @feed_path,
      language: language,
      base_url: base_url,
      image: image,
      history_path: history_path
    )
  end
end
