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

  def test_require_parsed_output_accepts_duck_typed_objects
    mock = Struct.new(:title).new("Duck")
    message = stub_message(parsed: mock)

    result = @harness.require_parsed_output!(message)
    assert_equal "Duck", result.title
  end

  private

  def stub_message(parsed:)
    msg = Struct.new(:stop_reason) do
      define_method(:parsed_output) { parsed }
    end
    msg.new("end_turn")
  end
end
