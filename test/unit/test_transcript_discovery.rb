# frozen_string_literal: true

require_relative "../test_helper"
require "transcript_discovery"

class TestTranscriptDiscovery < Minitest::Test
  # --- podcast:transcript ---

  def test_podcast_transcript_srt
    srt = "1\n00:00:01,000 --> 00:00:03,000\n" + ("word " * 120)

    TranscriptDiscovery.stub(:fetch_url, srt) do
      result = TranscriptDiscovery.search(rss_item: {
        transcript_url: "https://example.com/ep.srt",
        transcript_type: "application/x-subrip"
      })
      assert_equal :high, result[:quality]
      assert_equal "podcast:transcript", result[:source]
      assert result[:text].length > 0
    end
  end

  def test_podcast_transcript_vtt
    vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n" + ("word " * 120)

    TranscriptDiscovery.stub(:fetch_url, vtt) do
      result = TranscriptDiscovery.search(rss_item: {
        transcript_url: "https://example.com/ep.vtt"
      })
      assert_equal :high, result[:quality]
      assert_equal "podcast:transcript", result[:source]
    end
  end

  def test_podcast_transcript_too_short_skipped
    srt = "1\n00:00:01,000 --> 00:00:03,000\nJust a few words."

    TranscriptDiscovery.stub(:fetch_url, srt) do
      result = TranscriptDiscovery.search(rss_item: {
        transcript_url: "https://example.com/ep.srt"
      })
      assert_nil result
    end
  end

  def test_podcast_transcript_fetch_failure_returns_nil
    TranscriptDiscovery.stub(:fetch_url, nil) do
      result = TranscriptDiscovery.search(rss_item: {
        transcript_url: "https://example.com/broken.srt"
      })
      assert_nil result
    end
  end

  # P18-6 (Q-137): a transport failure inside the fetch was fully silent
  # (rescue => e; nil, never logged) — it now leaves a log line; the result
  # is still nil and the next strategy is still tried.
  def test_fetch_url_transport_failure_logs_and_returns_nil
    lines = []
    logger = Object.new
    logger.define_singleton_method(:log) { |msg| lines << msg }

    result = Net::HTTP.stub(:new, ->(*) { raise SocketError, "getaddrinfo failed" }) do
      TranscriptDiscovery.fetch_podcast_transcript("https://example.com/ep.srt", logger: logger)
    end

    assert_nil result
    assert(lines.any? { |l| l.include?("SocketError") && l.include?("https://example.com/ep.srt") },
      "expected a fetch-failure log line, got #{lines.inspect}")
  end

  # --- content:encoded ---

  def test_content_encoded_substantial_text
    html = "<p>" + ("word " * 150) + "</p>"
    result = TranscriptDiscovery.search(rss_item: { content_encoded: html })
    assert_equal :medium, result[:quality]
    assert_equal "content:encoded", result[:source]
  end

  def test_content_encoded_too_short_skipped
    result = TranscriptDiscovery.search(rss_item: { content_encoded: "<p>Short promo.</p>" })
    assert_nil result
  end

  # --- episode page (currently disabled — too many false positives) ---

  def test_episode_page_scraping_disabled
    result = TranscriptDiscovery.search(rss_item: { link: "https://example.com/ep1" })
    assert_nil result, "episode page scraping should be disabled"
  end

  def test_scrape_episode_page_extracts_article_when_called_directly
    html = "<html><body><article>" + ("word " * 200) + "</article></body></html>"

    TranscriptDiscovery.stub(:fetch_url, html) do
      result = TranscriptDiscovery.scrape_episode_page("https://example.com/ep1")
      assert_equal :high, result[:quality]
      assert_equal "episode_page", result[:source]
    end
  end

  # --- youtube captions ---

  def test_youtube_captions_returned_as_low_quality
    result = TranscriptDiscovery.search(youtube_captions: "some caption text here")
    assert_equal :low, result[:quality]
    assert_equal "youtube_captions", result[:source]
    assert_equal "some caption text here", result[:text]
  end

  def test_empty_youtube_captions_skipped
    result = TranscriptDiscovery.search(youtube_captions: "  ")
    assert_nil result
  end

  # --- priority order ---

  def test_podcast_transcript_takes_priority_over_content_encoded
    srt = "1\n00:00:01,000 --> 00:00:03,000\n" + ("word " * 120)

    TranscriptDiscovery.stub(:fetch_url, srt) do
      result = TranscriptDiscovery.search(rss_item: {
        transcript_url: "https://example.com/ep.srt",
        content_encoded: "<p>" + ("other " * 150) + "</p>"
      })
      assert_equal "podcast:transcript", result[:source]
    end
  end

  # P14-2 (Q-131): entities decode to their characters, not deleted
  def test_strip_html_keeps_diacritics
    html = "<p>Pe&#269;ica &scaron;e perch&eacute; &amp; &lt;x&gt;</p>"

    text = TranscriptDiscovery.send(:strip_html, html)

    assert_equal "Pečica še perché & <x>", text
  end

  def test_no_sources_returns_nil
    result = TranscriptDiscovery.search
    assert_nil result
  end
end
