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

  # --- episode page ---

  def test_episode_page_with_article
    html = "<html><body><article>" + ("word " * 200) + "</article></body></html>"

    TranscriptDiscovery.stub(:fetch_url, html) do
      result = TranscriptDiscovery.search(rss_item: { link: "https://example.com/ep1" })
      assert_equal :high, result[:quality]
      assert_equal "episode_page", result[:source]
    end
  end

  def test_episode_page_no_substantial_content
    html = "<html><body><p>Short page.</p></body></html>"

    TranscriptDiscovery.stub(:fetch_url, html) do
      result = TranscriptDiscovery.search(rss_item: { link: "https://example.com/ep1" })
      assert_nil result
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

  def test_no_sources_returns_nil
    result = TranscriptDiscovery.search
    assert_nil result
  end
end
