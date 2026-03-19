# frozen_string_literal: true

require_relative "../test_helper"
require "known_vocabulary"

class TestKnownVocabulary < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_known_vocab_test")
    @path = File.join(@tmpdir, "known_vocabulary.yml")
    @kv = KnownVocabulary.new(@path)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- lemmas ---

  def test_lemmas_returns_empty_array_when_file_missing
    assert_equal [], @kv.lemmas("sl")
  end

  def test_lemmas_returns_empty_array_for_unknown_language
    @kv.add("sl", "beseda")
    assert_equal [], @kv.lemmas("de")
  end

  def test_lemmas_returns_stored_words
    @kv.add("sl", "beseda")
    @kv.add("sl", "govoriti")
    assert_equal %w[beseda govoriti], @kv.lemmas("sl")
  end

  # --- lemma_set ---

  def test_lemma_set_returns_empty_set_when_file_missing
    assert_equal Set.new, @kv.lemma_set("sl")
  end

  def test_lemma_set_returns_set_of_downcased_lemmas
    @kv.add("sl", "Beseda")
    assert_includes @kv.lemma_set("sl"), "beseda"
  end

  # --- add ---

  def test_add_creates_file_and_stores_lemma
    assert @kv.add("sl", "beseda")
    assert File.exist?(@path)
    assert_equal ["beseda"], @kv.lemmas("sl")
  end

  def test_add_returns_false_for_duplicate
    @kv.add("sl", "beseda")
    refute @kv.add("sl", "beseda")
  end

  def test_add_deduplicates_case_insensitive
    @kv.add("sl", "Beseda")
    refute @kv.add("sl", "beseda")
  end

  def test_add_stores_downcased
    @kv.add("sl", "Govoriti")
    assert_equal ["govoriti"], @kv.lemmas("sl")
  end

  def test_add_keeps_list_sorted
    @kv.add("sl", "zavod")
    @kv.add("sl", "beseda")
    @kv.add("sl", "govoriti")
    assert_equal %w[beseda govoriti zavod], @kv.lemmas("sl")
  end

  def test_add_multiple_languages
    @kv.add("sl", "beseda")
    @kv.add("de", "sprechen")
    assert_equal ["beseda"], @kv.lemmas("sl")
    assert_equal ["sprechen"], @kv.lemmas("de")
  end

  # --- remove ---

  def test_remove_existing_lemma
    @kv.add("sl", "beseda")
    assert @kv.remove("sl", "beseda")
    assert_equal [], @kv.lemmas("sl")
  end

  def test_remove_returns_false_for_missing
    refute @kv.remove("sl", "beseda")
  end

  def test_remove_case_insensitive
    @kv.add("sl", "beseda")
    assert @kv.remove("sl", "Beseda")
  end

  def test_remove_deletes_file_when_empty
    @kv.add("sl", "beseda")
    @kv.remove("sl", "beseda")
    refute File.exist?(@path)
  end

  def test_remove_keeps_file_with_other_languages
    @kv.add("sl", "beseda")
    @kv.add("de", "sprechen")
    @kv.remove("sl", "beseda")
    assert File.exist?(@path)
    assert_equal ["sprechen"], @kv.lemmas("de")
  end

  # --- for_config ---

  def test_for_config_builds_path_from_podcast_dir
    config = Struct.new(:podcast_dir).new(@tmpdir)
    kv = KnownVocabulary.for_config(config)
    kv.add("sl", "test")
    assert File.exist?(File.join(@tmpdir, "known_vocabulary.yml"))
  end
end
