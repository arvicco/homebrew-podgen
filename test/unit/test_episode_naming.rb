# frozen_string_literal: true

require_relative "../test_helper"
require "date"
require "episode_naming"

# P4-9 — EpisodeNaming is the one home of the basename scheme. The table
# is the P3-0 characterization table (test_characterization_filename_scheme).
class TestEpisodeNaming < Minitest::Test
  CONFIGURED = %w[en es].freeze

  # basename => [date, day letter, lang (configured en+es), lang (legacy: no config)]
  # lang nil = matched by NO language (neither the primary nor any configured code).
  TABLE = {
    "pod-2026-01-15" => ["2026-01-15", "", "en", "en"],
    "pod-2026-01-15a" => ["2026-01-15", "a", "en", "en"],
    "pod-2026-01-15z" => ["2026-01-15", "z", "en", "en"],
    "pod-2026-01-15-es" => ["2026-01-15", "", "es", "es"],
    "pod-2026-01-15b-es" => ["2026-01-15", "b", "es", "es"],
    "pod-2026-01-15-ai" => ["2026-01-15", "", "en", nil],
    "pod-2026-01-15-jp" => ["2026-01-15", "", "en", nil],
    "pod-2026-01-15-esp" => ["2026-01-15", "", "en", "en"]
  }.freeze

  def test_parse_table_basenames_yield_podcast_date_letter_language
    TABLE.each do |base, (date, letter, lang, _)|
      expected = {podcast: "pod", date: date, letter: letter, language: lang}
      assert_equal expected, EpisodeNaming.parse(base, languages: CONFIGURED), base
    end
  end

  def test_parse_legacy_unconfigured_tail_is_its_own_language
    TABLE.each do |base, (_, _, _, legacy)|
      expected = legacy || base[/-([a-z]{2})\z/, 1]
      assert_equal expected, EpisodeNaming.parse(base)[:language], base
    end
  end

  def test_parse_no_date_returns_nil
    assert_nil EpisodeNaming.parse("cover")
  end

  def test_parse_date_table_basenames_parse_to_table_date
    TABLE.each do |base, (date, *)|
      assert_equal Date.parse(date), EpisodeNaming.parse_date("/x/#{base}.mp3"), base
    end
    assert_nil EpisodeNaming.parse_date("pod-2026-02-30.mp3")
    assert_nil EpisodeNaming.parse_date("pod.mp3")
  end

  def test_matches_language_configured_table_matches_exactly_one_language
    TABLE.each do |base, (_, _, lang, _)|
      matched = CONFIGURED.select { |c| EpisodeNaming.matches_language?(base, c, languages: CONFIGURED) }
      assert_equal [lang], matched, base
    end
  end

  def test_matches_language_non_en_primary_owns_suffixless_basenames
    langs = %w[sl es]
    assert EpisodeNaming.matches_language?("pod-2026-01-15", "sl", languages: langs)
    refute EpisodeNaming.matches_language?("pod-2026-01-15", "en", languages: langs)
    refute EpisodeNaming.matches_language?("pod-2026-01-15-es", "sl", languages: langs)
    assert_equal "sl", EpisodeNaming.language_of("pod-2026-01-15-ai", languages: langs)
  end

  def test_basename_for_round_trips_table_basenames_without_foreign_tails
    TABLE.each do |base, (date, letter, _, _)|
      next if base.match?(/-(ai|jp|esp)\z/) # title-like tails are not produced by basename_for

      lang = EpisodeNaming.language_suffix(base, languages: CONFIGURED)
      assert_equal base, EpisodeNaming.basename_for("pod", date, letter, language: lang), base
    end
  end

  def test_basename_for_index_maps_through_suffixes
    assert_equal "pod-2026-01-15", EpisodeNaming.basename_for("pod", "2026-01-15", 0)
    assert_equal "pod-2026-01-15a", EpisodeNaming.basename_for("pod", "2026-01-15", 1)
    assert_equal "pod-2026-01-15z-es", EpisodeNaming.basename_for("pod", "2026-01-15", 26, language: "es")
    assert_equal "pod-2026-01-1527", EpisodeNaming.basename_for("pod", "2026-01-15", 27)
  end

  def test_suffixes_and_index_for_are_inverse
    assert_equal [""] + ("a".."z").to_a, EpisodeNaming::SUFFIXES
    EpisodeNaming::SUFFIXES.each_with_index { |s, i| assert_equal i, EpisodeNaming.index_for(s) }
    assert_nil EpisodeNaming.index_for("27")
  end

  def test_primary_basename_strips_only_language_tails
    assert_equal "pod-2026-01-15a", EpisodeNaming.primary_basename("pod-2026-01-15a-es", languages: CONFIGURED)
    assert_equal "pod-2026-01-15-ai", EpisodeNaming.primary_basename("pod-2026-01-15-ai", languages: CONFIGURED)
    assert_equal "pod-2026-01-15", EpisodeNaming.primary_basename("pod-2026-01-15-ai")
  end

  def test_parse_episode_id_accepts_date_and_letter_only
    assert_equal ["2026-03-31", ""], EpisodeNaming.parse_episode_id("2026-03-31")
    assert_equal ["2026-03-31", "b"], EpisodeNaming.parse_episode_id("2026-03-31b")
    assert_nil EpisodeNaming.parse_episode_id("2026-03-31bb")
  end

  def test_primary_basename_re_matches_bare_primary_names_only
    re = EpisodeNaming.primary_basename_re("pod")
    assert_match re, "pod-2026-01-15a"
    refute_match re, "pod-2026-01-15-es"
    refute_match re, "other-2026-01-15"
  end

  def test_each_history_basename_explicit_wins_else_positional
    entries = [
      {"date" => "2026-01-15", "title" => "A"},
      {"date" => "2026-01-15", "title" => "C", "basename" => "pod-2026-01-15b"},
      {"title" => "undated"},
      {"date" => "2026-01-16", "title" => "D"}
    ]
    names = EpisodeNaming.each_history_basename(entries, "pod").map { |e, b| [e["title"], b] }
    assert_equal [["A", "pod-2026-01-15"], ["C", "pod-2026-01-15b"], ["D", "pod-2026-01-16"]], names
  end

  def test_history_entry_index_resolves_letter_through_the_history_mapping
    entries = [
      {"date" => "2026-01-15", "title" => "A", "basename" => "pod-2026-01-15"},
      {"date" => "2026-01-16", "title" => "X"},
      {"date" => "2026-01-15", "title" => "C", "basename" => "pod-2026-01-15b"}
    ]
    assert_equal 0, EpisodeNaming.history_entry_index(entries, "2026-01-15", "")
    assert_nil EpisodeNaming.history_entry_index(entries, "2026-01-15", "a")
    assert_equal 2, EpisodeNaming.history_entry_index(entries, "2026-01-15", "b")
    assert_equal 1, EpisodeNaming.history_entry_index(entries, "2026-01-16", "")
  end

  # Q-54 (P5-2a): an older positional entry and a newer explicit-basename
  # entry resolve to the same slot; HistoryMaps keeps the last one, so the
  # slot lookup must pick that same entry (what the feed shows).
  def test_history_entry_index_mixed_day_agrees_with_history_maps
    require "history_maps"
    require "yaml"
    entries = [
      {"date" => "2026-01-15", "title" => "Old positional"},
      {"date" => "2026-01-15", "title" => "New explicit", "basename" => "pod-2026-01-15"}
    ]
    Dir.mktmpdir("p52a_q54") do |dir|
      path = File.join(dir, "history.yml")
      File.write(path, entries.to_yaml)
      titles, = HistoryMaps.build(history_path: path, podcast_name: "pod", episodes_dir: dir)

      idx = EpisodeNaming.history_entry_index(entries, "2026-01-15", "")
      assert_equal 1, idx
      assert_equal titles["pod-2026-01-15.mp3"], entries[idx]["title"]
    end
  end

  # ── de-configured language: primary sibling on disk (CRPR round 1) ──

  def test_language_suffix_unconfigured_tail_with_primary_sibling_is_a_variant
    Dir.mktmpdir("naming_sibling") do |dir|
      File.write(File.join(dir, "pod-2026-01-15.mp3"), "")
      assert_equal "it", EpisodeNaming.language_suffix("pod-2026-01-15-it", languages: %w[en es], episodes_dir: dir)
      assert_equal "pod-2026-01-15", EpisodeNaming.primary_basename("pod-2026-01-15-it", languages: %w[en es], episodes_dir: dir)
      refute EpisodeNaming.matches_language?("pod-2026-01-15-it", "en", languages: %w[en es], episodes_dir: dir)
    end
  end

  def test_language_suffix_unconfigured_tail_with_script_sibling_is_a_variant
    Dir.mktmpdir("naming_sibling") do |dir|
      File.write(File.join(dir, "pod-2026-01-15_script.md"), "")
      assert_equal "it", EpisodeNaming.language_suffix("pod-2026-01-15-it", languages: %w[en es], episodes_dir: dir)
    end
  end

  def test_language_suffix_unconfigured_tail_without_sibling_is_primary
    Dir.mktmpdir("naming_sibling") do |dir|
      File.write(File.join(dir, "pod-2026-01-15-ai_script.md"), "")
      assert_nil EpisodeNaming.language_suffix("pod-2026-01-15-ai", languages: %w[en es], episodes_dir: dir)
      assert_nil EpisodeNaming.language_suffix("pod-2026-01-15-it", languages: %w[en es])
    end
  end
end
