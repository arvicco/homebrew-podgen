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
    fake_response = FakeMsg.new([Struct.new(:text).new("not json at all")], "end_turn", FakeUsage.new(1, 1))
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
    fake_response = FakeMsg.new([Struct.new(:text).new(JSON.generate("rankings" => rankings))], "end_turn", FakeUsage.new(1, 1))
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

  # P8-2 (Q-64): a thinking-first response truncated at max_tokens carries
  # no text block; the failure is a visible skippable warning, not silence.
  def test_rank_thinking_only_truncated_response_logs_no_text_block_warning
    thinking = Struct.new(:type, :thinking).new("thinking", "pondering...")
    response = FakeMsg.new([thinking], "max_tokens", FakeUsage.new(1200, 2000))
    logger = RecordingLogger.new

    ranked = with_fake_response(response) do
      ImageRanker.new(logger: logger).rank(@candidates, title: "T", description: "D")
    end

    assert_equal [], ranked
    warning = logger.warnings.join("\n")
    assert_includes warning, "NoTextBlockError"
    assert_includes warning, "max_tokens"
  end

  # P8-2 (Q-66): the vision call logs a usage line like every other site.
  def test_rank_logs_api_usage_line
    rankings = [{ "index" => 0, "visual_quality" => 8, "subject_match" => 8,
                  "has_title_text" => false, "has_overlay_watermark" => false, "reasons" => "" }]
    text = Struct.new(:type, :text).new("text", JSON.generate("rankings" => rankings))
    logger = RecordingLogger.new

    with_fake_response(FakeMsg.new([text], "end_turn", FakeUsage.new(900, 300))) do
      ImageRanker.new(logger: logger).rank([@candidates.first], title: "T", description: "D")
    end

    lines = logger.lines.join("\n")
    assert_includes lines, "(end_turn)"
    assert_includes lines, "Input: 900 tokens | Output: 300 tokens"
  end

  # P8-2: thinking-default sonnet line; 2000 left too little room beside
  # thinking (the web-search site measured 1024 truncating, 2026-10-11).
  def test_rank_requests_room_for_thinking_and_rankings
    captured = nil
    text = Struct.new(:type, :text).new("text", JSON.generate("rankings" => []))
    response = FakeMsg.new([text], "end_turn", FakeUsage.new(1, 1))
    with_fake_response(response, capture: ->(kw) { captured = kw }) do
      ImageRanker.new.rank([@candidates.first], title: "T", description: "D")
    end
    assert_operator captured[:max_tokens], :>=, 4096
  end

  private

  FakeMsg = Struct.new(:content, :stop_reason, :usage)
  FakeUsage = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens) do
    def initialize(i, o) = super(i, o, 0, 0)
  end

  class RecordingLogger
    attr_reader :lines, :warnings

    def initialize
      @lines = []
      @warnings = []
    end

    def log(msg) = @lines << msg
    def warning(msg) = @warnings << msg
    def error(msg) = @lines << msg
  end

  def with_fake_response(response, capture: nil)
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) { |**kw| capture&.call(kw); response }
    fake_client = Struct.new(:messages).new(fake_messages)
    Anthropic::Client.stub(:new, fake_client) { yield }
  end

  def with_stubbed_claude(rankings)
    fake_response = FakeMsg.new(
      [Struct.new(:text).new(JSON.generate("rankings" => rankings))], "end_turn", FakeUsage.new(1, 1)
    )
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) { |**_kwargs| fake_response }
    fake_client = Struct.new(:messages).new(fake_messages)

    Anthropic::Client.stub(:new, fake_client) do
      yield
    end
  end
end
