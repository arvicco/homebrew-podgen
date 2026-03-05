# frozen_string_literal: true

require_relative "../test_helper"
require "tell/history"

class TestTellHistory < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("tell_history_test")
    @path = File.join(@dir, "history")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- Load ---

  def test_nonexistent_file_returns_empty
    h = Tell::History.new(@path)
    assert_equal [], h.entries
  end

  def test_reads_entries_from_file
    File.write(@path, "alpha\nbeta\ngamma\n")
    h = Tell::History.new(@path)
    assert_equal %w[alpha beta gamma], h.entries
  end

  def test_dedup_keeps_last_occurrence
    File.write(@path, "a\nb\na\nc\n")
    h = Tell::History.new(@path)
    assert_equal %w[b a c], h.entries
  end

  def test_strips_blanks
    File.write(@path, "  hello  \n\n  world  \n")
    h = Tell::History.new(@path)
    assert_equal %w[hello world], h.entries
  end

  def test_utf8_slovenian
    File.write(@path, "čebela\nšola\nžaba\n", encoding: "UTF-8")
    h = Tell::History.new(@path)
    assert_equal %w[čebela šola žaba], h.entries
  end

  def test_utf8_japanese
    File.write(@path, "こんにちは\n世界\n", encoding: "UTF-8")
    h = Tell::History.new(@path)
    assert_equal %w[こんにちは 世界], h.entries
  end

  def test_utf8_arabic
    File.write(@path, "مرحبا\nعالم\n", encoding: "UTF-8")
    h = Tell::History.new(@path)
    assert_equal %w[مرحبا عالم], h.entries
  end

  def test_corrupted_binary_replaced
    File.binwrite(@path, "good\n\xFF\xFE\nbetter\n")
    h = Tell::History.new(@path)
    assert_equal 3, h.entries.size
    assert_equal "good", h.entries.first
    assert_equal "better", h.entries.last
  end

  def test_max_entries_cap_on_load
    File.write(@path, (1..20).map(&:to_s).join("\n") + "\n")
    h = Tell::History.new(@path, max_entries: 5)
    assert_equal %w[16 17 18 19 20], h.entries
  end

  # --- Add ---

  def test_add_to_empty_history
    h = Tell::History.new(@path)
    h.add("hello")
    assert_equal %w[hello], h.entries
  end

  def test_add_dedup_moves_to_end
    File.write(@path, "a\nb\nc\n")
    h = Tell::History.new(@path)
    h.add("a")
    assert_equal %w[b c a], h.entries
  end

  def test_add_caps_at_max_entries
    h = Tell::History.new(@path, max_entries: 3)
    %w[a b c d].each { |x| h.add(x) }
    assert_equal %w[b c d], h.entries
  end

  def test_add_persists_to_file
    h = Tell::History.new(@path)
    h.add("persisted")
    assert_equal "persisted\n", File.read(@path, encoding: "UTF-8")
  end

  def test_add_multibyte_roundtrip
    h = Tell::History.new(@path)
    h.add("žába")
    h2 = Tell::History.new(@path)
    assert_equal %w[žába], h2.entries
  end

  # --- Delete ---

  def test_delete_all_occurrences
    # After dedup on load, "a" appears once; delete removes it
    File.write(@path, "a\nb\nc\n")
    h = Tell::History.new(@path)
    count = h.delete("b")
    assert_equal 1, count
    assert_equal %w[a c], h.entries
  end

  def test_delete_nonexistent_returns_zero
    File.write(@path, "a\nb\n")
    h = Tell::History.new(@path)
    assert_equal 0, h.delete("z")
  end

  def test_delete_from_empty_history
    h = Tell::History.new(@path)
    assert_equal 0, h.delete("nothing")
  end

  def test_delete_last_entry_removes_file
    File.write(@path, "only\n")
    h = Tell::History.new(@path)
    h.delete("only")
    refute File.exist?(@path)
  end

  def test_delete_persists
    File.write(@path, "a\nb\nc\n")
    h = Tell::History.new(@path)
    h.delete("b")
    h2 = Tell::History.new(@path)
    assert_equal %w[a c], h2.entries
  end

  # --- Save ---

  def test_save_permissions
    h = Tell::History.new(@path)
    h.add("secret")
    mode = File.stat(@path).mode & 0o777
    assert_equal 0o600, mode
  end

  def test_no_temp_file_remains
    h = Tell::History.new(@path)
    h.add("test")
    tmp_files = Dir.glob("#{@path}.tmp.*")
    assert_empty tmp_files
  end

  def test_save_empty_deletes_file
    File.write(@path, "a\n")
    h = Tell::History.new(@path)
    h.delete("a")
    refute File.exist?(@path)
  end

  def test_save_creates_parent_dir
    nested = File.join(@dir, "sub", "dir", "history")
    h = Tell::History.new(nested)
    h.add("deep")
    assert File.exist?(nested)
  end

  # --- Reline sync ---

  def test_load_into_reline_populates
    require "reline"
    File.write(@path, "x\ny\nz\n")
    h = Tell::History.new(@path)
    h.load_into_reline!
    assert_equal %w[x y z], Reline::HISTORY.to_a
  ensure
    Reline::HISTORY.clear
  end

  def test_add_syncs_reline
    require "reline"
    h = Tell::History.new(@path)
    h.load_into_reline!
    h.add("new")
    assert_includes Reline::HISTORY.to_a, "new"
  ensure
    Reline::HISTORY.clear
  end

  def test_add_dedup_syncs_reline
    require "reline"
    File.write(@path, "a\nb\n")
    h = Tell::History.new(@path)
    h.load_into_reline!
    h.add("a")
    reline_entries = Reline::HISTORY.to_a
    assert_equal 1, reline_entries.count("a")
    assert_equal "a", reline_entries.last
  ensure
    Reline::HISTORY.clear
  end

  def test_delete_syncs_reline
    require "reline"
    File.write(@path, "a\nb\nc\n")
    h = Tell::History.new(@path)
    h.load_into_reline!
    h.delete("b")
    refute_includes Reline::HISTORY.to_a, "b"
  ensure
    Reline::HISTORY.clear
  end

  def test_no_reline_sync_without_load
    h = Tell::History.new(@path)
    h.add("test")
    # Should not raise even though Reline not loaded into
    assert_equal %w[test], h.entries
  end

  # --- Encoding ---

  def test_file_written_in_utf8
    h = Tell::History.new(@path)
    h.add("škola")
    raw = File.binread(@path)
    assert raw.force_encoding("UTF-8").valid_encoding?
  end

  # --- Defaults ---

  def test_default_max_entries
    h = Tell::History.new(@path)
    assert_equal Tell::History::DEFAULT_MAX_ENTRIES, 1000
  end

  def test_custom_max_entries
    h = Tell::History.new(@path, max_entries: 5)
    (1..10).each { |i| h.add(i.to_s) }
    assert_equal 5, h.entries.size
    assert_equal %w[6 7 8 9 10], h.entries
  end
end
