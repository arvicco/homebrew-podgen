# frozen_string_literal: true

require_relative "../test_helper"
require "atomic_writer"

class TestAtomicWriter < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_atomic_writer_test")
    @path = File.join(@tmpdir, "test.yml")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- Basic write ---

  def test_write_creates_file
    AtomicWriter.write(@path, "hello")
    assert File.exist?(@path)
    assert_equal "hello", File.read(@path)
  end

  def test_write_overwrites_existing
    File.write(@path, "old")
    AtomicWriter.write(@path, "new")
    assert_equal "new", File.read(@path)
  end

  def test_write_creates_parent_directories
    nested = File.join(@tmpdir, "a", "b", "c", "file.yml")
    AtomicWriter.write(nested, "deep")
    assert_equal "deep", File.read(nested)
  end

  def test_write_no_temp_file_left_on_success
    AtomicWriter.write(@path, "data")
    tmp_files = Dir.glob(File.join(@tmpdir, "*.tmp.*"))
    assert_empty tmp_files, "No temp files should remain after success"
  end

  # --- Error handling ---

  def test_write_successive_writes_produce_correct_content
    AtomicWriter.write(@path, "first")
    AtomicWriter.write(@path, "second")
    assert_equal "second", File.read(@path)
  end

  # --- Data serialization ---

  def test_write_yaml_helper
    data = [{ "url" => "https://example.com", "added" => "2026-03-18" }]
    AtomicWriter.write_yaml(@path, data)
    loaded = YAML.load_file(@path)
    assert_equal data, loaded
  end

  def test_write_yaml_empty_array
    AtomicWriter.write_yaml(@path, [])
    loaded = YAML.load_file(@path)
    assert_equal [], loaded
  end

  def test_write_yaml_hash
    data = { "key" => "value", "count" => 42 }
    AtomicWriter.write_yaml(@path, data)
    loaded = YAML.load_file(@path)
    assert_equal data, loaded
  end

  # --- Permissions ---

  def test_write_with_permissions
    AtomicWriter.write(@path, "secret", perm: 0o600)
    assert_equal "secret", File.read(@path)
    mode = File.stat(@path).mode & 0o777
    assert_equal 0o600, mode, "File should have 0600 permissions"
  end

  def test_write_default_permissions
    AtomicWriter.write(@path, "normal")
    mode = File.stat(@path).mode & 0o777
    assert_equal 0o644, mode, "Default permissions should be 0644"
  end

  # --- Encoding ---

  def test_write_preserves_utf8
    text = "Prekopiščevali šček žaba"
    AtomicWriter.write(@path, text)
    content = File.read(@path, encoding: "UTF-8")
    assert_equal text, content
    assert_equal Encoding::UTF_8, content.encoding
  end

  # --- Atomicity ---

  def test_write_sequential_writes_last_wins
    AtomicWriter.write(@path, "initial")
    AtomicWriter.write(@path, "writer_a")
    AtomicWriter.write(@path, "writer_b")

    assert_equal "writer_b", File.read(@path)
  end

  # --- delete_if_exists ---

  def test_delete_if_exists_removes_file
    File.write(@path, "data")
    assert File.exist?(@path)

    AtomicWriter.delete_if_exists(@path)
    refute File.exist?(@path)
  end

  def test_delete_if_exists_noop_when_no_file
    refute File.exist?(@path)
    AtomicWriter.delete_if_exists(@path) # should not raise
    refute File.exist?(@path)
  end
end
