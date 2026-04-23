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

  def test_mark_words_bolds_all_occurrences
    entries = [{ word: "razglasil", lemma: "razglasiti", level: "C1", pos: "v.", words: ["razglasil"] }]
    result = @annotator.send(:mark_words, "On je razglasil novico. Potem je razglasil še drugo.", entries)

    assert_includes result, "**razglasil**"
    assert_equal 2, result.scan("**razglasil**").length
  end

  def test_mark_words_bolds_all_known_forms
    entries = [{ word: "balo", lemma: "bala", level: "B2", pos: "noun", words: ["balo"] }]
    result = @annotator.send(:mark_words, "To je bala za carsko nevesto. Vzeli so balo.", entries)

    assert_includes result, "**bala**"
    assert_includes result, "**balo**"
  end

  def test_mark_words_bolds_merged_forms
    entries = [{ word: "skomignil", lemma: "skomigniti", level: "C1", pos: "verb",
                 words: ["skomignil", "skomignila"] }]
    result = @annotator.send(:mark_words, "On je skomignil. Ona je skomignila.", entries)

    assert_includes result, "**skomignil**"
    assert_includes result, "**skomignila**"
  end

  def test_mark_words_case_insensitive
    entries = [{ word: "Zavod", lemma: "zavod", level: "B2", pos: "n.", words: ["Zavod"] }]
    result = @annotator.send(:mark_words, "Zavod je odprt. Pridi v zavod.", entries)

    assert_includes result, "**Zavod**"
    assert_includes result, "**zavod**"
    assert_equal 2, result.scan(/\*\*[Zz]avod\*\*/).length
  end

  # --- dedup_by_lemma ---

  def test_dedup_by_lemma_merges_same_lemma
    entries = [
      { word: "skomignil", lemma: "skomigniti", level: "C1", pos: "verb", translation: "shrugged", definition: "To raise shoulders." },
      { word: "skomignila", lemma: "skomigniti", level: "C1", pos: "verb", translation: "shrugged", definition: "To raise shoulders." }
    ]
    result = @annotator.send(:dedup_by_lemma, entries)

    assert_equal 1, result.length
    assert_equal "skomigniti", result[0][:lemma]
    assert_includes result[0][:words], "skomignil"
    assert_includes result[0][:words], "skomignila"
  end

  def test_dedup_by_lemma_keeps_distinct_lemmas
    entries = [
      { word: "skomignil", lemma: "skomigniti", level: "C1", pos: "verb", translation: "shrugged", definition: "A." },
      { word: "balo", lemma: "bala", level: "B2", pos: "noun", translation: "dowry", definition: "B." }
    ]
    result = @annotator.send(:dedup_by_lemma, entries)

    assert_equal 2, result.length
  end

  def test_build_vocabulary_section_lists_multiple_forms
    entries = [
      { word: "skomignil", lemma: "skomigniti", level: "C1", pos: "verb",
        words: ["skomignil", "skomignila"],
        translation: "shrugged", definition: "To raise shoulders." }
    ]
    result = @annotator.send(:build_vocabulary_section, entries)

    assert_includes result, "*skomignil, skomignila*"
    # Only one entry, not two
    assert_equal 1, result.scan("**skomigniti**").length
  end

  def test_mark_words_does_not_double_bold
    entries = [{ word: "test", lemma: "test", level: "B1", pos: "n.", words: ["test"] }]
    result = @annotator.send(:mark_words, "This is a **test** already.", entries)

    # Should not create ***test*** — the already-bolded word should be left alone
    refute_includes result, "***"
  end

  # --- build_vocabulary_section ---

  def test_build_vocabulary_section_alphabetical
    entries = [
      { word: "oddaja", lemma: "oddaja", level: "B2", pos: "n.f.", translation: "broadcast", definition: "A radio or TV show." },
      { word: "razglasil", lemma: "razglasiti", level: "C1", pos: "v.", translation: "to announce", definition: "To declare publicly." },
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.m.", translation: "institute", definition: "An organization." }
    ]
    result = @annotator.send(:build_vocabulary_section, entries)

    # Flat alphabetical list, no level headers
    refute_includes result, "**C1**\n"
    refute_includes result, "**B2**\n"

    oddaja_pos = result.index("oddaja")
    razglasiti_pos = result.index("razglasiti")
    zavod_pos = result.index("zavod")
    assert oddaja_pos < razglasiti_pos, "oddaja before razglasiti"
    assert razglasiti_pos < zavod_pos, "razglasiti before zavod"
  end

  def test_build_vocabulary_section_level_in_pos
    entries = [
      { word: "razglasil", lemma: "razglasiti", level: "C1", pos: "v.", translation: "to announce", definition: "To declare publicly." }
    ]
    result = @annotator.send(:build_vocabulary_section, entries)

    assert_includes result, "(C1 v.)"
  end

  def test_build_vocabulary_section_includes_original_when_different
    entries = [
      { word: "razglasil", lemma: "razglasiti", level: "C1", pos: "v.", translation: "to announce", definition: "To declare publicly." }
    ]
    result = @annotator.send(:build_vocabulary_section, entries)

    assert_includes result, "**razglasiti**"
    assert_includes result, "*razglasil*"
    refute_includes result, "_Original:"
  end

  def test_build_vocabulary_section_omits_original_when_same
    entries = [
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.m.", translation: "institute", definition: "An organization." }
    ]
    result = @annotator.send(:build_vocabulary_section, entries)

    # No standalone *original* marker (word == lemma)
    refute_match(/\)\s+\*zavod\*/, result)
  end

  # --- filter_cognates ---

  def test_filter_cognates_removes_english_cognate
    entries = [
      { lemma: "profesor", translation: "professor", level: "B1", pos: "noun" },
      { lemma: "prepričati", translation: "to convince", level: "C1", pos: "verb" }
    ]
    result = @annotator.send(:filter_cognates, entries, ["English"])
    assert_equal 1, result.length
    assert_equal "prepričati", result[0][:lemma]
  end

  def test_filter_cognates_removes_russian_cognate_via_translation
    entries = [
      { lemma: "študentka", similar_translations: { "Russian" => "студентка" }, level: "B1", pos: "noun", translation: "student" },
      { lemma: "prepričati", similar_translations: { "Russian" => "убедить" }, level: "C1", pos: "verb", translation: "to convince" }
    ]
    result = @annotator.send(:filter_cognates, entries, ["Russian"])
    assert_equal 1, result.length
    assert_equal "prepričati", result[0][:lemma]
  end

  def test_filter_cognates_removes_when_any_similar_language_matches
    entries = [
      { lemma: "soldat", translation: "soldier", similar_translations: { "Russian" => "солдат" }, level: "B1", pos: "noun" }
    ]
    result = @annotator.send(:filter_cognates, entries, ["Russian", "English"])
    assert_equal 0, result.length
  end

  def test_filter_cognates_keeps_short_non_identical_words
    # "dan" (Slovenian: day) vs "day" (English) — too short, must be identical to filter
    entries = [
      { lemma: "dan", translation: "day", level: "A1", pos: "noun" }
    ]
    result = @annotator.send(:filter_cognates, entries, ["English"])
    assert_equal 1, result.length
  end

  def test_filter_cognates_removes_short_identical_words
    # "gol" (Slovenian) vs "гол" (Russian) — identical after transliteration
    entries = [
      { lemma: "gol", translation: "goal", similar_translations: { "Russian" => "гол" }, level: "B1", pos: "noun" }
    ]
    result = @annotator.send(:filter_cognates, entries, ["Russian"])
    assert_equal 0, result.length
  end

  # --- normalize_for_comparison ---

  def test_normalize_ascii_passthrough
    assert_equal "hello", @annotator.send(:normalize_for_comparison, "hello")
  end

  def test_normalize_strips_diacritics
    result = @annotator.send(:normalize_for_comparison, "študentka")
    assert_equal "studentka", result
  end

  def test_normalize_cyrillic_to_latin
    result = @annotator.send(:normalize_for_comparison, "студентка")
    assert_equal "studentka", result
  end

  def test_normalize_downcases
    assert_equal "hello", @annotator.send(:normalize_for_comparison, "HELLO")
  end

  def test_normalize_empty_string
    assert_equal "", @annotator.send(:normalize_for_comparison, "")
  end

  # --- cognate? ---

  def test_cognate_detects_similar_long_words
    assert @annotator.send(:cognate?, "klokotanje", "klokotanie")
  end

  def test_cognate_rejects_dissimilar_words
    refute @annotator.send(:cognate?, "prepricati", "ubediti")
  end

  def test_cognate_short_word_requires_exact_match
    refute @annotator.send(:cognate?, "dan", "day")
    assert @annotator.send(:cognate?, "gol", "gol")
  end

  def test_filter_cognates_noop_when_no_similar_languages
    entries = [
      { lemma: "profesor", translation: "professor", level: "B1", pos: "noun" }
    ]
    result = @annotator.send(:filter_cognates, entries, [])
    assert_equal 1, result.length
  end

  def test_filter_cognates_handles_multi_word_translation
    entries = [
      { lemma: "soldat", translation: "soldier, fighter", level: "B1", pos: "noun" }
    ]
    result = @annotator.send(:filter_cognates, entries, ["English"])
    assert_equal 0, result.length
  end

  # --- IPA pronunciation ---

  def test_build_vocabulary_section_includes_espeak_ipa
    entries = [
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.", translation: "institute", definition: "An org.", ipa: "/zaˈʋɔːt/" }
    ]
    result = @annotator.send(:build_vocabulary_section, entries)
    assert_includes result, "**zavod** /zaˈʋɔːt/ (B2 n.)"
  end

  def test_build_vocabulary_section_omits_ipa_when_nil
    entries = [
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.", translation: "institute", definition: "An org." }
    ]
    result = @annotator.send(:build_vocabulary_section, entries)
    assert_includes result, "**zavod** (B2 n.)"
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
          assert_includes vocab, "**zavod** (B2 n.)"
          refute_includes vocab, "//"
        end
      end
    end
  end

  # --- max cap ---

  def test_annotate_max_caps_entries_keeping_hardest
    entries = [
      { word: "easy", lemma: "easy", level: "B2", pos: "adj", translation: "easy", definition: "Not hard." },
      { word: "hard", lemma: "hard", level: "C2", pos: "adj", translation: "hard", definition: "Difficult." },
      { word: "medium", lemma: "medium", level: "C1", pos: "adj", translation: "medium", definition: "In between." }
    ]
    stub_classify(entries) do
      Tell::Espeak.stub(:supports?, false) do
        _marked, vocab = @annotator.annotate("easy hard medium", language: "sl", cutoff: "B2", max: 2,
                                             filters: { priority: "hardest" })
        assert_includes vocab, "hard"
        assert_includes vocab, "medium"
        refute_includes vocab, "**easy**"
      end
    end
  end

  # --- filter lines ---

  def test_build_filter_lines_frequency_rare
    result = @annotator.send(:build_filter_lines, { frequency: "rare" })
    assert_includes result, "rare"
    assert_includes result, "low-frequency"
  end

  def test_build_filter_lines_frequency_literary
    result = @annotator.send(:build_filter_lines, { frequency: "literary" })
    assert_includes result, "literary"
    assert_includes result, "formal"
  end

  def test_build_filter_lines_frequency_archaic
    result = @annotator.send(:build_filter_lines, { frequency: "archaic" })
    assert_includes result, "archaic"
  end

  def test_build_filter_lines_frequency_uncommon
    result = @annotator.send(:build_filter_lines, { frequency: "uncommon" })
    assert_includes result, "uncommon"
  end

  def test_build_filter_lines_no_similar_language_prompt
    # similar filter is handled by code-level filter_cognates, not prompt
    result = @annotator.send(:build_filter_lines, { similar: "Russian" })
    assert_equal "", result
  end

  def test_build_filter_lines_custom_filter
    result = @annotator.send(:build_filter_lines, { filter: "Skip food words" })
    assert_includes result, "Skip food words"
  end

  def test_build_filter_lines_empty_when_no_filters
    result = @annotator.send(:build_filter_lines, {})
    assert_equal "", result
  end

  def test_build_filter_lines_combined
    result = @annotator.send(:build_filter_lines, {
      frequency: "rare", similar: "Russian", filter: "Focus on verbs"
    })
    assert_includes result, "rare"
    assert_includes result, "Focus on verbs"
    # similar is NOT in prompt — handled by code-level filter
    refute_includes result, "Russian"
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

  def test_classify_single_salvages_when_regex_matches_preamble_brackets
    # Simulates: LLM writes preamble with [A1/A2/B1/B2/C1/C2] before the JSON array,
    # then the response is truncated at max_tokens. The regex /\[.*\]/m matches the
    # preamble brackets, not the JSON. Salvage must still recover the real entries.
    # Stage 1 classify returns lightweight entries (word/lemma/level/pos only).
    truncated_response = <<~RAW
      Here are the words at level [A1/A2/B1/B2/C1/C2] or above:

      ```json
      [{"word":"razglasil","lemma":"razglasiti","level":"C1","pos":"verb"},{"word":"trunc
    RAW

    text_block = Struct.new(:type, :text).new("text", truncated_response)
    usage = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens)
      .new(100, 16384, 0, 0)
    message = Struct.new(:content, :stop_reason, :model, :usage)
      .new([text_block], "max_tokens", "test", usage)

    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) { |**_| message }
    client = @annotator.instance_variable_get(:@client)
    client.stub(:messages, fake_messages) do
      entries = @annotator.send(:classify_single, "some text", "sl", "B1")
      assert_equal 1, entries.length, "Expected salvage to recover 1 entry from truncated response with preamble brackets"
      assert_equal "razglasiti", entries[0][:lemma]
    end
  end

  def test_salvage_truncated_json_returns_nil_for_no_bracket
    assert_nil @annotator.send(:salvage_truncated_json, "no json here")
  end

  def test_salvage_truncated_json_returns_nil_for_no_complete_object
    assert_nil @annotator.send(:salvage_truncated_json, '[{"word":"incomplete')
  end

  def test_salvage_truncated_json_skips_brace_inside_truncated_string
    # Truncation lands after a } inside a string value of the INCOMPLETE entry.
    # The salvage must skip that } and find the real object delimiter.
    truncated = '[{"word":"a","lemma":"a","level":"B2","pos":"n."},{"word":"b","definition":"has {braces} trun'
    result = @annotator.send(:salvage_truncated_json, truncated)
    assert result
    parsed = JSON.parse(result, symbolize_names: true)
    assert_equal 1, parsed.length
    assert_equal "a", parsed[0][:word]
  end

  # --- split_into_chunks ---

  def test_split_into_chunks_splits_at_paragraph_boundary
    text = "Para one.\n\nPara two.\n\nPara three.\n\nPara four."
    chunks = @annotator.send(:split_into_chunks, text)

    assert_equal 2, chunks.length
    assert_includes chunks[0], "Para one."
    assert_includes chunks[0], "Para two."
    assert_includes chunks[1], "Para three."
    assert_includes chunks[1], "Para four."
  end

  def test_split_into_chunks_handles_odd_paragraph_count
    text = "One.\n\nTwo.\n\nThree."
    chunks = @annotator.send(:split_into_chunks, text)

    assert_equal 2, chunks.length
    assert_includes chunks[0], "One."
    assert_includes chunks[1], "Two."
    assert_includes chunks[1], "Three."
  end

  def test_split_into_chunks_single_paragraph_returns_one_chunk
    text = "Just one paragraph with no breaks."
    chunks = @annotator.send(:split_into_chunks, text)

    assert_equal 1, chunks.length
  end

  # --- classify_prompt (stage 1: lightweight) ---

  def test_classify_prompt_requests_only_four_fields
    prompt = @annotator.send(:classify_prompt, "sl", "B1")
    assert_includes prompt, "word"
    assert_includes prompt, "lemma"
    assert_includes prompt, "level"
    assert_includes prompt, "pos"
    # Prompt mentions "translation" only to say "Do NOT include" it
    assert_includes prompt, "Do NOT include translation"
    refute_includes prompt, "- translation:"
    refute_includes prompt, "- definition:"
    refute_includes prompt, "- pronunciation:"
  end

  def test_classify_prompt_includes_frequency_filter
    prompt = @annotator.send(:classify_prompt, "sl", "B1", { frequency: "rare" })
    assert_includes prompt, "rare"
  end

  # --- enrich_prompt (stage 3: targeted) ---

  def test_enrich_prompt_requests_translations
    prompt = @annotator.send(:enrich_prompt, "sl", "English")
    assert_includes prompt, "translation"
    assert_includes prompt, "definition"
    assert_includes prompt, "English"
  end

  def test_enrich_prompt_uses_target_language
    prompt = @annotator.send(:enrich_prompt, "sl", "Polish")
    assert_includes prompt, "Polish translation"
    assert_includes prompt, "definition"
    refute_includes prompt, "English translation"
  end

  def test_enrich_prompt_includes_pronunciation_when_espeak_unsupported
    Tell::Espeak.stub(:supports?, false) do
      prompt = @annotator.send(:enrich_prompt, "zh", "English")
      assert_includes prompt, "pronunciation"
    end
  end

  def test_enrich_prompt_excludes_pronunciation_when_espeak_supported
    Tell::Espeak.stub(:supports?, true) do
      prompt = @annotator.send(:enrich_prompt, "sl", "English")
      refute_includes prompt, "pronunciation"
    end
  end

  def test_enrich_prompt_similar_excludes_target_language
    prompt = @annotator.send(:enrich_prompt, "sl", "Polish", { similar: "Polish, Russian" })
    assert_includes prompt, "Russian"
    refute_match(/similar_translations.*Polish/, prompt)
  end

  # --- enrich_entries (merge logic) ---

  def test_enrich_entries_merges_translation_into_entries
    entries = [
      { word: "razglasil", lemma: "razglasiti", level: "C1", pos: "verb" }
    ]
    enrichments = [
      { lemma: "razglasiti", translation: "to announce", definition: "To declare publicly." }
    ]

    @annotator.stub(:call_enrich_api, enrichments) do
      result = @annotator.send(:enrich_entries, entries, language: "sl", target_language: "English", filters: {})
      assert_equal "to announce", result.first[:translation]
      assert_equal "To declare publicly.", result.first[:definition]
    end
  end

  def test_enrich_entries_preserves_unmatched_entries
    entries = [
      { word: "test", lemma: "test", level: "B1", pos: "noun" }
    ]
    # API returns nothing for this lemma
    @annotator.stub(:call_enrich_api, []) do
      result = @annotator.send(:enrich_entries, entries, language: "sl", target_language: "English", filters: {})
      assert_equal 1, result.length
      assert_nil result.first[:translation]
    end
  end

  def test_enrich_entries_returns_unchanged_when_empty
    result = @annotator.send(:enrich_entries, [], language: "sl", target_language: "English", filters: {})
    assert_empty result
  end

  def test_cognate_in_language_uses_translation_for_target_language
    entry = { lemma: "telefon", translation: "telefon", similar_translations: { "Russian" => "телефон" } }
    # When target is Polish, cognate check on "Polish" should use the translation field
    assert @annotator.send(:cognate_in_language?, entry, "Polish", "Polish")
  end

  def test_cognate_in_language_uses_similar_translations_for_non_target
    entry = { lemma: "telefon", translation: "telephone", similar_translations: { "Russian" => "телефон" } }
    assert @annotator.send(:cognate_in_language?, entry, "Russian", "English")
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

  # --- include_words protection ---

  def test_annotate_include_words_survives_known_lemmas
    entries = [
      { word: "zavod", lemma: "zavod", level: "B2", pos: "n.", translation: "institute", definition: "An org." }
    ]
    stub_classify(entries) do
      Tell::Espeak.stub(:supports?, false) do
        _marked, vocab = @annotator.annotate("zavod", language: "sl", cutoff: "B1",
                                             known_lemmas: Set.new(["zavod"]),
                                             include_words: Set.new(["zavod"]))
        assert_includes vocab, "zavod", "include_words should protect from known_lemmas filtering"
      end
    end
  end

  # --- count_occurrences + frequency sorting ---

  def test_count_occurrences_counts_all_forms
    entries = [{ word: "lupini", lemma: "lupina", level: "B2", pos: "noun",
                 words: ["lupini"] }]
    text = "lupini in lupina in lupino"

    Tell::Hunspell.stub(:supports?, false) do
      @annotator.send(:count_occurrences, text, entries, "sl")
      # Without hunspell: only "lupini" + "lupina" match (2)
      assert_equal 2, entries.first[:frequency]
    end
  end

  def test_count_occurrences_with_hunspell_expansion
    entries = [{ word: "lupini", lemma: "lupina", level: "B2", pos: "noun",
                 words: ["lupini"] }]
    text = "lupini in lupina in lupino"

    Tell::Hunspell.stub(:supports?, true) do
      Tell::Hunspell.stub(:expand, %w[lupin lupina lupine lupini lupino]) do
        @annotator.send(:count_occurrences, text, entries, "sl")
        # With hunspell: "lupini" + "lupina" + "lupino" match (3)
        assert_equal 3, entries.first[:frequency]
      end
    end
  end

  # --- priority sorting ---

  def test_priority_hardest_keeps_highest_level
    entries = [
      { word: "easy", lemma: "easy", level: "A2", pos: "adj", translation: "easy", definition: "Not hard." },
      { word: "hard", lemma: "hard", level: "C2", pos: "adj", translation: "hard", definition: "Difficult." },
      { word: "medium", lemma: "medium", level: "B1", pos: "adj", translation: "medium", definition: "In between." }
    ]
    stub_classify(entries) do
      Tell::Espeak.stub(:supports?, false) do
        _marked, vocab = @annotator.annotate("easy hard medium", language: "sl", cutoff: "A2", max: 1,
                                             filters: { priority: "hardest" })
        assert_includes vocab, "hard"
        refute_includes vocab, "**easy**"
        refute_includes vocab, "**medium**"
      end
    end
  end

  def test_priority_frequent_keeps_most_common
    entries = [
      { word: "rare", lemma: "rare", level: "C2", pos: "adj", translation: "rare", definition: "Rare." },
      { word: "common", lemma: "common", level: "A2", pos: "adj", translation: "common", definition: "Common." }
    ]
    # "common" appears 5 times, "rare" only once
    text = "common common common common common rare"

    stub_classify(entries) do
      Tell::Hunspell.stub(:supports?, false) do
        _marked, vocab = @annotator.annotate(text, language: "sl", cutoff: "A2", max: 1,
                                             filters: { priority: "frequent" })
        assert_includes vocab, "common", "should keep the more frequent word"
        refute_includes vocab, "**rare**", "should drop the less frequent word"
      end
    end
  end

  def test_priority_balanced_prefers_words_near_cutoff
    entries = [
      { word: "basic", lemma: "basic", level: "A2", pos: "adj", translation: "basic", definition: "Basic." },
      { word: "obscure", lemma: "obscure", level: "C2", pos: "adj", translation: "obscure", definition: "Obscure." },
      { word: "middle", lemma: "middle", level: "B1", pos: "adj", translation: "middle", definition: "Middle." }
    ]
    # All appear once; balanced should prefer A2/B1 (near cutoff A2) over C2
    text = "basic obscure middle"

    stub_classify(entries) do
      Tell::Hunspell.stub(:supports?, false) do
        _marked, vocab = @annotator.annotate(text, language: "sl", cutoff: "A2", max: 2,
                                             filters: { priority: "balanced" })
        assert_includes vocab, "basic"
        assert_includes vocab, "middle"
        refute_includes vocab, "**obscure**"
      end
    end
  end

  def test_priority_defaults_to_balanced
    entries = [
      { word: "basic", lemma: "basic", level: "A2", pos: "adj", translation: "basic", definition: "Basic." },
      { word: "obscure", lemma: "obscure", level: "C2", pos: "adj", translation: "obscure", definition: "Obscure." }
    ]
    text = "basic obscure"

    stub_classify(entries) do
      Tell::Hunspell.stub(:supports?, false) do
        _marked, vocab = @annotator.annotate(text, language: "sl", cutoff: "A2", max: 1)
        # Default is balanced — A2 should win over C2
        assert_includes vocab, "basic"
        refute_includes vocab, "**obscure**"
      end
    end
  end

  def test_max_cap_prefers_more_frequent_words_at_same_level
    entries = [
      { word: "redek", lemma: "redek", level: "B2", pos: "adj", translation: "rare", definition: "Rare." },
      { word: "pogost", lemma: "pogost", level: "B2", pos: "adj", translation: "frequent", definition: "Frequent." }
    ]
    # "pogost" appears 3 times, "redek" only once
    text = "pogost pogost pogost redek"

    stub_classify(entries) do
      Tell::Hunspell.stub(:supports?, false) do
        _marked, vocab = @annotator.annotate(text, language: "sl", cutoff: "B2", max: 1)
        assert_includes vocab, "pogost", "should keep the more frequent word"
        refute_includes vocab, "redek", "should drop the less frequent word"
      end
    end
  end

  # --- mark_words with hunspell expansion ---

  def test_mark_words_bolds_hunspell_expanded_forms
    entries = [{ word: "lupini", lemma: "lupina", level: "B2", pos: "noun",
                 words: ["lupini"] }]
    text = "Na orehovo lupino in lupini."

    Tell::Hunspell.stub(:supports?, true) do
      Tell::Hunspell.stub(:expand, %w[lupin lupina lupine lupini lupino]) do
        result = @annotator.send(:mark_words, text, entries, "sl")
        assert_includes result, "**lupino**"
        assert_includes result, "**lupini**"
        assert_includes entries.first[:words], "lupino"
        refute_includes entries.first[:words], "lupine"
      end
    end
  end

  def test_mark_words_works_without_hunspell
    entries = [{ word: "lupini", lemma: "lupina", level: "B2", pos: "noun",
                 words: ["lupini"] }]
    text = "Na orehovo lupino in lupini."

    Tell::Hunspell.stub(:supports?, false) do
      result = @annotator.send(:mark_words, text, entries, "sl")
      assert_includes result, "**lupini**"
      refute_includes result, "**lupino**"
    end
  end

  def test_mark_words_works_without_language
    entries = [{ word: "lupini", lemma: "lupina", level: "B2", pos: "noun",
                 words: ["lupini"] }]
    text = "Lupina je trdna in lupini."

    result = @annotator.send(:mark_words, text, entries)
    assert_includes result, "**lupini**"
    assert_includes result, "**Lupina**"
  end

  # --- sanitize_script ---

  def test_sanitize_script_replaces_cyrillic_homoglyphs
    entries = [{ word: "ištevanк\u0430", lemma: "ištevan\u043A\u0430",
                 level: "C1", pos: "noun" }]
    result = @annotator.send(:sanitize_script, entries, "Slovenian")
    assert_equal "ištevanka", result.first[:lemma]
    refute result.first[:word].match?(/\p{Cyrillic}/)
  end

  def test_sanitize_script_preserves_cyrillic_for_cyrillic_language
    entries = [{ word: "студентка", lemma: "студентка", level: "B1", pos: "noun" }]
    result = @annotator.send(:sanitize_script, entries, "Russian")
    assert_equal "студентка", result.first[:lemma]
  end

  def test_sanitize_script_leaves_clean_latin_unchanged
    entries = [{ word: "ištevanka", lemma: "ištevanka", level: "C1", pos: "noun" }]
    result = @annotator.send(:sanitize_script, entries, "Slovenian")
    assert_equal "ištevanka", result.first[:lemma]
  end

  # --- partition_forms ---

  def test_partition_forms_single_word_lemma_returns_all_as_head
    entry = { word: "razglasil", lemma: "razglasiti", words: ["razglasil"] }
    head, particles = @annotator.send(:partition_forms, entry)
    assert_includes head, "razglasil"
    assert_includes head, "razglasiti"
    assert_empty particles
  end

  def test_partition_forms_multi_word_lemma_separates_particle
    # Claude typically returns only the verb form, not "se" separately
    entry = { word: "izvila", lemma: "izviti se", words: ["izvila"] }
    head, particles = @annotator.send(:partition_forms, entry)
    assert_includes head, "izvila"
    assert_includes head, "izviti se"
    refute_includes head, "se"
    assert_equal ["se"], particles
  end

  def test_partition_forms_multi_word_lemma_with_particle_in_words
    # When Claude returns "se" as a separate entry that gets deduped
    entry = { word: "izvila", lemma: "izviti se", words: ["izvila", "se"] }
    head, particles = @annotator.send(:partition_forms, entry)
    assert_includes head, "izvila"
    assert_includes head, "izviti se"
    assert_equal ["se"], particles
  end

  # --- mark_words with reflexive particles ---

  def test_mark_words_does_not_bold_particle_in_different_phrase
    entries = [{ word: "izvila", lemma: "izviti se", level: "C1", pos: "verb",
                 words: ["izvila"] }]
    text = "Ana se je smejala. Vrvica se je izvila."

    Tell::Hunspell.stub(:supports?, false) do
      result = @annotator.send(:mark_words, text, entries, "sl")
      # "se" in first sentence (no vocab verb) should NOT be bolded
      assert_includes result, "Ana se je smejala."
      # "se" in second sentence near "izvila" should be bolded
      assert_includes result, "**se**"
      assert_includes result, "**izvila**"
    end
  end

  def test_mark_words_bolds_particle_in_same_phrase
    entries = [{ word: "izvila", lemma: "izviti se", level: "C1", pos: "verb",
                 words: ["izvila"] }]
    text = "Vrvica se je izvila iz škatle."

    Tell::Hunspell.stub(:supports?, false) do
      result = @annotator.send(:mark_words, text, entries, "sl")
      assert_includes result, "**se**"
      assert_includes result, "**izvila**"
    end
  end

  def test_mark_words_bolds_one_particle_per_verb_per_phrase
    entries = [{ word: "izvila", lemma: "izviti se", level: "C1", pos: "verb",
                 words: ["izvila"] }]
    # Two "se" in same phrase but only one vocab verb
    text = "Vrvica se je izvila in se ovila."

    Tell::Hunspell.stub(:supports?, false) do
      result = @annotator.send(:mark_words, text, entries, "sl")
      assert_equal 1, result.scan("**se**").length, "should bold only one 'se' per phrase"
      assert_includes result, "**izvila**"
    end
  end

  def test_mark_words_comma_separates_phrases
    entries = [{ word: "izvila", lemma: "izviti se", level: "C1", pos: "verb",
                 words: ["izvila"] }]
    text = "Ana se je smejala, vrvica se je izvila"

    Tell::Hunspell.stub(:supports?, false) do
      result = @annotator.send(:mark_words, text, entries, "sl")
      # First "se" is in a different phrase (before comma)
      assert_match(/Ana se je smejala,/, result)
      # Second "se" is in same phrase as "izvila"
      assert_includes result, "**se**"
      assert_includes result, "**izvila**"
      assert_equal 1, result.scan("**se**").length
    end
  end

  def test_mark_words_single_word_lemma_unchanged_with_particles
    # Regression: single-word lemmas must still bold all occurrences
    entries = [{ word: "razglasil", lemma: "razglasiti", level: "C1", pos: "verb",
                 words: ["razglasil"] }]
    result = @annotator.send(:mark_words, "On je razglasil. Potem razglasil.", entries)
    assert_equal 2, result.scan("**razglasil**").length
  end

  # --- count_occurrences with particles ---

  def test_count_occurrences_excludes_particle_from_frequency
    entries = [{ word: "izvila", lemma: "izviti se", level: "C1", pos: "verb",
                 words: ["izvila"] }]
    text = "Ana se je smejala. Potem se je smejala. Vrvica se je izvila."

    Tell::Hunspell.stub(:supports?, false) do
      @annotator.send(:count_occurrences, text, entries, "sl")
      # Only "izvila" counted (1), NOT "se" (3)
      assert_equal 1, entries.first[:frequency]
    end
  end

  # --- build_vocabulary_section with particles ---

  def test_build_vocabulary_section_excludes_particle_from_forms
    entries = [{ word: "izvila", lemma: "izviti se", level: "C1", pos: "verb",
                 words: ["izvila", "se"], translation: "to twist", definition: "To wind." }]
    result = @annotator.send(:build_vocabulary_section, entries)
    assert_includes result, "*izvila*"
    refute_includes result, "*se*"
    refute_includes result, "izvila, se"
  end

  def test_build_vocabulary_section_excludes_particle_without_se_in_words
    # Realistic case: Claude didn't return "se" as a word, it's only in the lemma
    entries = [{ word: "izvila", lemma: "izviti se", level: "C1", pos: "verb",
                 words: ["izvila"], translation: "to twist", definition: "To wind." }]
    result = @annotator.send(:build_vocabulary_section, entries)
    assert_includes result, "*izvila*"
    assert_includes result, "**izviti se**"
  end

  # --- annotate integration with reflexive verb ---
  #
  # Claude's classification of reflexive verbs is non-deterministic:
  # sometimes it returns "se" as a separate word form, sometimes it doesn't.
  # The output must be identical regardless. These tests run the SAME assertions
  # against both variants to guard against regressions from Claude behavior changes.

  REFLEXIVE_TEXT = "Danes se je Ana odločila. Potem se je vrvica izvila iz škatle."

  def assert_reflexive_marking(marked, vocab)
    # "izvila" bolded
    assert_includes marked, "**izvila**"
    # "se" near "izvila" (second sentence) bolded
    assert_includes marked, "**se** je vrvica **izvila**"
    # "se" in first sentence NOT bolded (no vocab verb there)
    assert_includes marked, "Danes se je Ana"
    # Vocab section shows "izvila" form, not "se"
    assert_includes vocab, "*izvila*"
    refute_match(/\bse\b/, vocab.split("## Vocabulary").last.to_s.gsub(/\*\*.*?\*\*/, ""))
  end

  def test_annotate_reflexive_verb_claude_returns_se_as_word_form
    # Claude returns two entries: verb form + particle separately
    entries = [
      { word: "izvila", lemma: "izviti se", level: "C1", pos: "verb",
        translation: "to twist", definition: "To wind around." },
      { word: "se", lemma: "izviti se", level: "C1", pos: "verb",
        translation: "to twist", definition: "To wind around." }
    ]

    stub_classify(entries) do
      Tell::Espeak.stub(:supports?, false) do
        Tell::Hunspell.stub(:supports?, false) do
          marked, vocab = @annotator.annotate(REFLEXIVE_TEXT, language: "sl", cutoff: "B1")
          assert_reflexive_marking(marked, vocab)
        end
      end
    end
  end

  def test_annotate_reflexive_verb_claude_omits_se_from_word_forms
    # Claude returns only the verb form, no separate "se" entry
    entries = [
      { word: "izvila", lemma: "izviti se", level: "C1", pos: "verb",
        translation: "to twist", definition: "To wind around." }
    ]

    stub_classify(entries) do
      Tell::Espeak.stub(:supports?, false) do
        Tell::Hunspell.stub(:supports?, false) do
          marked, vocab = @annotator.annotate(REFLEXIVE_TEXT, language: "sl", cutoff: "B1")
          assert_reflexive_marking(marked, vocab)
        end
      end
    end
  end

  def test_annotate_reflexive_verb_with_hunspell_returning_se
    # Claude returns only verb form, but hunspell expands "izviti se" → ["se"]
    entries = [
      { word: "izvila", lemma: "izviti se", level: "C1", pos: "verb",
        translation: "to twist", definition: "To wind around." }
    ]

    stub_classify(entries) do
      Tell::Espeak.stub(:supports?, false) do
        Tell::Hunspell.stub(:supports?, true) do
          Tell::Hunspell.stub(:expand, ["se"]) do
            marked, vocab = @annotator.annotate(REFLEXIVE_TEXT, language: "sl", cutoff: "B1")
            assert_reflexive_marking(marked, vocab)
          end
        end
      end
    end
  end

  def test_annotate_multiple_reflexive_verbs_independent_particles
    # Two reflexive verbs — each "se" should only be bolded near its own verb
    entries = [
      { word: "izvila", lemma: "izviti se", level: "C1", pos: "verb",
        translation: "to twist", definition: "To twist." },
      { word: "oglasila", lemma: "oglasiti se", level: "B2", pos: "verb",
        translation: "to speak up", definition: "To speak up." }
    ]
    text = "Ana se je smejala. Vrvica se je izvila. Nato se je oglasila Ana."

    stub_classify(entries) do
      Tell::Espeak.stub(:supports?, false) do
        Tell::Hunspell.stub(:supports?, false) do
          marked, _vocab = @annotator.annotate(text, language: "sl", cutoff: "B1")
          # First "se" (smejala) — NOT bolded
          assert_includes marked, "Ana se je smejala."
          # Second "se" (izvila) — bolded
          assert_includes marked, "**se** je **izvila**"
          # Third "se" (oglasila) — bolded
          assert_includes marked, "**se** je **oglasila**"
          assert_equal 2, marked.scan("**se**").length
        end
      end
    end
  end

  private

  def stub_classify_empty(&block)
    stub_classify([], &block)
  end

  def stub_classify(entries)
    # Build enrichment lookup from test entries (keyed by lowercase lemma)
    enrichment_map = {}
    entries.each do |e|
      enrichment_map[e[:lemma].to_s.downcase] = e.slice(:translation, :definition, :pronunciation, :similar_translations).compact
    end

    # enrich_entries receives the current (filtered) entries and merges enrichment data
    enrich_passthrough = lambda do |current_entries, **_kwargs|
      current_entries.each do |e|
        data = enrichment_map[e[:lemma].to_s.downcase]
        data&.each { |k, v| e[k] ||= v }
      end
      current_entries
    end

    @annotator.stub(:classify_words, entries) do
      @annotator.stub(:enrich_entries, enrich_passthrough) do
        yield
      end
    end
  end
end
