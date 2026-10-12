# frozen_string_literal: true

require_relative "../anthropic_client"
require_relative "../openai_client"
require_relative "../loggable"
require_relative "../retryable"
require_relative "../language_names"

class TranslatedSegment < Anthropic::BaseModel
  required :name, String
  required :text, String
end

class TranslatedScript < Anthropic::BaseModel
  required :title, String
  required :segments, Anthropic::ArrayOf[TranslatedSegment]
end

class OpenAITranslatedSegment < OpenAI::BaseModel
  required :name, String
  required :text, String
end

class OpenAITranslatedScript < OpenAI::BaseModel
  required :title, String
  required :segments, OpenAI::ArrayOf[OpenAITranslatedSegment]
end

class TranslationAgent
  include AnthropicClient
  include OpenAIClient
  include Loggable
  include Retryable

  MAX_RETRIES = 3
  MAX_OUTPUT_TOKENS = 16384
  SUPPORTED_BACKENDS = %w[claude openai].freeze
  # Each backend retries only its own SDK's API errors.
  BACKEND_API_ERRORS = {
    "claude" => Anthropic::Errors::APIError,
    "openai" => OpenAI::Errors::APIError
  }.freeze

  def initialize(target_language:, backend: "claude", model_override: nil, glossary: nil, logger: nil)
    @logger = logger
    @target_language = target_language
    @language_name = LANGUAGE_NAMES.fetch(target_language, target_language)
    @glossary = glossary || {}
    @backend = backend || "claude"
    raise ArgumentError, "Unknown translation backend: #{@backend}" unless SUPPORTED_BACKENDS.include?(@backend)

    if @backend == "openai"
      init_openai_client(model_override: model_override)
    else
      init_anthropic_client(role: :translation)
      @model = model_override if model_override
    end
  end

  # Input: { title:, segments: [{ name:, text: }] }
  # Output: { title:, segments: [{ name:, text: }] } translated to target language
  #
  # One core for both backends (P4-4): prompt composition, retry policy,
  # logging and result mapping live here; the backend adapters below only
  # build the request, read stop reason + usage, and extract/validate the
  # parsed output.
  def translate(script)
    log("Translating script to #{@language_name} (#{@target_language}) with #{backend_model} (#{@backend})")

    system_prompt = build_system_prompt
    user_message = "Translate this podcast script to #{@language_name}:\n\n#{format_script_for_translation(script)}"

    with_retries(max: MAX_RETRIES, on: [BACKEND_API_ERRORS.fetch(@backend), StructuredOutputError]) do
      response, elapsed = measure_time { send(:"#{@backend}_request", system_prompt, user_message) }

      stop_reason, usage = send(:"#{@backend}_stop_and_usage", response)
      log_generation(elapsed, stop_reason, usage)

      translated = send(:"#{@backend}_parsed!", response)

      result = {
        title: translated.title,
        segments: translated.segments.map { |s| { name: s.name, text: s.text } }
      }
      result = carry_over_sources(script, result)

      log("Translation complete: #{result[:segments].length} segments")
      result
    end
  end

  private

  def backend_model
    (@backend == "openai") ? @openai_model : @model
  end

  # usage: { input:, output:, cache_create:, cache_read: }, or nil when the
  # backend reported none (then only the "generated" line is logged).
  def log_generation(elapsed, stop_reason, usage)
    log("Translation generated in #{elapsed}s (#{stop_reason})")
    return unless usage

    log("  Input: #{usage[:input]} tokens | Output: #{usage[:output]} tokens")
    cache_create = usage[:cache_create] || 0
    cache_read = usage[:cache_read] || 0
    log("  Cache create: #{cache_create} | Cache read: #{cache_read}") if cache_create > 0 || cache_read > 0
  end

  # --- Claude adapter ---

  def claude_request(system_prompt, user_message)
    @client.messages.create(
      model: @model,
      max_tokens: MAX_OUTPUT_TOKENS,
      system: system_prompt,
      messages: [{ role: "user", content: user_message }],
      output_config: { format: TranslatedScript }
    )
  end

  def claude_stop_and_usage(message)
    usage = message.usage
    [message.stop_reason, {
      input: usage.input_tokens,
      output: usage.output_tokens,
      cache_create: usage.cache_creation_input_tokens,
      cache_read: usage.cache_read_input_tokens
    }]
  end

  # Raises TruncatedOutputError on a max_tokens stop, StructuredOutputError
  # (retried) on a missing or unparseable output.
  def claude_parsed!(message)
    require_parsed_output!(message, TranslatedScript)
  end

  # --- OpenAI adapter ---

  # No output cap here (unlike Claude): Responses API `max_output_tokens`
  # counts reasoning tokens too, and reasoning models (gpt-5) could exhaust
  # it on a long script. The truncation check below still catches a stop at
  # the model's own ceiling.
  def openai_request(system_prompt, user_message)
    @openai_client.responses.create(
      model: @openai_model,
      input: [
        { role: :system, content: system_prompt },
        { role: :user, content: user_message }
      ],
      text: OpenAITranslatedScript
    )
  end

  def openai_stop_and_usage(response)
    usage = response.usage if response.respond_to?(:usage)
    reported = { input: usage.input_tokens, output: usage.output_tokens } if usage
    [openai_stop_reason(response) || "?", reported]
  end

  # The incomplete reason when there is one (e.g. "max_output_tokens"),
  # else the response status (e.g. "completed").
  def openai_stop_reason(response)
    return unless response.respond_to?(:status)

    reason = response.incomplete_details&.reason if response.respond_to?(:incomplete_details)
    (reason || response.status)&.to_s
  end

  def openai_parsed!(response)
    raise_openai_truncated!(response)
    extract_openai_parsed!(response)
  end

  # A response cut at the model's output ceiling carries truncated JSON; re-issuing the
  # identical request cannot succeed, so it is a TruncatedOutputError (not
  # retried), mirroring the Claude max_tokens check (P4-4).
  def raise_openai_truncated!(response)
    return unless openai_stop_reason(response) == "max_output_tokens"

    tokens = response.usage&.output_tokens if response.respond_to?(:usage)
    raise TruncatedOutputError,
      "Output truncated at max_output_tokens (#{tokens || "?"} output tokens) — " \
      "structured response is incomplete; the model's output ceiling was reached"
  end

  # Sources are not translated (they're URLs + titles in the source language).
  # The structured-output schema doesn't include them, so we copy the original
  # script's :sources (top-level) and per-segment :sources back onto the
  # translated result by positional segment index. This way, downstream
  # rendering keeps inline links intact across all languages.
  def carry_over_sources(original, translated)
    translated[:sources] = original[:sources] if original[:sources]
    Array(original[:segments]).each_with_index do |orig_seg, i|
      next unless orig_seg[:sources]&.any?
      target = translated[:segments][i]
      next unless target
      target[:sources] = orig_seg[:sources]
    end
    translated
  end

  def extract_openai_parsed!(response)
    # GPT-5 may interleave ResponseReasoningItem entries (content: nil) with
    # message items in response.output. Keep only message items, then walk
    # their content arrays and skip refusals.
    parsed = response
      .output
      .grep(OpenAI::Models::Responses::ResponseOutputMessage)
      .flat_map(&:content)
      .grep_v(OpenAI::Models::Responses::ResponseOutputRefusal)
      .map(&:parsed)
      .compact
      .first

    raise StructuredOutputError, "OpenAI returned no parsed output (possibly refusal or empty response)" if parsed.nil?
    parsed
  end

  def build_system_prompt
    base = <<~PROMPT
      You are an expert translator specializing in spoken-word audio content.
      Translate the podcast script to #{@language_name}.

      Rules:
      - Translate for spoken word: the text will be read aloud by a TTS engine
      - Translate every segment name (they appear as ## headings in the published
        transcript and on the site). Preserve the same number of segments in the
        same order.
      - Translate the title to #{@language_name}
      - Adapt idioms and cultural references naturally — do not translate literally when it sounds unnatural
      - Use the natural conventions of #{@language_name} for brand names and technical
        loanwords. Match how well-edited journalism in #{@language_name} actually writes
        these terms — Latin-script languages typically keep most brand names verbatim
        ("GitHub", "Ruby on Rails"); non-Latin scripts apply standard transliteration
        or loan conventions (e.g. ビットコイン in Japanese, but "GitHub" preserved in
        Latin script in JP tech writing).
      - Maintain the same tone, pacing, and style as the original
      - Do not add or remove content — translate faithfully
      - Write naturally as spoken #{@language_name} — no stage directions, no timestamps, no markdown
    PROMPT

    return base if @glossary.empty?

    # Pair lines start at column 0 (interpolated text is not de-indented by
    # the heredoc) and embedded double quotes are escaped (P4-4, Q-42).
    pairs = @glossary.map { |term, translation| "- \"#{escape_quotes(term)}\" → \"#{escape_quotes(translation)}\"" }.join("\n")
    base + <<~GLOSSARY

      GLOSSARY (always use these exact translations for the listed terms,
      overriding the natural-conventions rule above):
      #{pairs}
    GLOSSARY
  end

  def escape_quotes(text)
    text.to_s.gsub('"', '\"')
  end

  def format_script_for_translation(script)
    parts = ["Title: #{script[:title]}", ""]
    script[:segments].each do |seg|
      parts << "--- #{seg[:name]} ---"
      parts << seg[:text]
      parts << ""
    end
    parts.join("\n")
  end

end
