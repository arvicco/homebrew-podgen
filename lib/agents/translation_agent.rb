# frozen_string_literal: true

require_relative "../anthropic_client"
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

class TranslationAgent
  include AnthropicClient
  include Loggable
  include Retryable
  include UsageLogger

  MAX_RETRIES = 3

  def initialize(target_language:, logger: nil)
    @logger = logger
    init_anthropic_client
    @target_language = target_language
    @language_name = LANGUAGE_NAMES.fetch(target_language, target_language)
  end

  # Input: { title:, segments: [{ name:, text: }] }
  # Output: { title:, segments: [{ name:, text: }] } translated to target language
  def translate(script)
    log("Translating script to #{@language_name} (#{@target_language}) with #{@model}")

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

      log("Translation complete: #{result[:segments].length} segments")
      result
    end
  end

  private

  def build_system_prompt
    <<~PROMPT
      You are an expert translator specializing in spoken-word audio content.
      Translate the podcast script to #{@language_name}.

      Rules:
      - Translate for spoken word: the text will be read aloud by a TTS engine
      - Preserve the exact segment structure: same segment names, same number of segments
      - Translate the title to #{@language_name}
      - Adapt idioms and cultural references naturally — do not translate literally when it sounds unnatural
      - Keep proper nouns, brand names, and technical terms as-is (e.g. "Ruby on Rails", "GitHub", "OpenAI")
      - Maintain the same tone, pacing, and style as the original
      - Do not add or remove content — translate faithfully
      - Write naturally as spoken #{@language_name} — no stage directions, no timestamps, no markdown
    PROMPT
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
