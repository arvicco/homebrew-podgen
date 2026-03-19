# frozen_string_literal: true

require_relative "../test_helper"
require "cli/vocab_command"

class TestVocabCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_vocab_cmd_test")
    @podcast_dir = File.join(@tmpdir, "podcasts", "testpod")
    FileUtils.mkdir_p(@podcast_dir)
    File.write(File.join(@podcast_dir, "guidelines.md"), <<~MD)
      ## Podcast
      - name: testpod
      - type: language

      ## Audio
      - language: sl

      ## Format
      Short.

      ## Tone
      Neutral.
    MD
    @original_root = ENV["PODGEN_ROOT"]
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    if @original_root
      ENV["PODGEN_ROOT"] = @original_root
    else
      ENV.delete("PODGEN_ROOT")
    end
    FileUtils.rm_rf(@tmpdir)
  end

  # --- add ---

  def test_add_word
    code = nil
    out, = capture_io { code = build_command("add", "testpod", "beseda").run }
    assert_includes out, "Added 'beseda'"
    assert_includes out, "(sl)"
    assert_equal 0, code
  end

  def test_add_duplicate
    capture_io { build_command("add", "testpod", "beseda").run }
    code = nil
    out, = capture_io { code = build_command("add", "testpod", "beseda").run }
    assert_includes out, "Already known"
    assert_equal 0, code
  end

  def test_add_missing_word_argument
    code = nil
    _out, err = capture_io { code = build_command("add", "testpod").run }
    assert_includes err, "Usage"
    assert_equal 2, code
  end

  # --- remove ---

  def test_remove_word
    capture_io { build_command("add", "testpod", "beseda").run }
    code = nil
    out, = capture_io { code = build_command("remove", "testpod", "beseda").run }
    assert_includes out, "Removed 'beseda'"
    assert_equal 0, code
  end

  def test_remove_nonexistent_word
    code = nil
    out, = capture_io { code = build_command("remove", "testpod", "beseda").run }
    assert_includes out, "Not found"
    assert_equal 0, code
  end

  def test_remove_missing_word_argument
    code = nil
    _out, err = capture_io { code = build_command("remove", "testpod").run }
    assert_includes err, "Usage"
    assert_equal 2, code
  end

  # --- list ---

  def test_list_empty
    out, = capture_io { build_command("list", "testpod").run }
    assert_includes out, "No known vocabulary"
  end

  def test_list_with_words
    capture_io { build_command("add", "testpod", "beseda").run }
    capture_io { build_command("add", "testpod", "govoriti").run }
    out, = capture_io { build_command("list", "testpod").run }
    assert_includes out, "2 words"
    assert_includes out, "beseda"
    assert_includes out, "govoriti"
  end

  # --- language override ---

  def test_add_with_lang_flag
    out, = capture_io { build_command("add", "testpod", "sprechen", "--lang", "de").run }
    assert_includes out, "(de)"

    out, = capture_io { build_command("list", "testpod", "--lang", "de").run }
    assert_includes out, "sprechen"
  end

  # --- usage ---

  def test_unknown_subcommand
    code = nil
    _out, err = capture_io { code = build_command("unknown", "testpod").run }
    assert_includes err, "Usage"
    assert_equal 2, code
  end

  private

  def build_command(*args)
    PodgenCLI::VocabCommand.new(args, {})
  end
end
