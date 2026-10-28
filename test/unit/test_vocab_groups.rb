# frozen_string_literal: true

require_relative "../test_helper"
require "vocabulary_annotator"
require "transcript_renderer"
require "transcript_parser"
require "word_stats"

# P9-5 (Q-93): first-occurrence order and the Key words / Also new groups
# — loop call 6.
class TestVocabGroups < Minitest::Test
  GROUPED_SINGLE = <<~MD
    ## Vocabulary

    ### Key words

    - **asino** (A1 noun) — donkey. A farm animal.

    ### Also new

    - **brigante** (B2 noun) *briganti* — bandit. An outlaw.
    - **bosco** (B1 noun) — wood. A small forest.
  MD

  GROUPED_MULTI = <<~MD
    ## Vocabulary (English, Russian)

    ### Key words

    - **asino** (A1 noun)
      - donkey. A farm animal.
      - осёл. Животное.

    ### Also new

    - **bosco** (B1 noun)
      - wood. A small forest.
      - лес. Небольшой лес.
  MD

  def setup
    @annotator = VocabularyAnnotator.new("k", model: "m")
    @r = Object.new.extend(TranscriptRenderer)
  end

  # --- build_vocabulary_section ---

  def test_section_orders_entries_by_first_occurrence
    text = "#{"x " * 5}zeta #{"x " * 55}alfa #{"x " * 90}mela"
    entries = [entry("alfa"), entry("mela"), entry("zeta")]
    section = @annotator.send(:build_vocabulary_section, entries, nil, text)
    assert_operator section.index("**zeta**"), :<, section.index("**alfa**")
    assert_operator section.index("**alfa**"), :<, section.index("**mela**")
    refute_includes section, "###", "no key entry → today's shape, no sub-headings"
  end

  def test_section_first_occurrence_matches_any_form
    text = "Poi i briganti fuggirono nel bosco."
    entries = [entry("bosco"), entry("brigante", words: %w[briganti])]
    section = @annotator.send(:build_vocabulary_section, entries, nil, text)
    assert_operator section.index("**brigante**"), :<, section.index("**bosco**")
  end

  def test_section_groups_key_entries_first
    text = "Il bosco era scuro. L'asino entrò."
    entries = [entry("bosco"), entry("asino", key: true)]
    section = @annotator.send(:build_vocabulary_section, entries, nil, text)
    lines = section.lines.map(&:chomp)
    assert_equal ["## Vocabulary", "", "### Key words", "", "- **asino** (B1 noun) — t. d", "",
      "### Also new", "", "- **bosco** (B1 noun) — t. d"], lines
  end

  def test_section_all_key_entries_has_no_empty_also_new
    section = @annotator.send(:build_vocabulary_section, [entry("asino", key: true)], nil, "asino")
    assert_includes section, "### Key words"
    refute_includes section, "### Also new"
  end

  def test_section_multi_language_groups_keep_definition_sublines
    entries = [entry("bosco", multi: true), entry("asino", key: true, multi: true)]
    section = @annotator.send(:build_vocabulary_section, entries, %w[English Russian], "asino bosco")
    assert_equal ["## Vocabulary (English, Russian)", "", "### Key words", "", "- **asino** (B1 noun)",
      "  - t. d", "  - т. д", "", "### Also new", "", "- **bosco** (B1 noun)", "  - t. d", "  - т. д"],
      section.lines.map(&:chomp)
  end

  def test_annotate_renders_key_group_first_in_text_order
    entries = [{word: "bosco", lemma: "bosco", level: "B1", pos: "noun"},
      {word: "asino", lemma: "asino", level: "B1", pos: "noun"},
      {word: "brigante", lemma: "brigante", level: "B2", pos: "noun"}]
    text = "Il brigante vide il bosco. L'asino, l'asino, l'asino ragliò nel bosco."
    enrich = ->(list, **) { list.map { |e| {lemma: e[:lemma], translation: "t", definition: "d"} } }
    vocab = @annotator.stub(:classify_words, ->(*) { entries.map(&:dup) }) do
      @annotator.stub(:call_enrich_api, enrich) do
        Tell::Espeak.stub(:supports?, false) do
          Tell::Hunspell.stub(:supports?, false) do
            @annotator.annotate(text, language: "Italian", cutoff: "B1").last
          end
        end
      end
    end
    order = %w[### Key **asino** Also **brigante** **bosco**].map { |s| vocab.index(s) }
    assert_equal order.sort, order, vocab
  end

  # --- renderer ---

  def test_render_vocabulary_html_emits_h3_per_group
    _body, vocab = @r.split_vocabulary_section(GROUPED_SINGLE)
    html = @r.render_vocabulary_html(vocab)
    assert_equal ["Key words", "Also new"], html.scan(%r{<h3>(.*?)</h3>}).flatten
    assert_equal 3, html.scan("<dt ").length
    assert_includes html, '<dt id="vocab-brigante">'
    assert_includes html, "<dd>bandit. An outlaw.</dd>"
    assert_operator html.index("Key words"), :<, html.index("vocab-asino")
    assert_operator html.index("Also new"), :<, html.index("vocab-brigante")
  end

  def test_render_vocabulary_html_groups_keep_language_switcher_and_dd
    _body, vocab = @r.split_vocabulary_section(GROUPED_MULTI)
    html = @r.render_vocabulary_html(vocab)
    assert_includes html, "vocab-lang-switcher"
    assert_equal 2, html.scan("<h3>").length
    assert_includes html, '<dd data-vocab-lang="English" class="active">donkey. A farm animal.</dd>'
    assert_includes html, '<dd data-vocab-lang="Russian">лес. Небольшой лес.</dd>'
  end

  def test_render_vocabulary_html_without_groups_is_unchanged
    vocab = "\n\n- **gatto** (A2 noun) — cat. A feline."
    assert_equal ["<div class=\"vocabulary\" id=\"vocabulary\">", "<h2>Vocabulary</h2>", "<dl>",
      "<dt id=\"vocab-gatto\"><strong>gatto</strong> <span class=\"pos\">(A2 noun)</span></dt>",
      "<dd>cat. A feline.</dd>", "</dl>", "</div>"], @r.render_vocabulary_html(vocab).split("\n")
  end

  def test_render_body_html_links_words_of_both_groups
    body = "Il **briganti** e l'**asino**.\n\n#{GROUPED_SINGLE}"
    html = @r.render_body_html(body)
    assert_includes html, 'href="#vocab-brigante"'
    assert_includes html, 'href="#vocab-asino"'
  end

  # --- parsers tolerate the sub-headings ---

  def test_parse_vocab_entries_single_language_ignores_subheadings
    _body, vocab = @r.split_vocabulary_section(GROUPED_SINGLE)
    entries = @r.parse_vocab_entries(vocab)
    assert_equal %w[asino bosco brigante], entries.values.map { |e| e[:lemma] }.uniq.sort
    assert_equal "brigante", entries["briganti"][:lemma]
    assert_equal "donkey. A farm animal.", entries["asino"][:definition]
  end

  def test_parse_vocab_entries_multi_language_ignores_subheadings
    _body, vocab = @r.split_vocabulary_section(GROUPED_MULTI)
    entries = @r.parse_vocab_entries(vocab)
    assert_equal %w[asino bosco], entries.keys.sort
    assert_equal({"English" => "donkey. A farm animal.", "Russian" => "осёл. Животное."}, entries["asino"][:definitions])
    assert_equal({"English" => "wood. A small forest.", "Russian" => "лес. Небольшой лес."}, entries["bosco"][:definitions])
  end

  def test_transcript_parser_keeps_subheadings_in_the_vocabulary
    parsed = TranscriptParser.parse("# T\n\n## Transcript\n\nIl bosco.\n\n#{GROUPED_SINGLE}")
    assert_equal "Il bosco.", parsed.body
    assert_includes parsed.vocabulary, "### Key words"
    assert_includes parsed.vocabulary, "- **bosco**"
  end

  def test_word_stats_aggregate_vocab_ignores_subheadings
    _body, vocab = @r.split_vocabulary_section(GROUPED_SINGLE)
    stats = WordStats.new(config: nil)
    index = stats.send(:aggregate_vocab, [{basename: "ep1", body: "", vocab_entries: stats.parse_vocab_entries(vocab)}])
    assert_equal %w[asino bosco brigante], index.keys.sort
    assert_equal 1, index["brigante"][:episode_count]
  end

  private

  def entry(lemma, words: nil, key: false, multi: false)
    e = {word: (words || [lemma]).first, words: words || [lemma], lemma: lemma, level: "B1", pos: "noun"}
    if multi
      e[:translations] = {"English" => "t", "Russian" => "т"}
      e[:definitions] = {"English" => "d", "Russian" => "д"}
    else
      e[:translation] = "t"
      e[:definition] = "d"
    end
    e[:key] = true if key
    e
  end
end
