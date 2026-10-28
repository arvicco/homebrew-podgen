# frozen_string_literal: true

require_relative "../test_helper"
require "vocab_health"

class TestVocabHealth < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_vocab_health_test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- first test (P9-0): a lemma explained twice is a repeat ---

  def test_report_two_episodes_sharing_a_lemma_counts_one_repeat
    write_ep("p-2026-01-01", "Il lupo.", ["- **lupo** (B1 noun) — wolf. An animal"])
    write_ep("p-2026-01-02", "Il lupo e la mela.", ["- **lupo** (B1 noun) — wolf. Canine",
      "- **mela** (B2 noun) — apple"])

    r = health.report

    assert_equal 3, r.entries
    assert_equal 1, r.repeat_entries
    assert_equal [["lupo", 2]], r.top_lemmas.select { |_, c| c >= 2 }
  end

  # --- the three-episode fixture: every number hand-computed ---

  def test_report_three_episode_fixture_counts
    three_episode_fixture

    r = health(durations: {"p-2026-01-01" => 180, "p-2026-01-02" => 60}).report

    assert_equal 3, r.episodes
    assert_equal 8, r.entries                      # 3 + 2 + 3
    assert_equal 5, r.unique_lemmas                # casa lupo bosco mela fiume
    assert_equal 3, r.repeat_entries               # lupo (ep2), lupo + casa (ep3)
    assert_in_delta 37.5, r.repeat_share, 0.001
    assert_equal 3, r.median_per_episode           # [3, 2, 3]
    assert_in_delta 1.5, r.median_per_minute, 0.001 # [3/3 min, 2/1 min]; ep3 has no duration
    assert_equal 1, r.lemmas_3plus                 # lupo ×3
    assert_equal [["lupo", 3], ["casa", 2]], r.top_lemmas.first(2)
    assert_equal({below: 2, at: 4, plus1: 1, plus2: 1}, r.levels)
    assert_equal 1, r.drift                        # casa: house vs home; lupo always "wolf"
    assert_equal 2, r.repeated_with_definitions
  end

  def test_report_without_durations_has_no_per_minute
    three_episode_fixture

    assert_nil health.report.median_per_minute
  end

  def test_report_last_n_repeats_count_against_earlier_episodes
    three_episode_fixture

    r = health.report(last: 1)

    assert_equal 1, r.episodes
    assert_equal 3, r.entries
    assert_equal 2, r.repeat_entries               # lupo and casa were explained before
    assert_equal 0, r.lemmas_3plus                 # within the window
  end

  def test_report_reads_multi_language_sections
    write_raw("p-2026-01-01", "Il lupo.", "## Vocabulary (English, Russian)\n\n- **lupo** (B1 noun)\n  - wolf. An animal\n  - волк\n")
    write_raw("p-2026-01-02", "Il lupo.", "## Vocabulary (English, Russian)\n\n- **lupo** (B1 noun)\n  - she-wolf. x\n  - волчица\n")

    r = health.report

    assert_equal 2, r.entries
    assert_equal 1, r.repeat_entries
    assert_equal 1, r.drift
  end

  def test_report_ignores_entries_without_a_cefr_level
    write_ep("p-2026-01-01", "x", ["- **razglasiti** (v.) — to announce", "- **lupo** (B1 noun) — wolf"])

    r = health.report

    assert_equal 1, r.entries
    assert_equal 1, r.unlevelled
  end

  # --- key-term candidates (loop call 4) ---

  def test_report_key_term_df_counts_only_earlier_episodes
    2.times { |i| write_ep("p-2026-02-0#{i + 1}", "asino asino asino gatto gatto gatto rete rete rete", []) }
    5.times { |i| write_ep("p-2026-02-1#{i}", "Filler text here.", []) }

    r = health.report

    # ep1: no earlier episodes, df 0 for all -> 3 candidates (miss); ep2: df 1 of 1 earlier > 15 % -> none.
    assert_equal 1, r.key_term_misses
  end

  def test_report_key_term_proper_noun_is_not_a_candidate
    6.times { |i| write_ep("p-2026-02-0#{i + 1}", "Filler text here.", []) }
    write_ep("p-2026-02-07", "Un asino vide un asino e un asino. Il gatto e il gatto e il gatto. " \
                             "Poi venne Teresa con Teresa e Teresa.", [])

    assert_equal 0, health.report.key_term_misses # asino, gatto only: Teresa is capitalised mid-sentence
  end

  def test_uncovered_drops_tokens_sharing_five_chars_with_a_lemma_or_form
    cands = %w[asino briganti gattone]

    left = VocabHealth.uncovered(cands, covers: %w[brigante gattoni])

    assert_equal ["asino"], left # lemma brigante covers briganti; form gattoni covers gattone
  end

  def test_report_key_term_miss_needs_three_uncovered_candidates
    6.times { |i| write_ep("p-2026-02-0#{i + 1}", "Filler text here.", ["- **casa** (A2 noun) — house"]) }
    write_ep("p-2026-02-07", "asino asino asino gatto gatto gatto rete rete rete",
      ["- **casa** (A2 noun) — house"])
    write_ep("p-2026-02-08", "pane pane pane vino vino vino sale sale sale",
      ["- **salire** (B1 verb) — to climb"]) # covers nothing: "salir" vs "sale"

    r = health.report

    assert_equal 8, r.episodes
    assert_equal 2, r.key_term_misses
  end

  def test_report_key_term_miss_covered_candidate_does_not_count
    6.times { |i| write_ep("p-2026-02-0#{i + 1}", "Filler text here.", ["- **casa** (A2 noun) — house"]) }
    write_ep("p-2026-02-07", "asino asino asino gatto gatto gatto rete rete rete",
      ["- **gatto** (A2 noun) — cat"])

    assert_equal 0, health.report.key_term_misses
  end

  # --- rendering ---

  def test_lines_name_the_numbers
    three_episode_fixture

    text = health(durations: {"p-2026-01-01" => 180, "p-2026-01-02" => 60}).lines("p").join("\n")

    assert_includes text, "8 entries (5 unique lemmas)"
    assert_includes text, "repeat share 38%"
    assert_includes text, "lupo×3"
    assert_includes text, "1.5/min"
    assert_includes text, "at B1 50%"
  end

  def test_lines_omit_per_minute_without_durations
    three_episode_fixture

    refute_includes health.lines("p").join("\n"), "/min"
  end

  def test_lines_empty_show
    assert_includes health.lines("p").join("\n"), "no transcripts"
  end

  private

  def health(durations: {})
    VocabHealth.new(episodes_dir: @tmpdir, cutoff: "B1", durations: durations)
  end

  def three_episode_fixture
    write_ep("p-2026-01-01", "La casa nel bosco.", ["- **bosco** (B2 noun) — wood",
      "- **casa** (A2 noun) — house. A building",
      "- **lupo** (B1 noun) — wolf. An animal"])
    write_ep("p-2026-01-02", "Il lupo e la mela.", ["- **lupo** (B1 noun) — wolf. Canine",
      "- **mela** (C1 noun) — apple"])
    write_ep("p-2026-01-03", "La casa, il fiume, il lupo.", ["- **casa** (A2 noun) — home",
      "- **fiume** (B1 noun) — river",
      "- **lupo** (B1 noun) *lupi* — wolf"])
  end

  def write_ep(basename, body, vocab_lines)
    write_raw(basename, body, "## Vocabulary\n\n#{vocab_lines.join("\n")}\n")
  end

  def write_raw(basename, body, vocab)
    File.write(File.join(@tmpdir, "#{basename}_transcript.md"),
      "# Title\n\n## Transcript\n\n#{body}\n\n#{vocab}")
  end
end
