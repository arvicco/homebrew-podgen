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

  def test_distribute_by_topic_short_only_topic_never_matches
    # Characterization: a topic whose tokens are all <3 chars ("AI")
    # yields an empty keyword list, so nothing can ever match it.
    findings = [{ title: "AI breakthrough", summary: "" }]
    result = build_source([]).send(:distribute_by_topic, ["AI"], findings)

    assert_equal ["Other recent headlines (RSS)"], result.map { |b| b[:topic] }
  end

  # --- topic_keywords (characterization, private) ---

  def test_topic_keywords_lowercases_and_drops_short_tokens
    assert_equal %w[bitcoin mining 42x],
      build_source([]).send(:topic_keywords, "Bitcoin AI-Mining 42x")
  end

  def test_topic_keywords_all_short_tokens_returns_empty
    assert_equal [], build_source([]).send(:topic_keywords, "AI is ok")
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

  private

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
