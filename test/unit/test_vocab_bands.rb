# frozen_string_literal: true

require_relative "../test_helper"
require "vocab_ledger"
require "vocabulary_annotator"

# P9-4 (Q-91): level-band selection — loop call 5.
class TestVocabBands < Minitest::Test
  def setup
    @annotator = VocabularyAnnotator.new("k", model: "m")
  end

  def test_balanced_fills_quotas_by_band
    picked = select(pool(60, 30, 10), 40, "balanced")
    assert_equal({"B1" => 20, "B2" => 14, "C1" => 6}, levels(picked))
  end

  def test_hardest_spills_an_exhausted_band_down
    # quotas 10/16/14; C1 holds only 10 → its 4 unfilled slots go one band down (B2)
    picked = select(pool(60, 30, 10), 40, "hardest")
    assert_equal({"B1" => 10, "B2" => 20, "C1" => 10}, levels(picked))
  end

  def test_unfilled_quota_spills_up_when_nothing_below
    # balanced quotas 20/14/6, B1 holds only 5 → 15 spill up to B2 (then C1)
    picked = select(pool(5, 30, 10), 40, "balanced")
    assert_equal({"B1" => 5, "B2" => 29, "C1" => 6}, levels(picked))
  end

  def test_levels_two_or_more_above_share_the_top_band
    entries = pool(10, 0, 0) + [entry("c2", "C2", 1)] + [entry("c1", "C1", 1)]
    picked = select(entries, 10, "balanced")
    # quotas 5/4/1 (largest remainder); band 1 is empty and spills down to band 0
    assert_equal 1, picked.count { |e| %w[C1 C2].include?(e[:level]) }
    assert_equal 10, picked.length
  end

  def test_small_max_rounds_by_largest_remainder
    entries = [entry("a", "B1", 1), entry("b", "B2", 1), entry("c", "C1", 1)]
    assert_equal ["a"], select(entries, 1, "balanced").map { |e| e[:lemma] }
    assert_equal ["b"], select(entries, 1, "hardest").map { |e| e[:lemma] }
  end

  def test_within_band_order_is_tf_without_ledger
    entries = [entry("rare", "B1", 1), entry("often", "B1", 9), entry("mid", "B1", 4)]
    assert_equal %w[often mid], select(entries, 2, "balanced").map { |e| e[:lemma] }
  end

  def test_within_band_order_is_tf_times_idf_with_ledger
    ledger = VocabLedger.new
    10.times { |i| ledger.add("ep-#{i}", lemmas: [], body: "often") } # df(often) = 10 → idf 0
    entries = [entry("rare", "B1", 1), entry("often", "B1", 9)]
    assert_equal %w[rare], select(entries, 1, "balanced", ledger).map { |e| e[:lemma] }
  end

  def test_frequent_orders_by_raw_tf_even_with_ledger
    ledger = VocabLedger.new
    10.times { |i| ledger.add("ep-#{i}", lemmas: [], body: "often") }
    entries = [entry("rare", "B1", 1), entry("often", "B1", 9)]
    assert_equal %w[often], select(entries, 1, "frequent", ledger).map { |e| e[:lemma] }
  end

  def test_unknown_priority_falls_back_to_balanced
    picked = select(pool(60, 30, 10), 40, "whatever")
    assert_equal({"B1" => 20, "B2" => 14, "C1" => 6}, levels(picked))
  end

  def test_annotate_caps_with_bands
    entries = pool(60, 30, 10).map { |e| e.merge(word: e[:lemma]) }
    text = entries.map { |e| e[:lemma] }.join(" ")
    enrich = ->(list, **) { list.map { |e| {lemma: e[:lemma], translation: "t", definition: "d"} } }
    @annotator.stub(:classify_words, ->(*) { entries.map(&:dup) }) do
      @annotator.stub(:call_enrich_api, enrich) do
        Tell::Espeak.stub(:supports?, false) do
          Tell::Hunspell.stub(:supports?, false) do
            vocab = @annotator.annotate(text, language: "Italian", cutoff: "B1", max: 40).last
            counts = vocab.scan(/\((B1|B2|C1) noun\)/).flatten.tally
            assert_equal({"B1" => 20, "B2" => 14, "C1" => 6}, counts)
          end
        end
      end
    end
  end

  private

  def select(entries, max, priority, ledger = nil)
    @annotator.send(:select_by_bands, entries, max, priority, "B1", ledger)
  end

  def entry(lemma, level, frequency)
    {word: lemma, words: [lemma], lemma: lemma, level: level, pos: "noun", frequency: frequency}
  end

  def pool(b1, b2, c1)
    {"B1" => b1, "B2" => b2, "C1" => c1}.flat_map do |level, n|
      n.times.map { |i| entry("w#{level.downcase}x#{("a".."z").to_a[i % 26]}#{("a".."z").to_a[i / 26]}", level, 1) }
    end
  end

  def levels(entries)
    entries.map { |e| e[:level] }.tally
  end
end
