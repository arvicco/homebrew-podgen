# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "minitest/mock"
require "sources/rss_source"
require "loggable"

class CapturingLogger
  attr_reader :messages
  def initialize; @messages = []; end
  def log(msg); @messages << msg; end
  def output; @messages.join("\n"); end
end

class TestRSSSource < Minitest::Test
  EMPTY_FEED = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>x</title><link>x</link><description>x</description></channel></rss>
  XML

  def setup
    @logger = CapturingLogger.new
  end

  def test_fetch_episodes_logs_tag_when_present
    feeds = [{ url: "https://example.com/feed.xml", tag: "cortes" }]
    source = build_source(feeds)
    source.fetch_episodes

    assert_match(/Fetching RSS 'cortes' episodes: https:\/\/example\.com\/feed\.xml/, @logger.output)
  end

  def test_fetch_episodes_logs_url_only_when_no_tag
    source = build_source(["https://example.com/feed.xml"])
    source.fetch_episodes

    assert_match(/Fetching RSS episodes: https:\/\/example\.com\/feed\.xml/, @logger.output)
    refute_match(/Fetching RSS '/, @logger.output)
  end

  def test_research_logs_tag_when_present
    feeds = [{ url: "https://example.com/feed.xml", tag: "headlines" }]
    source = build_source(feeds)
    source.research(["Topic"])

    assert_match(/Fetching RSS 'headlines': https:\/\/example\.com\/feed\.xml/, @logger.output)
  end

  def test_fetch_episodes_transfers_overlay_options_to_episode
    feed_xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel><title>x</title><link>x</link><description>x</description>
        <item>
          <title>Ep</title>
          <link>https://example.com/ep</link>
          <description>d</description>
          <enclosure url="https://example.com/ep.mp3" type="audio/mpeg" length="1000"/>
        </item>
      </channel></rss>
    XML

    feeds = [{
      url: "https://example.com/feed.xml",
      font: "Arial",
      font_color: "white",
      font_size: 42,
      width: 500,
      gravity: "south",
      x_offset: 12,
      y_offset: 24,
      base_image: "/abs/bg.png"
    }]
    source = RSSSource.new(feeds: feeds, logger: @logger)
    source.define_singleton_method(:http_get_with_redirects) { |_url, _redirects = nil| feed_xml }

    episode = source.fetch_episodes.first
    assert_equal "Arial", episode[:font]
    assert_equal "white", episode[:font_color]
    assert_equal 42, episode[:font_size]
    assert_equal 500, episode[:width]
    assert_equal "south", episode[:gravity]
    assert_equal 12, episode[:x_offset]
    assert_equal 24, episode[:y_offset]
    assert_equal "/abs/bg.png", episode[:base_image]
  end

  # Q-134 (P18-1): an Atom feed yields clean entries instead of raising
  # NoMethodError on Entry#description (retried and the feed dropped).
  def test_parse_feed_atom_document_returns_clean_entries
    now = Time.now.utc.iso8601
    xml = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Ex</title><id>urn:x</id><updated>#{now}</updated>
        <entry>
          <title>Chips news</title>
          <link rel="alternate" href="https://example.com/a"/>
          <id>urn:a</id><updated>#{now}</updated>
          <summary type="html">&lt;p&gt;Some summary&lt;/p&gt;</summary>
        </entry>
        <entry>
          <title>Old one</title>
          <link href="https://example.com/old"/>
          <id>urn:b</id><updated>2020-01-01T00:00:00Z</updated>
          <content type="text">Body</content>
        </entry>
      </feed>
    XML

    items = build_source([]).send(:parse_feed, xml)

    assert_equal [{ title: "Chips news", url: "https://example.com/a", summary: "Some summary" }], items
  end

  def test_parse_feed_atom_entry_without_summary_uses_content
    now = Time.now.utc.iso8601
    xml = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Ex</title><id>urn:x</id><updated>#{now}</updated>
        <entry>
          <title>Two</title>
          <link rel="enclosure" href="https://example.com/b.mp3"/>
          <link href="https://example.com/b"/>
          <id>urn:b</id><updated>#{now}</updated>
          <content type="text">Body text</content>
        </entry>
      </feed>
    XML

    items = build_source([]).send(:parse_feed, xml)

    assert_equal [{ title: "Two", url: "https://example.com/b", summary: "Body text" }], items
  end

  # --- distribute_by_topic (characterization, private) ---

  def test_distribute_by_topic_buckets_by_keyword_match
    findings = [
      { title: "Bitcoin hits new high", summary: "" },
      { title: "Heavy rain expected", summary: "" }
    ]
    result = build_source([]).send(:distribute_by_topic, ["Bitcoin news"], findings)

    assert_equal 2, result.length
    assert_equal "Bitcoin news", result[0][:topic]
    assert_equal [findings[0]], result[0][:findings]
    assert_equal "Other recent headlines (RSS)", result[1][:topic]
    assert_equal [findings[1]], result[1][:findings]
  end

  def test_distribute_by_topic_matches_against_summary_too
    findings = [{ title: "Daily brief", summary: "New mining hardware announced" }]
    result = build_source([]).send(:distribute_by_topic, ["Bitcoin mining"], findings)

    assert_equal [{ topic: "Bitcoin mining", findings: findings }], result
  end

  def test_distribute_by_topic_first_matching_topic_wins
    findings = [{ title: "Bitcoin and Ethereum both rally", summary: "" }]
    result = build_source([]).send(:distribute_by_topic, ["Ethereum news", "Bitcoin news"], findings)

    assert_equal ["Ethereum news"], result.map { |b| b[:topic] }
  end

  # Q-134 (P18-1): an acronym topic ("AI") claims its findings.
  def test_distribute_by_topic_acronym_topic_matches
    findings = [{ title: "AI breakthrough", summary: "" }]
    result = build_source([]).send(:distribute_by_topic, ["AI"], findings)

    assert_equal ["AI"], result.map { |b| b[:topic] }
  end

  # A two-letter keyword matches whole words only: "ai" is not in "rain".
  def test_distribute_by_topic_acronym_does_not_match_inside_words
    findings = [{ title: "Heavy rain said to continue", summary: "" }]
    result = build_source([]).send(:distribute_by_topic, ["AI"], findings)

    assert_equal ["Other recent headlines (RSS)"], result.map { |b| b[:topic] }
  end

  # --- topic_keywords (private) ---

  def test_topic_keywords_lowercases_and_drops_short_tokens
    assert_equal %w[bitcoin ai mining 42x],
      build_source([]).send(:topic_keywords, "Bitcoin AI-Mining 42x")
  end

  def test_topic_keywords_lowercase_short_tokens_dropped_acronyms_kept
    assert_equal %w[ai], build_source([]).send(:topic_keywords, "AI is ok")
  end

  def test_topic_keywords_keeps_two_letter_acronyms
    assert_equal %w[ai chips the eu], build_source([]).send(:topic_keywords, "AI chips in the EU")
  end

  def test_topic_keywords_keeps_non_ascii_words_whole
    assert_equal %w[zürich banks], build_source([]).send(:topic_keywords, "Zürich banks")
  end

  # Q-101 (P11-4): a feed that cannot be fetched is a counted warning, not
  # a plain log line. Q-105 (P12-0): a 404/410 costs one request, not three.
  def test_fetch_episodes_feed_404_records_one_warning
    logger = WarningLogger.new
    source = failing_source("https://example.com/dead.xml", logger)

    requests = with_status_server("404") { assert_empty source.fetch_episodes }
    assert_equal 1, requests
    assert_equal 1, logger.warnings.size
    assert_match(%r{Warning: Failed to fetch https://example\.com/dead\.xml: RSSSource::FeedGone: HTTP 404 from https://example\.com/dead\.xml}, logger.warnings.first)
  end

  def test_research_feed_404_records_one_warning
    logger = WarningLogger.new
    source = failing_source("https://example.com/dead.xml", logger)

    requests = with_status_server("404") { source.research(["Topic"]) }
    assert_equal 1, requests
    assert_equal 1, logger.warnings.size
    assert_match(/Failed to fetch https:\/\/example\.com\/dead\.xml: RSSSource::FeedGone: HTTP 404/, logger.warnings.first)
  end

  def test_fetch_episodes_feed_410_costs_one_request
    logger = WarningLogger.new
    source = failing_source("https://example.com/gone.xml", logger)

    requests = with_status_server("410") { assert_empty source.fetch_episodes }
    assert_equal 1, requests
    assert_equal 1, logger.warnings.size
    assert_match(/RSSSource::FeedGone: HTTP 410/, logger.warnings.first)
  end

  def test_fetch_episodes_feed_500_keeps_retrying
    logger = WarningLogger.new
    source = failing_source("https://example.com/flaky.xml", logger)

    requests = with_status_server("500") { assert_empty source.fetch_episodes }
    assert_equal RSSSource::MAX_RETRIES + 1, requests
    assert_equal 1, logger.warnings.size
    assert_match(/RuntimeError: RSS failed after 3 attempts: HTTP 500/, logger.warnings.first)
  end

  # Q-119 (P14-4): exclusions compare cleaned on both sides, so tracking
  # parameters on the enclosure never defeat an exclusion.
  def test_fetch_episodes_cleaned_exclusion_excludes_tracked_enclosure
    source = feed_source_with_enclosure("https://example.com/a.mp3?src=rss")
    assert_empty source.fetch_episodes(exclude_urls: Set["https://example.com/a.mp3"])
  end

  def test_fetch_episodes_raw_exclusion_excludes_differently_tracked_enclosure
    source = feed_source_with_enclosure("https://example.com/a.mp3?utm_source=x")
    assert_empty source.fetch_episodes(exclude_urls: Set["https://example.com/a.mp3?src=rss"])
  end

  def test_fetch_episodes_tracked_enclosure_not_excluded_is_kept_raw
    source = feed_source_with_enclosure("https://example.com/a.mp3?src=rss")
    episodes = source.fetch_episodes(exclude_urls: Set["https://example.com/b.mp3"])
    assert_equal ["https://example.com/a.mp3?src=rss"], episodes.map { |e| e[:audio_url] }
  end

  private

  def feed_source_with_enclosure(url)
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel><title>x</title><link>x</link><description>x</description>
        <item><title>Ep</title><link>https://example.com/ep</link><description>d</description>
          <enclosure url="#{url}" type="audio/mpeg" length="1000"/></item>
      </channel></rss>
    XML
    source = RSSSource.new(feeds: ["https://example.com/feed.xml"], logger: @logger)
    source.define_singleton_method(:http_get_with_redirects) { |_url, _redirects = nil| xml }
    source
  end

  class WarningLogger < CapturingLogger
    attr_reader :warnings
    def initialize
      super
      @warnings = []
    end

    def warning(msg)
      @warnings << msg
      log(msg)
    end
  end

  def failing_source(url, logger)
    source = RSSSource.new(feeds: [url], logger: logger)
    source.define_singleton_method(:sleep) { |_| }
    source
  end

  # Stubs Net::HTTP.start with a fake connection answering every GET with
  # +code+; returns how many requests were made.
  def with_status_server(code)
    requests = 0
    response = Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new("1.1", code, "status")
    http = Object.new
    http.define_singleton_method(:get) do |*_a|
      requests += 1
      response
    end
    Net::HTTP.stub(:start, ->(*_a, **_k, &blk) { blk.call(http) }) { yield }
    requests
  end

  def build_source(feeds)
    source = RSSSource.new(feeds: feeds, logger: @logger)
    source.define_singleton_method(:http_get_with_redirects) { |_url, _redirects = nil| EMPTY_FEED }
    source
  end
end
