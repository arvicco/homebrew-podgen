# frozen_string_literal: true

require_relative "../test_helper"
require "upload_tracker"

class TestUploadTracker < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_upload_tracker_test")
    @path = File.join(@tmpdir, "uploads.yml")
    @tracker = UploadTracker.new(@path)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- load ---

  def test_load_empty_when_no_file
    assert_equal({}, @tracker.load)
  end

  def test_load_returns_hash
    File.write(@path, { "lingq" => { "12345" => { "ep-2026-03-01" => 100 } } }.to_yaml)
    data = @tracker.load
    assert_equal({ "lingq" => { "12345" => { "ep-2026-03-01" => 100 } } }, data)
  end

  def test_load_normalizes_symbol_keys_to_strings
    File.write(@path, { lingq: { collection: { episode: 99 } } }.to_yaml)
    data = @tracker.load
    assert data.key?("lingq"), "Platform keys should be strings"
    assert data["lingq"].key?("collection"), "Group keys should be strings"
    assert data["lingq"]["collection"].key?("episode"), "Basename keys should be strings"
  end

  def test_load_handles_corrupt_file
    File.write(@path, "not: valid: yaml: [[[")
    assert_equal({}, @tracker.load)
  end

  # --- save ---

  def test_save_writes_file
    @tracker.save({ "lingq" => { "12345" => { "ep-2026-03-01" => 100 } } })
    assert File.exist?(@path)
    data = YAML.load_file(@path)
    assert_equal 100, data["lingq"]["12345"]["ep-2026-03-01"]
  end

  # --- record ---

  def test_record_adds_entry
    @tracker.record(:lingq, "12345", "ep-2026-03-01", 100)

    data = @tracker.load
    assert_equal 100, data["lingq"]["12345"]["ep-2026-03-01"]
  end

  def test_record_appends_to_existing_group
    @tracker.record(:lingq, "12345", "ep-2026-03-01", 100)
    @tracker.record(:lingq, "12345", "ep-2026-03-02", 200)

    data = @tracker.load
    assert_equal 100, data["lingq"]["12345"]["ep-2026-03-01"]
    assert_equal 200, data["lingq"]["12345"]["ep-2026-03-02"]
  end

  def test_record_multiple_groups
    @tracker.record(:lingq, "col_a", "ep-2026-03-01", 100)
    @tracker.record(:lingq, "col_b", "ep-2026-03-01", 200)

    data = @tracker.load
    assert_equal 100, data["lingq"]["col_a"]["ep-2026-03-01"]
    assert_equal 200, data["lingq"]["col_b"]["ep-2026-03-01"]
  end

  def test_record_multiple_platforms
    @tracker.record(:lingq, "col_a", "ep-2026-03-01", 100)
    @tracker.record(:youtube, "PLabc", "ep-2026-03-01", "dQw4w9WgXcQ")

    data = @tracker.load
    assert_equal 100, data["lingq"]["col_a"]["ep-2026-03-01"]
    assert_equal "dQw4w9WgXcQ", data["youtube"]["PLabc"]["ep-2026-03-01"]
  end

  # --- remove ---

  def test_remove_deletes_entry_from_all_platforms
    @tracker.record(:lingq, "12345", "ep-2026-03-01", 100)
    @tracker.record(:youtube, "PLabc", "ep-2026-03-01", "vid123")
    @tracker.record(:lingq, "12345", "ep-2026-03-02", 200)

    result = @tracker.remove("ep-2026-03-01")
    assert result, "Should return true when entry found"

    data = @tracker.load
    refute data["lingq"]["12345"].key?("ep-2026-03-01")
    refute data["youtube"]["PLabc"].key?("ep-2026-03-01")
    assert_equal 200, data["lingq"]["12345"]["ep-2026-03-02"]
  end

  def test_remove_nonexistent_returns_false
    @tracker.record(:lingq, "12345", "ep-2026-03-01", 100)
    result = @tracker.remove("ep-9999-99-99")
    refute result
  end

  # --- tracked? ---

  def test_tracked_returns_true_for_existing
    @tracker.record(:lingq, "12345", "ep-2026-03-01", 100)
    assert @tracker.tracked?(:lingq, "12345", "ep-2026-03-01")
  end

  def test_tracked_returns_false_for_missing
    refute @tracker.tracked?(:lingq, "12345", "ep-2026-03-01")
  end

  def test_tracked_scoped_to_platform
    @tracker.record(:lingq, "12345", "ep-2026-03-01", 100)
    refute @tracker.tracked?(:youtube, "12345", "ep-2026-03-01")
  end

  # --- entries_for ---

  def test_entries_for_returns_group_entries
    @tracker.record(:lingq, "12345", "ep-2026-03-01", 100)
    @tracker.record(:lingq, "12345", "ep-2026-03-02", 200)

    entries = @tracker.entries_for(:lingq, "12345")
    assert_equal({ "ep-2026-03-01" => 100, "ep-2026-03-02" => 200 }, entries)
  end

  def test_entries_for_returns_empty_hash_when_missing
    assert_equal({}, @tracker.entries_for(:lingq, "nonexistent"))
  end

  # --- video_ids_for (YouTube convenience) ---

  def test_video_ids_for_returns_youtube_ids_for_basename
    @tracker.record(:youtube, "PLabc", "ep-2026-03-01", "vid123")
    @tracker.record(:youtube, "PLxyz", "ep-2026-03-01", "vid456")

    ids = @tracker.video_ids_for("ep-2026-03-01")
    assert_includes ids, "vid123"
    assert_includes ids, "vid456"
    assert_equal 2, ids.length
  end

  def test_video_ids_for_returns_empty_when_no_youtube
    @tracker.record(:lingq, "12345", "ep-2026-03-01", 100)
    assert_equal [], @tracker.video_ids_for("ep-2026-03-01")
  end

  # --- migration ---

  def test_migrate_from_lingq_uploads_yml
    old_path = File.join(@tmpdir, "lingq_uploads.yml")
    File.write(old_path, { "12345" => { "ep-2026-03-01" => 100 } }.to_yaml)

    tracker = UploadTracker.new(@path)
    data = tracker.load

    assert_equal 100, data["lingq"]["12345"]["ep-2026-03-01"]
    refute File.exist?(old_path), "Old file should be removed after migration"
    assert File.exist?(@path), "New file should exist after migration"
  end

  def test_no_migration_when_uploads_yml_exists
    old_path = File.join(@tmpdir, "lingq_uploads.yml")
    File.write(old_path, { "12345" => { "ep-old" => 999 } }.to_yaml)
    File.write(@path, { "lingq" => { "12345" => { "ep-new" => 100 } } }.to_yaml)

    tracker = UploadTracker.new(@path)
    data = tracker.load

    assert_equal 100, data["lingq"]["12345"]["ep-new"]
    refute data["lingq"]["12345"].key?("ep-old"), "Old data should not overwrite"
  end

  def test_no_migration_when_no_old_file
    tracker = UploadTracker.new(@path)
    data = tracker.load
    assert_equal({}, data)
  end
end
