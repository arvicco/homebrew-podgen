# frozen_string_literal: true

require_relative "../test_helper"
require "vocab_ledger"
require "vocabulary_annotator"

# P9-2 (Q-89): explained-lemma ledger with spaced re-exposure — loop calls 1–2.
class TestVocabLedger < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("vocab_ledger")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- VocabLedger.build ---

  def test_build_counts_episodes_and_explained_lemmas_in_basename_order
    write_episode("fiabe-2026-10-02", vocab: %w[avvicinarsi], body: "Il lupo si avvicina al bosco.")
    write_episode("fiabe-2026-10-01", vocab: %w[avvicinarsi accorgersi], body: "La volpe si accorse del lupo.")
    write_episode("fiabe-2026-10-03", vocab: [], body: "Nessun vocabolario oggi.")

    ledger = VocabLedger.build(@dir)
    assert_equal 3, ledger.episodes
    assert_equal %w[fiabe-2026-10-01 fiabe-2026-10-02], ledger.explained("Avvicinarsi")
    assert_equal 2, ledger.exposures("avvicinarsi")
    assert_equal 1, ledger.exposures("accorgersi")
    assert_equal 0, ledger.exposures("lupo")
    assert_equal [], ledger.explained("lupo")
  end

  def test_build_multi_language_sections_count_each_lemma_once_per_episode
    File.write(File.join(@dir, "fiabe-2026-10-01_transcript.md"), <<~MD)
      # Title

      ## Transcript

      Il **gatto** dorme.

      ## Vocabulary (English, Russian)

      - **gatto** (A2 noun) *gatti*
        - cat. A feline.
        - кот. Животное.
    MD
    ledger = VocabLedger.build(@dir)
    assert_equal ["fiabe-2026-10-01"], ledger.explained("gatto")
  end

  def test_build_before_is_an_exclusive_basename_cutoff
    write_episode("fiabe-2026-10-01", vocab: %w[avvicinarsi])
    write_episode("fiabe-2026-10-02", vocab: %w[avvicinarsi])
    write_episode("fiabe-2026-10-03", vocab: %w[avvicinarsi])

    ledger = VocabLedger.build(@dir, before: "fiabe-2026-10-02")
    assert_equal 1, ledger.episodes
    assert_equal ["fiabe-2026-10-01"], ledger.explained("avvicinarsi")
  end

  def test_for_config_reads_the_episodes_dir_with_cutoff
    write_series(3, {0 => %w[x], 2 => %w[x]})
    config = Struct.new(:episodes_dir).new(@dir)
    assert_equal 3, VocabLedger.for_config(config).episodes
    ledger = VocabLedger.for_config(config, before: "ep-002")
    assert_equal 2, ledger.episodes
    assert_equal ["ep-000"], ledger.explained("x")
  end

  def test_build_missing_dir_is_empty
    ledger = VocabLedger.build(File.join(@dir, "nope"))
    assert_equal 0, ledger.episodes
    assert ledger.allowed?("anything")
    assert_equal 0, ledger.df("anything")
  end

  def test_df_counts_episodes_whose_body_contains_the_token
    write_episode("ep-01", body: "Il **Gatto** dorme. Il gatto mangia.")
    write_episode("ep-02", body: "Un gatto nero.")
    write_episode("ep-03", body: "Un cane.")

    ledger = VocabLedger.build(@dir)
    assert_equal 2, ledger.df("gatto")
    assert_equal 2, ledger.df("Gatto")
    assert_equal 0, ledger.df("il"), "tokens shorter than 4 letters are not indexed"
  end

  def test_tokens_are_letters_only_downcased_four_or_more
    assert_equal %w[gatto città perché], VocabLedger.tokens("Il **Gatto**, la città: perché? 1234 un")
  end

  def test_top_explained_lists_lemmas_at_or_above_min
    3.times { |i| write_episode("ep-0#{i}", vocab: %w[avvicinarsi esclamare]) }
    write_episode("ep-03", vocab: %w[avvicinarsi])
    write_episode("ep-04", vocab: %w[lupo])

    ledger = VocabLedger.build(@dir)
    assert_equal [{lemma: "avvicinarsi", count: 4, last: "ep-03"}, {lemma: "esclamare", count: 3, last: "ep-02"}],
      ledger.top_explained(min: 3)
  end

  # --- spaced re-exposure (REEXPOSURE_GAPS = [8, 20, 50]) ---

  def test_allowed_never_explained
    write_series(5, {})
    assert VocabLedger.build(@dir).allowed?("avvicinarsi")
  end

  def test_allowed_second_exposure_needs_eight_episodes
    write_series(8, {0 => %w[avvicinarsi]})
    assert VocabLedger.build(@dir).allowed?("avvicinarsi"), "explained 8 episodes before the next → allowed"

    FileUtils.rm_f(Dir.glob(File.join(@dir, "*")))
    write_series(7, {0 => %w[avvicinarsi]})
    refute VocabLedger.build(@dir).allowed?("avvicinarsi"), "explained 7 episodes before → not yet"
  end

  def test_allowed_third_exposure_needs_twenty_after_the_second
    write_series(30, {0 => %w[x], 10 => %w[x]})
    assert VocabLedger.build(@dir).allowed?("x"), "20 episodes after the 2nd"

    FileUtils.rm_f(Dir.glob(File.join(@dir, "*")))
    write_series(29, {0 => %w[x], 10 => %w[x]})
    refute VocabLedger.build(@dir).allowed?("x"), "19 episodes after the 2nd"
  end

  def test_allowed_fourth_exposure_needs_fifty_after_the_third
    write_series(80, {0 => %w[x], 10 => %w[x], 30 => %w[x]})
    assert VocabLedger.build(@dir).allowed?("x")

    FileUtils.rm_f(Dir.glob(File.join(@dir, "*")))
    write_series(79, {0 => %w[x], 10 => %w[x], 30 => %w[x]})
    refute VocabLedger.build(@dir).allowed?("x")
  end

  def test_allowed_never_after_four_exposures
    write_series(300, {0 => %w[x], 10 => %w[x], 30 => %w[x], 80 => %w[x]})
    refute VocabLedger.build(@dir).allowed?("x")
  end

  # --- VocabularyAnnotator#annotate(ledger:) ---

  def test_annotate_drops_lemma_explained_in_the_two_previous_episodes
    write_series(10, {8 => %w[avvicinarsi], 9 => %w[avvicinarsi]})
    vocab = annotate_with(VocabLedger.build(@dir))
    refute_includes vocab, "avvicinarsi"
    assert_includes vocab, "**bosco**"
  end

  def test_annotate_keeps_lemma_explained_once_twenty_episodes_ago
    write_series(21, {0 => %w[avvicinarsi]})
    vocab = annotate_with(VocabLedger.build(@dir))
    assert_includes vocab, "**avvicinarsi**"
  end

  def test_annotate_drops_lemma_explained_four_times
    write_series(300, {0 => %w[avvicinarsi], 10 => %w[avvicinarsi], 30 => %w[avvicinarsi], 80 => %w[avvicinarsi]})
    vocab = annotate_with(VocabLedger.build(@dir))
    refute_includes vocab, "avvicinarsi"
  end

  def test_annotate_include_words_bypass_the_ledger
    write_series(10, {8 => %w[avvicinarsi], 9 => %w[avvicinarsi]})
    vocab = annotate_with(VocabLedger.build(@dir), include_words: Set.new(["avvicinarsi"]))
    assert_includes vocab, "**avvicinarsi**"
  end

  def test_annotate_logs_dropped_and_reexposed_lemmas
    write_series(21, {0 => %w[avvicinarsi], 20 => %w[bosco]})
    logs = []
    logger = Object.new
    logger.define_singleton_method(:log) { |m| logs << m }
    annotate_with(VocabLedger.build(@dir), annotator: VocabularyAnnotator.new("k", model: "m", logger: logger))
    assert logs.any? { |m| m.include?("Ledger: dropped 1 already-explained lemma") }, logs.inspect
    assert logs.any? { |m| m.include?("re-exposing") && m.include?("avvicinarsi") }, logs.inspect
  end

  # --- re-exposure share cap (measurement follow-up to loop call 2) ---

  RE_LEMMAS = %w[rea reb rec red ree ref reg reh rei rej].freeze
  # Explained in REVERSE alphabetical order (rej at episode 0 … rea at 9), so
  # oldest-first and the lemma tie-break pick different pairs.
  RE_BY_AGE = RE_LEMMAS.reverse.freeze
  NEW_LEMMAS = %w[nea neb nec ned nee nef neg neh nei nej].freeze

  def test_episodes_since_counts_from_the_last_explanation
    ledger = share_ledger
    assert_equal 30, ledger.episodes_since("rej")
    assert_equal 21, ledger.episodes_since("rea")
    assert_nil ledger.episodes_since("nea")
  end

  def test_annotate_caps_reexposures_at_a_quarter_of_max_keeping_the_oldest
    logs = []
    enriched = []
    vocab = annotate_share(max: 8, logs: logs, enriched: enriched)
    assert_equal %w[rei rej], lemmas_in(vocab) & RE_LEMMAS, "the two explained longest ago"
    assert_equal 6, (lemmas_in(vocab) & NEW_LEMMAS).length
    assert logs.any? { |m| m.end_with?("Ledger: re-exposure cap 2 of 10 (max × 0.25)") }, logs.inspect
    assert logs.any? { |m| m.end_with?("Ledger: re-exposing rej, rei") }, logs.inspect
    assert_equal %w[rei rej], enriched.uniq.sort & RE_LEMMAS, "capped-out re-exposures are never enriched"
  end

  def test_annotate_reexposure_cap_ties_on_age_go_to_the_more_frequent
    ledger = VocabLedger.new
    20.times { |i| ledger.add(format("ep-%03d", i), lemmas: (i == 0) ? %w[taa tab tac] : [], body: "Testo.") }
    vocab = annotate_entries("taa tab tab tab tac tac", %w[taa tab tac], ledger, max: 4)
    assert_equal %w[tab], lemmas_in(vocab)
  end

  def test_annotate_key_reexposure_does_not_consume_the_share
    vocab = annotate_share(max: 8, key: true)
    assert_includes lemmas_in(vocab), "asino"
    assert_equal %w[rei rej], lemmas_in(vocab) & RE_LEMMAS
  end

  def test_annotate_without_max_does_not_cap_reexposures
    vocab = annotate_share(max: nil)
    assert_equal RE_LEMMAS, lemmas_in(vocab) & RE_LEMMAS
    assert_equal NEW_LEMMAS, lemmas_in(vocab) & NEW_LEMMAS
  end

  private

  # 30 episodes; RE_BY_AGE[i] explained once at episode i (all past the
  # 8-episode gap); "asino" explained once at episode 10.
  def share_ledger
    ledger = VocabLedger.new
    30.times do |i|
      lemmas = (i < 10) ? [RE_BY_AGE[i]] : []
      lemmas << "asino" if i == 10
      ledger.add(format("ep-%03d", i), lemmas: lemmas, body: "Testo.")
    end
    ledger
  end

  # Re-exposable lemmas occur 3× (they would win the band cap), new ones
  # once; 3-letter names stay out of the key-term pass. key: adds "asino"
  # ×3 — a key term that is also a re-exposure.
  def annotate_share(max:, key: false, logs: [], enriched: [])
    lemmas = RE_LEMMAS + NEW_LEMMAS + (key ? ["asino"] : [])
    text = (RE_LEMMAS.map { |l| "#{l} #{l} #{l}" } + NEW_LEMMAS + (key ? ["asino asino asino"] : [])).join(" ")
    annotate_entries(text, lemmas, share_ledger, max: max, logs: logs, enriched: enriched)
  end

  # enriched collects every lemma handed to the enrichment call.
  def annotate_entries(text, lemmas, ledger, max:, logs: [], enriched: [])
    entries = lemmas.map { |l| {word: l, lemma: l, level: "B1", pos: "noun"} }
    logger = Object.new
    logger.define_singleton_method(:log) { |m| logs << m }
    annotator = VocabularyAnnotator.new("k", model: "m", logger: logger)
    enrich = lambda do |list, **|
      enriched.concat(list.map { |e| e[:lemma] })
      list.map { |e| {lemma: e[:lemma], translation: "t", definition: "d"} }
    end
    annotator.stub(:classify_words, ->(*) { entries.map(&:dup) }) do
      annotator.stub(:call_enrich_api, enrich) do
        Tell::Espeak.stub(:supports?, false) do
          Tell::Hunspell.stub(:supports?, false) do
            annotator.annotate(text, language: "Italian", cutoff: "B1", max: max, ledger: ledger).last
          end
        end
      end
    end
  end

  def lemmas_in(vocab)
    vocab.scan(/^- \*\*(\w+)\*\*/).flatten.sort
  end

  # Writes `count` chronological episodes ep-000 … with the given vocab per index.
  def write_series(count, vocab_by_index)
    count.times do |i|
      write_episode(format("ep-%03d", i), vocab: vocab_by_index.fetch(i, []))
    end
  end

  def write_episode(basename, vocab: [], body: "Testo.")
    lines = vocab.map { |l| "- **#{l}** (B1 verb) — gloss. Definition." }
    File.write(File.join(@dir, "#{basename}_transcript.md"), <<~MD)
      # #{basename}

      ## Transcript

      #{body}

      ## Vocabulary

      #{lines.join("\n")}
    MD
  end

  def annotate_with(ledger, annotator: VocabularyAnnotator.new("k", model: "m"), **kwargs)
    entries = [{word: "avvicina", lemma: "avvicinarsi", level: "B1", pos: "verb"},
      {word: "bosco", lemma: "bosco", level: "B1", pos: "noun"}]
    enrich = ->(list, **) { list.map { |e| {lemma: e[:lemma], translation: "t", definition: "d"} } }
    annotator.stub(:classify_words, ->(*) { entries.map(&:dup) }) do
      annotator.stub(:call_enrich_api, enrich) do
        Tell::Espeak.stub(:supports?, false) do
          Tell::Hunspell.stub(:supports?, false) do
            annotator.annotate("Il lupo si avvicina al bosco.", language: "Italian", cutoff: "B1",
              ledger: ledger, **kwargs).last
          end
        end
      end
    end
  end
end
