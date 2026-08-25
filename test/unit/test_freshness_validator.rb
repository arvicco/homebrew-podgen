# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "yaml"
require "validators/freshness_validator"

class TestFreshnessValidator < Minitest::Test
  FakeConfig = Struct.new(:history_path, keyword_init: true)

  def with_history(dates)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "history.yml")
      entries = dates.map { |d| {"date" => d, "title" => "t", "topics" => []} }
      File.write(path, entries.to_yaml)
      yield FakeConfig.new(history_path: path)
    end
  end

  def validate(config, today)
    Validators::FreshnessValidator.new(config, today: today).validate
  end

  def test_check_fresh_daily_podcast_passes
    with_history(%w[2026-08-20 2026-08-21 2026-08-22 2026-08-23 2026-08-24]) do |config|
      result = validate(config, Date.new(2026, 8, 25))
      assert_empty result[:warnings]
      assert result[:passes].any? { |p| p.include?("Freshness") }
    end
  end

  def test_check_stale_daily_podcast_trips_old_flag
    with_history(%w[2026-08-01 2026-08-02 2026-08-03 2026-08-04 2026-08-05]) do |config|
      result = validate(config, Date.new(2026, 8, 25))
      old = result[:warnings].find { |w| w.include?("OLD") }
      refute_nil old, "expected OLD flag, got: #{result.inspect}"
      assert_includes old, "2026-08-05"
    end
  end

  def test_check_weekly_cadence_not_stale_within_threshold
    # ~7-day cadence, newest 10 days old — within 2× median, no flag.
    with_history(%w[2026-07-18 2026-07-25 2026-08-01 2026-08-08 2026-08-15]) do |config|
      result = validate(config, Date.new(2026, 8, 25))
      assert_empty result[:warnings], result.inspect
    end
  end

  def test_check_weekly_cadence_stale_beyond_threshold
    with_history(%w[2026-06-06 2026-06-13 2026-06-20 2026-06-27 2026-07-04]) do |config|
      result = validate(config, Date.new(2026, 8, 25))
      assert result[:warnings].any? { |w| w.include?("OLD") }, result.inspect
    end
  end

  def test_check_too_little_history_passes_without_flag
    with_history(%w[2026-08-01]) do |config|
      result = validate(config, Date.new(2026, 8, 25))
      assert_empty result[:warnings]
      assert result[:passes].any? { |p| p =~ /cannot infer cadence/i }
    end
  end

  def test_check_missing_history_file_passes_quietly
    config = FakeConfig.new(history_path: "/nonexistent/history.yml")
    result = validate(config, Date.new(2026, 8, 25))
    assert_empty result[:warnings]
    assert_empty result[:errors]
  end

  def test_check_same_day_multi_episodes_use_unique_dates_for_cadence
    # Suffixed same-day episodes must not zero the median gap.
    with_history(%w[2026-08-10 2026-08-10 2026-08-10 2026-08-17 2026-08-24]) do |config|
      result = validate(config, Date.new(2026, 8, 25))
      assert_empty result[:warnings], result.inspect
    end
  end
end
