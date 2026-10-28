# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "key_terms"
require "vocab_ledger"
require "vocabulary_annotator"

# P9-3 (Q-90): story-critical words — loop call 4.
class TestKeyTerms < Minitest::Test
  STORY = (["Ieri Teresa vide l'asino nel campo. Poi l'asino guardò Teresa."] * 8 +
    ["L'asino corre. Un asino dorme."]).join(" ").freeze

  # --- KeyTerms.candidates ---

  def test_candidates_rank_by_tf_without_ledger_and_skip_proper_nouns
    candidates = KeyTerms.candidates(STORY)
    assert_equal "asino", candidates.first
    refute_includes candidates, "teresa"
    # "Ieri" only ever opens a sentence: never seen mid-sentence → treated as a name
    assert_equal %w[asino campo guardò vide], candidates
  end

  def test_candidates_need_tf_of_three_and_four_letters
    assert_equal ["cane"], KeyTerms.candidates("gatto gatto cane cane cane uno uno uno uno")
  end

  def test_candidates_word_capitalised_only_at_sentence_starts_is_not_a_proper_noun
    text = "Lupo era lì. il lupo corre. «Lupo!» gridò. Disse: «Lupo, vieni.» e il lupo venne."
    assert_includes KeyTerms.candidates(text), "lupo"
  end

  def test_candidates_drop_tokens_above_fifteen_percent_document_frequency
    ledger = VocabLedger.new
    10.times { |i| ledger.add("ep-#{i}", lemmas: [], body: (i < 2) ? "campo" : "altro") }
    # campo: df 2 of 10 > 1.5 → dropped; asino: df 0 → kept
    candidates = KeyTerms.candidates(STORY, ledger: ledger)
    refute_includes candidates, "campo"
    assert_includes candidates, "asino"
  end

  def test_candidates_score_is_tf_times_idf
    ledger = VocabLedger.new
    20.times { |i| ledger.add("ep-#{i}", lemmas: [], body: (i < 3) ? "asino" : "altro") }
    # asino: 18 × ln(21/4) ≈ 29.8; ieri (df 0): 8 × ln(21) ≈ 24.4; both kept, asino first
    candidates = KeyTerms.candidates(STORY, ledger: ledger)
    assert_equal "asino", candidates.first
    ledger.add("ep-20", lemmas: [], body: "asino")
    # 4/21 > 15 % → asino gone
    refute_includes KeyTerms.candidates(STORY, ledger: ledger), "asino"
  end

  def test_candidates_capped_at_key_terms
    text = %w[alfa beta gamma delta epsilon zeta theta iota kappa lambda].map { |w| "#{w} #{w} #{w}" }.join(" ")
    assert_equal KeyTerms::KEY_TERMS, KeyTerms.candidates(text).length
  end

  # --- VocabularyAnnotator integration ---

  def test_annotate_key_term_below_cutoff_is_kept_and_flagged
    prompts = []
    captured = annotate_story(prompts: prompts, classified: [
      {word: "asino", lemma: "asino", level: "A1", pos: "noun"},
      {word: "campo", lemma: "campo", level: "A1", pos: "noun"},
      {word: "dorme", lemma: "dormire", level: "B1", pos: "verb"}
    ])

    vocab = captured[:vocab]
    assert_includes vocab, "**asino** (A1 noun)"
    assert_includes vocab, "**campo** (A1 noun)"
    assert captured[:entries].find { |e| e[:lemma] == "asino" }[:key]
    refute captured[:entries].find { |e| e[:lemma] == "dormire" }[:key]

    classify_prompt = prompts.find { |p| p.include?("identify all unique words") }
    assert_match(/regardless of their CEFR level.*asino/m, classify_prompt)
    refute_match(/teresa/i, classify_prompt)
  end

  def test_annotate_non_key_entry_below_cutoff_is_still_rejected
    captured = annotate_story(classified: [{word: "dorme", lemma: "dormire", level: "A1", pos: "verb"}])
    assert_equal "", captured[:vocab]
  end

  def test_annotate_key_entry_bypasses_ledger_and_cap
    dir = Dir.mktmpdir
    3.times do |i|
      File.write(File.join(dir, "ep-#{i}_transcript.md"),
        "# t\n\n## Transcript\n\nTesto.\n\n## Vocabulary\n\n- **asino** (A1 noun) — donkey. An animal.\n")
    end
    captured = annotate_story(ledger: VocabLedger.build(dir), max: 1, classified: [
      {word: "asino", lemma: "asino", level: "A1", pos: "noun"},
      {word: "dorme", lemma: "dormire", level: "B1", pos: "verb"},
      {word: "corre", lemma: "correre", level: "B1", pos: "verb"}
    ])
    assert_includes captured[:vocab], "**asino**", "key bypasses the ledger"
    # Like include_words, a key entry takes a slot but is never cut: the A1 key
    # wins the single slot over the B1 entries at the cutoff.
    assert_equal 1, captured[:vocab].scan("- **").length
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_annotate_known_words_beat_key_entries
    captured = annotate_story(known_lemmas: Set.new(["asino"]),
      classified: [{word: "asino", lemma: "asino", level: "A1", pos: "noun"}])
    assert_equal "", captured[:vocab]
  end

  private

  def annotate_story(classified:, prompts: [], **kwargs)
    annotator = VocabularyAnnotator.new("k", model: "m")
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) do |**kw|
      prompts << kw[:system]
      payload = if kw[:system].include?("identify all unique words")
        classified
      else
        kw[:messages].first[:content].split("\n").map { |l| {lemma: l, translation: "t-#{l}", definition: "d."} }
      end
      text = Struct.new(:type, :text).new("text", JSON.generate(payload))
      usage = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens).new(1, 1, 0, 0)
      Struct.new(:content, :stop_reason, :model, :usage).new([text], "end_turn", "m", usage)
    end
    captured = {}
    build = annotator.method(:build_vocabulary_section)
    capture = lambda do |entries, *rest|
      captured[:entries] = entries
      build.call(entries, *rest)
    end
    annotator.instance_variable_get(:@client).stub(:messages, fake_messages) do
      annotator.stub(:build_vocabulary_section, capture) do
        Tell::Espeak.stub(:supports?, false) do
          Tell::Hunspell.stub(:supports?, false) do
            captured[:vocab] = annotator.annotate(STORY, language: "Italian", cutoff: "B1", **kwargs).last
          end
        end
      end
    end
    captured
  end
end
