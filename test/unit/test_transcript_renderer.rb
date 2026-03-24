# frozen_string_literal: true

require_relative "../test_helper"
require "transcript_renderer"

# Minimal host class to test the module methods
class Renderer
  include TranscriptRenderer
end

class TestTranscriptRenderer < Minitest::Test
  def setup
    @r = Renderer.new
  end

  # --- escape_html ---

  def test_escape_html_ampersand
    assert_equal "a &amp; b", @r.escape_html("a & b")
  end

  def test_escape_html_angle_brackets
    assert_equal "&lt;script&gt;", @r.escape_html("<script>")
  end

  def test_escape_html_multiple_entities
    assert_equal "&lt;b&gt;bold &amp; italic&lt;/b&gt;", @r.escape_html("<b>bold & italic</b>")
  end

  def test_escape_html_no_special_chars
    assert_equal "plain text", @r.escape_html("plain text")
  end

  # --- strip_bold_markers ---

  def test_strip_bold_markers_removes_stars
    assert_equal "hello world", @r.strip_bold_markers("**hello** world")
  end

  def test_strip_bold_markers_multiple
    assert_equal "one and two", @r.strip_bold_markers("**one** and **two**")
  end

  def test_strip_bold_markers_no_markers
    assert_equal "plain text", @r.strip_bold_markers("plain text")
  end

  # --- linkify_markdown ---

  def test_linkify_markdown_single_link
    result = @r.linkify_markdown("[Example](https://example.com)")
    assert_equal '<a href="https://example.com">Example</a>', result
  end

  def test_linkify_markdown_multiple_links
    result = @r.linkify_markdown("[A](https://a.com) and [B](https://b.com)")
    assert_includes result, '<a href="https://a.com">A</a>'
    assert_includes result, '<a href="https://b.com">B</a>'
  end

  def test_linkify_markdown_escapes_html_in_title
    result = @r.linkify_markdown("[A <b>tag</b>](https://example.com)")
    assert_includes result, "&lt;b&gt;tag&lt;/b&gt;"
    refute_includes result, "<b>"
  end

  def test_linkify_markdown_no_links
    assert_equal "plain text", @r.linkify_markdown("plain text")
  end

  # --- split_vocabulary_section ---

  def test_split_vocabulary_section_with_vocab
    body = "Main text\n\n## Vocabulary\n\nVocab entries"
    text, vocab = @r.split_vocabulary_section(body)
    assert_equal "Main text\n\n", text
    assert_equal "\n\nVocab entries", vocab
  end

  def test_split_vocabulary_section_without_vocab
    body = "Just main text"
    text, vocab = @r.split_vocabulary_section(body)
    assert_equal "Just main text", text
    assert_nil vocab
  end

  def test_split_vocabulary_section_splits_at_first_occurrence
    body = "Before\n\n## Vocabulary\n\nFirst\n\n## Vocabulary\n\nSecond"
    text, vocab = @r.split_vocabulary_section(body)
    assert_equal "Before\n\n", text
    assert_includes vocab, "First"
    assert_includes vocab, "Second"
  end

  # --- parse_vocab_lemmas ---

  def test_parse_vocab_lemmas_extracts_bold_words
    vocab = "\n- **razglasiti** (C1 v.) — to announce\n- **beseda** (B2 n.) — word\n"
    result = @r.parse_vocab_lemmas(vocab)
    assert_equal "razglasiti", result["razglasiti"]
    assert_equal "beseda", result["beseda"]
  end

  def test_parse_vocab_lemmas_maps_originals_to_lemma
    vocab = "\n- **razglasiti** (C1 v.) *razglasil* — to announce\n"
    result = @r.parse_vocab_lemmas(vocab)
    assert_equal "razglasiti", result["razglasil"]
  end

  def test_parse_vocab_lemmas_returns_nil_for_empty
    assert_nil @r.parse_vocab_lemmas("")
  end

  def test_parse_vocab_lemmas_case_insensitive_keys
    vocab = "\n- **Beseda** (B2 n.) — word\n"
    result = @r.parse_vocab_lemmas(vocab)
    assert_equal "Beseda", result["beseda"]
  end

  def test_parse_vocab_lemmas_diacritics_in_lemma
    vocab = "\n- **krošnja** (B2 noun) *krošnjo* — canopy\n"
    result = @r.parse_vocab_lemmas(vocab)
    assert_equal "krošnja", result["krošnja"]
    assert_equal "krošnja", result["krošnjo"]
  end

  def test_parse_vocab_lemmas_multi_word_lemma
    vocab = "\n- **prepletati se** (C1 verb) *prepletala* — to intertwine\n"
    result = @r.parse_vocab_lemmas(vocab)
    assert_equal "prepletati se", result["prepletati se"]
    assert_equal "prepletati se", result["prepletala"]
  end

  # --- vocab_anchor ---

  def test_vocab_anchor_simple
    assert_equal "vocab-hello", @r.vocab_anchor("hello")
  end

  def test_vocab_anchor_uppercase
    assert_equal "vocab-hello", @r.vocab_anchor("Hello")
  end

  def test_vocab_anchor_special_chars
    assert_equal "vocab-some-word", @r.vocab_anchor("some word!")
  end

  def test_vocab_anchor_strips_leading_trailing_hyphens
    assert_equal "vocab-abc", @r.vocab_anchor("--abc--")
  end

  def test_vocab_anchor_preserves_diacritics
    assert_equal "vocab-krošnja", @r.vocab_anchor("krošnja")
  end

  def test_vocab_anchor_preserves_multi_word_with_diacritics
    assert_equal "vocab-prepletati-se", @r.vocab_anchor("prepletati se")
  end

  # --- linkify_vocab_words ---

  def test_linkify_vocab_words_links_bold_to_anchor
    entries = { "beseda" => { lemma: "beseda", pos: "n.", definition: "word" } }
    result = @r.linkify_vocab_words("The **beseda** is here.", entries)
    assert_includes result, 'href="#vocab-beseda"'
    assert_includes result, 'class="vocab-word"'
    assert_includes result, ">beseda<"
    refute_includes result, "**"
  end

  def test_linkify_vocab_words_uses_lemma_for_anchor
    entries = { "razglasil" => { lemma: "razglasiti", pos: "v.", definition: "to announce" } }
    result = @r.linkify_vocab_words("He **razglasil** it.", entries)
    assert_includes result, 'href="#vocab-razglasiti"'
  end

  def test_linkify_vocab_words_falls_back_to_lowercase
    result = @r.linkify_vocab_words("A **Unknown** word.", {})
    assert_includes result, 'href="#vocab-unknown"'
  end

  # --- parse_vocab_entries ---

  def test_parse_vocab_entries_returns_structured_data
    vocab = <<~VOCAB

      - **beseda** (B1 n.) — word. a unit of language
    VOCAB

    result = @r.parse_vocab_entries(vocab)
    entry = result["beseda"]
    assert_equal "beseda", entry[:lemma]
    assert_equal "B1 n.", entry[:pos]
    assert_equal "word. a unit of language", entry[:definition]
    assert_nil entry[:original]
  end

  def test_parse_vocab_entries_returns_nil_for_empty
    assert_nil @r.parse_vocab_entries("")
  end

  # --- parse_vocab_entries with IPA ---

  def test_parse_vocab_entries_with_ipa
    vocab = <<~VOCAB

      - **zavod** /zaˈʋɔːt/ (B2 n.) — institute. An organization.
    VOCAB

    result = @r.parse_vocab_entries(vocab)
    entry = result["zavod"]
    assert_equal "zavod", entry[:lemma]
    assert_equal "/zaˈʋɔːt/", entry[:ipa]
    assert_equal "B2 n.", entry[:pos]
  end

  def test_parse_vocab_entries_without_ipa
    vocab = <<~VOCAB

      - **zavod** (B2 n.) — institute. An organization.
    VOCAB

    result = @r.parse_vocab_entries(vocab)
    assert_nil result["zavod"][:ipa]
  end

  def test_parse_vocab_entries_with_original
    vocab = <<~VOCAB

      - **razglasiti** (C1 v.) *razglasil* — to announce
    VOCAB

    result = @r.parse_vocab_entries(vocab)
    assert_equal "razglasiti", result["razglasiti"][:lemma]
    assert_equal "razglasil", result["razglasiti"][:original]
    assert_equal "razglasiti", result["razglasil"][:lemma]
  end

  def test_parse_vocab_entries_with_multiple_original_forms
    vocab = <<~VOCAB

      - **skomigniti** (C1 verb) *skomignil, skomignila* — shrugged
    VOCAB

    result = @r.parse_vocab_entries(vocab)
    # Both forms map to the same entry
    assert_equal "skomigniti", result["skomignil"][:lemma]
    assert_equal "skomigniti", result["skomignila"][:lemma]
    assert_equal "skomignil, skomignila", result["skomigniti"][:original]
  end

  def test_parse_vocab_entries_old_format_still_works
    vocab = <<~VOCAB

      **C1**
      - **razglasiti** (v.) — to announce _Original: razglasil_
    VOCAB

    result = @r.parse_vocab_entries(vocab)
    assert_equal "razglasiti", result["razglasiti"][:lemma]
    assert_equal "razglasil", result["razglasiti"][:original]
  end

  # --- linkify_vocab_words with tooltips ---

  def test_linkify_vocab_words_includes_tooltip_span
    entries = { "beseda" => { lemma: "beseda", pos: "n.", definition: "word" } }
    result = @r.linkify_vocab_words("The **beseda** is here.", entries)
    assert_includes result, '<span class="vocab-tip">'
    assert_includes result, "<strong>beseda</strong>"
    assert_includes result, "word"
  end

  def test_linkify_vocab_words_tooltip_includes_pos
    entries = { "beseda" => { lemma: "beseda", pos: "n.", definition: "word" } }
    result = @r.linkify_vocab_words("The **beseda** is here.", entries)
    assert_includes result, '<span class="pos">(n.)</span>'
  end

  def test_linkify_vocab_words_tooltip_without_definition
    entries = { "beseda" => { lemma: "beseda", pos: "n.", definition: "" } }
    result = @r.linkify_vocab_words("A **beseda** here.", entries)
    assert_includes result, '<span class="vocab-tip">'
    refute_includes result, "vocab-tip-def"
  end

  def test_linkify_vocab_words_tooltip_includes_ipa
    entries = { "zavod" => { lemma: "zavod", pos: "n.", definition: "institute", ipa: "/zaˈʋɔːt/" } }
    result = @r.linkify_vocab_words("The **zavod** is here.", entries)
    assert_includes result, '<span class="ipa">/zaˈʋɔːt/</span>'
  end

  def test_linkify_vocab_words_tooltip_omits_ipa_when_nil
    entries = { "zavod" => { lemma: "zavod", pos: "n.", definition: "institute", ipa: nil } }
    result = @r.linkify_vocab_words("The **zavod** is here.", entries)
    refute_includes result, "ipa"
  end

  def test_linkify_vocab_words_tooltip_escapes_html
    entries = { "word" => { lemma: "word", pos: "n.", definition: "a <b>unit</b>" } }
    result = @r.linkify_vocab_words("A **word** here.", entries)
    assert_includes result, "a &lt;b&gt;unit&lt;/b&gt;"
  end

  # --- render_vocabulary_html ---

  def test_render_vocabulary_html_basic_structure
    vocab = <<~VOCAB

      - **beseda** (B1 n.) — word. a unit of language
    VOCAB

    html = @r.render_vocabulary_html(vocab)
    assert_includes html, '<div class="vocabulary" id="vocabulary">'
    assert_includes html, "<h2>Vocabulary</h2>"
    assert_includes html, "<dl>"
    assert_includes html, "</dl>"
    assert_includes html, "</div>"
    refute_includes html, "<h3>"
  end

  def test_render_vocabulary_html_entry_content
    vocab = <<~VOCAB

      - **beseda** (A2 n.) — word. a unit of language
    VOCAB

    html = @r.render_vocabulary_html(vocab)
    assert_includes html, 'id="vocab-beseda"'
    assert_includes html, "<strong>beseda</strong>"
    assert_includes html, '<span class="pos">(A2 n.)</span>'
    assert_includes html, "word. a unit of language"
  end

  def test_render_vocabulary_html_with_original
    vocab = <<~VOCAB

      - **razglasiti** (C1 v.) *razglasil* — to announce
    VOCAB

    html = @r.render_vocabulary_html(vocab)
    assert_includes html, '<span class="original">razglasil</span>'
    assert_includes html, "to announce"
  end

  def test_render_vocabulary_html_with_ipa
    vocab = <<~VOCAB

      - **zavod** /zaˈʋɔːt/ (B2 n.) — institute
    VOCAB

    html = @r.render_vocabulary_html(vocab)
    assert_includes html, '<span class="ipa">/zaˈʋɔːt/</span>'
    assert_includes html, "<strong>zavod</strong>"
  end

  def test_render_vocabulary_html_flat_alphabetical
    vocab = <<~VOCAB

      - **dve** (B1 num.) — two
      - **ena** (A2 num.) — one
    VOCAB

    html = @r.render_vocabulary_html(vocab)
    refute_includes html, "<h3>"
    assert_includes html, "ena"
    assert_includes html, "dve"
  end

  # --- render_body_html ---

  def test_render_body_html_paragraphs
    html = @r.render_body_html("First para.\n\nSecond para.")
    assert_includes html, "<p>First para.</p>"
    assert_includes html, "<p>Second para.</p>"
  end

  def test_render_body_html_headings
    html = @r.render_body_html("## Section Title\n\nBody text.")
    assert_includes html, "<h2>Section Title</h2>"
    assert_includes html, "<p>Body text.</p>"
  end

  def test_render_body_html_link_list
    html = @r.render_body_html("- [Link](https://example.com)\n- [Other](https://other.com)")
    assert_includes html, "<ul>"
    assert_includes html, "<li>"
    assert_includes html, '<a href="https://example.com">Link</a>'
  end

  def test_render_body_html_escapes_html
    html = @r.render_body_html("Text with <script>alert('xss')</script>")
    refute_includes html, "<script>"
    assert_includes html, "&lt;script&gt;"
  end

  def test_render_body_html_with_vocab_true_links_words
    body = "He **razglasil** it.\n\n## Vocabulary\n\n- **razglasiti** (C1 v.) *razglasil* — to announce"
    html = @r.render_body_html(body, vocab: true)
    assert_includes html, 'class="vocab-word"'
    assert_includes html, '<div class="vocabulary" id="vocabulary">'
  end

  def test_render_body_html_with_vocab_false_strips_vocab
    body = "He **razglasil** it.\n\n## Vocabulary\n\n- **razglasiti** (C1 v.) — to announce"
    html = @r.render_body_html(body, vocab: false)
    refute_includes html, "Vocabulary"
    refute_includes html, "vocab-word"
    # Bold markers stripped, text kept
    assert_includes html, "razglasil"
    refute_includes html, "**"
  end

  def test_render_body_html_without_vocab_section_strips_bold
    html = @r.render_body_html("The **word** is here.", vocab: true)
    # No vocab section, so bold markers should be stripped
    assert_includes html, "The word is here."
    refute_includes html, "**"
  end

  def test_render_body_html_diacritics_link_matches_anchor
    body = "Videli so **krošnjo** drevesa.\n\n## Vocabulary\n\n- **krošnja** (B2 noun) *krošnjo* — canopy"
    html = @r.render_body_html(body, vocab: true)
    assert_includes html, 'href="#vocab-krošnja"'
    assert_includes html, 'id="vocab-krošnja"'
  end

  def test_render_body_html_multi_word_lemma_link_matches_anchor
    body = "Barve so se **prepletale** med sabo.\n\n## Vocabulary\n\n- **prepletati se** (C1 verb) *prepletale* — to intertwine"
    html = @r.render_body_html(body, vocab: true)
    assert_includes html, 'href="#vocab-prepletati-se"'
    assert_includes html, 'id="vocab-prepletati-se"'
  end
end
