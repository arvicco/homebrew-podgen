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

  # --- resolve_feeds ---

  def test_resolve_feeds_substring_matches_configured_feed
    feeds = [
      { url: "https://podcast.rtvslo.si/lahko_noc", skip: 38.0, autotrim: true },
      "https://other.com/feed.xml"
    ]
    s = source(rss_feeds: feeds)
    matched = s.send(:resolve_feeds, feeds, "rtvslo")
    assert_equal 1, matched.length
    assert_equal "https://podcast.rtvslo.si/lahko_noc", matched.first[:url]
    assert_equal 38.0, matched.first[:skip]
  end

  def test_resolve_feeds_substring_matches_plain_url_feed
    feeds = ["https://podcast.rtvslo.si/lahko_noc", "https://other.com/feed.xml"]
    s = source(rss_feeds: feeds)
    matched = s.send(:resolve_feeds, feeds, "rtvslo")
    assert_equal 1, matched.length
    assert_equal "https://podcast.rtvslo.si/lahko_noc", matched.first
  end

  def test_resolve_feeds_case_insensitive
    feeds = [{ url: "https://Podcast.RTVSLO.si/lahko_noc", skip: 10.0 }]
    s = source(rss_feeds: feeds)
    matched = s.send(:resolve_feeds, feeds, "rtvslo")
    assert_equal 1, matched.length
  end

  def test_resolve_feeds_no_match_url_uses_adhoc
    feeds = ["https://podcast.rtvslo.si/lahko_noc"]
    s = source(rss_feeds: feeds)
    matched = s.send(:resolve_feeds, feeds, "https://other.com/feed.xml")
    assert_equal ["https://other.com/feed.xml"], matched
  end

  def test_resolve_feeds_no_match_non_url_raises_error
    feeds = ["https://podcast.rtvslo.si/lahko_noc"]
    s = source(rss_feeds: feeds)
    err = assert_raises(RuntimeError) { s.send(:resolve_feeds, feeds, "nonexistent") }
    assert_includes err.message, "No configured RSS feed matches"
  end

  def test_resolve_feeds_nil_uses_all_feeds
    feeds = ["https://a.com/feed", "https://b.com/feed"]
    s = source(rss_feeds: feeds)
    matched = s.send(:resolve_feeds, feeds, nil)
    assert_equal feeds, matched
  end

  def test_resolve_feeds_matches_tag
    feeds = [
      { url: "https://anchor.fm/s/7ad18ac4/podcast/rss", tag: "babi" },
      { url: "https://anchor.fm/s/54a7b1e8/podcast/rss", tag: "nisem" }
    ]
    s = source(rss_feeds: feeds)
    matched = s.send(:resolve_feeds, feeds, "babi")
    assert_equal 1, matched.length
    assert_equal "https://anchor.fm/s/7ad18ac4/podcast/rss", matched.first[:url]
  end

  def test_resolve_feeds_tag_case_insensitive
    feeds = [{ url: "https://anchor.fm/s/7ad18ac4/podcast/rss", tag: "Babi Bere" }]
    s = source(rss_feeds: feeds)
    matched = s.send(:resolve_feeds, feeds, "babi")
    assert_equal 1, matched.length
  end

  # --- RSS episode image extraction ---

  def test_parse_feed_episodes_extracts_image_url
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" version="2.0">
        <channel>
          <item>
            <title>With Image</title>
            <enclosure url="http://example.com/ep.mp3" type="audio/mpeg" length="1000"/>
            <itunes:image href="http://example.com/cover.jpg"/>
          </item>
        </channel>
      </rss>
    XML
    rss = RSSSource.new(feeds: [], logger: nil)
    episodes = rss.send(:parse_feed_episodes, xml)
    assert_equal "http://example.com/cover.jpg", episodes.first[:image_url]
  end

  def test_parse_feed_episodes_omits_image_url_when_absent
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" version="2.0">
        <channel>
          <item>
            <title>No Image</title>
            <enclosure url="http://example.com/ep.mp3" type="audio/mpeg" length="1000"/>
          </item>
        </channel>
      </rss>
    XML
    rss = RSSSource.new(feeds: [], logger: nil)
    episodes = rss.send(:parse_feed_episodes, xml)
    refute episodes.first.key?(:image_url)
  end

  # --- exclude_url! ---

  def test_exclude_url_writes_to_file
    path = File.join(@tmpdir, "excluded_urls.yml")
    s = source_with_excluded(rss_feeds: ["https://a.com/feed"], excluded_path: path)
    s.send(:exclude_url!, "http://example.com/ep.mp3")

    data = YAML.load_file(path)
    assert_includes data, "http://example.com/ep.mp3"
  end

  def test_exclude_url_does_not_duplicate
    path = File.join(@tmpdir, "excluded_urls.yml")
    File.write(path, ["http://example.com/ep.mp3"].to_yaml)

    s = source_with_excluded(rss_feeds: ["https://a.com/feed"], excluded_path: path)
    s.send(:exclude_url!, "http://example.com/ep.mp3")

    data = YAML.load_file(path)
    assert_equal 1, data.count("http://example.com/ep.mp3")
  end

  def test_exclude_url_noop_without_path
    s = source(rss_feeds: ["https://a.com/feed"])
    # Should not raise
    s.send(:exclude_url!, "http://example.com/ep.mp3")
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

  def source_with_excluded(known_urls: [], rss_feeds: nil, excluded_path: nil)
    sources = rss_feeds.nil? ? {} : { "rss" => rss_feeds }
    config = Struct.new(:sources, :excluded_urls_path).new(sources, excluded_path)
    history = Struct.new(:all_urls).new(Set.new(known_urls))
    EpisodeSource.new(config: config, history: history)
  end

  def create_temp_file(name, content)
    path = File.join(@tmpdir, name)
    File.write(path, content)
    path
  end
end
