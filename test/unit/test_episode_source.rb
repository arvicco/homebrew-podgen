# frozen_string_literal: true

require_relative "../test_helper"
require "episode_source"

class TestEpisodeSource < Minitest::Test
  # --- build_local ---

  def test_build_local_with_title
    path = create_temp_file("test.mp3", "audio data")
    ep = source.build_local(path, "My Title")

    assert_equal "My Title", ep[:title]
    assert_match(/^file:\/\//, ep[:audio_url])
    assert_equal "", ep[:description]
  end

  def test_build_local_auto_title
    path = create_temp_file("my-cool_episode.mp3", "audio data")
    ep = source.build_local(path)

    assert_equal "My Cool Episode", ep[:title]
  end

  def test_build_local_raises_for_missing_file
    assert_raises(RuntimeError) { source.build_local("/nonexistent.mp3") }
  end

  def test_build_local_raises_for_empty_file
    path = create_temp_file("empty.mp3", "")
    assert_raises(RuntimeError) { source.build_local(path) }
  end

  def test_build_local_dedup_key_uses_name_and_size
    path = create_temp_file("test.mp3", "audio data")
    ep = source.build_local(path)
    assert_match(/^file:\/\/test\.mp3:\d+$/, ep[:audio_url])
  end

  # --- build_youtube ---

  def test_build_youtube_basic
    metadata = { title: "YouTube Video", description: "Desc", url: "https://youtube.com/watch?v=abc", duration: 120 }
    ep = source.build_youtube(metadata)

    assert_equal "YouTube Video", ep[:title]
    assert_equal "Desc", ep[:description]
    assert_equal "https://youtube.com/watch?v=abc", ep[:audio_url]
    assert_equal "https://youtube.com/watch?v=abc", ep[:link]
  end

  def test_build_youtube_with_title_override
    metadata = { title: "Original", description: "", url: "https://youtube.com/watch?v=abc" }
    ep = source.build_youtube(metadata, title_override: "Custom Title")

    assert_equal "Custom Title", ep[:title]
  end

  def test_build_youtube_nil_description
    metadata = { title: "T", description: nil, url: "u" }
    ep = source.build_youtube(metadata)
    assert_equal "", ep[:description]
  end

  # --- already_processed? ---

  def test_already_processed_returns_false_with_force
    s = source(known_urls: ["http://example.com/ep.mp3"])
    ep = { audio_url: "http://example.com/ep.mp3", title: "T" }
    refute s.already_processed?(ep, force: true)
  end

  def test_already_processed_returns_false_for_new_url
    ep = { audio_url: "http://example.com/new.mp3", title: "T" }
    refute source.already_processed?(ep)
  end

  def test_already_processed_returns_true_for_known_url
    s = source(known_urls: ["http://example.com/ep.mp3"])
    ep = { audio_url: "http://example.com/ep.mp3", title: "T" }
    assert s.already_processed?(ep)
  end

  def test_already_processed_returns_false_with_dry_run
    s = source(known_urls: ["http://example.com/ep.mp3"])
    ep = { audio_url: "http://example.com/ep.mp3", title: "T" }
    refute s.already_processed?(ep, dry_run: true)
  end

  # --- fetch_next ---

  def test_fetch_next_raises_without_rss_sources
    s = source(rss_feeds: nil)
    assert_raises(RuntimeError) { s.fetch_next }
  end

  def test_fetch_next_raises_with_empty_rss_sources
    s = source(rss_feeds: [])
    assert_raises(RuntimeError) { s.fetch_next }
  end

  def setup
    @tmpdir = Dir.mktmpdir("episode_source_test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  private

  def source(known_urls: [], rss_feeds: nil)
    sources = rss_feeds.nil? ? {} : { "rss" => rss_feeds }
    config = Struct.new(:sources).new(sources)
    history = Struct.new(:all_urls).new(Set.new(known_urls))
    EpisodeSource.new(config: config, history: history)
  end

  def create_temp_file(name, content)
    path = File.join(@tmpdir, name)
    File.write(path, content)
    path
  end
end
