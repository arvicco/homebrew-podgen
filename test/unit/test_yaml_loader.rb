# frozen_string_literal: true

require_relative "../test_helper"
require "yaml_loader"

class TestYamlLoader < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # --- missing file ---

  def test_load_missing_file_returns_default_hash
    assert_equal({}, YamlLoader.load(File.join(@dir, "nope.yml"), default: {}))
  end

  def test_load_missing_file_returns_default_array
    assert_equal [], YamlLoader.load(File.join(@dir, "nope.yml"), default: [])
  end

  def test_load_missing_file_returns_nil_default
    assert_nil YamlLoader.load(File.join(@dir, "nope.yml"), default: nil)
  end

  # --- valid YAML ---

  def test_load_valid_hash
    path = write_yaml({ "a" => 1, "b" => 2 })
    assert_equal({ "a" => 1, "b" => 2 }, YamlLoader.load(path, default: {}))
  end

  def test_load_valid_array
    path = write_yaml([1, 2, 3])
    assert_equal [1, 2, 3], YamlLoader.load(path, default: [])
  end

  # --- type mismatch ---

  def test_load_type_mismatch_returns_default
    path = write_yaml([1, 2])
    assert_equal({}, YamlLoader.load(path, default: {}))
  end

  def test_load_nil_default_returns_any_type
    path = write_yaml([1, 2])
    assert_equal [1, 2], YamlLoader.load(path, default: nil)
  end

  # --- nil/empty content ---

  def test_load_nil_content_returns_default
    path = File.join(@dir, "empty.yml")
    File.write(path, "---\n")
    assert_equal [], YamlLoader.load(path, default: [])
  end

  # --- syntax errors ---

  def test_load_syntax_error_returns_default
    path = File.join(@dir, "bad.yml")
    File.write(path, "- valid\n-broken\n  : garbage: [")
    assert_equal [], YamlLoader.load(path, default: [])
  end

  def test_load_syntax_error_raises_when_requested
    path = File.join(@dir, "bad.yml")
    File.write(path, "- valid\n-broken\n  : garbage: [")
    err = assert_raises(RuntimeError) do
      YamlLoader.load(path, default: {}, raise_on_error: true)
    end
    assert_includes err.message, "YAML syntax error in #{path}"
  end

  private

  def write_yaml(data)
    path = File.join(@dir, "test.yml")
    File.write(path, data.to_yaml)
    path
  end
end
