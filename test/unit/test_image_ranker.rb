# frozen_string_literal: true

require_relative "../test_helper"
ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "image_ranker"

class TestImageRanker < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_ranker_test")
    @candidates = (1..3).map do |i|
      path = File.join(@tmpdir, "c#{i}.jpg")
      File.binwrite(path, "fake-image-bytes-#{i}")
      { url: "https://x.com/c#{i}.jpg", path: path, bytes: 10_000, ext: ".jpg" }
    end
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_rank_returns_candidates_with_scores
    rankings = [
      { "index" => 0, "fits_fairytale_cover" => 8, "matches_episode_description" => 9,
        "has_title_text" => false, "has_watermark" => false, "composition_ok" => true, "reasons" => "ok" },
      { "index" => 1, "fits_fairytale_cover" => 6, "matches_episode_description" => 5,
        "has_title_text" => false, "has_watermark" => false, "composition_ok" => true, "reasons" => "weaker" },
      { "index" => 2, "fits_fairytale_cover" => 7, "matches_episode_description" => 8,
        "has_title_text" => true, "has_watermark" => false, "composition_ok" => true, "reasons" => "has title" }
    ]
    ranked = with_stubbed_claude(rankings) do
      ImageRanker.new.rank(@candidates, title: "T", description: "D")
    end

    assert_equal 3, ranked.length
    # has_title_text first (index 2), then by score
    assert_equal "https://x.com/c3.jpg", ranked[0][:url]
    assert_equal 15, ranked[0][:score]
    assert_equal true, ranked[0][:has_title_text]
    # remaining sorted by score: 8+9=17 > 6+5=11
    assert_equal "https://x.com/c1.jpg", ranked[1][:url]
    assert_equal "https://x.com/c2.jpg", ranked[2][:url]
  end

  def test_rank_marks_watermarked_as_vetoed_but_keeps_in_results
    rankings = [
      { "index" => 0, "fits_fairytale_cover" => 9, "matches_episode_description" => 9,
        "has_title_text" => false, "has_watermark" => true, "composition_ok" => true, "reasons" => "watermark" },
      { "index" => 1, "fits_fairytale_cover" => 6, "matches_episode_description" => 6,
        "has_title_text" => false, "has_watermark" => false, "composition_ok" => true, "reasons" => "ok" },
      { "index" => 2, "fits_fairytale_cover" => 5, "matches_episode_description" => 5,
        "has_title_text" => false, "has_watermark" => false, "composition_ok" => true, "reasons" => "ok" }
    ]
    ranked = with_stubbed_claude(rankings) do
      ImageRanker.new.rank(@candidates, title: "T", description: "D")
    end

    # Watermarked one (high raw score) sorted last because vetoed
    assert_equal "https://x.com/c1.jpg", ranked.last[:url]
    assert_equal true, ranked.last[:vetoed]
    refute ranked[0][:vetoed]
    refute ranked[1][:vetoed]
  end

  def test_rank_marks_bad_composition_as_vetoed
    rankings = [
      { "index" => 0, "fits_fairytale_cover" => 8, "matches_episode_description" => 8,
        "has_title_text" => false, "has_watermark" => false, "composition_ok" => false, "reasons" => "bad" },
      { "index" => 1, "fits_fairytale_cover" => 5, "matches_episode_description" => 5,
        "has_title_text" => false, "has_watermark" => false, "composition_ok" => true, "reasons" => "ok" },
      { "index" => 2, "fits_fairytale_cover" => 6, "matches_episode_description" => 6,
        "has_title_text" => false, "has_watermark" => false, "composition_ok" => true, "reasons" => "ok" }
    ]
    ranked = with_stubbed_claude(rankings) do
      ImageRanker.new.rank(@candidates, title: "T", description: "D")
    end

    assert_equal true, ranked.last[:vetoed]
    assert_equal "https://x.com/c1.jpg", ranked.last[:url]
  end

  def test_rank_handles_malformed_json_returns_empty
    fake_response = Struct.new(:content).new([Struct.new(:text).new("not json at all")])
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) { |**_kwargs| fake_response }
    fake_client = Struct.new(:messages).new(fake_messages)

    Anthropic::Client.stub(:new, fake_client) do
      ranked = ImageRanker.new.rank(@candidates, title: "T", description: "D")
      assert_equal [], ranked
    end
  end

  def test_rank_returns_empty_when_no_candidates
    ranked = ImageRanker.new.rank([], title: "T", description: "D")
    assert_equal [], ranked
  end

  def test_rank_passes_configured_model_to_api
    captured_model = nil
    rankings = [{ "index" => 0, "fits_fairytale_cover" => 8, "matches_episode_description" => 8,
                  "has_title_text" => false, "has_watermark" => false, "composition_ok" => true, "reasons" => "" }]
    fake_response = Struct.new(:content).new([Struct.new(:text).new(JSON.generate("rankings" => rankings))])
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) { |**kwargs| captured_model = kwargs[:model]; fake_response }
    fake_client = Struct.new(:messages).new(fake_messages)

    Anthropic::Client.stub(:new, fake_client) do
      ImageRanker.new(model: "claude-haiku-4-5-20251001").rank([@candidates.first], title: "T", description: "D")
    end
    assert_equal "claude-haiku-4-5-20251001", captured_model
  end

  def test_rank_default_model_is_sonnet_4_6
    ranker = ImageRanker.new
    assert_equal "claude-sonnet-4-6", ranker.instance_variable_get(:@model)
  end

  private

  def with_stubbed_claude(rankings)
    fake_response = Struct.new(:content).new(
      [Struct.new(:text).new(JSON.generate("rankings" => rankings))]
    )
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) { |**_kwargs| fake_response }
    fake_client = Struct.new(:messages).new(fake_messages)

    Anthropic::Client.stub(:new, fake_client) do
      yield
    end
  end
end
