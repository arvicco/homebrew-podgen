# frozen_string_literal: true

require "anthropic"

class TranslatedSegment < Anthropic::BaseModel
  required :name, String
  required :text, String
end

class TranslatedScript < Anthropic::BaseModel
  required :title, String
  required :segments, Anthropic::ArrayOf[TranslatedSegment]
end

class TranslationAgent
  MAX_RETRIES = 3

  LANGUAGE_NAMES = {
    "es" => "Spanish",
    "fr" => "French",
    "de" => "German",
    "it" => "Italian",
    "pt" => "Portuguese",
    "nl" => "Dutch",
    "pl" => "Polish",
    "ja" => "Japanese",
    "ko" => "Korean",
    "zh" => "Chinese",
    "ar" => "Arabic",
    "hi" => "Hindi",
    "ru" => "Russian",
    "tr" => "Turkish",
    "sv" => "Swedish",
    "da" => "Danish",
    "no" => "Norwegian",
    "fi" => "Finnish",
    "uk" => "Ukrainian",
    "cs" => "Czech",
    "ro" => "Romanian",
    "hu" => "Hungarian",
    "el" => "Greek",
    "he" => "Hebrew",
    "th" => "Thai",
    "vi" => "Vietnamese",
    "id" => "Indonesian",
    "ms" => "Malay"
  }.freeze

  def initialize(target_language:, logger: nil)
    @logger = logger
    @client = Anthropic::Client.new
    @model = ENV.fetch("CLAUDE_MODEL", "claude-opus-4-6")
    @target_language = target_language
    @language_name = LANGUAGE_NAMES.fetch(target_language, target_language)
  end

  # Input: { title:, segments: [{ name:, text: }] }
  # Output: { title:, segments: [{ name:, text: }] } translated to target language
  def translate(script)
    log("Translating script to #{@language_name} (#{@target_language}) with #{@model}")

    script_text = format_script_for_translation(script)

    retries = 0
    begin
      retries += 1
      start = Time.now

      message = @client.messages.create(
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

      elapsed = (Time.now - start).round(2)
      log_usage(message, elapsed)

      translated = message.parsed_output
      raise "Structured output parsing failed" if translated.nil?

      result = {
        title: translated.title,
        segments: translated.segments.map { |s| { name: s.name, text: s.text } }
      }

      log("Translation complete: #{result[:segments].length} segments")
      result

    rescue Anthropic::Errors::APIError => e
      if retries <= MAX_RETRIES
        sleep_time = 2**retries
        log("API error (attempt #{retries}/#{MAX_RETRIES}): #{e.message}. Retrying in #{sleep_time}s...")
        sleep(sleep_time)
        retry
      else
        raise "TranslationAgent failed after #{MAX_RETRIES} retries: #{e.message}"
      end
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

  def log_usage(message, elapsed)
    usage = message.usage
    log("Translation generated in #{elapsed}s (#{message.stop_reason})")
    log("  Input: #{usage.input_tokens} tokens | Output: #{usage.output_tokens} tokens")
    cache_create = usage.cache_creation_input_tokens || 0
    cache_read = usage.cache_read_input_tokens || 0
    log("  Cache create: #{cache_create} | Cache read: #{cache_read}") if cache_create > 0 || cache_read > 0
  end

  def log(message)
    if @logger
      @logger.log("[TranslationAgent] #{message}")
    else
      puts "[TranslationAgent] #{message}"
    end
  end
end
