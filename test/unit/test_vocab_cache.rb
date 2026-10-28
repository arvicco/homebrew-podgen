# frozen_string_literal: true

require_relative "../test_helper"
require "vocab_cache"
require "vocabulary_annotator"

# P9-1 (Q-92): per-show enrichment cache — loop call 3.
class TestVocabCache < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("vocab_cache")
    @path = File.join(@dir, "vocab_cache.yml")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- VocabCache ---

  def test_fetch_missing_file_returns_nil_and_size_zero
    cache = VocabCache.new(@path)
    assert_nil cache.fetch("gatto")
    assert_equal 0, cache.size
    assert_equal [], cache.lemmas
  end

  def test_store_save_reload_round_trips_the_schema
    cache = VocabCache.new(@path)
    cache.store("Gatto", translations: {"English" => "cat"}, definitions: {"English" => "A feline."},
      pronunciation: "/ˈɡatto/", similar_translations: nil, first_seen: "fiabe-2026-10-01")
    cache.save

    reloaded = VocabCache.new(@path)
    entry = reloaded.fetch("gatto")
    assert_equal({"English" => "cat"}, entry["translations"])
    assert_equal({"English" => "A feline."}, entry["definitions"])
    assert_equal "/ˈɡatto/", entry["pronunciation"]
    assert_nil entry["similar_translations"]
    assert_equal "fiabe-2026-10-01", entry["first_seen"]
    assert_equal ["gatto"], reloaded.lemmas
  end

  def test_store_merges_languages_and_keeps_first_seen
    cache = VocabCache.new(@path)
    cache.store("gatto", translations: {"English" => "cat"}, definitions: {"English" => "A feline."},
      first_seen: "ep-1")
    cache.store("gatto", translations: {"Russian" => "кот"}, definitions: {"Russian" => "Животное."},
      first_seen: "ep-2")
    entry = cache.fetch("gatto")
    assert_equal({"English" => "cat", "Russian" => "кот"}, entry["translations"])
    assert_equal "ep-1", entry["first_seen"]
  end

  def test_set_overwrites_one_language
    cache = VocabCache.new(@path)
    cache.store("gatto", translations: {"English" => "cat", "Russian" => "кот"},
      definitions: {"English" => "A feline.", "Russian" => "Животное."})
    cache.set("gatto", "English", translation: "tomcat", definition: "A male cat.")
    entry = cache.fetch("gatto")
    assert_equal "tomcat", entry["translations"]["English"]
    assert_equal "A male cat.", entry["definitions"]["English"]
    assert_equal "кот", entry["translations"]["Russian"]
  end

  def test_set_on_empty_cache_creates_the_lemma
    cache = VocabCache.new(@path)
    cache.set("asino", "English", translation: "donkey")
    assert_equal({"English" => "donkey"}, cache.fetch("asino")["translations"])
    assert_equal({}, cache.fetch("asino")["definitions"])
  end

  def test_save_without_changes_writes_nothing
    VocabCache.new(@path).save
    refute File.exist?(@path)
  end

  # --- VocabularyAnnotator#annotate(cache:) ---

  def test_annotate_second_run_uses_cache_and_makes_no_enrichment_call
    calls = []
    enrich = lambda do |entries, language:, target_language:, filters:|
      calls << [target_language, entries.map { |e| e[:lemma] }]
      entries.map { |e| {lemma: e[:lemma], translation: "cat", definition: "A feline."} }
    end
    cache = VocabCache.new(@path)

    2.times do
      annotate_with(enrich, cache: cache) do |_marked, vocab|
        assert_includes vocab, "**gatto** (B1 noun) — cat. A feline."
      end
    end

    assert_equal [["English", ["gatto"]]], calls, "second run must not call enrichment"
    assert_equal "cat", VocabCache.new(@path).fetch("gatto")["translations"]["English"],
      "cache saved to disk after the first run"
  end

  def test_annotate_partial_hit_enriches_only_missing_language
    cache = VocabCache.new(@path)
    cache.store("gatto", translations: {"English" => "cat"}, definitions: {"English" => "A feline."})
    calls = []
    enrich = lambda do |entries, language:, target_language:, filters:|
      calls << [target_language, entries.map { |e| e[:lemma] }]
      entries.map { |e| {lemma: e[:lemma], translation: "кот", definition: "Животное."} }
    end

    annotate_with(enrich, cache: cache, target_languages: %w[English Russian]) do |_marked, vocab|
      assert_includes vocab, "  - cat. A feline."
      assert_includes vocab, "  - кот. Животное."
    end

    assert_equal [["Russian", ["gatto"]]], calls
    assert_equal({"English" => "cat", "Russian" => "кот"}, VocabCache.new(@path).fetch("gatto")["translations"])
  end

  def test_annotate_cache_records_first_seen_episode
    enrich = ->(entries, **) { entries.map { |e| {lemma: e[:lemma], translation: "cat", definition: "A feline."} } }
    cache = VocabCache.new(@path)
    annotate_with(enrich, cache: cache, episode: "fiabe-2026-10-28") { |*| }
    assert_equal "fiabe-2026-10-28", VocabCache.new(@path).fetch("gatto")["first_seen"]
  end

  def test_annotate_logs_hits_and_misses
    logs = []
    logger = Object.new
    logger.define_singleton_method(:log) { |m| logs << m }
    @annotator = VocabularyAnnotator.new("test-key", model: "m", logger: logger)
    cache = VocabCache.new(@path)
    cache.store("gatto", translations: {"English" => "cat"}, definitions: {"English" => "A feline."})
    enrich = ->(entries, **) { entries.map { |e| {lemma: e[:lemma], translation: "dog", definition: "A canine."} } }
    entries = [{word: "gatto", lemma: "gatto", level: "B1", pos: "noun"},
      {word: "cane", lemma: "cane", level: "B1", pos: "noun"}]

    annotate_with(enrich, cache: cache, entries: entries, text: "Il gatto e il cane.") { |*| }
    assert logs.any? { |m| m.end_with?("Enrichment cache: 1 hits, 1 misses") }, logs.inspect
  end

  def test_annotate_without_cache_is_unchanged
    calls = 0
    enrich = lambda do |entries, **|
      calls += 1
      entries.map { |e| {lemma: e[:lemma], translation: "cat", definition: "A feline."} }
    end
    2.times { annotate_with(enrich) { |_m, vocab| assert_includes vocab, "— cat. A feline." } }
    assert_equal 2, calls
  end

  private

  def annotate_with(enrich, entries: nil, text: "Il gatto dorme.", **kwargs)
    entries ||= [{word: "gatto", lemma: "gatto", level: "B1", pos: "noun"}]
    @annotator ||= VocabularyAnnotator.new("test-key", model: "m")
    # Fresh copies per run: classify returns new hashes each time in production.
    @annotator.stub(:classify_words, ->(*) { entries.map(&:dup) }) do
      @annotator.stub(:call_enrich_api, enrich) do
        Tell::Espeak.stub(:supports?, false) do
          Tell::Hunspell.stub(:supports?, false) do
            yield @annotator.annotate(text, language: "Italian", cutoff: "B1", **kwargs)
          end
        end
      end
    end
  end
end
