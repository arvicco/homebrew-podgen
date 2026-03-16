# frozen_string_literal: true

require_relative "detector"
require_relative "translator"
require_relative "glosser"
require_relative "espeak"
require_relative "icu_phonetic"
require_relative "kana"

module Tell
  class Engine
    def initialize(config, translator: nil, glossers: nil, callbacks: {})
      @config = config
      @translator_instance = translator
      @glossers = glossers || {}
      @callbacks = callbacks
      @ja_hiragana_cache = {}
    end

    # --- Individual operations (return structured results) ---

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

    def run_gloss(mode, text, from:, to:, system: nil, phonetic_ref: nil)
      kwargs = { from: from, to: to, system: system }
      if phonetic_ref && %i[gloss_phonetic gloss_translate_phonetic].include?(mode)
        kwargs[:phonetic_ref] = phonetic_ref
      end

      results = Glosser.multi_model(@config.gloss_model) do |model_id|
        build_glosser(model_id).public_send(mode, text, **kwargs)
      end

      if results.size > 1
        build_glosser(@config.gloss_reconciler).reconcile(
          results, text, from: from, to: to, mode: mode, system: system
        )
      else
        results.values.first
      end
    end

    def compute_phonetic(text, lang:, system: nil)
      resolved = system || Glosser.default_system(lang)

      if lang == "ja"
        result = japanese_phonetic(text, resolved)
        if result
          sisters = compute_sister_phonetics(result[:hiragana])
          return { primary: result[:primary], hiragana: result[:hiragana], sisters: sisters }
        end
      end

      result = deterministic_phonetic(text, lang, resolved)

      unless result
        results = Glosser.multi_model(@config.phonetic_model) do |model_id|
          build_glosser(model_id).phonetic(text, lang: lang, system: system)
        end
        result = if results.size > 1
          build_glosser(@config.phonetic_reconciler).reconcile_phonetic(
            results, text, lang: lang, system: system
          )
        else
          results.values.first
        end
      end

      { primary: result }
    end

    def voice_for_gender(gender)
      case gender
      when :male   then @config.voice_male
      when :female then @config.voice_female
      end
    end

    # --- Composite: run all enabled addons in parallel, fire callbacks ---

    def fire_addons(text, reverse: false, gloss: false, gloss_translate: false,
                    phonetic: false, gloss_phonetic: false,
                    target_lang: nil, reverse_lang: nil, phonetic_system: nil)
      target = target_lang || @config.target_language
      rev_lang = reverse_lang || @config.reverse_language

      ph_system = nil
      if phonetic || gloss_phonetic
        raw = phonetic_system || (@config.phonetic_system_for(target) if @config.respond_to?(:phonetic_system_for))
        ph_system = Glosser.resolve_phonetic_system(target, raw)
      end

      threads = []

      if reverse
        threads << Thread.new do
          result = self.reverse_translate(text, from: target, to: rev_lang)
          case result[:type]
          when :translation then emit(:on_reverse, text: result[:text], lang: rev_lang)
          when :error then emit(:on_reverse_error, error: result[:error])
          end
        end
      end

      any_gloss = gloss || gloss_translate

      if target == "ja" && (phonetic || (gloss_phonetic && any_gloss))
        threads += japanese_coordinated(
          text, phonetic_system: ph_system, from: target, to: rev_lang,
          do_gloss: gloss, do_gloss_translate: gloss_translate,
          do_phonetic: phonetic, do_gloss_phonetic: gloss_phonetic
        )
      elsif phonetic && gloss_phonetic && (gloss ^ gloss_translate)
        # Non-Japanese combined: parallel phonetic + base gloss, then merge
        threads += combined_phonetic_gloss_threads(
          text, target, rev_lang, ph_system,
          do_gloss_translate: gloss_translate
        )
      else
        if any_gloss
          threads += independent_gloss_threads(
            text, target, rev_lang, ph_system,
            do_gloss: gloss, do_gloss_translate: gloss_translate,
            do_gloss_phonetic: gloss_phonetic
          )
        end

        if phonetic
          threads << Thread.new do
            result = compute_phonetic(text, lang: target, system: ph_system)
            emit(:on_phonetic, text: result[:primary]) if result
            emit(:on_phonetic_sisters, sisters: result[:sisters]) if result&.dig(:sisters)
          rescue => e
            emit(:on_phonetic_error, error: e)
          end
        end
      end

      threads
    end

    # Japanese coordination: phonetic + gloss with bracket correction.
    def japanese_coordinated(text, phonetic_system:, from:, to:,
                             do_gloss:, do_gloss_translate:, do_phonetic:, do_gloss_phonetic:)
      threads = []

      ph_thread = Thread.new do
        compute_phonetic(text, lang: "ja", system: phonetic_system)
      rescue => e
        emit(:on_phonetic_error, error: e)
        nil
      end

      gloss_infos = []
      if do_gloss
        mode = do_gloss_phonetic ? :gloss_phonetic : :gloss
        sys = do_gloss_phonetic ? "hiragana" : nil
        gloss_infos << {
          event: :on_gloss,
          thread: Thread.new { run_gloss(mode, text, from: from, to: to, system: sys) rescue nil }
        }
      end
      if do_gloss_translate
        mode = do_gloss_phonetic ? :gloss_translate_phonetic : :gloss_translate
        sys = do_gloss_phonetic ? "hiragana" : nil
        gloss_infos << {
          event: :on_gloss_translate,
          thread: Thread.new { run_gloss(mode, text, from: from, to: to, system: sys) rescue nil }
        }
      end

      threads << Thread.new do
        ph_result = ph_thread.value

        if ph_result
          emit(:on_phonetic, text: ph_result[:primary]) if do_phonetic
          emit(:on_phonetic_sisters, sisters: ph_result[:sisters]) if ph_result[:sisters]
        end

        gloss_infos.each do |info|
          gloss_result = info[:thread].value
          next unless gloss_result

          if ph_result && do_gloss_phonetic
            gloss_result = ensure_all_brackets(gloss_result)
            gloss_result = align_bracket_readings(gloss_result, ph_result[:hiragana])
            gloss_result = fix_particle_readings(gloss_result)
            bracket_cache = build_gloss_bracket_cache(gloss_result)
            emit(:on_gloss_bracket_cache, brackets: bracket_cache) if bracket_cache

            if phonetic_system && phonetic_system != "hiragana"
              gloss_result = convert_gloss_brackets(gloss_result, phonetic_system)
            end
          end

          emit(info[:event], text: strip_redundant_brackets(gloss_result))
        end
      rescue => e
        emit(:on_gloss_error, error: e)
      end

      threads
    end

    def japanese_hiragana(text)
      @ja_hiragana_cache[text] ||= begin
        model_id = Array(@config.phonetic_model).first
        build_glosser(model_id).phonetic(text, lang: "ja", system: "hiragana")
      end
    end

    def clear_cache!
      @ja_hiragana_cache.clear
    end

    # --- Bracket correction (public for testing) ---

    # Character-level alignment of phonetic readings to gloss brackets.
    # Unlike Glosser.correct_readings (which requires 1:1 word count),
    # this handles different word segmentations by consuming the flat
    # hiragana string character-by-character, guided by bracket lengths.
    def align_bracket_readings(gloss, hiragana)
      flat = hiragana.delete("・").scan(/[\u3040-\u309F\u30A0-\u30FF]/).join
      pos = 0

      gloss.gsub(Glosser::GLOSS_WORD_RE) do |match|
        next match unless match.include?("[")

        word = match[/(?:\*\S+?\*)?(\S+?)\[/, 1]
        current = match[/\[([^\]]+)\]/, 1]
        len = current.length

        if pos + len <= flat.length
          reading = flat[pos, len]
          pos += len
          # Hiragana-only words are self-reading — keep original bracket,
          # don't overwrite with potentially wrong PH (AI may change word form).
          # Particle corrections (は→わ) are handled by fix_particle_readings.
          if word&.match?(HIRAGANA_RE)
            match
          else
            match.sub(/\[[^\]]+\]/, "[#{reading}]")
          end
        else
          match
        end
      end
    end

    # Fix Japanese particle pronunciation in bracket readings.
    # は→わ and へ→え when the grammar annotation marks the word as a particle.
    # Catches standalone は and compounds like では, には, とは.
    def fix_particle_readings(gloss)
      gloss.gsub(Glosser::GLOSS_WORD_RE) do |match|
        next match unless match.include?("[") && match.include?("part")

        match
          .sub(/\[([^\]]*?)は([^\]]*)\]/) { "[#{$1}わ#{$2}]" }
          .sub(/\[([^\]]*?)へ([^\]]*)\]/) { "[#{$1}え#{$2}]" }
      end
    end

    # Remove [reading] brackets where the reading is identical to the word —
    # they add no information. Applies to any language.
    def strip_redundant_brackets(gloss)
      gloss.gsub(Glosser::GLOSS_WORD_RE) do |match|
        next match unless match.include?("[")

        m = match.match(/(?:\*\S+?\*)?(\S+?)\[([^\]]+)\]/)
        next match unless m

        m[1] == m[2] ? match.sub("[#{m[2]}]", "") : match
      end
    end

    def ensure_all_brackets(gloss)
      gloss.gsub(Glosser::GLOSS_WORD_RE) do |match|
        next match if match.include?("[")

        m = match.match(/(?:\*\S+?\*)?(\S+?)\(/)
        next match unless m

        word = m[1]
        next match unless word.match?(HIRAGANA_RE)

        match.sub("(", "[#{word}](")
      end
    end

    def build_gloss_bracket_cache(gloss)
      readings = gloss.scan(/\[([^\]]+)\]/).flatten
      return nil if readings.empty?

      cache = { "hiragana" => readings }
      cache["hepburn"] = readings.map { |r| Kana.to_romaji(r, system: "hepburn") }
      cache["kunrei"] = readings.map { |r| Kana.to_romaji(r, system: "kunrei") }
      cache["ipa"] = readings.map { |r| Kana.to_romaji(r, system: "ipa") }
      cache
    end

    private

    HIRAGANA_RE = /\A[\u3040-\u309F]+\z/

    # --- Japanese phonetic pipeline ---

    def japanese_phonetic(text, system)
      return nil unless %w[hiragana hepburn kunrei ipa].include?(system)

      hiragana = japanese_hiragana(text)
      return nil unless hiragana

      primary = derive_japanese_system(hiragana, system)
      { primary: primary, hiragana: hiragana }
    end

    def derive_japanese_system(hiragana, system)
      case system
      when "hiragana", nil then hiragana
      when "hepburn" then kana_words_to_romaji(hiragana, "hepburn")
      when "kunrei"  then kana_words_to_romaji(hiragana, "kunrei")
      when "ipa"     then "/#{kana_words_to_romaji(hiragana, "ipa")}/"
      else hiragana
      end
    end

    def kana_words_to_romaji(hiragana, system)
      words = hiragana.split(/\s*・\s*/)
      words.map { |w| Kana.to_romaji(w, system: system) }.join(" ")
    end

    def compute_sister_phonetics(hiragana)
      sisters = { "hiragana" => hiragana }
      sisters["hepburn"] = kana_words_to_romaji(hiragana, "hepburn")
      sisters["kunrei"] = kana_words_to_romaji(hiragana, "kunrei")
      sisters["ipa"] = kana_words_to_romaji(hiragana, "ipa")
      sisters
    end

    # Convert [hiragana] bracket readings to another phonetic system.
    def convert_gloss_brackets(gloss, system)
      gloss.gsub(/\[([^\]]+)\]/) do
        "[#{Kana.to_romaji($1, system: system)}]"
      end
    end

    # --- Deterministic phonetic ---

    def deterministic_phonetic(text, lang, system)
      if system == "ipa" && Espeak.supports?(lang)
        Espeak.ipa(text, lang: lang)
      elsif IcuPhonetic.supports?(lang, system)
        IcuPhonetic.transliterate(text, lang: lang, system: system)
      end
    end

    # --- Combined non-Japanese phonetic + gloss ---

    def combined_phonetic_gloss_threads(text, target, rev_lang, ph_system,
                                        do_gloss_translate:)
      threads = []
      base_mode = do_gloss_translate ? :gloss_translate : :gloss
      full_mode = do_gloss_translate ? :gloss_translate_phonetic : :gloss_phonetic
      gloss_event = do_gloss_translate ? :on_gloss_translate : :on_gloss

      ph_thread = Thread.new do
        compute_phonetic(text, lang: target, system: ph_system)
      rescue => e
        emit(:on_phonetic_error, error: e)
        nil
      end

      gloss_thread = Thread.new do
        run_gloss(base_mode, text, from: target, to: rev_lang, system: ph_system)
      rescue => e
        emit(:on_gloss_error, error: e)
        nil
      end

      threads << Thread.new do
        ph_result = ph_thread.value
        base_result = gloss_thread.value

        emit(:on_phonetic, text: ph_result[:primary]) if ph_result

        if ph_result && base_result
          merged = Glosser.merge_phonetic(
            base_result, ph_result[:primary], lang: target, system: ph_system
          )
          if merged
            emit(gloss_event, text: strip_redundant_brackets(merged))
          else
            result = run_gloss(full_mode, text, from: target, to: rev_lang,
                               phonetic_ref: ph_result[:primary], system: ph_system)
            emit(gloss_event, text: strip_redundant_brackets(result))
          end
        elsif base_result
          emit(gloss_event, text: base_result)
        end
      rescue => e
        emit(:on_gloss_error, error: e)
      end

      threads
    end

    # --- Independent gloss threads ---

    def independent_gloss_threads(text, target, rev_lang, ph_system,
                                  do_gloss:, do_gloss_translate:, do_gloss_phonetic:)
      threads = []

      if do_gloss
        gl_mode = do_gloss_phonetic ? :gloss_phonetic : :gloss
        threads << Thread.new do
          result = run_gloss(gl_mode, text, from: target, to: rev_lang, system: ph_system)
          emit(:on_gloss, text: strip_redundant_brackets(result))
        rescue => e
          emit(:on_gloss_error, error: e)
        end
      end

      if do_gloss_translate
        gt_mode = do_gloss_phonetic ? :gloss_translate_phonetic : :gloss_translate
        threads << Thread.new do
          result = run_gloss(gt_mode, text, from: target, to: rev_lang, system: ph_system)
          emit(:on_gloss_translate, text: strip_redundant_brackets(result))
        rescue => e
          emit(:on_gloss_error, error: e)
        end
      end

      threads
    end

    # --- Lazy factories ---

    def build_glosser(model_id)
      return @glossers[model_id] if @glossers[model_id]

      key = ENV["ANTHROPIC_API_KEY"]
      raise "Gloss requires ANTHROPIC_API_KEY" unless key
      @glossers[model_id] = Glosser.new(key, model: model_id)
    end

    def translator
      @translator_instance ||= Tell.build_translator_chain(
        @config.translation_engines, @config.engine_api_keys,
        timeout: @config.translation_timeout
      )
    end

    def emit(event, **data)
      @callbacks[event]&.call(**data)
    end
  end
end
