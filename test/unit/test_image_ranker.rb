# frozen_string_literal: true

require_relative "../test_helper"
require "claude_models"
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
      { "index" => 0, "visual_quality" => 8, "subject_match" => 9,
        "has_title_text" => false, "has_overlay_watermark" => false, "reasons" => "ok" },
      { "index" => 1, "visual_quality" => 6, "subject_match" => 5,
        "has_title_text" => false, "has_overlay_watermark" => false, "reasons" => "weaker" },
      { "index" => 2, "visual_quality" => 7, "subject_match" => 8,
        "has_title_text" => true, "has_overlay_watermark" => false, "reasons" => "has title" }
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

  def test_rank_marks_overlay_watermark_as_vetoed
    rankings = [
      { "index" => 0, "visual_quality" => 9, "subject_match" => 9,
        "has_title_text" => false, "has_overlay_watermark" => true, "reasons" => "watermark" },
      { "index" => 1, "visual_quality" => 6, "subject_match" => 6,
        "has_title_text" => false, "has_overlay_watermark" => false, "reasons" => "ok" },
      { "index" => 2, "visual_quality" => 5, "subject_match" => 5,
        "has_title_text" => false, "has_overlay_watermark" => false, "reasons" => "ok" }
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

  def test_rank_sort_key_orders_veto_then_title_text_then_score_then_index
    cands = (1..5).map do |i|
      path = File.join(@tmpdir, "s#{i}.jpg")
      File.binwrite(path, "fake-#{i}")
      { url: "https://x.com/s#{i}.jpg", path: path, bytes: 10_000, ext: ".jpg" }
    end
    row = lambda do |i, q, m, title, wm|
      { "index" => i, "visual_quality" => q, "subject_match" => m,
        "has_title_text" => title, "has_overlay_watermark" => wm, "reasons" => "" }
    end
    rankings = [
      row.call(0, 10, 10, true, true),   # vetoed: last despite title text + top score
      row.call(1, 5, 5, false, false),   # score 10, no title
      row.call(2, 2, 2, true, false),    # score 4 but title text: first
      row.call(3, 5, 5, false, false),   # score 10 tie with index 1: input order kept
      row.call(4, 8, 8, false, false)    # score 16
    ]
    ranked = with_stubbed_claude(rankings) do
      ImageRanker.new.rank(cands, title: "T", description: "D")
    end

    assert_equal %w[s3 s5 s2 s4 s1], ranked.map { |c| c[:url][/s\d/] }
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
    rankings = [{ "index" => 0, "visual_quality" => 8, "subject_match" => 8,
                  "has_title_text" => false, "has_overlay_watermark" => false, "reasons" => "" }]
    fake_response = Struct.new(:content).new([Struct.new(:text).new(JSON.generate("rankings" => rankings))])
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) { |**kwargs| captured_model = kwargs[:model]; fake_response }
    fake_client = Struct.new(:messages).new(fake_messages)

    Anthropic::Client.stub(:new, fake_client) do
      ImageRanker.new(model: "claude-haiku-4-5-20251001").rank([@candidates.first], title: "T", description: "D")
    end
    assert_equal "claude-haiku-4-5-20251001", captured_model
  end

  def test_client_is_built_with_the_bounded_request_timeout
    captured = nil
    Anthropic::Client.stub(:new, ->(**kw) { captured = kw; Object.new }) { ImageRanker.new }
    assert_equal AnthropicClient::REQUEST_TIMEOUT, captured[:timeout]
  end

  def test_rank_default_model_is_the_registry_image_rank_role
    ranker = ImageRanker.new
    assert_equal ClaudeModels.for(:image_rank), ranker.instance_variable_get(:@model)
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
