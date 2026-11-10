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

  # --- P18-6 (Q-137): temp names carry a random suffix, not the pid alone ---

  YtStatus = Struct.new(:success?)

  # Fake yt-dlp: writes the file its -o template names, with the given ext.
  def fake_yt_dlp(ext, written)
    ->(*args) {
      path = args[args.index("-o") + 1].sub("%(ext)s", ext)
      File.write(path, "x")
      written << path
      ["", "", YtStatus.new(true)]
    }
  end

  def test_download_audio_two_calls_get_distinct_random_suffixed_paths
    written = []
    paths = Open3.stub(:capture3, fake_yt_dlp("mp3", written)) do
      [build_downloader.download_audio("https://youtu.be/a"), build_downloader.download_audio("https://youtu.be/b")]
    end

    paths.each { |p| assert_match(/podgen_yt_#{Process.pid}_\h{8}\.mp3\z/, p) }
    refute_equal paths[0], paths[1]
  ensure
    written&.each { |p| FileUtils.rm_f(p) }
  end

  def test_download_thumbnail_random_suffixed_path_found
    written = []
    path = Open3.stub(:capture3, fake_yt_dlp("jpg", written)) do
      build_downloader.download_thumbnail("https://youtu.be/a")
    end

    assert_match(/podgen_thumb_#{Process.pid}_\h{8}\.jpg\z/, path)
  ensure
    written&.each { |p| FileUtils.rm_f(p) }
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
