# frozen_string_literal: true

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "agents/translation_agent"

class TestTranslationAgent < Minitest::Test
  def test_translate_returns_translated_script
    agent = build_agent("sl")
    stub_client(agent, title: "Epizoda 1", segments: [{ name: "Uvod", text: "Pozdravljeni!" }])

    result = agent.translate(sample_script)
    assert_equal "Epizoda 1", result[:title]
    assert_equal 1, result[:segments].length
    assert_equal "Uvod", result[:segments].first[:name]
    assert_equal "Pozdravljeni!", result[:segments].first[:text]
  end

  def test_translate_raises_on_nil_parsed_output
    agent = build_agent("sl")
    stub_client(agent, nil_output: true)

    err = assert_raises(RuntimeError) { agent.translate(sample_script) }
    assert_includes err.message, "Structured output parsing failed"
  end

  def test_prompt_includes_language_name
    agent = build_agent("sl")
    client = stub_client(agent, title: "T", segments: [])

    agent.translate(sample_script)
    system = client.last_call[:system]
    assert_includes system, "Slovenian"
  end

  def test_prompt_includes_proper_noun_preservation
    agent = build_agent("de")
    client = stub_client(agent, title: "T", segments: [])

    agent.translate(sample_script)
    system = client.last_call[:system]
    assert_includes system, "proper nouns"
  end

  def test_format_script_for_translation
    agent = build_agent("sl")
    formatted = agent.send(:format_script_for_translation, sample_script)

    assert_includes formatted, "Title: Episode 1"
    assert_includes formatted, "--- Opening ---"
    assert_includes formatted, "Hello everyone!"
    assert_includes formatted, "--- Wrap-Up ---"
    assert_includes formatted, "Thanks for listening."
  end

  def test_unknown_language_code_uses_code_as_name
    agent = build_agent("xx")
    client = stub_client(agent, title: "T", segments: [])

    agent.translate(sample_script)
    system = client.last_call[:system]
    assert_includes system, "xx"
  end

  private

  def sample_script
    {
      title: "Episode 1",
      segments: [
        { name: "Opening", text: "Hello everyone!" },
        { name: "Wrap-Up", text: "Thanks for listening." }
      ]
    }
  end

  def build_agent(lang)
    agent = TranslationAgent.new(target_language: lang)
    agent.define_singleton_method(:sleep) { |_| }
    agent
  end

  def stub_client(agent, title: nil, segments: nil, nil_output: false)
    output = if nil_output
      nil
    else
      segs = (segments || []).map { |s| MockSegment.new(s[:name], s[:text]) }
      MockTranslation.new(title, segs)
    end
    client = MockClient.new(output)
    agent.instance_variable_set(:@client, client)
    client
  end

  MockSegment = Struct.new(:name, :text)
  MockTranslation = Struct.new(:title, :segments)

  class MockClient
    attr_reader :calls
    def initialize(output) = (@output = output; @calls = [])
    def messages = self
    def last_call = @calls.last
    def create(**kw) = (@calls << kw; MockMsg.new(@output))
  end

  class MockMsg
    def initialize(output) = @output = output
    def parsed_output = @output
    def stop_reason = "end_turn"
    def usage = MockUsage.new
  end

  class MockUsage
    def input_tokens = 500
    def output_tokens = 400
    def cache_creation_input_tokens = 0
    def cache_read_input_tokens = 0
  end
end
