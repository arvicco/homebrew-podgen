# frozen_string_literal: true

require_relative "../test_helper"
require "date"
require "optparse"
require "cli/episode_selector"

class TestEpisodeDateParser < Minitest::Test
  TODAY = Date.new(2026, 5, 16)

  # ── Format matrix ──────────────────────────────────────────────────

  def test_parse_full_iso
    assert_equal [Date.new(2026, 3, 31), nil],
      PodgenCLI::EpisodeSelector::DateParser.parse("2026-03-31", today: TODAY)
  end

  def test_parse_full_iso_with_suffix
    assert_equal [Date.new(2026, 3, 31), "b"],
      PodgenCLI::EpisodeSelector::DateParser.parse("2026-03-31b", today: TODAY)
  end

  def test_parse_compact_yyyymmdd
    assert_equal [Date.new(2026, 3, 31), nil],
      PodgenCLI::EpisodeSelector::DateParser.parse("20260331", today: TODAY)
  end

  def test_parse_compact_yyyymmdd_with_suffix
    assert_equal [Date.new(2026, 3, 31), "b"],
      PodgenCLI::EpisodeSelector::DateParser.parse("20260331b", today: TODAY)
  end

  def test_parse_mm_dd_uses_current_year
    assert_equal [Date.new(2026, 3, 31), nil],
      PodgenCLI::EpisodeSelector::DateParser.parse("03-31", today: TODAY)
  end

  def test_parse_mm_dd_with_suffix
    assert_equal [Date.new(2026, 3, 31), "a"],
      PodgenCLI::EpisodeSelector::DateParser.parse("03-31a", today: TODAY)
  end

  def test_parse_mm_dd_single_digit_month
    assert_equal [Date.new(2026, 3, 31), nil],
      PodgenCLI::EpisodeSelector::DateParser.parse("3-31", today: TODAY)
  end

  def test_parse_mm_dd_single_digit_month_and_day
    assert_equal [Date.new(2026, 3, 1), nil],
      PodgenCLI::EpisodeSelector::DateParser.parse("3-1", today: TODAY)
  end

  def test_parse_mmdd_uses_current_year
    assert_equal [Date.new(2026, 3, 31), nil],
      PodgenCLI::EpisodeSelector::DateParser.parse("0331", today: TODAY)
  end

  def test_parse_mmdd_with_suffix
    assert_equal [Date.new(2026, 3, 31), "a"],
      PodgenCLI::EpisodeSelector::DateParser.parse("0331a", today: TODAY)
  end

  def test_parse_dd_uses_current_year_and_month
    assert_equal [Date.new(2026, 5, 31), nil],
      PodgenCLI::EpisodeSelector::DateParser.parse("31", today: TODAY)
  end

  def test_parse_single_digit_day
    assert_equal [Date.new(2026, 5, 5), nil],
      PodgenCLI::EpisodeSelector::DateParser.parse("5", today: TODAY)
  end

  def test_parse_dd_with_suffix
    assert_equal [Date.new(2026, 5, 5), "b"],
      PodgenCLI::EpisodeSelector::DateParser.parse("5b", today: TODAY)
  end

  # ── Error cases ────────────────────────────────────────────────────

  def test_parse_rejects_invalid_month
    assert_raises(ArgumentError) do
      PodgenCLI::EpisodeSelector::DateParser.parse("13-01", today: TODAY)
    end
  end

  def test_parse_rejects_invalid_day
    assert_raises(ArgumentError) do
      PodgenCLI::EpisodeSelector::DateParser.parse("02-31", today: TODAY)
    end
  end

  def test_parse_rejects_garbage
    assert_raises(ArgumentError) do
      PodgenCLI::EpisodeSelector::DateParser.parse("abc", today: TODAY)
    end
  end

  def test_parse_rejects_empty
    assert_raises(ArgumentError) do
      PodgenCLI::EpisodeSelector::DateParser.parse("", today: TODAY)
    end
  end

  def test_parse_rejects_six_digit_yymmdd
    # Ambiguous and not supported — must error rather than silently misparse.
    assert_raises(ArgumentError) do
      PodgenCLI::EpisodeSelector::DateParser.parse("260331", today: TODAY)
    end
  end

  def test_error_message_lists_supported_forms
    err = assert_raises(ArgumentError) do
      PodgenCLI::EpisodeSelector::DateParser.parse("nope", today: TODAY)
    end
    assert_match(/YYYY-MM-DD/, err.message)
    assert_match(/YYYYMMDD/, err.message)
    assert_match(/MM-DD/, err.message)
    assert_match(/MMDD/, err.message)
    assert_match(/DD/, err.message)
  end

  # ── extract_ymd (characterization, direct calls) ─────────────────

  def test_extract_ymd_full_iso
    assert_equal [2026, 3, 31],
      PodgenCLI::EpisodeSelector::DateParser.extract_ymd("2026-03-31", TODAY)
  end

  def test_extract_ymd_compact_yyyymmdd
    assert_equal [2026, 3, 31],
      PodgenCLI::EpisodeSelector::DateParser.extract_ymd("20260331", TODAY)
  end

  def test_extract_ymd_mm_dd_defaults_year
    assert_equal [2026, 3, 31],
      PodgenCLI::EpisodeSelector::DateParser.extract_ymd("3-31", TODAY)
  end

  def test_extract_ymd_mmdd_defaults_year
    assert_equal [2026, 3, 31],
      PodgenCLI::EpisodeSelector::DateParser.extract_ymd("0331", TODAY)
  end

  def test_extract_ymd_dd_defaults_year_and_month
    assert_equal [2026, 5, 31],
      PodgenCLI::EpisodeSelector::DateParser.extract_ymd("31", TODAY)
  end

  def test_extract_ymd_single_digit_day
    assert_equal [2026, 5, 5],
      PodgenCLI::EpisodeSelector::DateParser.extract_ymd("5", TODAY)
  end

  def test_extract_ymd_unsupported_form_returns_nil
    assert_nil PodgenCLI::EpisodeSelector::DateParser.extract_ymd("260331", TODAY)
    assert_nil PodgenCLI::EpisodeSelector::DateParser.extract_ymd("abc", TODAY)
  end

  # ── strip_suffix (characterization, direct calls) ────────────────

  def test_strip_suffix_digit_body_with_letter
    assert_equal ["15", "a"], PodgenCLI::EpisodeSelector::DateParser.strip_suffix("15a")
  end

  def test_strip_suffix_no_suffix
    assert_equal ["15", nil], PodgenCLI::EpisodeSelector::DateParser.strip_suffix("15")
  end

  def test_strip_suffix_bare_letter_kept_whole
    # A lone letter has an empty body after stripping — not a date suffix.
    assert_equal ["a", nil], PodgenCLI::EpisodeSelector::DateParser.strip_suffix("a")
  end

  def test_strip_suffix_alpha_body_kept_whole
    assert_equal ["abc", nil], PodgenCLI::EpisodeSelector::DateParser.strip_suffix("abc")
  end
end

class TestEpisodeSelectorMixin < Minitest::Test
  # Minimal harness that uses the mixin the same way a real command will.
  class Harness
    include PodgenCLI::EpisodeSelector

    attr_reader :args_after_extract

    def initialize(argv, today: Date.new(2026, 5, 16))
      @today = today
      OptionParser.new do |opts|
        add_episode_selection_options!(opts)
      end.parse!(argv)
      extract_positional_date!(argv)
      @args_after_extract = argv.dup
      validate_episode_selection!
    end

    private

    def episode_selector_today_override = @today
  end

  def test_date_flag_sets_episode_date
    h = Harness.new(["--date", "2026-03-31"])
    assert_equal Date.new(2026, 3, 31), h.episode_date
    assert_nil h.episode_suffix
    assert_nil h.last_n
  end

  def test_date_flag_with_suffix
    h = Harness.new(["--date", "2026-03-31b"])
    assert_equal Date.new(2026, 3, 31), h.episode_date
    assert_equal "b", h.episode_suffix
  end

  def test_positional_date_equivalent_to_flag
    h = Harness.new(["2026-03-31"])
    assert_equal Date.new(2026, 3, 31), h.episode_date
    assert_empty h.args_after_extract
  end

  def test_positional_short_form_uses_current_month
    h = Harness.new(["5"])
    assert_equal Date.new(2026, 5, 5), h.episode_date
  end

  def test_positional_with_suffix
    h = Harness.new(["0331a"])
    assert_equal Date.new(2026, 3, 31), h.episode_date
    assert_equal "a", h.episode_suffix
  end

  def test_positional_and_flag_together_is_error
    assert_raises(OptionParser::ParseError) do
      Harness.new(["--date", "2026-03-31", "2026-04-01"])
    end
  end

  def test_date_and_last_mutually_exclusive
    assert_raises(OptionParser::ParseError) do
      Harness.new(["--date", "2026-03-31", "--last", "3"])
    end
  end

  def test_last_n
    h = Harness.new(["--last", "5"])
    assert_equal 5, h.last_n
    assert_nil h.episode_date
  end

  def test_no_selection_means_no_episode
    h = Harness.new([])
    assert_nil h.episode_date
    assert_nil h.episode_suffix
    assert_nil h.last_n
  end

  def test_non_date_positional_is_left_for_caller
    # Caller's reject_leftover_args! will then error on this.
    h = Harness.new(["random-thing"])
    assert_equal ["random-thing"], h.args_after_extract
    assert_nil h.episode_date
  end

  def test_invalid_positional_date_raises
    # Looks like a date token (digits + hyphens) but doesn't parse.
    assert_raises(OptionParser::ParseError) do
      Harness.new(["02-31"])
    end
  end

  def test_positional_single_digit_day
    # Documented short form: `podgen <cmd> mypod 1` resolves to day 1 of
    # the current month. Single-digit positionals are accepted on purpose.
    h = Harness.new(["1"])
    assert_equal Date.new(2026, 5, 1), h.episode_date
  end

  def test_raw_episode_id_preserves_raw_form
    h = Harness.new(["0331b"])
    assert_equal "0331b", h.raw_episode_id
  end

  def test_add_date_option_alone
    # Commands that only want --date (no --last) use add_date_option!
    harness = Class.new do
      include PodgenCLI::EpisodeSelector
      def initialize(argv)
        OptionParser.new { |o| add_date_option!(o) }.parse!(argv)
        extract_positional_date!(argv)
        validate_episode_selection!
      end
      private
      def episode_selector_today_override = Date.new(2026, 5, 16)
    end
    h = harness.new(["--date", "2026-03-31"])
    assert_equal Date.new(2026, 3, 31), h.episode_date
    assert_nil h.last_n
  end

  # ── english_episode_basenames ─────────────────────────────────────

  class FakeConfig
    attr_reader :episodes_dir
    def initialize(dir); @episodes_dir = dir; end
  end

  def with_episodes_dir
    Dir.mktmpdir("ep_dir") do |dir|
      yield FakeConfig.new(dir), dir
    end
  end

  def test_english_episode_basenames_returns_base_mp3s
    with_episodes_dir do |config, dir|
      File.write(File.join(dir, "pod-2026-05-14.mp3"), "")
      File.write(File.join(dir, "pod-2026-05-16.mp3"), "")
      h = Harness.new([])
      assert_equal %w[pod-2026-05-14 pod-2026-05-16], h.english_episode_basenames(config)
    end
  end

  def test_english_episode_basenames_excludes_language_variants
    with_episodes_dir do |config, dir|
      File.write(File.join(dir, "pod-2026-05-16.mp3"), "")
      File.write(File.join(dir, "pod-2026-05-16-jp.mp3"), "")
      File.write(File.join(dir, "pod-2026-05-16-it.mp3"), "")
      h = Harness.new([])
      assert_equal %w[pod-2026-05-16], h.english_episode_basenames(config)
    end
  end

  def test_english_episode_basenames_finds_language_pipeline_episodes_without_scripts
    # Regression check that mirrors the bajke bug: language-pipeline podcasts
    # never produce _script.md, but every episode has a .mp3. The new helper
    # should find them where english_script_basenames does not.
    with_episodes_dir do |config, dir|
      File.write(File.join(dir, "pod-2026-05-16.mp3"), "")
      File.write(File.join(dir, "pod-2026-05-16_transcript.md"), "")
      h = Harness.new([])
      assert_equal %w[pod-2026-05-16], h.english_episode_basenames(config)
      assert_empty h.english_script_basenames(config)
    end
  end

  def test_english_episode_basenames_empty_when_dir_empty
    with_episodes_dir do |config, _|
      h = Harness.new([])
      assert_empty h.english_episode_basenames(config)
    end
  end

  def test_add_date_option_rejects_last_flag
    harness = Class.new do
      include PodgenCLI::EpisodeSelector
      def initialize(argv)
        OptionParser.new { |o| add_date_option!(o) }.parse!(argv)
      end
    end
    assert_raises(OptionParser::InvalidOption) do
      harness.new(["--last", "3"])
    end
  end

  def test_normalized_episode_id_canonical_form
    h = Harness.new(["0331b"])
    assert_equal "2026-03-31b", h.normalized_episode_id
  end

  def test_normalized_episode_id_no_suffix
    h = Harness.new(["2026-03-31"])
    assert_equal "2026-03-31", h.normalized_episode_id
  end

  def test_normalized_episode_id_nil_without_date
    h = Harness.new([])
    assert_nil h.normalized_episode_id
  end
end
