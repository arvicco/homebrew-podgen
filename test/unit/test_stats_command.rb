# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "cli/stats_command"

class TestStatsCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_stats_test")
    @podcast_dir = File.join(@tmpdir, "mypod")
    @episodes_dir = File.join(@podcast_dir, "episodes")
    @history_path = File.join(@podcast_dir, "history.yml")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- format_duration ---

  def test_format_duration_minutes_only
    cmd = build_command
    assert_equal "5m", cmd.send(:format_duration, 300)
  end

  def test_format_duration_hours_and_minutes
    cmd = build_command
    assert_equal "1h 30m", cmd.send(:format_duration, 5400)
  end

  def test_format_duration_zero
    cmd = build_command
    assert_equal "0m", cmd.send(:format_duration, 0)
  end

  def test_format_duration_fractional_seconds
    cmd = build_command
    assert_equal "2m", cmd.send(:format_duration, 150.7)
  end

  # --- format_duration_short ---

  def test_format_duration_short_basic
    cmd = build_command
    assert_equal "3:05", cmd.send(:format_duration_short, 185)
  end

  def test_format_duration_short_zero
    cmd = build_command
    assert_equal "0:00", cmd.send(:format_duration_short, 0)
  end

  def test_format_duration_short_exact_minute
    cmd = build_command
    assert_equal "10:00", cmd.send(:format_duration_short, 600)
  end

  # --- format_size ---

  def test_format_size_bytes
    cmd = build_command
    assert_equal "500 B", cmd.send(:format_size, 500)
  end

  def test_format_size_kilobytes
    cmd = build_command
    assert_equal "10 KB", cmd.send(:format_size, 10_000)
  end

  def test_format_size_megabytes
    cmd = build_command
    assert_equal "2 MB", cmd.send(:format_size, 1_500_000)
  end

  def test_format_size_gigabytes
    cmd = build_command
    assert_equal "2.3 GB", cmd.send(:format_size, 2_300_000_000)
  end

  # --- truncate ---

  def test_truncate_short_string
    cmd = build_command
    assert_equal "hello", cmd.send(:truncate, "hello", 10)
  end

  def test_truncate_long_string
    cmd = build_command
    result = cmd.send(:truncate, "a very long string", 10)
    assert_equal 10, result.length
    assert result.end_with?("…")
  end

  def test_truncate_exact_length
    cmd = build_command
    assert_equal "abcde", cmd.send(:truncate, "abcde", 5)
  end

  # --- build_duration_map ---

  def test_build_duration_map_from_history
    File.write(@history_path, [
      { "date" => "2026-01-15", "title" => "Ep 1", "duration" => 120.5 },
      { "date" => "2026-01-16", "title" => "Ep 2", "duration" => 200.0 }
    ].to_yaml)

    cmd = build_command
    config = stub_config
    map = cmd.send(:build_duration_map, config)

    assert_in_delta 120.5, map["mypod-2026-01-15.mp3"]
    assert_in_delta 200.0, map["mypod-2026-01-16.mp3"]
  end

  def test_build_duration_map_same_date_suffixes
    File.write(@history_path, [
      { "date" => "2026-01-15", "title" => "Ep A", "duration" => 60.0 },
      { "date" => "2026-01-15", "title" => "Ep B", "duration" => 90.0 }
    ].to_yaml)

    cmd = build_command
    config = stub_config
    map = cmd.send(:build_duration_map, config)

    assert_in_delta 60.0, map["mypod-2026-01-15.mp3"]
    assert_in_delta 90.0, map["mypod-2026-01-15a.mp3"]
  end

  def test_build_duration_map_missing_history
    cmd = build_command
    config = stub_config(history_path: "/nonexistent.yml")
    map = cmd.send(:build_duration_map, config)

    assert_equal({}, map)
  end

  def test_build_duration_map_skips_entries_without_duration
    File.write(@history_path, [
      { "date" => "2026-01-15", "title" => "No Duration" }
    ].to_yaml)

    cmd = build_command
    config = stub_config
    map = cmd.send(:build_duration_map, config)

    assert_empty map
  end

  private

  def create_mp3(name, size)
    File.write(File.join(@episodes_dir, name), "x" * size)
  end

  StubStatsConfig = Struct.new(:episodes_dir, :history_path, keyword_init: true)

  def stub_config(**overrides)
    defaults = {
      episodes_dir: @episodes_dir,
      history_path: @history_path
    }
    StubStatsConfig.new(**defaults.merge(overrides))
  end

  def build_command
    PodgenCLI::StatsCommand.allocate
  end
end
