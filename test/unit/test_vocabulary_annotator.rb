# frozen_string_literal: true

require_relative "../test_helper"
require "vocabulary_annotator"
require "tell/espeak"

class TestVocabularyAnnotator < Minitest::Test
  def setup
    @annotator = VocabularyAnnotator.new("test-key", model: "claude-sonnet-4-6")
  end

  # --- CEFR level validation ---

  def test_rejects_invalid_cefr_level
    assert_raises(ArgumentError) do
      @annotator.annotate("some text", language: "Slovenian", cutoff: "X1")
    end
  end

  def test_accepts_lowercase_cutoff
    # Should normalize to uppercase — won't reach API since we stub nothing,
    # but validates the argument check passes
    stub_classify_empty do
      marked, vocab = @annotator.annotate("hello", language: "English", cutoff: "b1")
      assert_equal "hello", marked
      assert_equal "", vocab
    end
  end

  # --- mark_words ---

  def test_mark_words_bolds_first_occurrence
    entries = [{ word: "razglasil", lemma: "razglasiti", level: "C1", pos: "v.", translation: "to announce", definition: "To make known publicly." }]
    result = @annotator.send(:mark_words, "On je razglasil novico. Potem je razglasil še drugo.", entries)

    assert_includes result, "**razglasil**"
    # Should only bold the first occurrence
    assert_equal 1, result.scan("**razglasil**").length
  end

  def test_mark_words_case_insensitive
    entries = [{ word: "Zavod", lemma: "zavod", level: "B2", pos: "n.", translation: "institute", definition: "An organization." }]
    result = @annotator.send(:mark_words, "Zavod je odprt. Pridi v zavod.", entries)

    # Should bold the first occurrence (capital Z)
    assert_includes result, "**Zavod**"
    assert_equal 1, result.scan(/\*\*[Zz]avod\*\*/).length
  end

  def test_mark_words_does_not_double_bold
    entries = [{ word: "test", lemma: "test", level: "B1", pos: "n.", translation: "test", definition: "A test." }]
    result = @annotator.send(:mark_words, "This is a **test** already.", entries)

    # Should not create ***test*** — the already-bolded word should be left alone
    refute_includes result, "***"
  end

  # --- build_vocabulary_section ---

  def test_build_vocabulary_section_sorts_by_level_then_alpha
    entries = [
      { word: "oddaja", lemma: "oddaja", level: "B2", pos: "n.f.", translation: "broadcast", definition: "A radio or TV show." },
      { word: "razglasil", lemma: "razglasiti", level: "C1", pos: "v.", translation: "to announce", definition: "To declare publicly." },
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.m.", translation: "institute", definition: "An organization." }
    ]
    result = @annotator.send(:build_vocabulary_section, entries)

    # C1 should come before B2
    c1_pos = result.index("**C1**")
    b2_pos = result.index("**B2**")
    assert c1_pos < b2_pos, "C1 should appear before B2"

    # Within B2, oddaja should come before zavod (alphabetical)
    oddaja_pos = result.index("oddaja")
    zavod_pos = result.index("zavod")
    assert oddaja_pos < zavod_pos, "oddaja should appear before zavod"
  end

  def test_build_vocabulary_section_includes_original_when_different
    entries = [
      { word: "razglasil", lemma: "razglasiti", level: "C1", pos: "v.", translation: "to announce", definition: "To declare publicly." }
    ]
    result = @annotator.send(:build_vocabulary_section, entries)

    assert_includes result, "## Vocabulary"
    assert_includes result, "**razglasiti**"
    assert_includes result, "_Original: razglasil_"
  end

  def test_build_vocabulary_section_omits_original_when_same
    entries = [
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.m.", translation: "institute", definition: "An organization." }
    ]
    result = @annotator.send(:build_vocabulary_section, entries)

    refute_includes result, "_Original:"
  end

  # --- IPA pronunciation ---

  def test_build_vocabulary_section_includes_espeak_ipa
    entries = [
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.", translation: "institute", definition: "An org.", ipa: "/zaˈʋɔːt/" }
    ]
    result = @annotator.send(:build_vocabulary_section, entries)
    assert_includes result, "**zavod** /zaˈʋɔːt/ (n.)"
  end

  def test_build_vocabulary_section_omits_ipa_when_nil
    entries = [
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.", translation: "institute", definition: "An org." }
    ]
    result = @annotator.send(:build_vocabulary_section, entries)
    assert_includes result, "**zavod** (n.)"
    refute_includes result, "//"
  end

  def test_annotate_adds_espeak_ipa_for_supported_language
    entries = [
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.", translation: "institute", definition: "An org." }
    ]
    stub_classify(entries) do
      Tell::Espeak.stub(:supports?, true) do
        Tell::Espeak.stub(:ipa, "/zaˈʋɔːt/") do
          _marked, vocab = @annotator.annotate("zavod", language: "sl", cutoff: "B1")
          assert_includes vocab, "/zaˈʋɔːt/"
        end
      end
    end
  end

  def test_annotate_uses_llm_ipa_when_espeak_unsupported
    entries = [
      { word: "猫", lemma: "猫", level: "B2", pos: "n.", translation: "cat", definition: "A feline.", pronunciation: "/maʊ/" }
    ]
    stub_classify(entries) do
      Tell::Espeak.stub(:supports?, false) do
        _marked, vocab = @annotator.annotate("猫", language: "zh", cutoff: "B1")
        assert_includes vocab, "/maʊ/"
      end
    end
  end

  def test_annotate_espeak_failure_falls_back_gracefully
    entries = [
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.", translation: "institute", definition: "An org." }
    ]
    stub_classify(entries) do
      Tell::Espeak.stub(:supports?, true) do
        Tell::Espeak.stub(:ipa, nil) do
          _marked, vocab = @annotator.annotate("zavod", language: "sl", cutoff: "B1")
          # Should still generate vocab, just without IPA
          assert_includes vocab, "**zavod** (n.)"
          refute_includes vocab, "//"
        end
      end
    end
  end

  # --- salvage_truncated_json ---

  def test_salvage_truncated_json_recovers_complete_entries
    truncated = '[{"word":"one","lemma":"one","level":"B2","pos":"n."},{"word":"two","lemma":"tw'
    result = @annotator.send(:salvage_truncated_json, truncated)
    assert result
    parsed = JSON.parse(result, symbolize_names: true)
    assert_equal 1, parsed.length
    assert_equal "one", parsed[0][:word]
  end

  def test_salvage_truncated_json_with_code_fence
    truncated = "```json\n[{\"word\":\"a\",\"lemma\":\"a\",\"level\":\"B2\"},{\"word\":\"b\",\"lem"
    result = @annotator.send(:salvage_truncated_json, truncated)
    assert result
    parsed = JSON.parse(result, symbolize_names: true)
    assert_equal 1, parsed.length
  end

  def test_salvage_truncated_json_returns_nil_for_no_bracket
    assert_nil @annotator.send(:salvage_truncated_json, "no json here")
  end

  def test_salvage_truncated_json_returns_nil_for_no_complete_object
    assert_nil @annotator.send(:salvage_truncated_json, '[{"word":"incomplete')
  end

  # --- system_prompt IPA conditional ---

  def test_system_prompt_includes_pronunciation_when_espeak_unsupported
    Tell::Espeak.stub(:supports?, false) do
      prompt = @annotator.send(:system_prompt, "zh", "B1")
      assert_includes prompt, "pronunciation"
    end
  end

  def test_system_prompt_excludes_pronunciation_when_espeak_supported
    Tell::Espeak.stub(:supports?, true) do
      prompt = @annotator.send(:system_prompt, "sl", "B1")
      refute_includes prompt, "pronunciation"
    end
  end

  # --- valid_entry? ---

  def test_valid_entry_filters_below_cutoff
    refute @annotator.send(:valid_entry?, { word: "hi", lemma: "hi", level: "A1" }, "B1")
    refute @annotator.send(:valid_entry?, { word: "hi", lemma: "hi", level: "A2" }, "B1")
    assert @annotator.send(:valid_entry?, { word: "hi", lemma: "hi", level: "B1" }, "B1")
    assert @annotator.send(:valid_entry?, { word: "hi", lemma: "hi", level: "C2" }, "B1")
  end

  def test_valid_entry_rejects_missing_fields
    refute @annotator.send(:valid_entry?, { word: "hi", lemma: "hi" }, "B1")
    refute @annotator.send(:valid_entry?, { word: "hi", level: "B1" }, "B1")
    refute @annotator.send(:valid_entry?, {}, "B1")
  end

  def test_valid_entry_rejects_invalid_level
    refute @annotator.send(:valid_entry?, { word: "hi", lemma: "hi", level: "X1" }, "B1")
  end

  # --- annotate integration (with stubbed API) ---

  def test_annotate_returns_unchanged_when_no_words
    stub_classify_empty do
      marked, vocab = @annotator.annotate("Hello world", language: "English", cutoff: "C1")
      assert_equal "Hello world", marked
      assert_equal "", vocab
    end
  end

  def test_annotate_returns_marked_text_and_vocab_section
    entries = [
      { word: "razglasil", lemma: "razglasiti", level: "C1", pos: "v.", translation: "to announce", definition: "To declare publicly." }
    ]
    stub_classify(entries) do
      marked, vocab = @annotator.annotate("On je razglasil novico.", language: "Slovenian", cutoff: "B1")
      assert_includes marked, "**razglasil**"
      assert_includes vocab, "## Vocabulary"
      assert_includes vocab, "razglasiti"
    end
  end

  # --- known_lemmas filtering ---

  def test_annotate_excludes_known_lemmas
    entries = [
      { word: "razglasil", lemma: "razglasiti", level: "C1", pos: "v.", translation: "to announce", definition: "To declare." },
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.", translation: "institute", definition: "An org." }
    ]
    stub_classify(entries) do
      marked, vocab = @annotator.annotate("razglasil zavod", language: "sl", cutoff: "B1",
                                          known_lemmas: Set.new(["razglasiti"]))
      refute_includes vocab, "razglasiti"
      assert_includes vocab, "zavod"
      refute_includes marked, "**razglasil**"
      assert_includes marked, "**zavod**"
    end
  end

  def test_annotate_known_lemmas_case_insensitive
    entries = [
      { word: "Beseda", lemma: "Beseda", level: "B2", pos: "n.", translation: "word", definition: "A unit." }
    ]
    stub_classify(entries) do
      _marked, vocab = @annotator.annotate("Beseda", language: "sl", cutoff: "B1",
                                           known_lemmas: Set.new(["beseda"]))
      assert_equal "", vocab
    end
  end

  def test_annotate_known_lemmas_empty_set_no_effect
    entries = [
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.", translation: "institute", definition: "An org." }
    ]
    stub_classify(entries) do
      _marked, vocab = @annotator.annotate("zavod", language: "sl", cutoff: "B1",
                                           known_lemmas: Set.new)
      assert_includes vocab, "zavod"
    end
  end

  def test_annotate_known_lemmas_filters_all_returns_empty
    entries = [
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.", translation: "institute", definition: "An org." }
    ]
    stub_classify(entries) do
      marked, vocab = @annotator.annotate("zavod je tu", language: "sl", cutoff: "B1",
                                          known_lemmas: Set.new(["zavod"]))
      assert_equal "zavod je tu", marked
      assert_equal "", vocab
    end
  end

  private

  def stub_classify_empty(&block)
    stub_classify([], &block)
  end

  def stub_classify(entries)
    @annotator.stub(:classify_words, entries) do
      yield
    end
  end
end
