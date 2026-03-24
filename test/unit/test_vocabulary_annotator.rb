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

  # --- dedup_by_family ---

  def test_dedup_by_family_merges_same_family
    entries = [
      { word: "drobec", lemma: "drobec", level: "C1", pos: "noun", family: "drobec",
        translation: "crumb", definition: "A small piece.", words: ["drobec"] },
      { word: "drobtinic", lemma: "drobtina", level: "C1", pos: "noun", family: "drobec",
        translation: "crumb", definition: "A tiny fragment.", words: ["drobtinic"] }
    ]
    result = @annotator.send(:dedup_by_family, entries)

    assert_equal 1, result.length
    assert_equal "drobec", result[0][:lemma]
    assert_includes result[0][:words], "drobec"
    assert_includes result[0][:words], "drobtinic"
  end

  def test_dedup_by_family_prefers_entry_matching_family_tag
    entries = [
      { word: "kikirikanje", lemma: "kikirikanje", level: "B2", pos: "noun", family: "kikirikati",
        translation: "crowing", definition: "The cry of a rooster.", words: ["kikirikanje"] },
      { word: "kikirikal", lemma: "kikirikati", level: "B2", pos: "verb", family: "kikirikati",
        translation: "to crow", definition: "To make a rooster cry.", words: ["kikirikal"] }
    ]
    result = @annotator.send(:dedup_by_family, entries)

    assert_equal 1, result.length
    assert_equal "kikirikati", result[0][:lemma]
    assert_includes result[0][:words], "kikirikanje"
    assert_includes result[0][:words], "kikirikal"
  end

  def test_dedup_by_family_keeps_different_families
    entries = [
      { word: "drobec", lemma: "drobec", level: "C1", pos: "noun", family: "drobec",
        translation: "crumb", definition: "A small piece.", words: ["drobec"] },
      { word: "hodil", lemma: "hoditi", level: "B2", pos: "verb", family: "hoditi",
        translation: "to walk", definition: "To move on foot.", words: ["hodil"] }
    ]
    result = @annotator.send(:dedup_by_family, entries)

    assert_equal 2, result.length
  end

  def test_dedup_by_family_falls_back_to_first_when_no_match
    # Neither entry's lemma matches the family tag — keep the first one
    entries = [
      { word: "drobtinic", lemma: "drobtina", level: "C1", pos: "noun", family: "drobiti",
        translation: "crumb", definition: "A tiny fragment.", words: ["drobtinic"] },
      { word: "drobce", lemma: "drobec", level: "C1", pos: "noun", family: "drobiti",
        translation: "crumb", definition: "A small piece.", words: ["drobce"] }
    ]
    result = @annotator.send(:dedup_by_family, entries)

    assert_equal 1, result.length
    assert_equal "drobtina", result[0][:lemma]
    assert_includes result[0][:words], "drobtinic"
    assert_includes result[0][:words], "drobce"
  end

  def test_dedup_by_family_skips_entries_without_family
    entries = [
      { word: "drobec", lemma: "drobec", level: "C1", pos: "noun",
        translation: "crumb", definition: "A small piece.", words: ["drobec"] },
      { word: "hodil", lemma: "hoditi", level: "B2", pos: "verb",
        translation: "to walk", definition: "To move on foot.", words: ["hodil"] }
    ]
    result = @annotator.send(:dedup_by_family, entries)

    # No family field — entries pass through unchanged
    assert_equal 2, result.length
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
        _marked, vocab = @annotator.annotate("easy hard medium", language: "sl", cutoff: "B2", max: 2)
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
    truncated_response = <<~RAW
      Here are the words at level [A1/A2/B1/B2/C1/C2] or above:

      ```json
      [{"word":"razglasil","lemma":"razglasiti","level":"C1","pos":"verb","translation":"to announce","definition":"To declare publicly.","family":"razglasiti"},{"word":"trunc
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
