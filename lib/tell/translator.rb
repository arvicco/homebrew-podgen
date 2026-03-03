# frozen_string_literal: true

module Tell
  LANGUAGE_NAMES = {
    "en" => "English",
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
    "ms" => "Malay",
    "sl" => "Slovenian",
    "hr" => "Croatian",
    "sr" => "Serbian",
    "bg" => "Bulgarian",
    "sk" => "Slovak",
    "lt" => "Lithuanian",
    "lv" => "Latvian",
    "et" => "Estonian"
  }.freeze

  def self.build_translator(engine, api_key)
    case engine
    when "deepl"  then DeeplTranslator.new(api_key)
    when "claude" then ClaudeTranslator.new(api_key)
    when "openai" then OpenaiTranslator.new(api_key)
    else raise "Unknown translation engine: #{engine}"
    end
  end

  class DeeplTranslator
    def initialize(api_key)
      require "deepl"
      DeepL.configure do |config|
        config.auth_key = api_key
      end
    end

    def translate(text, from:, to:)
      result = DeepL.translate(text, from.upcase, to.upcase)
      result.text
    end
  end

  class ClaudeTranslator
    def initialize(api_key)
      require "anthropic"
      @client = Anthropic::Client.new(api_key: api_key)
      @model = ENV.fetch("CLAUDE_MODEL", "claude-sonnet-4-6")
    end

    def translate(text, from:, to:)
      to_name = LANGUAGE_NAMES.fetch(to, to)

      message = @client.messages.create(
        model: @model,
        max_tokens: 4096,
        messages: [
          {
            role: "user",
            content: "Translate the following text to #{to_name}. If it is already in #{to_name}, return it unchanged. Output ONLY the translated text — no explanations, no commentary.\n\n#{text}"
          }
        ]
      )

      message.content.first.text.strip
    end
  end

  class OpenaiTranslator
    API_URL = "https://api.openai.com/v1/chat/completions"

    def initialize(api_key)
      require "httparty"
      @api_key = api_key
      @model = ENV.fetch("OPENAI_TRANSLATE_MODEL", "gpt-4o-mini")
    end

    def translate(text, from:, to:)
      to_name = LANGUAGE_NAMES.fetch(to, to)

      response = HTTParty.post(
        API_URL,
        headers: {
          "Authorization" => "Bearer #{@api_key}",
          "Content-Type" => "application/json"
        },
        body: {
          model: @model,
          messages: [
            {
              role: "user",
              content: "Translate the following text to #{to_name}. If it is already in #{to_name}, return it unchanged. Output ONLY the translated text — no explanations, no commentary.\n\n#{text}"
            }
          ],
          temperature: 0.3
        }.to_json,
        timeout: 30
      )

      unless response.code == 200
        raise "OpenAI translation failed: HTTP #{response.code}: #{response.body[0..200]}"
      end

      data = JSON.parse(response.body)
      data.dig("choices", 0, "message", "content").strip
    end
  end
end
