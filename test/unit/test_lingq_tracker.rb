# frozen_string_literal: true

require_relative "../test_helper"
require "lingq_tracker"

class TestLingqTracker < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_lingq_tracker_test")
    @path = File.join(@tmpdir, "lingq_uploads.yml")
    @tracker = LingqTracker.new(@path)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- load ---

  def test_load_empty_when_no_file
    assert_equal({}, @tracker.load)
  end

  def test_load_returns_hash
    File.write(@path, { "12345" => { "ep-2026-03-01" => 100 } }.to_yaml)
    data = @tracker.load
    assert_equal({ "12345" => { "ep-2026-03-01" => 100 } }, data)
  end

  def test_load_normalizes_symbol_keys_to_strings
    File.write(@path, { collection: { episode: 99 } }.to_yaml)
    data = @tracker.load
    assert data.key?("collection"), "Top-level keys should be strings"
    assert data["collection"].key?("episode"), "Nested keys should be strings"
  end

  def test_load_handles_corrupt_file
    File.write(@path, "not: valid: yaml: [[[")
    assert_equal({}, @tracker.load)
  end

  # --- save ---

  def test_save_writes_file
    @tracker.save({ "12345" => { "ep-2026-03-01" => 100 } })
    assert File.exist?(@path)
    data = YAML.load_file(@path)
    assert_equal 100, data["12345"]["ep-2026-03-01"]
  end

  # --- record ---

  def test_record_adds_entry
    @tracker.record("12345", "ep-2026-03-01", 100)

    data = @tracker.load
    assert_equal 100, data["12345"]["ep-2026-03-01"]
  end

  def test_record_appends_to_existing
    @tracker.record("12345", "ep-2026-03-01", 100)
    @tracker.record("12345", "ep-2026-03-02", 200)

    data = @tracker.load
    assert_equal 100, data["12345"]["ep-2026-03-01"]
    assert_equal 200, data["12345"]["ep-2026-03-02"]
  end

  def test_record_multiple_collections
    @tracker.record("col_a", "ep-2026-03-01", 100)
    @tracker.record("col_b", "ep-2026-03-01", 200)

    data = @tracker.load
    assert_equal 100, data["col_a"]["ep-2026-03-01"]
    assert_equal 200, data["col_b"]["ep-2026-03-01"]
  end

  # --- remove ---

  def test_remove_deletes_entry
    @tracker.record("12345", "ep-2026-03-01", 100)
    @tracker.record("12345", "ep-2026-03-02", 200)

    result = @tracker.remove("ep-2026-03-01")
    assert result, "Should return true when entry found"

    data = @tracker.load
    refute data["12345"].key?("ep-2026-03-01")
    assert_equal 200, data["12345"]["ep-2026-03-02"]
  end

  def test_remove_nonexistent_returns_false
    @tracker.record("12345", "ep-2026-03-01", 100)
    result = @tracker.remove("ep-9999-99-99")
    refute result
  end

  # --- tracked? ---

  def test_tracked_returns_true_for_existing
    @tracker.record("12345", "ep-2026-03-01", 100)
    assert @tracker.tracked?("12345", "ep-2026-03-01")
  end

  def test_tracked_returns_false_for_missing
    refute @tracker.tracked?("12345", "ep-2026-03-01")
  end
end
