# frozen_string_literal: true

require_relative "../test_helper"
require "vocabulary_annotator"
require "transcript_renderer"

# P17-4 (Q-114): every vocabulary entry the annotator emits reads back
# through the renderer's parser with its glosses under the right language.
class TestVocabGlossLines < Minitest::Test
  PARSER = Object.new.extend(TranscriptRenderer)

  def setup
    @annotator = VocabularyAnnotator.new("test-key", model: "m")
  end

  def test_build_vocabulary_section_missing_first_language_parses_under_the_present_one
    entry = {word: "pes", lemma: "pes", level: "B1", pos: "noun",
             translations: {"English" => "x"}}
    parsed = round_trip([entry], %w[Russian English])
    assert_equal({"English" => "x"}, parsed["pes"][:definitions])
  end

  def test_build_vocabulary_section_missing_last_language_parses_under_the_first
    entry = {word: "pes", lemma: "pes", level: "B1", pos: "noun",
             translations: {"Russian" => "собака"}, definitions: {"Russian" => "Животное."}}
    parsed = round_trip([entry], %w[Russian English])
    assert_equal({"Russian" => "собака. Животное."}, parsed["pes"][:definitions])
  end

  def test_build_vocabulary_section_definition_without_translation_has_no_leading_dot
    entry = {word: "pes", lemma: "pes", level: "B1", pos: "noun",
             translations: {"Russian" => "собака", "English" => nil}, definitions: {"English" => "A dog."}}
    parsed = round_trip([entry], %w[Russian English])
    assert_equal({"Russian" => "собака", "English" => "A dog."}, parsed["pes"][:definitions])
  end

  def test_build_vocabulary_section_full_entries_keep_the_existing_line_shape
    entry = {word: "pes", lemma: "pes", level: "B1", pos: "noun",
             translations: {"Russian" => "собака", "English" => "dog"},
             definitions: {"Russian" => "Животное.", "English" => "An animal."}}
    section = @annotator.send(:build_vocabulary_section, [entry], %w[Russian English])
    assert_equal "## Vocabulary (Russian, English)\n\n- **pes** (B1 noun)\n  - собака. Животное.\n  - dog. An animal.",
      section
  end

  def test_parse_vocab_entries_existing_positional_lines_still_parse
    body = " (Russian, English)\n\n- **pes** (B1 noun)\n  - собака. Животное.\n  - dog. An animal.\n"
    entry = PARSER.parse_vocab_entries(body)["pes"]
    assert_equal({"Russian" => "собака. Животное.", "English" => "dog. An animal."}, entry[:definitions])
    assert_equal "собака. Животное.", entry[:definition]
  end

  # P18-8 (2): :definition is the first language's gloss only — a `—`
  # first line leaves it empty rather than borrowing the second language's
  # (vocab-health definition drift would compare English against Russian).
  def test_parse_vocab_entries_placeholder_first_language_leaves_definition_empty
    body = " (Russian, English)\n\n- **pes** (B1 noun)\n  - —\n  - dog. An animal.\n"
    entry = PARSER.parse_vocab_entries(body)["pes"]
    assert_equal({"English" => "dog. An animal."}, entry[:definitions])
    assert_empty entry[:definition].to_s
  end

  def test_render_vocabulary_html_placeholder_renders_no_definition
    entry = {word: "pes", lemma: "pes", level: "B1", pos: "noun", translations: {"English" => "x"}}
    section = @annotator.send(:build_vocabulary_section, [entry], %w[Russian English])
    html = PARSER.render_vocabulary_html(section.delete_prefix("## Vocabulary"))
    assert_includes html, %(<dd data-vocab-lang="English">x</dd>)
    refute_includes html, %(data-vocab-lang="Russian" class="active">)
  end

  def test_build_vocabulary_section_definition_only_single_language_parses
    entry = {word: "pes", lemma: "pes", level: "B1", pos: "noun", definition: "A dog."}
    parsed = round_trip([entry], nil)
    refute_nil parsed, "the entry must parse"
    assert_equal "A dog.", parsed["pes"][:definition]
  end

  def test_build_vocabulary_section_fallback_ipa_without_slashes_parses
    entry = {word: "pes", lemma: "pes", level: "B1", pos: "noun", ipa: "pɛs", translation: "dog"}
    parsed = round_trip([entry], nil)
    refute_nil parsed, "the entry must parse"
    assert_equal "/pɛs/", parsed["pes"][:ipa]
    assert_equal "dog", parsed["pes"][:definition]
  end

  def test_build_vocabulary_section_slashed_ipa_is_not_doubled
    entry = {word: "pes", lemma: "pes", level: "B1", pos: "noun", ipa: "/pɛs/", translation: "dog"}
    section = @annotator.send(:build_vocabulary_section, [entry])
    assert_includes section, "- **pes** /pɛs/ (B1 noun) — dog"
  end

  private

  def round_trip(entries, target_languages)
    section = @annotator.send(:build_vocabulary_section, entries, target_languages)
    PARSER.parse_vocab_entries(section.delete_prefix("## Vocabulary"))
  end
end
