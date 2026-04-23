# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
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

  # --- RSS content_type capture ---

  def test_parse_feed_episodes_captures_content_type
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" version="2.0">
        <channel>
          <item>
            <title>M4A Episode</title>
            <enclosure url="http://example.com/ep.m4a" type="audio/x-m4a" length="5000"/>
          </item>
        </channel>
      </rss>
    XML
    rss = RSSSource.new(feeds: [], logger: nil)
    episodes = rss.send(:parse_feed_episodes, xml)
    assert_equal "audio/x-m4a", episodes.first[:content_type]
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

  # --- weighted_pick ---

  def test_weighted_pick_respects_weights
    feeds = [
      { url: "https://a.com/feed", tag: "a", weight: 80 },
      { url: "https://b.com/feed", tag: "b", weight: 20 }
    ]
    s = source(rss_feeds: feeds)

    counts = Hash.new(0)
    1000.times do
      pick = s.send(:weighted_pick, feeds, 0)
      counts[pick[:tag]] += 1
    end

    assert counts["a"] > 600, "Expected feed 'a' (weight 80) to be picked >600/1000 times, got #{counts['a']}"
    assert counts["b"] > 100, "Expected feed 'b' (weight 20) to be picked >100/1000 times, got #{counts['b']}"
  end

  def test_weighted_pick_cycle_mode_equal_weights
    feeds = [
      { url: "https://a.com/feed", tag: "a" },
      { url: "https://b.com/feed", tag: "b" }
    ]
    s = source(rss_feeds: feeds)

    counts = Hash.new(0)
    1000.times do
      pick = s.send(:weighted_pick, feeds, 1)  # cycle mode: default weight 1
      counts[pick[:tag]] += 1
    end

    assert counts["a"] > 350, "Expected roughly even distribution, got a=#{counts['a']}"
    assert counts["b"] > 350, "Expected roughly even distribution, got b=#{counts['b']}"
  end

  def test_weights_mode_excludes_unweighted_feeds
    feeds = [
      { url: "https://a.com/feed", tag: "a", weight: 100 },
      { url: "https://b.com/feed", tag: "b" }  # no weight → 0 in weights mode
    ]
    s = source(rss_feeds: feeds, select: "weights")

    pool = feeds.select { |f| s.send(:feed_weight, f, 0) > 0 }
    assert_equal 1, pool.length
    assert_equal "a", pool.first[:tag]
  end

  def test_weighted_pick_handles_plain_url_strings
    feeds = ["https://a.com/feed", "https://b.com/feed"]
    s = source(rss_feeds: feeds)

    pick = s.send(:weighted_pick, feeds, 1)
    assert_includes feeds, pick
  end

  def test_select_mode_defaults_to_latest
    s = source(rss_feeds: ["https://a.com/feed"])
    assert_equal "latest", s.send(:select_mode)
  end

  def test_select_mode_reads_from_config
    s = source(rss_feeds: ["https://a.com/feed"], select: "weights")
    assert_equal "weights", s.send(:select_mode)
  end

  def setup
    @tmpdir = Dir.mktmpdir("episode_source_test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- audio_extension_for ---

  def test_audio_extension_for_mpeg_mime
    s = source(rss_feeds: ["https://example.com/feed"])
    assert_equal ".mp3", s.send(:audio_extension_for, { audio_url: "https://x.com/ep", content_type: "audio/mpeg" })
  end

  def test_audio_extension_for_m4a_mime
    s = source(rss_feeds: ["https://example.com/feed"])
    assert_equal ".m4a", s.send(:audio_extension_for, { audio_url: "https://x.com/ep", content_type: "audio/x-m4a" })
  end

  def test_audio_extension_for_mp4_mime
    s = source(rss_feeds: ["https://example.com/feed"])
    assert_equal ".m4a", s.send(:audio_extension_for, { audio_url: "https://x.com/ep", content_type: "audio/mp4" })
  end

  def test_audio_extension_for_ogg_mime
    s = source(rss_feeds: ["https://example.com/feed"])
    assert_equal ".ogg", s.send(:audio_extension_for, { audio_url: "https://x.com/ep", content_type: "audio/ogg" })
  end

  def test_audio_extension_falls_back_to_url_extension
    s = source(rss_feeds: ["https://example.com/feed"])
    assert_equal ".m4a", s.send(:audio_extension_for, { audio_url: "https://cdn.example.com/file.m4a" })
  end

  def test_audio_extension_url_encoded_nested_url
    url = "https://anchor.fm/s/123/play/456/https%3A%2F%2Fcdn.example.com%2Ffile.m4a"
    s = source(rss_feeds: ["https://example.com/feed"])
    assert_equal ".m4a", s.send(:audio_extension_for, { audio_url: url })
  end

  def test_audio_extension_url_with_query_params
    s = source(rss_feeds: ["https://example.com/feed"])
    assert_equal ".ogg", s.send(:audio_extension_for, { audio_url: "https://x.com/ep.ogg?token=abc" })
  end

  def test_audio_extension_defaults_to_mp3
    s = source(rss_feeds: ["https://example.com/feed"])
    assert_equal ".mp3", s.send(:audio_extension_for, { audio_url: "https://x.com/stream/play" })
  end

  def test_audio_extension_unknown_mime_falls_back_to_url
    s = source(rss_feeds: ["https://example.com/feed"])
    assert_equal ".flac", s.send(:audio_extension_for, { audio_url: "https://x.com/ep.flac", content_type: "audio/x-flac" })
  end

  # --- probe_and_fix_extension ---

  def test_probe_and_fix_extension_renames_when_wrong
    # Create a file with .mp3 extension but M4A content header
    path = File.join(@tmpdir, "podgen_source_test.mp3")
    # Minimal valid ftyp box for MP4/M4A: 8 bytes size + "ftyp" + brand
    File.binwrite(path, "\x00\x00\x00\x14ftypisom\x00\x00\x00\x00isom")

    s = source(rss_feeds: ["https://example.com/feed"])

    Open3.stub(:capture3, ["mov,mp4,m4a,3gp,3g2,mj2\n", "", stub_status(true)]) do
      result = s.send(:probe_and_fix_extension, path)
      assert_equal ".m4a", File.extname(result)
      assert File.exist?(result)
      refute File.exist?(path) unless result == path
    end
  end

  def test_probe_and_fix_extension_keeps_correct_extension
    path = File.join(@tmpdir, "podgen_source_test.mp3")
    File.write(path, "fake mp3")

    s = source(rss_feeds: ["https://example.com/feed"])

    Open3.stub(:capture3, ["mp3\n", "", stub_status(true)]) do
      result = s.send(:probe_and_fix_extension, path)
      assert_equal path, result
      assert_equal ".mp3", File.extname(result)
    end
  end

  def test_probe_and_fix_extension_keeps_file_when_probe_fails
    path = File.join(@tmpdir, "podgen_source_test.mp3")
    File.write(path, "fake")

    s = source(rss_feeds: ["https://example.com/feed"])

    Open3.stub(:capture3, ["", "error", stub_status(false)]) do
      result = s.send(:probe_and_fix_extension, path)
      assert_equal path, result
    end
  end

  def test_probe_and_fix_extension_ogg_format
    path = File.join(@tmpdir, "podgen_source_test.mp3")
    File.write(path, "fake ogg")

    s = source(rss_feeds: ["https://example.com/feed"])

    Open3.stub(:capture3, ["ogg\n", "", stub_status(true)]) do
      result = s.send(:probe_and_fix_extension, path)
      assert_equal ".ogg", File.extname(result)
    end
  end

  private

  def stub_status(success)
    Struct.new(:success?).new(success)
  end

  def source(known_urls: [], rss_feeds: nil, select: nil)
    sources = rss_feeds.nil? ? {} : { "rss" => rss_feeds }
    sources["select"] = [select] if select
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
