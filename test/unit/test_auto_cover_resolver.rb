# frozen_string_literal: true

require_relative "../test_helper"
require "auto_cover_resolver"

class TestAutoCoverResolver < Minitest::Test
  def setup
    @episodes_dir = Dir.mktmpdir("podgen_acr_episodes")
    @basename = "show-2026-04-25"
    @tmp_imgs = Dir.mktmpdir("podgen_acr_tmp_imgs")
    @candidates = (1..3).map do |i|
      path = File.join(@tmp_imgs, "c#{i}.jpg")
      File.binwrite(path, "img-bytes-#{i}")
      { url: "https://x.com/c#{i}.jpg", path: path, bytes: 30_000, ext: ".jpg" }
    end
  end

  def teardown
    FileUtils.rm_rf(@episodes_dir)
    FileUtils.rm_rf(@tmp_imgs)
  end

  def test_returns_winner_when_top_score_above_threshold
    ranked = [
      @candidates[0].merge(score: 18, has_title_text: true,  has_overlay_watermark: false, vetoed: false, reasons: ""),
      @candidates[1].merge(score: 14, has_title_text: false, has_overlay_watermark: false, vetoed: false, reasons: ""),
      @candidates[2].merge(score: 10, has_title_text: false, has_overlay_watermark: false, vetoed: false, reasons: "")
    ]
    result = build_resolver(@candidates, ranked).try(
      title: "T", description: "D", episodes_dir: @episodes_dir, basename: @basename
    )

    expected_winner = File.join(@episodes_dir, "#{@basename}_cover1.jpg")
    assert_equal expected_winner, result[:winner_path]
    assert File.exist?(expected_winner)
    assert_equal 3, result[:top_paths].length
    result[:top_paths].each { |p| assert File.exist?(p) }
  end

  def test_returns_no_winner_when_top_score_below_threshold
    ranked = [
      @candidates[0].merge(score: 10, has_title_text: false, has_overlay_watermark: false, vetoed: false, reasons: ""),
      @candidates[1].merge(score:  8, has_title_text: false, has_overlay_watermark: false, vetoed: false, reasons: ""),
      @candidates[2].merge(score:  6, has_title_text: false, has_overlay_watermark: false, vetoed: false, reasons: "")
    ]
    result = build_resolver(@candidates, ranked, config: { auto_cover_min_score: 14 }).try(
      title: "T", description: "D", episodes_dir: @episodes_dir, basename: @basename
    )

    assert_nil result[:winner_path]
    # Top 3 still persisted for inspection
    assert_equal 3, result[:top_paths].length
    result[:top_paths].each { |p| assert File.exist?(p) }
  end

  def test_returns_no_winner_when_top_is_vetoed
    ranked = [
      @candidates[0].merge(score: 20, has_title_text: false, has_overlay_watermark: true, vetoed: true, reasons: "watermark"),
      @candidates[1].merge(score: 10, has_title_text: false, has_overlay_watermark: false, vetoed: false, reasons: "ok"),
      @candidates[2].merge(score:  8, has_title_text: false, has_overlay_watermark: false, vetoed: false, reasons: "ok")
    ]
    # Note: ImageRanker normally sorts vetoed last; here the test passes them
    # in (presumably already-sorted) order to reflect the resolver's contract.
    result = build_resolver(@candidates, ranked).try(
      title: "T", description: "D", episodes_dir: @episodes_dir, basename: @basename
    )

    assert_nil result[:winner_path]
  end

  def test_returns_empty_when_search_returns_no_candidates
    resolver = build_resolver([], [])
    result = resolver.try(title: "T", description: "D", episodes_dir: @episodes_dir, basename: @basename)
    assert_nil result[:winner_path]
    assert_equal [], result[:top_paths]
    assert_equal [], result[:candidates]
  end

  def test_persists_top_3_with_episode_basename_and_correct_extension
    @candidates[1][:path] = File.join(@tmp_imgs, "c2.png")
    File.binwrite(@candidates[1][:path], "png-bytes")
    @candidates[1][:ext] = ".png"

    ranked = @candidates.each_with_index.map do |c, i|
      c.merge(score: 18 - i, has_title_text: false, has_overlay_watermark: false, vetoed: false, reasons: "")
    end
    result = build_resolver(@candidates, ranked).try(
      title: "T", description: "D", episodes_dir: @episodes_dir, basename: @basename
    )

    expected = [
      File.join(@episodes_dir, "#{@basename}_cover1.jpg"),
      File.join(@episodes_dir, "#{@basename}_cover2.png"),
      File.join(@episodes_dir, "#{@basename}_cover3.jpg")
    ]
    assert_equal expected, result[:top_paths]
    expected.each { |p| assert File.exist?(p) }
  end

  def test_passes_config_overrides_to_searcher_and_ranker
    captured = {}
    fake_searcher = Object.new
    fake_searcher.define_singleton_method(:search) do |q, count:, min_bytes:|
      captured[:search] = { q: q, count: count, min_bytes: min_bytes }
      []
    end
    fake_ranker = Object.new
    fake_ranker.define_singleton_method(:rank) do |_cs, **_kw| [] end

    resolver = AutoCoverResolver.new(
      config: { auto_cover_min_bytes: 99_000, auto_cover_candidates: 7,
                auto_cover_min_score: 5, auto_cover_model: "claude-haiku-4-5-20251001" },
      searcher: fake_searcher, ranker: fake_ranker
    )
    resolver.try(title: "Q", description: "D", episodes_dir: @episodes_dir, basename: @basename)

    assert_equal "Q", captured[:search][:q]
    assert_equal 7, captured[:search][:count]
    assert_equal 99_000, captured[:search][:min_bytes]
  end

  def test_cleans_up_tmp_files_after_persisting
    ranked = [
      @candidates[0].merge(score: 18, has_title_text: true,  has_overlay_watermark: false, vetoed: false, reasons: ""),
      @candidates[1].merge(score: 14, has_title_text: false, has_overlay_watermark: false, vetoed: false, reasons: ""),
      @candidates[2].merge(score: 10, has_title_text: false, has_overlay_watermark: false, vetoed: false, reasons: "")
    ]
    build_resolver(@candidates, ranked).try(
      title: "T", description: "D", episodes_dir: @episodes_dir, basename: @basename
    )
    @candidates.each { |c| refute File.exist?(c[:path]), "tmp file should be cleaned: #{c[:path]}" }
  end

  private

  def build_resolver(candidates, ranked, config: {})
    fake_searcher = Object.new
    fake_searcher.define_singleton_method(:search) { |_q, **_kw| candidates }
    fake_ranker = Object.new
    fake_ranker.define_singleton_method(:rank) { |_cs, **_kw| ranked }
    AutoCoverResolver.new(config: config, searcher: fake_searcher, ranker: fake_ranker)
  end
end
