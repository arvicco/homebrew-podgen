# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "yaml"
require "validators/freshness_validator"

class TestFreshnessValidator < Minitest::Test
  FakeConfig = Struct.new(:history_path, :freshness_enabled, :lead_days, keyword_init: true) do
    def freshness_enabled?
      freshness_enabled != false
    end

    def freshness_lead_days = lead_days || 3
  end

  def with_history(dates, freshness_enabled: true, lead_days: nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "history.yml")
      entries = dates.map { |d| {"date" => d, "title" => "t", "topics" => []} }
      File.write(path, entries.to_yaml)
      yield FakeConfig.new(history_path: path, freshness_enabled: freshness_enabled, lead_days: lead_days)
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

  def test_check_newest_within_lead_days_passes_as_scheduled
    with_history(%w[2026-08-23 2026-08-24 2026-08-25 2026-08-26]) do |config|
      result = validate(config, Date.new(2026, 8, 25))
      assert_empty result[:warnings], result.inspect
      assert result[:passes].any? { |p| p.include?("scheduled +1d") }, result.inspect
    end
  end

  def test_check_newest_beyond_lead_days_warns_future
    with_history(%w[2026-09-02 2026-09-03 2026-09-04]) do |config|
      result = validate(config, Date.new(2026, 8, 25))
      assert result[:warnings].any? { |w| w.include?("dated in the future (10 days ahead)") }, result.inspect
    end
  end

  def test_check_lead_days_zero_warns_one_day_ahead
    with_history(%w[2026-08-24 2026-08-25 2026-08-26], lead_days: 0) do |config|
      result = validate(config, Date.new(2026, 8, 25))
      assert result[:warnings].any? { |w| w.include?("dated in the future (1 days ahead)") }, result.inspect
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

  def test_check_freshness_disabled_skips_old_flag_with_notice
    with_history(%w[2026-08-01 2026-08-02 2026-08-03 2026-08-04 2026-08-05], freshness_enabled: false) do |config|
      result = validate(config, Date.new(2026, 8, 25))
      assert_empty result[:warnings], result.inspect
      assert_empty result[:errors]
      assert result[:passes].any? { |p| p.include?("disabled by guidelines") }, result.inspect
    end
  end

  def test_check_future_dated_newest_episode_warns_naming_date
    with_history(%w[2026-08-20 2026-08-21 2026-08-22 2026-08-23 2026-09-30]) do |config|
      result = validate(config, Date.new(2026, 8, 25))
      future = result[:warnings].find { |w| w.include?("future") }
      refute_nil future, result.inspect
      assert_includes future, "2026-09-30"
      assert_empty result[:errors]
    end
  end

  def test_check_newest_dated_today_is_not_future
    with_history(%w[2026-08-22 2026-08-23 2026-08-24 2026-08-25]) do |config|
      result = validate(config, Date.new(2026, 8, 25))
      assert_empty result[:warnings], result.inspect
    end
  end
end
