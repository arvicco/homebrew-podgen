# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/anthropic_client"

class TestAnthropicClient < Minitest::Test
  # Minimal class that includes the mixin so we can test the helper
  class Harness
    include AnthropicClient
    public :require_parsed_output!
  end

  class FakeModel < Anthropic::BaseModel
    required :title, String
  end

  def setup
    @harness = Harness.new
  end

  # -- require_parsed_output! --

  def test_require_parsed_output_returns_valid_model
    model = FakeModel.new(title: "Hello")
    message = stub_message(parsed: model)

    result = @harness.require_parsed_output!(message)
    assert_equal "Hello", result.title
  end

  def test_require_parsed_output_raises_on_nil
    message = stub_message(parsed: nil)

    error = assert_raises(StructuredOutputError) do
      @harness.require_parsed_output!(message)
    end
    assert_includes error.message, "No parsed output"
    assert_includes error.message, "end_turn"
  end

  def test_require_parsed_output_raises_on_error_hash
    message = stub_message(parsed: { error: "unexpected token at pos 0" })

    error = assert_raises(StructuredOutputError) do
      @harness.require_parsed_output!(message)
    end
    assert_includes error.message, "SDK parsing failed"
    assert_includes error.message, "unexpected token at pos 0"
  end

  # -- truncation (P1-11): a max_tokens stop is deterministic, must not be retried --

  def test_require_parsed_output_raises_truncated_on_max_tokens_with_error_hash
    message = stub_message(parsed: { error: "unexpected end of input" }, stop_reason: "max_tokens")

    error = assert_raises(TruncatedOutputError) do
      @harness.require_parsed_output!(message)
    end
    refute_kind_of StructuredOutputError, error
    assert_includes error.message, "max_tokens"
    assert_includes error.message, "8192"
  end

  def test_require_parsed_output_raises_truncated_on_max_tokens_with_nil
    message = stub_message(parsed: nil, stop_reason: :max_tokens)

    assert_raises(TruncatedOutputError) { @harness.require_parsed_output!(message) }
  end

  def test_require_parsed_output_end_turn_error_hash_stays_structured_error
    message = stub_message(parsed: { error: "bad token" }, stop_reason: "end_turn")

    assert_raises(StructuredOutputError) { @harness.require_parsed_output!(message) }
  end

  # -- init_anthropic_client bounds the request timeout (P1-13): the SDK default of
  # 10 min × retries is what turned a dead network into a 2.5 h run --

  def test_init_anthropic_client_sets_a_bounded_timeout
    captured = nil
    fake = Object.new
    Anthropic::Client.stub(:new, ->(**kw) {
      captured = kw
      fake
    }) do
      h = Class.new {
        include AnthropicClient
        public :init_anthropic_client
      }.new
      h.init_anthropic_client(role: :script)
    end
    assert_operator captured[:timeout], :<=, 300
    assert_operator captured[:timeout], :>=, 120, "scripts and reconciliation take ~1-2 min"
  end

  # -- text_of (P1-0 hazard H1): thinking-default models put a thinking block first --

  def test_text_of_skips_a_leading_thinking_block
    thinking = Struct.new(:type, :thinking).new(:thinking, "hmm")
    text = Struct.new(:type, :text).new(:text, "answer")
    message = Struct.new(:content, :stop_reason).new([thinking, text], "end_turn")

    assert_equal "answer", AnthropicClient.text_of(message)
  end

  def test_text_of_accepts_untyped_fakes_with_text
    message = Struct.new(:content).new([Struct.new(:text).new("plain")])

    assert_equal "plain", AnthropicClient.text_of(message)
  end

  def test_text_of_raises_when_no_text_block
    thinking = Struct.new(:type, :thinking).new("thinking", "only")
    message = Struct.new(:content, :stop_reason).new([thinking], "max_tokens")

    err = assert_raises(NoTextBlockError) { AnthropicClient.text_of(message) }
    assert_includes err.message, "max_tokens"
  end

  def test_require_parsed_output_accepts_duck_typed_objects
    mock = Struct.new(:title).new("Duck")
    message = stub_message(parsed: mock)

    result = @harness.require_parsed_output!(message)
    assert_equal "Duck", result.title
  end

  private

  def stub_message(parsed:, stop_reason: "end_turn")
    usage = Struct.new(:output_tokens).new(8192)
    msg = Struct.new(:stop_reason, :usage) do
      define_method(:parsed_output) { parsed }
    end
    msg.new(stop_reason, usage)
  end
end
