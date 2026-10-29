# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "minitest/mock"
require "yaml"
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

  # --- re-post guard by normalized title (Q-88, P10-0) ---

  SPREAKER = "https://api.spreaker.com/download/episode"
  LUPO_ENTRY = {
    "date" => "2026-04-28", "title" => "Il lupo e il pastore", "basename" => "fiabe-2026-04-28",
    "urls" => ["#{SPREAKER}/24548/il-lupo-e-il-pastore-una-favola-di-esopo.mp3"]
  }.freeze

  def test_fetch_next_same_host_title_match_skipped_next_candidate_returned
    dup = rss_ep("Il lupo e il pastore. Una favola di Esopo", "#{SPREAKER}/24548/il-lupo-e-altre.wav")
    nxt = rss_ep("La lepre e la tartaruga", "#{SPREAKER}/24600/lepre.mp3")
    s, logger = guard_source(history: [LUPO_ENTRY], feeds: { "f" => [dup, nxt] })

    picked = nil
    _, err = capture_io { picked = with_rss { s.fetch_next } }

    assert_equal nxt, picked
    line = 'Already processed as fiabe-2026-04-28 (2026-04-28): title match "Il lupo e il pastore"'
    assert_includes err, line
    assert(logger.lines.any? { |l| l.include?(line) }, "log line missing: #{logger.lines.inspect}")
  end

  def test_fetch_next_different_story_same_opening_not_skipped
    other = rss_ep("Il lupo e i sette capretti", "#{SPREAKER}/24601/capretti.mp3")
    s, = guard_source(history: [LUPO_ENTRY], feeds: { "f" => [other] })
    assert_equal other, with_rss { s.fetch_next }
  end

  def test_fetch_next_other_host_match_unattended_skipped_and_logged
    dup = rss_ep("Il lupo e il pastore", "https://anchor.fm/s/abc/play/1.m4a")
    s, logger = guard_source(history: [LUPO_ENTRY], feeds: { "f" => [dup] })

    picked = :unset
    _, err = capture_io { picked = with_rss { s.fetch_next } }

    assert_nil picked
    assert_includes err, "Already processed as fiabe-2026-04-28"
    assert(logger.lines.any? { |l| l.include?("Already processed as fiabe-2026-04-28") })
  end

  def test_fetch_next_other_host_match_prompt_keep_returns_candidate
    dup = rss_ep("Il lupo e il pastore", "https://anchor.fm/s/abc/play/1.m4a")
    s, = guard_source(history: [LUPO_ENTRY], feeds: { "f" => [dup] })
    asked = []
    prompt = ->(ep, match) {
      asked << [ep[:title], match[:basename], match[:title]]
      "k"
    }

    assert_equal dup, with_rss { s.fetch_next(duplicate_prompt: prompt) }
    assert_equal [["Il lupo e il pastore", "fiabe-2026-04-28", "Il lupo e il pastore"]], asked
  end

  def test_fetch_next_other_host_match_prompt_blank_or_eof_or_d_skips
    ["", nil, "d", "D"].each do |answer|
      dup = rss_ep("Il lupo e il pastore", "https://anchor.fm/s/abc/play/1.m4a")
      nxt = rss_ep("La lepre e la tartaruga", "https://anchor.fm/s/abc/play/2.m4a")
      s, = guard_source(history: [LUPO_ENTRY], feeds: { "f" => [dup, nxt] })
      picked = nil
      capture_io { picked = with_rss { s.fetch_next(duplicate_prompt: ->(_e, _m) { answer }) } }
      assert_equal nxt, picked, "answer #{answer.inspect} should skip"
    end
  end

  # P10-0c: under --ask-trim a same-feed match is asked about too (a sequel
  # must not be skipped forever); unattended it is still skipped.
  def test_fetch_next_same_feed_match_prompt_keep_returns_candidate
    dup = rss_ep("Il lupo e il pastore", "#{SPREAKER}/24548/x.wav")
    s, = guard_source(history: [LUPO_ENTRY], feeds: { "f" => [dup] })
    asked = []
    prompt = ->(_e, match) { (asked << match[:same_feed]) && "k" }
    assert_equal dup, with_rss { s.fetch_next(duplicate_prompt: prompt) }
    assert_equal [true], asked
  end

  def test_fetch_next_same_feed_match_prompt_nil_skips
    dup = rss_ep("Il lupo e il pastore", "#{SPREAKER}/24548/x.wav")
    s, = guard_source(history: [LUPO_ENTRY], feeds: { "f" => [dup] })
    capture_io { assert_nil with_rss { s.fetch_next(duplicate_prompt: nil) } }
  end

  def test_fetch_next_force_bypasses_title_guard
    dup = rss_ep("Il lupo e il pastore. Una favola di Esopo", "#{SPREAKER}/24548/x.wav")
    s, = guard_source(history: [LUPO_ENTRY], feeds: { "f" => [dup] })
    assert_equal dup, with_rss { s.fetch_next(force: true) }
  end

  def test_fetch_next_jaccard_reordered_title_skipped
    entry = { "date" => "2026-05-01", "title" => "La volpe e l'uva — favola", "basename" => "fiabe-2026-05-01",
              "urls" => ["https://example.com/a.mp3"] }
    dup = rss_ep("L'uva e la volpe", "https://example.com/b.mp3")
    s, = guard_source(history: [entry], feeds: { "f" => [dup] })
    capture_io { assert_nil with_rss { s.fetch_next } }
  end

  def test_fetch_next_guard_runs_before_length_filter
    dup = rss_ep("Il lupo e il pastore", "#{SPREAKER}/24548/x.wav", duration: "3:00")
    s, logger = guard_source(history: [LUPO_ENTRY], feeds: { "f" => [dup] }, min: 120, max: 600)
    capture_io { assert_nil with_rss { s.fetch_next } }
    refute(logger.lines.any? { |l| l.include?("Length filter") }, "length filter must not see the duplicate")
  end

  # P10-0b: same feed = host + first path segment, through redirector segments.
  def test_feed_key_shapes
    s = source
    assert_equal "paroledistorie.net/podcast-download",
      s.send(:feed_key, "https://paroledistorie.net/podcast-download/24548/il-lupo-e-il-pastore-una-favola-di-esopo.mp3")
    assert_equal "anchor.fm/s/54a7b1e8", s.send(:feed_key, "https://anchor.fm/s/54a7b1e8/podcast/play/81353291/x.m4a")
    assert_equal "dts.podtrac.com/redirect.mp3/videoweb.rtvslo.si",
      s.send(:feed_key, "https://dts.podtrac.com/redirect.mp3/videoweb.rtvslo.si/podcast/a.mp3")
    assert_nil s.send(:feed_key, "not a url")
  end

  def test_fetch_next_same_spreaker_item_reposted_is_same_feed
    entry = LUPO_ENTRY.merge("urls" => ["https://paroledistorie.net/podcast-download/24548/il-lupo-e-il-pastore-una-favola-di-esopo.mp3"])
    dup = rss_ep("Il lupo e il pastore", "https://paroledistorie.net/podcast-download/24548/il-lupo-e-il-pastore-e-altre-favole-di-esopo.wav")
    s, = guard_source(history: [entry], feeds: {"f" => [dup]})
    asked = []
    capture_io { assert_nil with_rss { s.fetch_next(duplicate_prompt: ->(_e, m) { (asked << m[:same_feed]) && "" }) } }
    assert_equal [true], asked, "the spreaker re-post is asked about as same feed"
  end

  def test_fetch_next_two_anchor_shows_are_other_feeds
    entry = LUPO_ENTRY.merge("urls" => ["https://anchor.fm/s/11049c0a8/podcast/play/1/a.mp3"])
    dup = rss_ep("Il lupo e il pastore", "https://anchor.fm/s/dcf9365c/podcast/play/2/b.mp3")
    s, = guard_source(history: [entry], feeds: {"f" => [dup]})
    asked = []
    assert_equal dup, with_rss { s.fetch_next(duplicate_prompt: ->(_e, m) { (asked << m[:same_feed]) && "k" }) }
    assert_equal [false], asked
  end

  def test_fetch_next_podtrac_to_two_real_hosts_are_other_feeds
    entry = LUPO_ENTRY.merge("urls" => ["https://dts.podtrac.com/redirect.mp3/videoweb.rtvslo.si/podcast/a.mp3"])
    dup = rss_ep("Il lupo e il pastore", "https://dts.podtrac.com/redirect.mp3/feeds.soundcloud.com/stream/b.mp3")
    s, = guard_source(history: [entry], feeds: {"f" => [dup]})
    asked = []
    assert_equal dup, with_rss { s.fetch_next(duplicate_prompt: ->(_e, m) { (asked << m[:same_feed]) && "k" }) }
    assert_equal [false], asked
  end

  # CRPR round 1: a pending match the length filter removes is never asked about.
  def test_fetch_next_pending_match_removed_by_length_filter_is_never_prompted
    dup = rss_ep("Il lupo e il pastore", "https://anchor.fm/s/abc/play/1.m4a", duration: "20:00")
    nxt = rss_ep("La lepre e la tartaruga", "https://anchor.fm/s/abc/play/2.m4a", duration: "5:00")
    s, = guard_source(history: [LUPO_ENTRY], feeds: {"f" => [dup, nxt]}, min: 120, max: 600)
    asked = []
    picked = with_rss { s.fetch_next(duplicate_prompt: ->(ep, _m) { (asked << ep[:title]) && "" }) }
    assert_equal nxt, picked
    assert_empty asked
  end

  def test_fetch_next_history_entries_with_nil_or_empty_title_are_skipped_by_the_index
    entries = [LUPO_ENTRY.merge("title" => nil, "basename" => "fiabe-2026-04-01"),
      LUPO_ENTRY.merge("title" => "", "basename" => "fiabe-2026-04-02")]
    ep = rss_ep("Il lupo e il pastore", "#{SPREAKER}/24548/x.wav")
    s, = guard_source(history: entries, feeds: {"f" => [ep]})
    out, err = capture_io { assert_equal ep, with_rss { s.fetch_next } }
    refute_includes out + err, "Already processed"
  end

  def test_fetch_next_candidate_title_normalizing_to_empty_never_matches
    entry = LUPO_ENTRY.merge("title" => "!!! ???", "basename" => "fiabe-2026-04-03")
    ep = rss_ep("¡¿…?!", "#{SPREAKER}/24548/x.wav")
    s, = guard_source(history: [entry], feeds: {"f" => [ep]})
    out, err = capture_io { assert_equal ep, with_rss { s.fetch_next } }
    refute_includes out + err, "Already processed"
  end

  # CRPR round 1 nit: the title index is built once per fetch_next.
  def test_fetch_weighted_reads_history_titles_once_per_fetch_next
    feeds = [{url: "f1", tag: "a", weight: 100}, {url: "f2", tag: "b", weight: 100}]
    too_long = {"f1" => [rss_ep("La lepre", "https://a.example/1.mp3", duration: "99:00")],
                "f2" => [rss_ep("La volpe", "https://b.example/2.mp3", duration: "99:00")]}
    s, = guard_source(history: [LUPO_ENTRY], feeds: too_long, rss_feeds: feeds, select: "weights", max: 600)
    reads = 0
    s.instance_variable_get(:@history).define_singleton_method(:all_episodes) { (reads += 1) && [LUPO_ENTRY] }

    assert_nil with_rss { s.fetch_next }, "both feeds tried and exhausted"
    assert_equal 1, reads
    with_rss { s.fetch_next }
    assert_equal 2, reads, "no caching across fetch_next calls"
  end

  def test_fetch_weighted_title_guard_skips_and_moves_to_next_feed
    dup = rss_ep("Il lupo e il pastore", "#{SPREAKER}/24548/x.wav")
    other = rss_ep("La lepre e la tartaruga", "https://b.example/lepre.mp3")
    feeds = [{ url: "f1", tag: "a", weight: 100 }, { url: "f2", tag: "b", weight: 100 }]
    s, = guard_source(history: [LUPO_ENTRY], feeds: { "f1" => [dup], "f2" => [other] },
      rss_feeds: feeds, select: "weights")
    picked = nil
    capture_io { picked = with_rss { s.fetch_next } }
    assert_equal other, picked
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

  # --- filter_by_length ---

  def test_filter_by_length_returns_unchanged_when_no_limits
    eps = [{ duration: "5:00" }, { duration: "9:00" }]
    src = source_with_length(min: nil, max: nil)
    assert_equal eps, src.send(:filter_by_length, eps)
  end

  def test_filter_by_length_drops_episodes_over_max
    eps = [
      { duration: "5:00", audio_url: "a" },
      { duration: "12:55", audio_url: "b" },
      { duration: "8:00", audio_url: "c" }
    ]
    src = source_with_length(min: 120, max: 570) # 2:00–9:30
    kept = src.send(:filter_by_length, eps)
    assert_equal ["a", "c"], kept.map { |e| e[:audio_url] }
  end

  def test_filter_by_length_drops_episodes_under_min
    eps = [
      { duration: "0:30", audio_url: "short" },
      { duration: "5:00", audio_url: "ok" }
    ]
    src = source_with_length(min: 120, max: 570)
    kept = src.send(:filter_by_length, eps)
    assert_equal ["ok"], kept.map { |e| e[:audio_url] }
  end

  def test_filter_by_length_keeps_episodes_with_missing_duration
    eps = [
      { audio_url: "no-duration" },
      { duration: "12:55", audio_url: "too-long" },
      { duration: "5:00", audio_url: "ok" }
    ]
    src = source_with_length(min: 120, max: 570)
    kept = src.send(:filter_by_length, eps)
    assert_equal ["no-duration", "ok"], kept.map { |e| e[:audio_url] }
  end

  def test_filter_by_length_logs_stats
    eps = [
      { duration: "0:30", audio_url: "a" },
      { duration: "12:55", audio_url: "b" },
      { duration: "5:00", audio_url: "c" }
    ]
    logged = []
    logger = Object.new
    logger.define_singleton_method(:log) { |msg| logged << msg }

    src = source_with_length(min: 120, max: 570, logger: logger)
    src.send(:filter_by_length, eps)
    msg = logged.find { |m| m.include?("Length filter") }
    refute_nil msg
    assert_includes msg, "1/3 kept"
    assert_includes msg, "1 too short"
    assert_includes msg, "1 too long"
    assert_includes msg, "2:00–9:30"
  end

  # --- length_check ---

  def test_length_check_ok_when_no_limits
    src = source_with_length(min: nil, max: nil)
    assert_equal :ok, src.length_check(99999)
  end

  def test_length_check_too_long
    src = source_with_length(min: 120, max: 570)
    assert_equal :too_long, src.length_check(600)
  end

  def test_length_check_too_short
    src = source_with_length(min: 120, max: 570)
    assert_equal :too_short, src.length_check(60)
  end

  def test_length_check_ok_within_range
    src = source_with_length(min: 120, max: 570)
    assert_equal :ok, src.length_check(300)
  end

  private

  def source_with_length(min:, max:, logger: nil)
    config = Struct.new(:sources, :min_length_seconds, :max_length_seconds, keyword_init: true).new(
      sources: {}, min_length_seconds: min, max_length_seconds: max
    )
    history = Struct.new(:all_urls).new(Set.new)
    EpisodeSource.new(config: config, history: history, logger: logger)
  end

  class LineLogger
    attr_reader :lines

    def initialize = @lines = []
    def log(msg) = @lines << msg
  end

  # Stands in for RSSSource: serves the episodes configured per feed URL,
  # honouring exclude_urls as the real one does.
  class FakeRSS
    def initialize(by_feed, feeds)
      @episodes = feeds.flat_map { |f| by_feed.fetch(f.is_a?(Hash) ? f[:url] : f, []) }
    end

    def fetch_episodes(exclude_urls: Set.new)
      @episodes.reject { |e| exclude_urls.include?(e[:audio_url]) }
    end
  end

  def rss_ep(title, url, duration: nil)
    { title: title, audio_url: url, description: "", duration: duration }
  end

  def guard_source(history:, feeds:, rss_feeds: nil, select: nil, min: nil, max: nil)
    sources = { "rss" => rss_feeds || feeds.keys }
    sources["select"] = [select] if select
    config = Struct.new(:sources, :min_length_seconds, :max_length_seconds).new(sources, min, max)
    hist = Struct.new(:all_urls, :all_episodes).new(Set.new(history.flat_map { |e| e["urls"] }), history)
    logger = LineLogger.new
    @fake_feeds = feeds
    [EpisodeSource.new(config: config, history: hist, logger: logger), logger]
  end

  def with_rss(&block)
    by_feed = @fake_feeds
    RSSSource.stub(:new, ->(feeds:, **) { FakeRSS.new(by_feed, feeds) }, &block)
  end

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
