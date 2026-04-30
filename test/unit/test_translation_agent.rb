# frozen_string_literal: true

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
ENV["OPENAI_API_KEY"] ||= "test-key"
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
    assert_includes err.message, "No parsed output"
  end

  def test_prompt_includes_language_name
    agent = build_agent("sl")
    client = stub_client(agent, title: "T", segments: [])

    agent.translate(sample_script)
    system = client.last_call[:system]
    assert_includes system, "Slovenian"
  end

  def test_prompt_uses_natural_conventions_not_blanket_preserve
    agent = build_agent("de")
    client = stub_client(agent, title: "T", segments: [])

    agent.translate(sample_script)
    system = client.last_call[:system]
    # New prompt: trust target-language conventions, don't force English-as-is.
    assert_includes system, "natural conventions"
    refute_includes system, "as-is"
    # Mentions both Latin-script preservation and non-Latin transliteration as examples
    assert_includes system, "ビットコイン"
  end

  def test_prompt_omits_glossary_block_when_empty
    agent = build_agent("de")
    client = stub_client(agent, title: "T", segments: [])

    agent.translate(sample_script)
    refute_includes client.last_call[:system], "GLOSSARY"
  end

  def test_prompt_includes_glossary_pairs_when_provided
    agent = TranslationAgent.new(target_language: "jp", glossary: {
      "Bitcoin" => "ビットコイン",
      "GitHub" => "GitHub",
      "mining" => "マイニング"
    })
    agent.define_singleton_method(:sleep) { |_| }
    stub_client(agent, title: "T", segments: [])

    agent.translate(sample_script)
    system = agent.instance_variable_get(:@client).last_call[:system]

    assert_includes system, "GLOSSARY"
    assert_includes system, %{"Bitcoin" → "ビットコイン"}
    assert_includes system, %{"GitHub" → "GitHub"}
    assert_includes system, %{"mining" → "マイニング"}
  end

  def test_prompt_instructs_segment_name_translation
    agent = build_agent("de")
    client = stub_client(agent, title: "T", segments: [])

    agent.translate(sample_script)
    system = client.last_call[:system]
    assert_includes system, "Translate every segment name"
    refute_includes system, "same segment names"
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

  def test_country_code_aliases_resolve_to_language_name
    # jp/cn/kr are common country-code aliases for ja/zh/ko
    {
      "jp" => "Japanese",
      "cn" => "Chinese",
      "kr" => "Korean"
    }.each do |code, expected_name|
      agent = build_agent(code)
      client = stub_client(agent, title: "T", segments: [])
      agent.translate(sample_script)
      assert_includes client.last_call[:system], expected_name,
        "Expected #{code} to resolve to #{expected_name} in prompt"
    end
  end

  def test_translate_carries_top_level_sources_from_original
    agent = build_agent("sl")
    stub_client(agent, title: "T", segments: [{ name: "Open", text: "Pozdravljeni." }])

    script_with_sources = sample_script.merge(sources: [
      { title: "S1", url: "https://example.com/1" }
    ])

    result = agent.translate(script_with_sources)
    assert_equal [{ title: "S1", url: "https://example.com/1" }], result[:sources]
  end

  def test_translate_carries_per_segment_sources_by_index
    agent = build_agent("sl")
    stub_client(agent, title: "T", segments: [
      { name: "Open", text: "A." },
      { name: "Conclude", text: "B." }
    ])

    script_with_sources = {
      title: "Original",
      segments: [
        { name: "Opening", text: "Hello.", sources: [{ title: "Src1", url: "https://example.com/1" }] },
        { name: "Wrap", text: "Bye.", sources: [{ title: "Src2", url: "https://example.com/2" }] }
      ]
    }

    result = agent.translate(script_with_sources)

    assert_equal [{ title: "Src1", url: "https://example.com/1" }], result[:segments][0][:sources]
    assert_equal [{ title: "Src2", url: "https://example.com/2" }], result[:segments][1][:sources]
  end

  def test_translate_omits_sources_when_original_has_none
    agent = build_agent("sl")
    stub_client(agent, title: "T", segments: [{ name: "Open", text: "Hi." }])

    result = agent.translate(sample_script)  # sample has no sources
    refute result[:segments].first.key?(:sources)
    refute result.key?(:sources)
  end

  def test_unknown_backend_raises
    err = assert_raises(ArgumentError) { TranslationAgent.new(target_language: "jp", backend: "bogus") }
    assert_includes err.message, "Unknown translation backend"
  end

  def test_model_override_is_applied_for_claude_backend
    agent = TranslationAgent.new(target_language: "es", backend: "claude", model_override: "claude-haiku-4-5-20251001")
    assert_equal "claude-haiku-4-5-20251001", agent.instance_variable_get(:@model)
  end

  # --- OpenAI backend ---

  def test_openai_backend_uses_responses_api
    agent = build_openai_agent("jp")
    client = stub_openai_client(agent, title: "エピソード1", segments: [{ name: "オープニング", text: "こんにちは" }])

    result = agent.translate(sample_script)
    assert_equal "エピソード1", result[:title]
    assert_equal 1, result[:segments].length
    assert_equal "オープニング", result[:segments].first[:name]
    # Confirm we hit responses.create, not messages.create
    assert_equal :responses, client.api_called
  end

  def test_openai_backend_uses_default_model_when_no_override
    agent = TranslationAgent.new(target_language: "jp", backend: "openai")
    assert_equal "gpt-5", agent.instance_variable_get(:@openai_model)
  end

  def test_openai_backend_respects_model_override
    agent = TranslationAgent.new(target_language: "jp", backend: "openai", model_override: "gpt-4o")
    assert_equal "gpt-4o", agent.instance_variable_get(:@openai_model)
  end

  def test_openai_backend_respects_env_default_model
    ENV["OPENAI_TRANSLATION_MODEL"] = "gpt-4o-mini"
    agent = TranslationAgent.new(target_language: "jp", backend: "openai")
    assert_equal "gpt-4o-mini", agent.instance_variable_get(:@openai_model)
  ensure
    ENV.delete("OPENAI_TRANSLATION_MODEL")
  end

  def test_openai_backend_raises_on_empty_output
    agent = build_openai_agent("jp")
    stub_openai_client(agent, empty: true)

    err = assert_raises(RuntimeError) { agent.translate(sample_script) }
    assert_includes err.message, "no parsed output"
  end

  def test_openai_backend_skips_reasoning_items_with_nil_content
    # Regression: GPT-5 interleaves ResponseReasoningItem entries (content: nil)
    # with message items in response.output. Prior code crashed with
    # `undefined method 'parsed' for nil` because flat_map(&:content) included nil.
    agent = build_openai_agent("ja")

    reasoning = OpenAI::Models::Responses::ResponseReasoningItem.new({})
    reasoning.define_singleton_method(:content) { nil }

    parsed = MockTranslation.new("Title", [MockSegment.new("Open", "Hello")])
    msg = OpenAI::Models::Responses::ResponseOutputMessage.new({})
    msg.define_singleton_method(:content) { [MockOpenAIContent.new(parsed)] }

    response = MockOpenAIResponse.new([reasoning, msg])
    agent.instance_variable_set(:@openai_client, MockOpenAIClient.new(response))

    result = agent.translate(sample_script)
    assert_equal "Title", result[:title]
    assert_equal "Hello", result[:segments].first[:text]
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

  def build_openai_agent(lang)
    agent = TranslationAgent.new(target_language: lang, backend: "openai")
    agent.define_singleton_method(:sleep) { |_| }
    agent
  end

  def stub_openai_client(agent, title: nil, segments: nil, empty: false)
    response = if empty
      MockOpenAIResponse.new([])
    else
      segs = (segments || []).map { |s| MockSegment.new(s[:name], s[:text]) }
      content = MockOpenAIContent.new(MockTranslation.new(title, segs))
      # Real ResponseOutputMessage so the production code's `grep(class)` matches.
      msg = OpenAI::Models::Responses::ResponseOutputMessage.new({})
      msg.define_singleton_method(:content) { [content] }
      MockOpenAIResponse.new([msg])
    end
    client = MockOpenAIClient.new(response)
    agent.instance_variable_set(:@openai_client, client)
    client
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

  # OpenAI response shape: response.output → [item], item.content → [content], content.parsed → parsed schema.
  # The output items must be real OpenAI::Models::Responses::ResponseOutputMessage instances
  # because the production code filters via Array#grep on that class.
  MockOpenAIContent = Struct.new(:parsed)
  MockOpenAIResponse = Struct.new(:output)

  class MockOpenAIClient
    attr_reader :calls, :api_called
    def initialize(response) = (@response = response; @calls = [])
    def responses
      @api_called = :responses
      self
    end
    def last_call = @calls.last
    def create(**kw) = (@calls << kw; @response)
  end
end
