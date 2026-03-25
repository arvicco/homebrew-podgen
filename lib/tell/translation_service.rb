# frozen_string_literal: true

require_relative "detector"

module Tell
  # Handles language detection and bidirectional translation.
  # Extracted from Engine to separate translation concerns from
  # glossing, phonetics, and orchestration.
  class TranslationService
    def initialize(config, translator: nil)
      @config = config
      @translator_instance = translator
    end

    def resolve_source(text, translate_from, target_lang = nil)
      target = target_lang || @config.target_language
      return translate_from unless translate_from == "auto"

      detected = Detector.detect(text)
      if detected.nil? && Detector.has_characteristic_chars?(text, target)
        target
      else
        detected
      end
    end

    def forward_translate(text, from:, to:, hints: nil)
      translation = translator.translate(text, from: from, to: to, hints: hints)

      if translation.strip.downcase == text.strip.downcase
        { type: :same_text, text: text, lang: to }
      elsif Detector.explanation?(text, translation)
        { type: :explanation, text: translation, lang: to }
      else
        { type: :translation, text: translation, lang: to }
      end
    rescue => e
      { type: :error, error: e, lang: to }
    end

    def reverse_translate(text, from:, to:)
      translation = translator.translate(text, from: from, to: to)

      if translation.strip.downcase == text.strip.downcase
        { type: :same_text, text: text, lang: to }
      else
        { type: :translation, text: translation, lang: to }
      end
    rescue => e
      { type: :error, error: e, lang: to }
    end

    private

    def translator
      @translator_instance ||= Tell.build_translator_chain(
        @config.translation_engines, @config.engine_api_keys,
        timeout: @config.translation_timeout
      )
    end
  end
end
