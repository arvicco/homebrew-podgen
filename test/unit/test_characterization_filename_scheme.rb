# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "date"
require "history_maps"
require "episode_history"
require "episode_filtering"
require "episode_artifacts"
require "site_generator"
require "podcast_config"
require "cli/stats_command"

# P3-0 H2 — characterization harness for the episode filename scheme
# (FROZEN DOMAIN, CLAUDE.md rule 4). The `<podcast>-<date><a-z>` rule
# and the `-<lang>` rule are implemented separately in HistoryMaps,
# EpisodeHistory, StatsCommand#build_duration_map, EpisodeFiltering,
# SiteGenerator, PodcastConfig#language_for_episode and EpisodeArtifacts.
# These tests pin what each one does TODAY on one shared basename table,
# so a consolidation cannot change output selection or naming with the
# suite green. Tests named `..._diverges_...` pin a CURRENT disagreement
# between implementations: a consolidation must resolve it consciously
# (and update the pin in the same commit), never by accident.
class TestCharacterizationFilenameScheme < Minitest::Test
  CONFIGURED = %w[en es].freeze

  # basename => [date, day letter, lang (configured en+es), lang (legacy: no config)]
  # lang nil = matched by NO language (neither "en" nor any configured code).
  TABLE = {
    "pod-2026-01-15" => ["2026-01-15", "", "en", "en"],
    "pod-2026-01-15a" => ["2026-01-15", "a", "en", "en"],
    "pod-2026-01-15z" => ["2026-01-15", "z", "en", "en"],
    "pod-2026-01-15-es" => ["2026-01-15", "", "es", "es"],
    "pod-2026-01-15b-es" => ["2026-01-15", "b", "es", "es"],
    # title-like / unconfigured two-letter tails (P1-15, Q-06)
    "pod-2026-01-15-ai" => ["2026-01-15", "", "en", nil],
    "pod-2026-01-15-jp" => ["2026-01-15", "", "en", nil],
    # three-letter tail is never a language suffix
    "pod-2026-01-15-esp" => ["2026-01-15", "", "en", "en"]
  }.freeze

  # Day-letter parser shared verbatim by ScrapCommand#resolve_from_path and
  # the validators' name pattern: date followed by an optional single letter.
  DAY_LETTER_RE = /(\d{4}-\d{2}-\d{2})([a-z])?/

  def setup
    @tmpdir = Dir.mktmpdir("podgen_char_filename")
    @podcast_dir = File.join(@tmpdir, "pod")
    @episodes_dir = File.join(@podcast_dir, "episodes")
    @history_path = File.join(@podcast_dir, "history.yml")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # ── shared table: every parser agrees per basename ──────────────────

  def test_parse_date_table_basenames_all_parse_to_table_date
    TABLE.each do |base, (date, *)|
      assert_equal Date.parse(date), EpisodeFiltering.parse_date("#{base}.mp3"), base
      assert_equal Date.parse(date), EpisodeFiltering.parse_date(File.join(@episodes_dir, "#{base}-es_script.md")), base
    end
  end

  def test_day_letter_table_basenames_all_yield_table_letter
    TABLE.each do |base, (_, letter, *)|
      match = base.match(DAY_LETTER_RE)
      assert_equal letter, match[2].to_s, base
    end
  end

  def test_matches_language_configured_table_basenames_match_exactly_one_language
    TABLE.each do |base, (_, _, lang, _)|
      matched = CONFIGURED.select { |code| EpisodeFiltering.matches_language?(base, code, languages: CONFIGURED) }
      assert_equal [lang], matched, base
    end
  end

  def test_matches_language_legacy_table_basenames_match_legacy_language
    TABLE.each do |base, (_, _, _, legacy)|
      matched = %w[en es ai jp].select { |code| EpisodeFiltering.matches_language?(base, code) }
      expected = if legacy
        [legacy]
      else
        # legacy rule: the unconfigured tail is "its own language", not English
        [base[/-([a-z]{2})\z/, 1]]
      end
      assert_equal expected, matched, base
    end
  end

  def test_language_for_episode_table_basenames_agree_with_episode_filtering
    config = config_with_languages(CONFIGURED)
    TABLE.each do |base, (_, _, lang, _)|
      assert_equal lang, config.language_for_episode(base), base
      assert EpisodeFiltering.matches_language?(base, config.language_for_episode(base), languages: CONFIGURED), base
    end
  end

  def test_scan_episodes_table_files_partition_by_configured_language
    TABLE.each_key { |base| touch("#{base}.mp3") }
    gen = site_generator(CONFIGURED)

    by_lang = CONFIGURED.to_h { |code| [code, gen.send(:scan_episodes, code).map { |e| e[:basename] }.sort] }

    CONFIGURED.each do |code|
      expected = TABLE.select { |_, row| row[2] == code }.keys.sort
      assert_equal expected, by_lang[code], code
    end
    assert_equal TABLE.keys.sort, by_lang.values.flatten.sort, "every table file lands in exactly one language"
  end

  def test_scan_episodes_table_files_dates_match_parse_date
    TABLE.each_key { |base| touch("#{base}.mp3") }
    gen = site_generator(CONFIGURED)

    CONFIGURED.each do |code|
      gen.send(:scan_episodes, code).each do |ep|
        assert_equal Date.parse(TABLE.fetch(ep[:basename])[0]), ep[:date], ep[:basename]
      end
    end
  end

  # ── `-<lang>` rule: SiteGenerator lang-nav derivation vs HistoryMaps ──

  def test_build_lang_nav_episode_round_trips_table_basenames_through_lang_suffix
    TABLE.each_key { |base| touch("#{base}.mp3") }
    touch("pod-2026-01-15a-es.mp3")
    touch("pod-2026-01-15-ai-es.mp3")
    gen = site_generator(CONFIGURED)

    cases = {
      ["pod-2026-01-15", "en"] => "../es/episodes/pod-2026-01-15-es.html",
      ["pod-2026-01-15a", "en"] => "../es/episodes/pod-2026-01-15a-es.html",
      ["pod-2026-01-15-ai", "en"] => "../es/episodes/pod-2026-01-15-ai-es.html",
      ["pod-2026-01-15-es", "es"] => "../../episodes/pod-2026-01-15.html",
      ["pod-2026-01-15b-es", "es"] => nil # pod-2026-01-15b.mp3 not on disk → greyed out
    }
    cases.each do |(base, current), expected|
      other = (current == "en") ? "es" : "en"
      nav = gen.send(:build_lang_nav_episode, current, {basename: base})
      actual = nav.find { |n| n[:code] == other }[:index_path]
      if expected
        assert_equal expected, actual, "#{base} from #{current}"
      else
        assert_nil actual, "#{base} from #{current}"
      end
    end
  end

  def test_build_history_maps_lang_filenames_match_site_lang_nav_target
    write_history([
      {"date" => "2026-01-15", "title" => "T", "duration" => 10.0, "basename" => "pod-2026-01-15a"}
    ])
    title_map, = HistoryMaps.build(history_path: @history_path, podcast_name: "pod",
      episodes_dir: @episodes_dir, languages: CONFIGURED)

    assert_equal %w[pod-2026-01-15a-es.mp3 pod-2026-01-15a.mp3], title_map.keys.sort
    # SiteGenerator derives the same target name from the primary basename
    touch("pod-2026-01-15a-es.mp3")
    nav = site_generator(CONFIGURED).send(:build_lang_nav_episode, "en", {basename: "pod-2026-01-15a"})
    assert_equal "../es/episodes/pod-2026-01-15a-es.html", nav.last[:index_path]
  end

  # ── `<podcast>-<date><a-z>` rule: generators agree on positional history ──

  def test_build_positional_history_history_maps_and_stats_agree
    write_history(positional_history)

    _, _, hm_durations = HistoryMaps.build(history_path: @history_path, podcast_name: "pod",
      episodes_dir: @episodes_dir, languages: [])
    stats_durations = stats_duration_map

    expected = {
      "pod-2026-01-15.mp3" => 10.0, "pod-2026-01-15a.mp3" => 11.0,
      "pod-2026-01-15b.mp3" => 12.0, "pod-2026-01-16.mp3" => 20.0
    }
    assert_equal expected, hm_durations
    assert_equal expected, stats_durations
  end

  def test_build_positional_history_names_match_table_day_letter_parse
    write_history(positional_history)
    title_map, = HistoryMaps.build(history_path: @history_path, podcast_name: "pod",
      episodes_dir: @episodes_dir, languages: [])

    title_map.each do |fname, title|
      m = File.basename(fname, ".mp3").match(DAY_LETTER_RE)
      same_day = positional_history.select { |e| e["date"] == m[1] }
      assert_equal title, same_day[HistoryMaps::SUFFIXES.index(m[2].to_s)]["title"], fname
    end
  end

  def test_remove_by_date_positional_history_letter_index_removes_the_mapped_entry
    write_history(positional_history)
    title_map, = HistoryMaps.build(history_path: @history_path, podcast_name: "pod",
      episodes_dir: @episodes_dir, languages: [])

    title_map.each do |fname, title|
      write_history(positional_history)
      m = File.basename(fname, ".mp3").match(DAY_LETTER_RE)
      removed = EpisodeHistory.new(@history_path).remove_by_date!(m[1], HistoryMaps::SUFFIXES.index(m[2].to_s))
      assert_equal title, removed["title"], fname
    end
  end

  def test_suffixes_constants_are_identical_across_implementations
    expected = [""] + ("a".."z").to_a
    assert_equal expected, HistoryMaps::SUFFIXES
    assert_equal expected, PodgenCLI::StatsCommand::SUFFIXES
    assert_equal expected, EpisodeNaming::SUFFIXES
    assert_equal DAY_LETTER_RE, EpisodeNaming::DAY_LETTER_RE
  end

  def test_build_more_than_27_same_day_entries_falls_back_to_numeric_suffix_in_both
    entries = (0..27).map { |i| {"date" => "2026-01-15", "title" => "E#{i}", "duration" => i.to_f} }
    write_history(entries)

    _, _, hm = HistoryMaps.build(history_path: @history_path, podcast_name: "pod",
      episodes_dir: @episodes_dir, languages: [])
    stats = stats_duration_map

    assert_equal 26.0, hm["pod-2026-01-15z.mp3"]
    assert_equal 27.0, hm["pod-2026-01-1527.mp3"], "28th same-day entry gets the numeric index"
    assert_equal hm, stats
    assert_equal Date.new(2026, 1, 15), EpisodeFiltering.parse_date("pod-2026-01-1527.mp3")
  end

  def test_build_podcast_name_derived_from_episodes_dir_parent_in_stats_and_site
    write_history([{"date" => "2026-01-15", "title" => "T", "duration" => 5.0}])

    assert_equal ["pod-2026-01-15.mp3"], stats_duration_map.keys
    assert_equal "pod", site_generator(%w[en]).instance_variable_get(:@podcast_name)
  end

  # ── Q-44 divergences, resolved by P4-9 (EpisodeNaming) ──────────────

  # Stats honours an entry's explicit basename exactly as HistoryMaps does,
  # so after a middle scrap the two still agree (was: Stats re-derived
  # positionally and keyed C as "...15a").
  def test_build_explicit_basename_after_middle_scrap_history_maps_and_stats_agree
    write_history([
      {"date" => "2026-01-15", "title" => "A", "duration" => 10.0, "basename" => "pod-2026-01-15"},
      {"date" => "2026-01-15", "title" => "C", "duration" => 30.0, "basename" => "pod-2026-01-15b"}
    ])

    _, _, hm = HistoryMaps.build(history_path: @history_path, podcast_name: "pod",
      episodes_dir: @episodes_dir, languages: [])

    assert_equal({"pod-2026-01-15.mp3" => 10.0, "pod-2026-01-15b.mp3" => 30.0}, hm)
    assert_equal hm, stats_duration_map
  end

  # EpisodeHistory#remove_by_date! resolves the letter through the same
  # mapping HistoryMaps uses: after a middle scrap, letter "b" (index 2)
  # removes the "b" entry and letter "a" (index 1) resolves to nothing
  # (was: purely positional, index 1 removed the "b" entry).
  def test_remove_by_date_explicit_basename_after_middle_scrap_resolves_letter_via_history_mapping
    entries = [
      {"date" => "2026-01-15", "title" => "A", "basename" => "pod-2026-01-15"},
      {"date" => "2026-01-15", "title" => "C", "basename" => "pod-2026-01-15b"}
    ]
    write_history(entries)
    assert_nil EpisodeHistory.new(@history_path).remove_by_date!("2026-01-15", 1)

    removed = EpisodeHistory.new(@history_path).remove_by_date!("2026-01-15", 2)
    assert_equal "pod-2026-01-15b", removed["basename"]
  end

  # Stats maps the per-language filenames HistoryMaps maps (was: primary
  # only; language mp3s fell through to ffprobe/size estimate).
  def test_build_language_variants_history_maps_and_stats_agree
    write_history([{"date" => "2026-01-15", "title" => "T", "duration" => 10.0}])

    _, _, hm = HistoryMaps.build(history_path: @history_path, podcast_name: "pod",
      episodes_dir: @episodes_dir, languages: CONFIGURED)

    assert_equal({"pod-2026-01-15.mp3" => 10.0, "pod-2026-01-15-es.mp3" => 10.0}, hm)
    assert_equal hm, stats_duration_map(CONFIGURED)
  end

  # Divergent by design (P4-9, CRPR round 1): EpisodeArtifacts (what scrap
  # deletes and move renames) treats ANY `<base>-*` file as part of the
  # episode, so a language commented out of the config is not left behind;
  # the configured-language rule is for attribution only, where
  # "pod-2026-01-15-ai" is its own English episode.
  def test_for_basename_unconfigured_dash_tail_diverges_from_language_rule
    %w[pod-2026-01-15.mp3 pod-2026-01-15-es.mp3 pod-2026-01-15-ai.mp3 pod-2026-01-15-ai_script.md
      pod-2026-01-15-ai-es.mp3 pod-2026-01-15-esp.mp3].each { |f| touch(f) }

    names = EpisodeArtifacts.for_basename(@episodes_dir, "pod-2026-01-15").map { |f| File.basename(f) }
    assert_equal %w[pod-2026-01-15-ai-es.mp3 pod-2026-01-15-ai.mp3 pod-2026-01-15-ai_script.md
      pod-2026-01-15-es.mp3 pod-2026-01-15-esp.mp3 pod-2026-01-15.mp3], names
    assert EpisodeFiltering.matches_language?("pod-2026-01-15-ai", "en", languages: CONFIGURED),
      "the -ai file is its own English episode under the configured-language rule"
    assert_equal 2, EpisodeArtifacts.method(:for_basename).arity, "no languages: narrowing for delete/move"
  end

  # The primary language comes from config (languages.first) in
  # SiteGenerator/EpisodeFiltering as in PodcastConfig: a non-en primary
  # lists its suffix-less episodes on its primary page (was: hard-coded
  # "en", so the 'sl' page listed nothing).
  def test_scan_episodes_non_en_primary_agrees_with_language_for_episode
    touch("pod-2026-01-15.mp3")
    touch("pod-2026-01-15-es.mp3")
    langs = %w[sl es]

    gen = site_generator(langs)
    assert_equal ["pod-2026-01-15"], gen.send(:scan_episodes, "sl").map { |e| e[:basename] },
      "primary 'sl' site page lists the suffix-less episode"
    assert_equal ["pod-2026-01-15-es"], gen.send(:scan_episodes, "es").map { |e| e[:basename] }
    assert_equal "sl", config_with_languages(langs).language_for_episode("pod-2026-01-15")
  end

  # ── artifact taxonomy across the table ──────────────────────────────

  def test_for_basename_table_primary_bases_own_their_lang_variants_not_siblings
    files = %w[
      pod-2026-01-15.mp3 pod-2026-01-15_script.md pod-2026-01-15_timestamps.json
      pod-2026-01-15-es.mp3 pod-2026-01-15-es_script.md pod-2026-01-15_concat.mp3
      pod-2026-01-15a.mp3 pod-2026-01-15a_script.md pod-2026-01-15a-es.mp3
      pod-2026-01-15b-es.mp3
    ]
    files.each { |f| touch(f) }

    expectations = {
      "pod-2026-01-15" => %w[pod-2026-01-15-es.mp3 pod-2026-01-15-es_script.md pod-2026-01-15.mp3
        pod-2026-01-15_script.md pod-2026-01-15_timestamps.json],
      "pod-2026-01-15a" => %w[pod-2026-01-15a-es.mp3 pod-2026-01-15a.mp3 pod-2026-01-15a_script.md],
      "pod-2026-01-15-es" => %w[pod-2026-01-15-es.mp3 pod-2026-01-15-es_script.md],
      "pod-2026-01-15b" => %w[pod-2026-01-15b-es.mp3],
      "pod-2026-01-15z" => []
    }
    expectations.each do |base, expected|
      names = EpisodeArtifacts.for_basename(@episodes_dir, base).map { |f| File.basename(f) }
      assert_equal expected, names, base
    end
  end

  # ── empty inputs ────────────────────────────────────────────────────

  def test_build_empty_history_all_generators_return_empty
    write_history([])

    assert_equal [{}, {}, {}], HistoryMaps.build(history_path: @history_path, podcast_name: "pod",
      episodes_dir: @episodes_dir, languages: CONFIGURED)
    assert_equal({}, stats_duration_map)
    assert_nil EpisodeHistory.new(@history_path).remove_by_date!("2026-01-15", 0)
  end

  def test_scan_episodes_empty_dir_returns_empty_for_every_language
    gen = site_generator(CONFIGURED)
    CONFIGURED.each { |code| assert_equal [], gen.send(:scan_episodes, code) }
    assert_equal [], EpisodeArtifacts.for_basename(@episodes_dir, "pod-2026-01-15")
  end

  # ── StatsCommand date range uses the same date rule as parse_date ────

  def test_gather_stats_date_range_and_durations_follow_shared_rules
    %w[pod-2026-01-15.mp3 pod-2026-01-15a.mp3 pod-2026-03-02-es.mp3 pod-2026-02-30.mp3].each { |f| touch(f) }
    write_history([
      {"date" => "2026-01-15", "title" => "A", "duration" => 60.0},
      {"date" => "2026-01-15", "title" => "B", "duration" => 120.0}
    ])
    config = StatsGatherConfig.new(@episodes_dir, @history_path, File.join(@podcast_dir, "feed.xml"), @podcast_dir)

    result = PodcastConfig.stub(:new, config) do
      AudioAssembler.stub(:probe_duration, nil) do
        PodgenCLI::StatsCommand.allocate.send(:gather_stats, "pod")
      end
    end

    # 2026-02-30 is not a date in either implementation
    assert_nil EpisodeFiltering.parse_date("pod-2026-02-30.mp3")
    assert_equal " (Jan 15 – Mar 02, 2026)", result[:date_range]
    durations = result[:episodes].to_h { |e| [e[:filename], e[:duration_str]] }
    assert_equal "1:00", durations["pod-2026-01-15.mp3"]
    assert_equal "2:00", durations["pod-2026-01-15a.mp3"]
  end

  private

  StatsGatherConfig = Struct.new(:episodes_dir, :history_path, :feed_path, :podcast_dir) do
    def load_env! = nil
    def language_codes = %w[en]
    def type = "news"
    def image = nil
    def base_url = nil
  end

  SiteFakeConfig = Struct.new(:episodes_dir, :languages, :base_url, :history_path, :title,
    :description, :image, :site_config, :site_css_path, :favicon_path, keyword_init: true)

  def positional_history
    [
      {"date" => "2026-01-15", "title" => "A", "duration" => 10.0},
      {"date" => "2026-01-15", "title" => "B", "duration" => 11.0},
      {"date" => "2026-01-15", "title" => "C", "duration" => 12.0},
      {"date" => "2026-01-16", "title" => "D", "duration" => 20.0}
    ]
  end

  def touch(name)
    File.write(File.join(@episodes_dir, name), "x" * 10)
  end

  def write_history(entries)
    File.write(@history_path, entries.to_yaml)
  end

  def stats_duration_map(language_codes = [])
    config = Struct.new(:episodes_dir, :history_path, :language_codes).new(@episodes_dir, @history_path, language_codes)
    PodgenCLI::StatsCommand.allocate.send(:build_duration_map, config)
  end

  def config_with_languages(codes)
    config = PodcastConfig.allocate
    langs = codes.map { |c| {"code" => c} }
    config.define_singleton_method(:languages) { langs }
    config
  end

  def site_generator(codes)
    config = SiteFakeConfig.new(
      episodes_dir: @episodes_dir, languages: codes.map { |c| {"code" => c} },
      base_url: nil, history_path: @history_path, title: "Pod", description: "D",
      image: nil, site_config: {}, site_css_path: nil, favicon_path: nil
    )
    SiteGenerator.new(config: config)
  end
end
