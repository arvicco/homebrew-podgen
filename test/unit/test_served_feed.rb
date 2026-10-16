# frozen_string_literal: true

require_relative "../test_helper"
require "served_feed"

class TestServedFeed < Minitest::Test
  FEED = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>t</title>
      <lastBuildDate>Sun, 11 Oct 2026 07:00:00 +0000</lastBuildDate>
      <item><title>a</title><pubDate>Mon, 05 Oct 2026 06:00:00 +0200</pubDate></item>
      <item><title>b</title><pubDate>Wed, 07 Oct 2026 16:31:02 +0200</pubDate></item>
      <item><title>c</title><pubDate>Tue, 06 Oct 2026 06:00:00 +0200</pubDate></item>
    </channel></rss>
  XML

  def test_newest_date_returns_newest_item_pub_date
    feed = ServedFeed.new(fetcher: ->(_url) { FEED })
    assert_equal Date.new(2026, 10, 7), feed.newest_date("https://media.example.com/alpha/feed.xml")
  end

  def test_newest_date_passes_url_to_fetcher
    seen = nil
    ServedFeed.new(fetcher: ->(url) { (seen = url) && FEED }).newest_date("https://h/x/feed.xml")
    assert_equal "https://h/x/feed.xml", seen
  end

  def test_newest_date_feed_without_items_is_nil
    feed = ServedFeed.new(fetcher: ->(_url) { "<rss><channel><title>t</title></channel></rss>" })
    assert_nil feed.newest_date("https://h/feed.xml")
  end

  def test_newest_date_skips_unparseable_pub_dates
    xml = "<rss><channel><item><pubDate>garbage</pubDate></item>" \
      "<item><pubDate>Mon, 05 Oct 2026 06:00:00 +0000</pubDate></item></channel></rss>"
    assert_equal Date.new(2026, 10, 5), ServedFeed.new(fetcher: ->(_url) { xml }).newest_date("https://h/feed.xml")
  end

  def test_newest_date_network_error_retries_once_then_raises_with_cause
    calls = 0
    feed = ServedFeed.new(fetcher: ->(_url) {
      calls += 1
      raise SocketError, "getaddrinfo: nodename nor servname provided"
    })
    feed.define_singleton_method(:sleep) { |_| nil }

    err = assert_raises(RuntimeError) { feed.newest_date("https://h/feed.xml") }
    assert_equal 2, calls
    assert_kind_of SocketError, err.cause
  end

  def test_newest_date_down_host_is_fetched_once_per_run
    calls = []
    feed = ServedFeed.new(fetcher: ->(url) {
      calls << url
      raise SocketError, "down" if url.include?("down.example")
      FEED
    })
    feed.define_singleton_method(:sleep) { |_| nil }

    first = assert_raises(RuntimeError) { feed.newest_date("https://down.example/a/feed.xml") }
    second = assert_raises(RuntimeError) { feed.newest_date("https://down.example/b/feed.xml") }
    assert_equal Date.new(2026, 10, 7), feed.newest_date("https://up.example/c/feed.xml")

    assert_equal 2, calls.count { |u| u.include?("down.example") } # first attempt + one retry, then cached
    assert_kind_of SocketError, first.cause
    assert_kind_of SocketError, second.cause
  end

  def test_newest_date_status_error_does_not_mark_host_down
    calls = 0
    feed = ServedFeed.new(fetcher: ->(url) {
      calls += 1
      raise ServedFeed::StatusError, "HTTP 404" if url.include?("/a/")
      FEED
    })
    assert_raises(ServedFeed::StatusError) { feed.newest_date("https://h/a/feed.xml") }
    assert_equal Date.new(2026, 10, 7), feed.newest_date("https://h/b/feed.xml")
    assert_equal 2, calls
  end

  def test_newest_date_status_error_is_not_retried
    calls = 0
    feed = ServedFeed.new(fetcher: ->(_url) {
      calls += 1
      raise ServedFeed::StatusError, "HTTP 404"
    })
    assert_raises(ServedFeed::StatusError) { feed.newest_date("https://h/feed.xml") }
    assert_equal 1, calls
  end
end
