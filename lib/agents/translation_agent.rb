# frozen_string_literal: true

require_relative "../anthropic_client"
require_relative "../openai_client"
require_relative "../loggable"
require_relative "../retryable"
require_relative "../language_names"
require_relative "../usage_logger"

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
  include UsageLogger

  MAX_RETRIES = 3
  SUPPORTED_BACKENDS = %w[claude openai].freeze

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
      init_anthropic_client
      @model = model_override if model_override
    end
  end

  # Input: { title:, segments: [{ name:, text: }] }
  # Output: { title:, segments: [{ name:, text: }] } translated to target language
  def translate(script)
    case @backend
    when "openai" then translate_with_openai(script)
    else translate_with_claude(script)
    end
  end

  private

  def translate_with_claude(script)
    log("Translating script to #{@language_name} (#{@target_language}) with #{@model} (claude)")

    script_text = format_script_for_translation(script)

    with_retries(max: MAX_RETRIES, on: [Anthropic::Errors::APIError, StructuredOutputError]) do
      message, elapsed = measure_time do
        @client.messages.create(
          model: @model,
          max_tokens: 8192,
          system: build_system_prompt,
          messages: [
            {
              role: "user",
              content: "Translate this podcast script to #{@language_name}:\n\n#{script_text}"
            }
          ],
          output_config: { format: TranslatedScript }
        )
      end

      log_api_usage("Translation generated", message, elapsed)

      translated = require_parsed_output!(message, TranslatedScript)

      result = {
        title: translated.title,
        segments: translated.segments.map { |s| { name: s.name, text: s.text } }
      }
      result = carry_over_sources(script, result)

      log("Translation complete: #{result[:segments].length} segments")
      result
    end
  end

  def translate_with_openai(script)
    log("Translating script to #{@language_name} (#{@target_language}) with #{@openai_model} (openai)")

    script_text = format_script_for_translation(script)

    with_retries(max: MAX_RETRIES, on: [OpenAI::Errors::APIError, StructuredOutputError]) do
      response, elapsed = measure_time do
        @openai_client.responses.create(
          model: @openai_model,
          input: [
            { role: :system, content: build_system_prompt },
            { role: :user, content: "Translate this podcast script to #{@language_name}:\n\n#{script_text}" }
          ],
          text: OpenAITranslatedScript
        )
      end

      translated = extract_openai_parsed!(response)

      result = {
        title: translated.title,
        segments: translated.segments.map { |s| { name: s.name, text: s.text } }
      }
      result = carry_over_sources(script, result)

      log("Translation complete in #{elapsed}s: #{result[:segments].length} segments")
      result
    end
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

    pairs = @glossary.map { |term, translation| "      - \"#{term}\" → \"#{translation}\"" }.join("\n")
    base + <<~GLOSSARY

      GLOSSARY (always use these exact translations for the listed terms,
      overriding the natural-conventions rule above):
      #{pairs.lstrip.then { |s| s.empty? ? "" : pairs }}
    GLOSSARY
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
