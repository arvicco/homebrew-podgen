# frozen_string_literal: true

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
ENV["OPENAI_API_KEY"] ||= "test-key"
require "agents/translation_agent"

# P3-0 H3 characterization harness — duplicated path 6.
#
# TranslationAgent#translate runs one core over two backend adapters,
# claude and openai (P4-4 consolidated the former translate_with_claude /
# translate_with_openai copies). Each behavior is pinned per backend with
# injected fake clients that record every call (no network); tests named
# test_translate_claude_backend_* / test_translate_openai_backend_* pin one
# backend. Where the backends still differ, the test name says "divergent"
# and both behaviors are asserted; rows that P4-4 aligned (output cap,
# truncation, logging, the glossary block) say "aligned". These pin CURRENT
# behavior; they are not a spec.
class TestCharacterizationTranslationPaths < Minitest::Test
  Segment = Struct.new(:name, :text)
  Translation = Struct.new(:title, :segments)
  OpenAIContent = Struct.new(:parsed)
  OpenAIResponse = Struct.new(:output, :status, :usage, :incomplete_details)
  OpenAIIncomplete = Struct.new(:reason)

  class Usage
    def input_tokens = 500
    def output_tokens = 400
    def cache_creation_input_tokens = 0
    def cache_read_input_tokens = 0
  end

  ClaudeMessage = Struct.new(:parsed_output, :stop_reason) do
    def usage = Usage.new
  end

  # Fake Anthropic client: messages.create(**kw) records kw and plays the
  # next scripted step (an Exception is raised, anything else returned).
  class FakeClaudeClient
    attr_reader :calls
    def initialize(*steps) = (@steps = steps
                              @calls = [])

    def messages = self

    def create(**kw)
      @calls << kw
      step = (@steps.length > 1) ? @steps.shift : @steps.first
      raise step if step.is_a?(Exception)
      step
    end
  end

  # Fake OpenAI client: responses.create(**kw), same scripting.
  class FakeOpenAIClient
    attr_reader :calls
    def initialize(*steps) = (@steps = steps
                              @calls = [])

    def responses = self

    def create(**kw)
      @calls << kw
      step = (@steps.length > 1) ? @steps.shift : @steps.first
      raise step if step.is_a?(Exception)
      step
    end
  end

  class RecordingLogger
    attr_reader :lines
    def initialize = @lines = []
    def log(msg) = @lines << msg
    def error(msg) = @lines << "ERROR #{msg}"
  end

  # --- helpers ---

  def script
    {
      title: "Episode 1",
      segments: [
        {name: "Opening", text: "Hello everyone!"},
        {name: "Wrap-Up", text: "Thanks for listening."}
      ]
    }
  end

  def expected_script_text
    "Title: Episode 1\n\n--- Opening ---\nHello everyone!\n\n--- Wrap-Up ---\nThanks for listening.\n"
  end

  def translation(title = "T", segs = [["Uvod", "Živjo"]])
    Translation.new(title, segs.map { |n, t| Segment.new(n, t) })
  end

  def claude_ok(parsed = translation) = ClaudeMessage.new(parsed, "end_turn")

  def openai_message(*contents)
    msg = OpenAI::Models::Responses::ResponseOutputMessage.new({})
    msg.define_singleton_method(:content) { contents }
    msg
  end

  def openai_ok(parsed = translation) = OpenAIResponse.new([openai_message(OpenAIContent.new(parsed))])

  def build(backend, lang: "sl", glossary: nil, steps: [], logger: nil)
    agent = TranslationAgent.new(target_language: lang, backend: backend, glossary: glossary, logger: logger)
    sleeps = []
    agent.define_singleton_method(:sleep) { |s| sleeps << s }
    client = (backend == "openai") ? FakeOpenAIClient.new(*steps) : FakeClaudeClient.new(*steps)
    agent.instance_variable_set((backend == "openai") ? :@openai_client : :@client, client)
    [agent, client, sleeps]
  end

  def anthropic_api_error(msg = "overloaded")
    Anthropic::Errors::APIError.new(url: URI("https://api.anthropic.com"), status: 529, message: msg)
  end

  def openai_api_error(msg = "rate limited")
    OpenAI::Errors::APIError.new(url: URI("https://api.openai.com"), status: 429, message: msg)
  end

  # --- prompt composition ---

  def test_translate_claude_backend_request_shape_pinned
    agent, client, = build("claude", steps: [claude_ok])

    agent.translate(script)

    call = client.calls.last
    assert_equal %i[model max_tokens system messages output_config request_options], call.keys
    assert_equal ClaudeModels.for(:translation), call[:model]
    assert_equal 16384, call[:max_tokens]
    assert_equal agent.send(:build_system_prompt), call[:system]
    assert_equal [{role: "user", content: "Translate this podcast script to Slovenian:\n\n#{expected_script_text}"}],
      call[:messages]
    assert_equal({format: TranslatedScript}, call[:output_config])
  end

  def test_translate_openai_backend_request_shape_pinned
    agent, client, = build("openai", steps: [openai_ok])

    agent.translate(script)

    call = client.calls.last
    assert_equal %i[model input text], call.keys
    assert_equal agent.instance_variable_get(:@openai_model), call[:model]
    assert_equal [
      {role: :system, content: agent.send(:build_system_prompt)},
      {role: :user, content: "Translate this podcast script to Slovenian:\n\n#{expected_script_text}"}
    ], call[:input]
    assert_equal OpenAITranslatedScript, call[:text]
  end

  # Divergent by design (P4-4, CRPR round 1): Claude caps output at 16384
  # (`max_tokens`); OpenAI sends NO output cap — on the Responses API
  # `max_output_tokens` counts reasoning tokens too, and the ja translator
  # (gpt-5) reasons by default, so a cap could truncate a long script. Also
  # divergent by API shape: Claude sends a separate `system:` with a
  # string-role user message; OpenAI puts the system prompt in `input` with
  # symbol roles.
  def test_translate_output_cap_claude_only
    c_agent, c_client, = build("claude", steps: [claude_ok])
    o_agent, o_client, = build("openai", steps: [openai_ok])

    c_agent.translate(script)
    o_agent.translate(script)

    assert_equal 16384, c_client.calls.last[:max_tokens]
    refute o_client.calls.last.key?(:max_tokens)
    refute o_client.calls.last.key?(:max_output_tokens)
    assert_equal "user", c_client.calls.last[:messages].first[:role]
    assert_equal :user, o_client.calls.last[:input].last[:role]
  end

  def test_translate_system_and_user_text_identical_across_paths
    glossary = {"Bitcoin" => "ビットコイン"}
    c_agent, c_client, = build("claude", lang: "jp", glossary: glossary, steps: [claude_ok])
    o_agent, o_client, = build("openai", lang: "jp", glossary: glossary, steps: [openai_ok])

    c_agent.translate(script)
    o_agent.translate(script)

    assert_equal c_client.calls.last[:system], o_client.calls.last[:input].first[:content]
    assert_equal c_client.calls.last[:messages].first[:content], o_client.calls.last[:input].last[:content]
    assert_includes c_client.calls.last[:system], "Translate the podcast script to Japanese."
  end

  def test_translate_unknown_language_code_used_verbatim_in_user_message_both_paths
    c_agent, c_client, = build("claude", lang: "xx", steps: [claude_ok])
    o_agent, o_client, = build("openai", lang: "xx", steps: [openai_ok])

    c_agent.translate(script)
    o_agent.translate(script)

    assert c_client.calls.last[:messages].first[:content].start_with?("Translate this podcast script to xx:\n\n")
    assert o_client.calls.last[:input].last[:content].start_with?("Translate this podcast script to xx:\n\n")
  end

  # P4-4 (Q-42): the glossary pair lines start at column 0 (previously 6
  # leading spaces) and embedded double quotes are escaped.
  def test_build_system_prompt_glossary_block_exact_text_pinned
    agent, = build("claude", glossary: {"Bitcoin" => "bitcoin", "say \"hi\"" => "x"})

    prompt = agent.send(:build_system_prompt)

    expected_tail = "- Write naturally as spoken Slovenian — no stage directions, no timestamps, no markdown\n" \
      "\nGLOSSARY (always use these exact translations for the listed terms,\n" \
      "overriding the natural-conventions rule above):\n" \
      "- \"Bitcoin\" → \"bitcoin\"\n" \
      "- \"say \\\"hi\\\"\" → \"x\"\n"
    assert prompt.end_with?(expected_tail), prompt
  end

  def test_build_system_prompt_without_glossary_ends_after_rules
    agent, = build("claude", glossary: {})

    prompt = agent.send(:build_system_prompt)

    assert prompt.start_with?("You are an expert translator specializing in spoken-word audio content.\n" \
      "Translate the podcast script to Slovenian.\n\nRules:\n")
    assert prompt.end_with?("- Write naturally as spoken Slovenian — no stage directions, no timestamps, no markdown\n")
    assert_equal 19, prompt.lines.length
  end

  def test_build_system_prompt_glossary_preserves_insertion_order
    agent, = build("claude", glossary: {"zeta" => "Z", "alpha" => "A"})

    prompt = agent.send(:build_system_prompt)

    assert_operator prompt.index("\"zeta\""), :<, prompt.index("\"alpha\"")
  end

  def test_format_script_for_translation_exact_text_pinned
    agent, = build("claude")

    assert_equal expected_script_text, agent.send(:format_script_for_translation, script)
  end

  # --- response parsing ---

  def test_translate_claude_backend_maps_parsed_output_to_plain_hashes
    agent, = build("claude", steps: [claude_ok(translation("Naslov", [["A", "a"], ["B", "b"]]))])

    result = agent.translate(script)

    assert_equal({title: "Naslov", segments: [{name: "A", text: "a"}, {name: "B", text: "b"}]}, result)
  end

  def test_translate_openai_backend_maps_parsed_output_to_plain_hashes
    agent, = build("openai", steps: [openai_ok(translation("Naslov", [["A", "a"], ["B", "b"]]))])

    result = agent.translate(script)

    assert_equal({title: "Naslov", segments: [{name: "A", text: "a"}, {name: "B", text: "b"}]}, result)
  end

  def test_translate_openai_backend_skips_refusal_and_nil_parsed_contents
    refusal = OpenAI::Models::Responses::ResponseOutputRefusal.new(refusal: "no", type: :refusal)
    response = OpenAIResponse.new([openai_message(refusal, OpenAIContent.new(nil), OpenAIContent.new(translation("Kept")))])
    agent, = build("openai", steps: [response])

    assert_equal "Kept", agent.translate(script)[:title]
  end

  def test_translate_openai_backend_uses_first_parsed_across_messages
    response = OpenAIResponse.new([
      openai_message(OpenAIContent.new(translation("First"))),
      openai_message(OpenAIContent.new(translation("Second")))
    ])
    agent, = build("openai", steps: [response])

    assert_equal "First", agent.translate(script)[:title]
  end

  def test_translate_openai_backend_ignores_non_message_output_items
    stray = Struct.new(:content).new([OpenAIContent.new(translation("Stray"))])
    response = OpenAIResponse.new([stray, openai_message(OpenAIContent.new(translation("Real")))])
    agent, = build("openai", steps: [response])

    assert_equal "Real", agent.translate(script)[:title]
  end

  def test_translate_openai_backend_carries_over_sources
    agent, = build("openai", steps: [openai_ok(translation("T", [["A", "a"], ["B", "b"]]))])
    src = script.merge(sources: [{url: "u"}])
    src[:segments] = [src[:segments][0].merge(sources: [{url: "s1"}]), src[:segments][1]]

    result = agent.translate(src)

    assert_equal [{url: "u"}], result[:sources]
    assert_equal [{url: "s1"}], result[:segments][0][:sources]
    refute result[:segments][1].key?(:sources)
  end

  # --- errors and retries ---

  def test_translate_claude_backend_api_error_retried_then_succeeds
    agent, client, sleeps = build("claude", steps: [anthropic_api_error, claude_ok])

    assert_equal "T", agent.translate(script)[:title]
    assert_equal 2, client.calls.length
    assert_equal [2], sleeps
  end

  def test_translate_openai_backend_api_error_retried_then_succeeds
    agent, client, sleeps = build("openai", steps: [openai_api_error, openai_ok])

    assert_equal "T", agent.translate(script)[:title]
    assert_equal 2, client.calls.length
    assert_equal [2], sleeps
  end

  def test_translate_claude_backend_nil_output_exhausts_retries_with_wrapped_message
    agent, client, sleeps = build("claude", steps: [ClaudeMessage.new(nil, "end_turn")])

    err = assert_raises(RuntimeError) { agent.translate(script) }

    assert_equal "TranslationAgent failed after 4 attempts: No parsed output (stop_reason: end_turn)", err.message
    assert_equal 4, client.calls.length
    assert_equal [2, 4, 8], sleeps
  end

  def test_translate_claude_backend_sdk_error_hash_retried_and_wrapped
    agent, client, = build("claude", steps: [ClaudeMessage.new({error: "boom"}, "end_turn")])

    err = assert_raises(RuntimeError) { agent.translate(script) }

    assert_equal "TranslationAgent failed after 4 attempts: SDK parsing failed: boom", err.message
    assert_equal 4, client.calls.length
  end

  def test_translate_openai_backend_empty_output_exhausts_retries_with_wrapped_message
    agent, client, sleeps = build("openai", steps: [OpenAIResponse.new([])])

    err = assert_raises(RuntimeError) { agent.translate(script) }

    assert_equal "TranslationAgent failed after 4 attempts: " \
      "OpenAI returned no parsed output (possibly refusal or empty response)", err.message
    assert_equal 4, client.calls.length
    assert_equal [2, 4, 8], sleeps
  end

  def test_translate_openai_backend_refusal_only_retried_as_empty_output
    refusal = OpenAI::Models::Responses::ResponseOutputRefusal.new(refusal: "no", type: :refusal)
    agent, client, = build("openai", steps: [OpenAIResponse.new([openai_message(refusal)])])

    assert_raises(RuntimeError) { agent.translate(script) }
    assert_equal 4, client.calls.length
  end

  def test_translate_claude_backend_api_error_exhausts_retries_with_wrapped_message
    agent, client, = build("claude", steps: [anthropic_api_error("overloaded")])

    err = assert_raises(RuntimeError) { agent.translate(script) }

    assert_equal "TranslationAgent failed after 4 attempts: overloaded", err.message
    assert_equal 4, client.calls.length
  end

  # Divergence: each path retries only its own SDK's APIError.
  def test_translate_foreign_sdk_error_not_retried_divergent_between_paths
    c_agent, c_client, = build("claude", steps: [openai_api_error])
    o_agent, o_client, = build("openai", steps: [anthropic_api_error])

    assert_raises(OpenAI::Errors::APIError) { c_agent.translate(script) }
    assert_raises(Anthropic::Errors::APIError) { o_agent.translate(script) }
    assert_equal 1, c_client.calls.length
    assert_equal 1, o_client.calls.length
  end

  def test_translate_unlisted_error_propagates_unwrapped_both_paths
    %w[claude openai].each do |backend|
      agent, client, sleeps = build(backend, steps: [ArgumentError.new("bad")])

      err = assert_raises(ArgumentError) { agent.translate(script) }
      assert_equal "bad", err.message
      assert_equal 1, client.calls.length, backend
      assert_empty sleeps, backend
    end
  end

  # Aligned (P4-4): a stop at the output cap is a TruncatedOutputError after
  # ONE call on both paths (Claude stop_reason max_tokens; OpenAI status
  # incomplete with reason max_output_tokens). An OpenAI empty/unparsed
  # response that is not truncated stays a retried StructuredOutputError.
  def test_translate_truncation_handling_aligned_between_paths
    c_agent, c_client, = build("claude", steps: [ClaudeMessage.new(nil, "max_tokens")])
    truncated = OpenAIResponse.new([], :incomplete, Usage.new, OpenAIIncomplete.new(:max_output_tokens))
    o_agent, o_client, = build("openai", steps: [truncated])

    err = assert_raises(TruncatedOutputError) { c_agent.translate(script) }
    assert_match(/\AOutput truncated at max_tokens \(400 output tokens\)/, err.message)
    assert_equal 1, c_client.calls.length

    err = assert_raises(TruncatedOutputError) { o_agent.translate(script) }
    assert_match(/\AOutput truncated at max_output_tokens \(400 output tokens\)/, err.message)
    assert_equal 1, o_client.calls.length
  end

  # --- logging ---

  # Aligned (P4-4): both paths log the same 4-line shape — start, "generated
  # in Xs (stop)", usage, "complete: N". OpenAI's stop is the response status.
  def test_translate_logging_aligned_between_paths
    c_logger = RecordingLogger.new
    o_logger = RecordingLogger.new
    c_agent, = build("claude", steps: [claude_ok], logger: c_logger)
    o_response = openai_ok
    o_response.status = :completed
    o_response.usage = Usage.new
    o_agent, = build("openai", steps: [o_response], logger: o_logger)

    c_agent.translate(script)
    o_agent.translate(script)

    assert_equal 4, c_logger.lines.length
    assert_equal "[TranslationAgent] Translating script to Slovenian (sl) with #{ClaudeModels.for(:translation)} (claude)",
      c_logger.lines[0]
    assert_match(/\A\[TranslationAgent\] Translation generated in [\d.]+s \(end_turn\)\z/, c_logger.lines[1])
    assert_equal "[TranslationAgent]   Input: 500 tokens | Output: 400 tokens", c_logger.lines[2]
    assert_equal "[TranslationAgent] Translation complete: 1 segments", c_logger.lines[3]

    model = o_agent.instance_variable_get(:@openai_model)
    assert_equal 4, o_logger.lines.length
    assert_equal "[TranslationAgent] Translating script to Slovenian (sl) with #{model} (openai)", o_logger.lines[0]
    assert_match(/\A\[TranslationAgent\] Translation generated in [\d.]+s \(completed\)\z/, o_logger.lines[1])
    assert_equal "[TranslationAgent]   Input: 500 tokens | Output: 400 tokens", o_logger.lines[2]
    assert_equal "[TranslationAgent] Translation complete: 1 segments", o_logger.lines[3]
  end

  # When the backend reports no usage the usage line is omitted (3 lines).
  def test_translate_logging_without_usage_omits_usage_line
    logger = RecordingLogger.new
    agent, = build("openai", steps: [openai_ok], logger: logger)

    agent.translate(script)

    assert_equal 3, logger.lines.length
    assert_match(/\A\[TranslationAgent\] Translation generated in [\d.]+s \(\?\)\z/, logger.lines[1])
  end

  def test_translate_retry_log_line_pinned_both_paths
    {"claude" => [anthropic_api_error("x"), claude_ok], "openai" => [openai_api_error("x"), openai_ok]}.each do |backend, steps|
      logger = RecordingLogger.new
      agent, = build(backend, steps: steps, logger: logger)

      agent.translate(script)

      assert_includes logger.lines, "[TranslationAgent] TranslationAgent error (attempt 1/3): x. Retrying in 2s...", backend
    end
  end

  # --- construction ---

  def test_initialize_nil_backend_defaults_to_claude_path
    agent = TranslationAgent.new(target_language: "sl", backend: nil)
    client = FakeClaudeClient.new(claude_ok)
    agent.instance_variable_set(:@client, client)

    agent.translate(script)

    assert_equal 1, client.calls.length
  end
end
