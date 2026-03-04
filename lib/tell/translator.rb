# frozen_string_literal: true

require_relative "colors"
require_relative "../language_names"

module Tell

  def self.build_translator(engine, api_key)
    case engine
    when "deepl"  then DeeplTranslator.new(api_key)
    when "claude" then ClaudeTranslator.new(api_key)
    when "openai" then OpenaiTranslator.new(api_key)
    else raise "Unknown translation engine: #{engine}"
    end
  end

  def self.build_translator_chain(engines, api_keys, timeout:)
    pairs = engines.filter_map do |eng|
      key = api_keys[eng]
      next unless key
      [eng, build_translator(eng, key)]
    end
    TranslatorChain.new(pairs, timeout: timeout)
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
      @client = Anthropic::Client.new(api_key: api_key, timeout: 15, max_retries: 1)
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
    MAX_RETRIES = 2

    def initialize(api_key)
      require "httparty"
      @api_key = api_key
      @model = ENV.fetch("OPENAI_TRANSLATE_MODEL", "gpt-4o-mini")
    end

    def translate(text, from:, to:)
      to_name = LANGUAGE_NAMES.fetch(to, to)

      (MAX_RETRIES + 1).times do |attempt|
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

        if [429, 503, 529].include?(response.code) && attempt < MAX_RETRIES
          sleep((attempt + 1) * 2)
          next
        end

        unless response.code == 200
          raise "OpenAI translation failed: HTTP #{response.code}: #{response.body[0..200]}"
        end

        data = JSON.parse(response.body)
        return data.dig("choices", 0, "message", "content").strip
      end
    end
  end

  class TranslatorChain
    def initialize(engines_with_translators, timeout:)
      require "timeout"
      @translators = engines_with_translators
      @timeout = timeout
    end

    def translate(text, from:, to:)
      last_error = nil
      @translators.each do |name, translator|
        return Timeout.timeout(@timeout) { translator.translate(text, from: from, to: to) }
      rescue Timeout::Error => e
        $stderr.puts Colors.warning("#{name}: timed out (#{@timeout}s), trying next...")
        last_error = e
      rescue => e
        $stderr.puts Colors.warning("#{name}: #{friendly_error(e)}, trying next...")
        last_error = e
      end
      raise last_error || RuntimeError.new("All translation engines failed")
    end

    private

    def friendly_error(err)
      msg = err.message
      if msg.include?('"overloaded_error"') || msg.include?("status: 529")
        "API overloaded"
      elsif msg.include?('"rate_limit_error"') || msg.include?("status: 429")
        "rate limited"
      elsif msg =~ /status[":]\s*(\d{3})/ && msg =~ /"message":\s*"([^"]+)"/
        "HTTP #{$1}: #{$2}"
      else
        msg.length > 80 ? "#{msg[0, 77]}..." : msg
      end
    end
  end
end
