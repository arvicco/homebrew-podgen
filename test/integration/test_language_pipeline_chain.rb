# frozen_string_literal: true

# Integration test: verifies transcript → RSS/Site generation chain.
# Ensures TranscriptRenderer, RssGenerator, and SiteGenerator compose correctly
# when fed realistic file structures.

require_relative "../test_helper"
require "rexml/document"
require "yaml"
require "rss_generator"
require "site_generator"
require "transcript_renderer"

class TestLanguagePipelineChain < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_lpc_test")
    @podcast_dir = File.join(@tmpdir, "test_pod")
    @episodes_dir = File.join(@podcast_dir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- Transcript → RSS HTML ---

  def test_transcript_to_rss_html_strips_vocabulary_and_bold
    md_path = File.join(@episodes_dir, "test_pod-2026-03-01_transcript.md")
    File.write(md_path, <<~MD)
      # Episode Title

      A description here.

      ## Transcript

      The **fox** jumped over the **lazy** dog.

      Another paragraph with **bold** words.

      ## Vocabulary

      **A1**

      - **fox** (noun) — a clever animal _Original: fox_
    MD

    RssGenerator.convert_transcripts(@episodes_dir)

    html_path = md_path.sub(/\.md$/, ".html")
    assert File.exist?(html_path), "HTML file should be created"

    html = File.read(html_path)
    # Vocabulary section should be stripped (vocab: false for RSS)
    refute_includes html, "Vocabulary"
    refute_includes html, "clever animal"
    # Bold markers should be stripped, not linked
    refute_includes html, "**fox**"
    refute_includes html, "vocab-word"
    # Plain text should survive
    assert_includes html, "fox"
    assert_includes html, "jumped over"
    assert_includes html, "<p>"
  end

  def test_transcript_to_site_html_with_vocabulary
    renderer = TranscriptRendererHelper.new

    body = <<~BODY

      The **fox** jumped over the **lazy** dog.

      ## Vocabulary

      **A1**

      - **fox** (noun) — a clever animal _Original: fox_
    BODY

    html = renderer.render_body_html(body, vocab: true)

    # Vocabulary section should be present
    assert_includes html, "Vocabulary"
    assert_includes html, "clever animal"
    # Bold words should become vocab links
    assert_includes html, 'class="vocab-word"'
    assert_includes html, "vocab-fox"
    # Paragraph content should survive
    assert_includes html, "jumped over"
  end

  # --- RSS generation from fixtures ---

  def test_rss_generation_from_fixture_episodes
    build_episode_fixtures(2)
    feed_path = File.join(@podcast_dir, "feed.xml")

    gen = RssGenerator.new(
      episodes_dir: @episodes_dir,
      feed_path: feed_path,
      title: "Test Podcast",
      author: "Test Author",
      language: "en",
      base_url: "https://example.com/test_pod",
      history_path: File.join(@podcast_dir, "history.yml")
    )
    gen.generate

    assert File.exist?(feed_path), "feed.xml should be created"
    doc = REXML::Document.new(File.read(feed_path))

    items = REXML::XPath.match(doc, "//item")
    assert_equal 2, items.length, "Should have 2 episodes"

    # Verify enclosure URLs
    items.each do |item|
      enclosure = item.elements["enclosure"]
      assert enclosure, "Each item should have an enclosure"
      assert_match %r{^https://example\.com/test_pod/episodes/}, enclosure.attributes["url"]
      assert_equal "audio/mpeg", enclosure.attributes["type"]
    end

    # Verify titles come from history
    titles = items.map { |i| i.elements["title"].text }
    assert_includes titles, "Episode One"
    assert_includes titles, "Episode Two"

    # Verify pub dates
    items.each do |item|
      pub_date = item.elements["pubDate"]
      assert pub_date, "Each item should have pubDate"
      refute_empty pub_date.text
    end
  end

  # --- Site generation from fixtures ---

  def test_site_generation_from_fixture_episodes
    build_episode_fixtures(2, with_transcripts: true)
    config = build_site_config

    gen = SiteGenerator.new(config: config, clean: true)
    output_dir = gen.generate

    assert Dir.exist?(output_dir), "Site directory should be created"

    # Index should exist
    index_path = File.join(output_dir, "index.html")
    assert File.exist?(index_path), "index.html should exist"
    index_html = File.read(index_path)
    assert_includes index_html, "Episode One"
    assert_includes index_html, "Episode Two"

    # Episode pages should exist
    ep_dir = File.join(output_dir, "episodes")
    assert Dir.exist?(ep_dir), "episodes/ directory should exist"
    ep_files = Dir.glob(File.join(ep_dir, "*.html"))
    assert_equal 2, ep_files.length, "Should have 2 episode pages"

    # Episode page should contain transcript content
    ep_html = File.read(ep_files.sort.first)
    assert_includes ep_html, "jumped over"

    # CSS should be installed
    assert File.exist?(File.join(output_dir, "style.css"))
  end

  # --- Multi-language site ---

  def test_multi_language_site_generation
    build_multi_language_fixtures
    config = build_site_config(languages: [{ "code" => "en" }, { "code" => "es" }])

    gen = SiteGenerator.new(config: config, clean: true)
    output_dir = gen.generate

    # Primary language (en) at root
    assert File.exist?(File.join(output_dir, "index.html"))
    en_episodes = Dir.glob(File.join(output_dir, "episodes", "*.html"))
    assert_equal 1, en_episodes.length

    # Secondary language in subdirectory
    es_dir = File.join(output_dir, "es")
    assert Dir.exist?(es_dir), "es/ subdirectory should exist"
    assert File.exist?(File.join(es_dir, "index.html"))
    es_episodes = Dir.glob(File.join(es_dir, "episodes", "*.html"))
    assert_equal 1, es_episodes.length

    # Language navigation should be present
    en_index = File.read(File.join(output_dir, "index.html"))
    assert_includes en_index, "es/index.html"
  end

  # --- RSS ↔ Site consistency ---

  def test_rss_and_site_episode_count_matches
    build_episode_fixtures(3, with_transcripts: true)
    feed_path = File.join(@podcast_dir, "feed.xml")

    rss_gen = RssGenerator.new(
      episodes_dir: @episodes_dir,
      feed_path: feed_path,
      title: "Test Podcast",
      language: "en",
      base_url: "https://example.com/test_pod",
      history_path: File.join(@podcast_dir, "history.yml")
    )
    rss_gen.generate

    config = build_site_config
    site_gen = SiteGenerator.new(config: config, clean: true)
    output_dir = site_gen.generate

    # Count RSS items
    doc = REXML::Document.new(File.read(feed_path))
    rss_count = REXML::XPath.match(doc, "//item").length

    # Count site episode pages
    site_count = Dir.glob(File.join(output_dir, "episodes", "*.html")).length

    assert_equal rss_count, site_count, "RSS item count should match site episode page count"
    assert_equal 3, rss_count
  end

  # --- RSS skips up-to-date HTML ---

  def test_rss_convert_transcripts_skips_up_to_date
    md_path = File.join(@episodes_dir, "test_pod-2026-03-01_transcript.md")
    File.write(md_path, "# Title\n\n## Transcript\n\nHello world.")

    RssGenerator.convert_transcripts(@episodes_dir)
    html_path = md_path.sub(/\.md$/, ".html")
    first_mtime = File.mtime(html_path)

    # Ensure at least 1 second has passed so mtime would differ if rewritten
    sleep 0.1

    RssGenerator.convert_transcripts(@episodes_dir)
    second_mtime = File.mtime(html_path)

    assert_equal first_mtime, second_mtime, "HTML should not be regenerated when MD is unchanged"
  end

  private

  # Builds N episode fixtures with MP3s, history.yml, and optionally transcripts
  def build_episode_fixtures(count, with_transcripts: false)
    history = []

    count.times do |i|
      date = "2026-03-#{format('%02d', i + 1)}"
      filename = "test_pod-#{date}.mp3"
      titles = ["Episode One", "Episode Two", "Episode Three"]

      # Create a minimal MP3 file (just needs to exist with non-zero size)
      mp3_path = File.join(@episodes_dir, filename)
      File.write(mp3_path, "fake mp3 content " * 100)

      history << {
        "date" => date,
        "title" => titles[i] || "Episode #{i + 1}",
        "topics" => ["topic#{i}"],
        "urls" => ["https://example.com/#{i}"],
        "duration" => 300 + i * 60,
        "timestamp" => "#{date}T06:00:00Z"
      }

      if with_transcripts
        transcript_path = File.join(@episodes_dir, "test_pod-#{date}_transcript.md")
        File.write(transcript_path, <<~MD)
          # #{titles[i] || "Episode #{i + 1}"}

          A test episode description.

          ## Transcript

          The **fox** jumped over the lazy dog in episode #{i + 1}.

          Another paragraph about testing.
        MD
      end
    end

    File.write(File.join(@podcast_dir, "history.yml"), history.to_yaml)
  end

  def build_multi_language_fixtures
    date = "2026-03-01"

    # English episode
    File.write(File.join(@episodes_dir, "test_pod-#{date}.mp3"), "fake mp3 " * 100)
    File.write(File.join(@episodes_dir, "test_pod-#{date}_script.md"), <<~MD)
      # Episode One

      ## Opening

      Welcome to the show.
    MD

    # Spanish episode
    File.write(File.join(@episodes_dir, "test_pod-#{date}-es.mp3"), "fake mp3 " * 100)
    File.write(File.join(@episodes_dir, "test_pod-#{date}-es_script.md"), <<~MD)
      # Episodio Uno

      ## Apertura

      Bienvenidos al show.
    MD

    history = [{
      "date" => date,
      "title" => "Episode One",
      "topics" => ["test"],
      "urls" => [],
      "duration" => 300,
      "timestamp" => "#{date}T06:00:00Z"
    }]
    File.write(File.join(@podcast_dir, "history.yml"), history.to_yaml)
  end

  def build_site_config(languages: [{ "code" => "en" }])
    SiteConfig.new(
      episodes_dir: @episodes_dir,
      base_url: "https://example.com/test_pod",
      languages: languages,
      title: "Test Podcast",
      description: "A test podcast",
      image: nil,
      site_config: {},
      site_css_path: nil,
      favicon_path: nil,
      history_path: File.join(@podcast_dir, "history.yml")
    )
  end
end

# Minimal config struct for SiteGenerator
SiteConfig = Struct.new(
  :episodes_dir, :base_url, :languages, :title, :description,
  :image, :site_config, :site_css_path, :favicon_path, :history_path,
  keyword_init: true
)

# Helper to access TranscriptRenderer instance methods
class TranscriptRendererHelper
  include TranscriptRenderer
end
