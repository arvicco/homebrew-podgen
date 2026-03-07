# frozen_string_literal: true

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "transcription/reconciler"

class TestReconciler < Minitest::Test
  # --- argument validation ---

  def test_reconcile_requires_two_or_more_transcripts
    reconciler = build_reconciler
    err = assert_raises(ArgumentError) { reconciler.reconcile({ "open" => "text" }) }
    assert_includes err.message, "2+ transcripts"
  end

  def test_cleanup_requires_non_empty_text
    reconciler = build_reconciler
    assert_raises(ArgumentError) { reconciler.cleanup("") }
    assert_raises(ArgumentError) { reconciler.cleanup("  ") }
    assert_raises(ArgumentError) { reconciler.cleanup(nil) }
  end

  # --- reconcile ---

  def test_reconcile_returns_text
    reconciler = build_reconciler
    stub_client(reconciler, "Reconciled transcript text")

    result = reconciler.reconcile({ "open" => "text A", "groq" => "text B" })
    assert_equal "Reconciled transcript text", result
  end

  def test_reconcile_prompt_includes_all_engines
    reconciler = build_reconciler
    client = stub_client(reconciler, "merged")

    reconciler.reconcile({ "open" => "text A", "groq" => "text B" })
    user_msg = client.last_call[:messages].first[:content]
    assert_includes user_msg, "=== Engine: open ==="
    assert_includes user_msg, "=== Engine: groq ==="
    assert_includes user_msg, "text A"
    assert_includes user_msg, "text B"
  end

  def test_reconcile_prompt_includes_language
    reconciler = build_reconciler(language: "Japanese")
    client = stub_client(reconciler, "merged")

    reconciler.reconcile({ "a" => "x", "b" => "y" })
    user_msg = client.last_call[:messages].first[:content]
    assert_includes user_msg, "Japanese"
  end

  # --- cleanup ---

  def test_cleanup_returns_text
    reconciler = build_reconciler
    stub_client(reconciler, "Cleaned transcript")

    result = reconciler.cleanup("raw text with errors")
    assert_equal "Cleaned transcript", result
  end

  def test_cleanup_includes_captions_when_provided
    reconciler = build_reconciler
    client = stub_client(reconciler, "cleaned")

    reconciler.cleanup("raw text", captions: "youtube captions here")
    user_msg = client.last_call[:messages].first[:content]
    assert_includes user_msg, "youtube captions here"
  end

  def test_cleanup_omits_captions_section_when_nil
    reconciler = build_reconciler
    client = stub_client(reconciler, "cleaned")

    reconciler.cleanup("raw text")
    user_msg = client.last_call[:messages].first[:content]
    refute_includes user_msg, "Reference: auto-generated YouTube captions"
  end

  def test_raises_on_empty_response
    reconciler = build_reconciler
    stub_client(reconciler, "")

    assert_raises(RuntimeError) { reconciler.cleanup("some text") }
  end

  private

  def build_reconciler(language: "Slovenian")
    reconciler = Transcription::Reconciler.new(language: language)
    reconciler.define_singleton_method(:sleep) { |_| }
    reconciler
  end

  def stub_client(reconciler, response_text)
    client = MockClient.new(response_text)
    reconciler.instance_variable_set(:@client, client)
    client
  end

  class MockClient
    attr_reader :calls
    def initialize(text) = (@text = text; @calls = [])
    def messages = self
    def last_call = @calls.last

    def create(**kw)
      @calls << kw
      MockMsg.new(@text)
    end
  end

  class MockMsg
    def initialize(text) = @text = text
    def stop_reason = "end_turn"
    def usage = MockUsage.new
    def content = [MockBlock.new(@text)]
  end

  class MockBlock
    def initialize(text) = @text = text
    def type = "text"
    def text = @text
  end

  class MockUsage
    def input_tokens = 1000
    def output_tokens = 800
    def cache_creation_input_tokens = 0
    def cache_read_input_tokens = 0
  end
end
