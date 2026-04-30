# frozen_string_literal: true

require_relative "../test_helper"
require "script_artifact"

class TestScriptArtifact < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_artifact")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_json_path_for_replaces_md_extension
    assert_equal "/x/y_script.json", ScriptArtifact.json_path_for("/x/y_script.md")
  end

  def test_json_path_for_handles_dotted_basenames
    # Only the trailing .md is stripped
    assert_equal "/x/y.foo_script.json", ScriptArtifact.json_path_for("/x/y.foo_script.md")
  end

  def test_write_then_read_roundtrips_full_structure
    path = File.join(@tmpdir, "ep_script.json")
    script = {
      title: "Episode Title",
      segments: [
        {
          name: "Opening",
          text: "Welcome.",
          sources: [{ title: "Article 1", url: "https://example.com/a" }]
        },
        { name: "Wrap-Up", text: "Thanks." }
      ],
      sources: [{ title: "Article 1", url: "https://example.com/a" }]
    }

    ScriptArtifact.write(path, script)
    result = ScriptArtifact.read(path)

    assert_equal "Episode Title", result[:title]
    assert_equal 2, result[:segments].length
    assert_equal "Opening", result[:segments][0][:name]
    assert_equal "Welcome.", result[:segments][0][:text]
    assert_equal [{ title: "Article 1", url: "https://example.com/a" }], result[:segments][0][:sources]
    refute result[:segments][1].key?(:sources), "Segment without sources should not have :sources key"
    assert_equal [{ title: "Article 1", url: "https://example.com/a" }], result[:sources]
  end

  def test_read_returns_nil_for_missing_file
    assert_nil ScriptArtifact.read(File.join(@tmpdir, "nope.json"))
  end

  def test_read_returns_nil_for_invalid_json
    path = File.join(@tmpdir, "bad.json")
    File.write(path, "not json {{{")
    assert_nil ScriptArtifact.read(path)
  end

  def test_read_returns_nil_for_json_missing_required_fields
    path = File.join(@tmpdir, "incomplete.json")
    File.write(path, JSON.generate({ "foo" => "bar" }))
    assert_nil ScriptArtifact.read(path)
  end

  def test_exist_reflects_file_existence
    path = File.join(@tmpdir, "ep_script.json")
    refute ScriptArtifact.exist?(path)
    ScriptArtifact.write(path, { title: "T", segments: [], sources: [] })
    assert ScriptArtifact.exist?(path)
  end

  def test_write_is_atomic_no_partial_files
    path = File.join(@tmpdir, "ep_script.json")
    ScriptArtifact.write(path, { title: "T", segments: [], sources: [] })
    leftover = Dir.glob(File.join(@tmpdir, "*.tmp.*"))
    assert_empty leftover, "Atomic write should leave no .tmp files"
  end

  def test_write_creates_parent_directory
    path = File.join(@tmpdir, "nested", "subdir", "ep_script.json")
    ScriptArtifact.write(path, { title: "T", segments: [], sources: [] })
    assert File.exist?(path)
  end

  def test_serialize_coerces_missing_optional_fields
    serialized = ScriptArtifact.serialize({ title: "T" })
    assert_equal "T", serialized[:title]
    assert_equal [], serialized[:segments]
    assert_equal [], serialized[:sources]
  end
end
