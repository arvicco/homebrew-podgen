# frozen_string_literal: true

require_relative "../test_helper"
require "subtitle_generator"

class TestSubtitleGenerator < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_subtitle_test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- format_srt_time ---

  def test_format_srt_time_zero
    assert_equal "00:00:00,000", SubtitleGenerator.format_srt_time(0.0)
  end

  def test_format_srt_time_seconds_only
    assert_equal "00:00:05,200", SubtitleGenerator.format_srt_time(5.2)
  end

  def test_format_srt_time_minutes_and_seconds
    assert_equal "00:01:23,456", SubtitleGenerator.format_srt_time(83.456)
  end

  def test_format_srt_time_hours
    assert_equal "01:02:03,500", SubtitleGenerator.format_srt_time(3723.5)
  end

  # --- generate_srt ---

  def test_generate_srt_basic
    ts_path = write_timestamps([
      { "start" => 0.0, "end" => 4.2, "text" => "First sentence." },
      { "start" => 4.2, "end" => 9.1, "text" => "Second sentence." }
    ])
    srt_path = File.join(@tmpdir, "episode.srt")

    SubtitleGenerator.generate_srt(ts_path, srt_path)

    content = File.read(srt_path)
    lines = content.strip.split("\n")
    assert_equal "1", lines[0]
    assert_equal "00:00:00,000 --> 00:00:04,200", lines[1]
    assert_equal "First sentence.", lines[2]
    assert_equal "", lines[3]
    assert_equal "2", lines[4]
    assert_equal "00:00:04,200 --> 00:00:09,100", lines[5]
    assert_equal "Second sentence.", lines[6]
  end

  def test_generate_srt_empty_segments
    ts_path = write_timestamps([])
    srt_path = File.join(@tmpdir, "episode.srt")

    SubtitleGenerator.generate_srt(ts_path, srt_path)

    assert_equal "", File.read(srt_path).strip
  end

  def test_generate_srt_splits_long_segments
    long_text = "This is a very long sentence that exceeds the maximum character limit " \
                "and should be split into multiple subtitle entries for readability."
    ts_path = write_timestamps([
      { "start" => 0.0, "end" => 10.0, "text" => long_text }
    ])
    srt_path = File.join(@tmpdir, "episode.srt")

    SubtitleGenerator.generate_srt(ts_path, srt_path)

    content = File.read(srt_path)
    entries = content.strip.split("\n\n")
    assert entries.length > 1, "Long segment should be split into multiple entries"
    # All parts combined should equal the original text
    texts = entries.map { |e| e.split("\n")[2..].join("\n") }
    assert_equal long_text, texts.join(" ")
  end

  def test_generate_srt_preserves_short_segments
    ts_path = write_timestamps([
      { "start" => 0.0, "end" => 5.0, "text" => "Short." }
    ])
    srt_path = File.join(@tmpdir, "episode.srt")

    SubtitleGenerator.generate_srt(ts_path, srt_path)

    entries = File.read(srt_path).strip.split("\n\n")
    assert_equal 1, entries.length
  end

  def test_generate_srt_split_distributes_time_proportionally
    text = "Short part. " + ("A" * 70 + " long part.")
    ts_path = write_timestamps([
      { "start" => 0.0, "end" => 10.0, "text" => text }
    ])
    srt_path = File.join(@tmpdir, "episode.srt")

    SubtitleGenerator.generate_srt(ts_path, srt_path)

    content = File.read(srt_path)
    entries = content.strip.split("\n\n")
    # First part should get a proportionally smaller time slice
    first_end = parse_srt_time(entries[0].split("\n")[1].split(" --> ")[1])
    assert first_end < 5.0, "Shorter text should get proportionally less time"
  end

  def test_generate_srt_returns_output_path
    ts_path = write_timestamps([{ "start" => 0.0, "end" => 1.0, "text" => "Hi." }])
    srt_path = File.join(@tmpdir, "episode.srt")

    result = SubtitleGenerator.generate_srt(ts_path, srt_path)
    assert_equal srt_path, result
  end

  def test_generate_srt_returns_nil_for_missing_timestamps
    result = SubtitleGenerator.generate_srt(File.join(@tmpdir, "nonexistent.json"), File.join(@tmpdir, "out.srt"))
    assert_nil result
  end

  private

  def write_timestamps(segments)
    path = File.join(@tmpdir, "ep_timestamps.json")
    data = { "version" => 1, "engine" => "groq", "intro_duration" => 0.0, "segments" => segments }
    File.write(path, JSON.generate(data))
    path
  end

  def parse_srt_time(time_str)
    parts = time_str.match(/(\d+):(\d+):(\d+),(\d+)/)
    parts[1].to_f * 3600 + parts[2].to_f * 60 + parts[3].to_f + parts[4].to_f / 1000
  end
end
