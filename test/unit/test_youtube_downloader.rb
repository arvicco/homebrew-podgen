# frozen_string_literal: true

require_relative "../test_helper"
require "youtube_downloader"

class TestYouTubeDownloader < Minitest::Test
  # --- strip_srt_timestamps ---

  def test_strip_srt_basic
    srt = <<~SRT
      1
      00:00:01,000 --> 00:00:04,000
      Hello world

      2
      00:00:05,000 --> 00:00:08,000
      This is a test
    SRT

    result = build_downloader.send(:strip_srt_timestamps, srt)
    assert_equal "Hello world This is a test", result
  end

  def test_strip_srt_deduplicates_whitespace
    srt = <<~SRT
      1
      00:00:01,000 --> 00:00:04,000
      Hello   world

      2
      00:00:05,000 --> 00:00:08,000
      More    text    here
    SRT

    result = build_downloader.send(:strip_srt_timestamps, srt)
    assert_equal "Hello world More text here", result
  end

  def test_strip_srt_handles_empty
    result = build_downloader.send(:strip_srt_timestamps, "")
    assert_equal "", result
  end

  def test_strip_srt_handles_only_timestamps
    srt = <<~SRT
      1
      00:00:01,000 --> 00:00:04,000

      2
      00:00:05,000 --> 00:00:08,000
    SRT

    result = build_downloader.send(:strip_srt_timestamps, srt)
    assert_equal "", result
  end

  def test_strip_srt_with_multiline_subtitles
    srt = <<~SRT
      1
      00:00:01,000 --> 00:00:04,000
      First line
      Second line

      2
      00:00:05,000 --> 00:00:08,000
      Third line
    SRT

    result = build_downloader.send(:strip_srt_timestamps, srt)
    assert_equal "First line Second line Third line", result
  end

  def test_strip_srt_with_comma_milliseconds
    srt = "1\n00:01:23,456 --> 00:01:25,789\nText here\n"
    result = build_downloader.send(:strip_srt_timestamps, srt)
    assert_equal "Text here", result
  end

  def test_strip_srt_with_period_milliseconds
    srt = "1\n00:01:23.456 --> 00:01:25.789\nText here\n"
    result = build_downloader.send(:strip_srt_timestamps, srt)
    assert_equal "Text here", result
  end

  # --- cookies_args ---

  def test_cookies_args_default
    dl = build_downloader
    assert_equal ["--cookies-from-browser", "chrome"], dl.send(:cookies_args)
  end

  def test_cookies_args_from_env
    original = ENV["YOUTUBE_BROWSER"]
    ENV["YOUTUBE_BROWSER"] = "firefox"
    dl = YouTubeDownloader.new
    assert_equal ["--cookies-from-browser", "firefox"], dl.send(:cookies_args)
  ensure
    if original
      ENV["YOUTUBE_BROWSER"] = original
    else
      ENV.delete("YOUTUBE_BROWSER")
    end
  end

  private

  def build_downloader
    # Skip yt-dlp verification
    dl = YouTubeDownloader.allocate
    dl.instance_variable_set(:@verified, true)
    dl.instance_variable_set(:@logger, nil)
    dl.instance_variable_set(:@browser, "chrome")
    dl
  end
end
