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

  # --- review (P9-6) ---

  def test_review_lists_lemmas_explained_min_times_with_count_and_last
    review_fixture

    code = nil
    out, = capture_io { code = build_command("review", "testpod").run }

    assert_equal 0, code
    assert_match(/lupo\s+3\s+testpod-2026-01-03/, out)
    refute_includes out, "mela"
  end

  def test_review_min_two_lists_both
    review_fixture

    out, = capture_io { build_command("review", "testpod", "--min", "2").run }

    assert_includes out, "lupo"
    assert_match(/mela\s+2\s+testpod-2026-01-02/, out)
  end

  def test_review_excludes_known_lemmas
    review_fixture
    capture_io { build_command("add", "testpod", "lupo").run }

    out, = capture_io { build_command("review", "testpod", "--min", "2").run }

    refute_includes out, "lupo"
    assert_includes out, "mela"
  end

  def test_review_promote_adds_listed_lemmas_to_known_vocabulary
    review_fixture

    code = nil
    out, = capture_io { code = build_command("review", "testpod", "--promote").run }

    assert_equal 0, code
    assert_includes out, "Promoted 1"
    kv = KnownVocabulary.new(File.join(@podcast_dir, "known_vocabulary.yml"))
    assert_equal ["lupo"], kv.lemmas("sl")
  end

  def test_review_missing_podcast_is_usage_error
    code = nil
    capture_io { code = build_command("review").run }
    assert_equal 2, code
  end

  # --- edit (P9-6) ---

  def test_edit_on_empty_cache_creates_lemma_with_one_language
    code = nil
    out, = capture_io do
      code = build_command("edit", "testpod", "lupo", "--lang", "English",
        "--translation", "wolf", "--definition", "A wild canine").run
    end

    assert_equal 0, code
    assert_includes out, "Cached lupo (English)"
    entry = VocabCache.new(cache_path).fetch("lupo")
    assert_equal({"English" => "wolf"}, entry["translations"])
    assert_equal({"English" => "A wild canine"}, entry["definitions"])
  end

  def test_edit_without_lang_is_usage_error
    code = nil
    _out, err = capture_io { code = build_command("edit", "testpod", "lupo", "--translation", "wolf").run }

    assert_equal 2, code
    assert_includes err, "Usage"
    refute File.exist?(cache_path)
  end

  def test_edit_rejects_language_outside_configured_targets
    code = nil
    _out, err = capture_io do
      code = build_command("edit", "testpod", "lupo", "--lang", "english", "--translation", "wolf").run
    end

    assert_equal 2, code
    assert_includes err, "English" # the allowed list
    refute File.exist?(cache_path)
  end

  def test_edit_without_translation_is_usage_error
    code = nil
    capture_io { code = build_command("edit", "testpod", "lupo", "--lang", "English").run }

    assert_equal 2, code
  end

  private

  def cache_path
    File.join(@tmpdir, "output", "testpod", "vocab_cache.yml")
  end

  # lupo explained 3x (last 01-03), mela 2x (last 01-02).
  def review_fixture
    eps = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(eps)
    {"2026-01-01" => %w[lupo mela], "2026-01-02" => %w[lupo mela], "2026-01-03" => %w[lupo]}.each do |date, lemmas|
      vocab = lemmas.map { |l| "- **#{l}** (B1 noun) — gloss" }.join("\n")
      File.write(File.join(eps, "testpod-#{date}_transcript.md"),
        "# T\n\n## Transcript\n\nText.\n\n## Vocabulary\n\n#{vocab}\n")
    end
  end

  def build_command(*args)
    PodgenCLI::VocabCommand.new(args, {})
  end
end
