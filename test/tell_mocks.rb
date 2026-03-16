# frozen_string_literal: true

# Shared mock objects for Tell unit tests (Engine, Processor, Web).

MockConfig = Struct.new(
  :original_language, :target_language, :voice_id,
  :voice_male, :voice_female,
  :translation_engines, :tts_engine, :engine_api_keys,
  :api_key, :tts_api_key, :tts_model_id, :output_format,
  :google_language_code, :reverse_translate, :gloss, :gloss_reverse,
  :phonetic, :gloss_model, :phonetic_model, :phonetic_system,
  :translation_timeout,
  keyword_init: true
) do
  def translation_engine
    translation_engines&.first
  end

  def engine_api_key
    engine_api_keys&.dig(translation_engine)
  end

  def reverse_language
    original_language == "auto" ? "en" : original_language
  end

  def gloss_reconciler
    gloss_model&.first
  end

  def phonetic_reconciler
    phonetic_model&.first
  end

  def phonetic_system_for(_lang)
    phonetic_system
  end
end

class MockTts
  attr_reader :calls, :voices

  def initialize
    @calls = []
    @voices = []
  end

  def synthesize(text, voice: nil)
    @calls << text
    @voices << voice
    "fake_audio"
  end
end

class MockTranslator
  attr_reader :reverse_calls, :forward_calls, :forward_hints
  attr_accessor :forward_result, :forward_error

  def initialize
    @reverse_calls = []
    @forward_calls = []
    @forward_hints = []
    @forward_result = nil
    @forward_error = nil
  end

  def translate(text, from:, to:, hints: nil)
    raise @forward_error if @forward_error

    if to == "en" # reverse translation
      @reverse_calls << [text, { from: from, to: to }]
      "back_translation"
    else
      @forward_calls << [text, { from: from, to: to }]
      @forward_hints << hints
      @forward_result || text
    end
  end
end

class MockGlosser
  attr_reader :calls, :reconcile_calls, :phonetic_calls
  attr_accessor :error

  def initialize(gloss_result: nil, gloss_translate_result: nil,
                 gloss_phonetic_result: nil, gloss_translate_phonetic_result: nil,
                 phonetic_result: nil, error: nil)
    @calls = []
    @reconcile_calls = []
    @phonetic_calls = []
    @gloss_result = gloss_result || "word(n.m.N.sg)"
    @gloss_translate_result = gloss_translate_result || "word(n.m.N.sg)translation"
    @gloss_phonetic_result = gloss_phonetic_result || "word[reading](n.m.N.sg)"
    @gloss_translate_phonetic_result = gloss_translate_phonetic_result || "word[reading](n.m.N.sg)translation"
    @phonetic_result = phonetic_result || "reading"
    @error = error
  end

  def gloss(text, from:, to:, system: nil)
    raise @error if @error
    @calls << [:gloss, text]
    @gloss_result
  end

  def gloss_translate(text, from:, to:, system: nil)
    raise @error if @error
    @calls << [:gloss_translate, text]
    @gloss_translate_result
  end

  def gloss_phonetic(text, from:, to:, phonetic_ref: nil, system: nil)
    raise @error if @error
    @calls << [:gloss_phonetic, text]
    @gloss_phonetic_result
  end

  def gloss_translate_phonetic(text, from:, to:, phonetic_ref: nil, system: nil)
    raise @error if @error
    @calls << [:gloss_translate_phonetic, text]
    @gloss_translate_phonetic_result
  end

  def phonetic(text, lang:, system: nil)
    raise @error if @error
    @phonetic_calls << [:phonetic, text]
    @phonetic_result
  end

  def reconcile(glosses, text, from:, to:, mode:, system: nil)
    @reconcile_calls << { glosses: glosses, text: text, from: from, to: to, mode: mode }
    "reconciled(n.m.N.sg)"
  end

  def reconcile_phonetic(phonetics, text, lang:, system: nil)
    @reconcile_calls << { phonetics: phonetics, text: text, lang: lang, system: system }
    "reconciled_phonetic"
  end
end
