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

  # P18-8 (8): a pinned key word bypasses the re-exposure cap, so its
  # re-explanation is not a repeat the cap controls; the same lemma
  # re-explained outside Key words still is.
  def test_report_repeats_do_not_count_re_explained_key_words
    write_ep("p-2026-01-01", "x", ["- **lupo** (B1 noun) — wolf", "- **mela** (B1 noun) — apple"])
    write_raw("p-2026-01-02", "x", "## Vocabulary\n\n### Key words\n\n- **lupo** (B1 noun) — wolf\n\n" \
      "### Also new\n\n- **mela** (B1 noun) — apple\n")
    write_raw("p-2026-01-03", "x", "## Vocabulary (English, Russian)\n\n### Key words\n\n" \
      "- **lupo** (B1 noun)\n  - wolf\n  - волк\n\n### Also new\n\n- **mela** (B1 noun)\n  - apple\n  - яблоко\n")

    r = health.report

    assert_equal 6, r.entries
    assert_equal 2, r.repeat_entries # mela (ep2, ep3); lupo pinned both times
  end

  def test_key_group_title_matches_the_annotator_heading
    require "vocabulary_annotator"
    assert_equal VocabularyAnnotator::KEY_GROUP_HEADING, "### #{VocabHealth::KEY_GROUP_TITLE}"
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

  # --- --split: before / after / before, last N (P21-1) ---

  def test_split_report_undated_transcripts_are_named_and_left_out_of_every_cohort
    write_ep("p-2026-01-01", "Uno due.", ["- **uno** (B1): one"])
    write_ep("p-2026-01-03", "Tre quattro.", ["- **tre** (B1): three"])
    write_ep("p-special", "Cinque sei.", ["- **cinque** (B1): five"])

    s = health.split_report(split: Date.new(2026, 1, 2))
    out = health.split_lines("p", split: Date.new(2026, 1, 2))

    assert_equal [1, 1, 1], [s[:before], s[:after], s[:before_last]].map(&:episodes)
    assert_equal 1, s[:undated]
    assert_includes out, "  (1 transcripts without a date in the name left out of every cohort)"
  end

  def test_split_report_all_undated_prints_the_header_and_the_note_not_no_transcripts
    write_ep("p-special", "Cinque sei.", ["- **cinque** (B1): five"])

    out = health.split_lines("p", split: Date.new(2026, 1, 2))

    refute_includes out, "p: no transcripts"
    assert_includes out, "  (1 transcripts without a date in the name left out of every cohort)"
  end

  def test_split_report_cohorts_have_the_right_episode_counts
    split_fixture

    s = health.split_report(split: Date.new(2026, 1, 3))

    assert_equal [2, 2, 2], [s[:before], s[:after], s[:before_last]].map(&:episodes)
  end

  def test_split_report_after_cohort_metrics_hand_computed
    split_fixture

    r = health.split_report(split: Date.new(2026, 1, 3))[:after]

    assert_equal 4, r.entries
    assert_equal 3, r.unique_lemmas                # casa fiume lupo
    assert_equal 2, r.repeat_entries               # fiume (ep3) and lupo (ep1, ep2), both in ep4
    assert_equal 1, r.within_repeats               # fiume: explained in ep3, again in ep4
    assert_equal({below: 1, at: 2, plus1: 0, plus2: 1}, r.levels)
    assert_equal 1, r.median_gloss_words           # house, big river, river, wolf
    assert_equal 1, r.prominent_entries            # fiume ×3 in ep4's body
    assert_equal 1, r.drift                        # fiume: big river vs river
  end

  def test_split_report_title_occurrence_makes_an_entry_prominent
    write_raw("p-2026-01-01", "Nothing here.", "## Vocabulary\n\n- **lupo** (B1 noun) — wolf\n", title: "Il lupo")

    r = health.split_report(split: Date.new(2026, 1, 1))[:after]

    assert_equal 1, r.prominent_entries
  end

  def test_split_report_would_have_re_explained_per_after_episode
    split_fixture

    s = health.split_report(split: Date.new(2026, 1, 3))

    # ep3: lupo (B1, ep1) in its body; ep4: bosco (B2, ep1) and fiume (B1, ep3); mela and casa are A2
    assert_equal [["p-2026-01-03", 1], ["p-2026-01-04", 2]], s[:would_have]
  end

  def test_split_lines_render_identical_labels_for_the_three_cohorts
    split_fixture

    out = health.split_lines("p", split: Date.new(2026, 1, 3))
    header = out.find { |l| l.start_with?("metric") }

    assert_match(/before\s+after\s+before, last 2/, header)
    assert_match(/^episodes\s+2\s+2\s+2$/, out.find { |l| l.start_with?("episodes") })
    rows = out.drop_while { |l| l != header }.drop(1).take_while { |l| !l.empty? }
    assert_equal VocabHealth.split_labels("B1"), rows.map { |l| l[/\A.+?(?=\s{2,})/] }
  end

  def test_split_lines_per_minute_is_na_without_durations
    split_fixture

    out = health.split_lines("p", split: Date.new(2026, 1, 3))

    assert_match(%r{^entries per minute \(median\)\s+n/a\s+n/a\s+n/a$}, out.find { |l| l.include?("per minute") })
  end

  def test_split_lines_after_side_empty_names_it_and_renders_before
    split_fixture

    out = health.split_lines("p", split: Date.new(2026, 2, 1))

    assert_includes out, "  no episodes on or after 2026-02-01"
    assert_match(/^episodes\s+4$/, out.find { |l| l.start_with?("episodes") })
  end

  def test_split_lines_before_side_empty_names_it_and_renders_after
    split_fixture

    out = health.split_lines("p", split: Date.new(2025, 1, 1))

    assert_includes out, "  no episodes before 2025-01-01"
    assert_match(/^episodes\s+4$/, out.find { |l| l.start_with?("episodes") })
  end

  def test_split_report_would_have_matches_whole_lemma_or_form_exactly
    write_ep("p-2026-01-01", "x", ["- **salire** (B1 verb) — to climb",
      "- **lupo** (B1 noun) *lupi* — wolf",
      "- **avere paura** (B2 verb) — to be afraid"])
    write_ep("p-2026-01-02", "Salirono. I Lupi, avere paura.", [])

    s = health.split_report(split: Date.new(2026, 1, 2))

    # salirono shares salire's first 5 letters but is not the lemma or a form;
    # lupi is a recorded form (case-insensitive); avere paura matches as a phrase
    assert_equal [["p-2026-01-02", 2]], s[:would_have]
  end

  def test_split_lines_interpretation_note_prints_would_have_counts
    split_fixture

    text = health.split_lines("p", split: Date.new(2026, 1, 3)).join("\n")

    assert_includes text, "partly by construction"
    assert_includes text, "exact lemma/form match in the body"
    assert_includes text, "p-2026-01-03 1, p-2026-01-04 2"
    assert_includes text, "2 of 2 after-episodes"
  end

  def test_split_lines_without_cutoff_say_would_have_cannot_be_derived
    split_fixture

    text = VocabHealth.new(episodes_dir: @tmpdir).split_lines("p", split: Date.new(2026, 1, 3)).join("\n")

    assert_includes text, "cannot be derived"
  end

  def test_split_lines_seeded_sample_is_deterministic
    6.times do |i|
      write_ep("p-2026-03-0#{i + 1}", "x", (1..4).map { |j| "- **w#{i}#{j}** (B1 noun) — gloss #{i}#{j}. More" })
    end
    sample = ->(seed) { health.split_lines("p", split: Date.new(2026, 3, 4), seed: seed).grep(/ · /) }

    first = sample.call(1)

    assert_equal first, sample.call(1)
    assert_equal 30, first.size # 10 per cohort
    assert(first.all? { |l| l.match?(/\A    w\d\d · B1 · gloss \d\d\z/) }, first.inspect)
    refute_equal first, sample.call(2)
  end

  private

  def split_fixture
    write_ep("p-2026-01-01", "Il lupo nel bosco.", ["- **lupo** (B1 noun) — wolf. An animal",
      "- **bosco** (B2 noun) — wood"])
    write_ep("p-2026-01-02", "Il lupo e la mela.", ["- **lupo** (B1 noun) — wolf",
      "- **mela** (A2 noun) — apple"])
    write_ep("p-2026-01-03", "La casa, il lupo, il fiume.", ["- **casa** (A2 noun) — house",
      "- **fiume** (B1 noun) — big river"])
    write_ep("p-2026-01-04", "Il bosco e il fiume, il fiume, il fiume.", ["- **fiume** (B1 noun) — river",
      "- **lupo** (C1 noun) — wolf"])
  end

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

  def write_raw(basename, body, vocab, title: "Title")
    File.write(File.join(@tmpdir, "#{basename}_transcript.md"),
      "# #{title}\n\n## Transcript\n\n#{body}\n\n#{vocab}")
  end
end
