# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "colors"
require_relative "hints"
require_relative "espeak"
require_relative "icu_phonetic"
require_relative "kana"
require_relative "error_formatter"

module Tell
  class Processor
    include ErrorFormatter

    def initialize(config, interactive: false, tts: nil, translator: nil, glossers: nil)
      @config = config
      @interactive = interactive
      @translator = translator
      @tts = tts
      @glossers = glossers
      @play_pid = nil
      @play_tmp = nil
    end

    def process(text, output_path: nil, translate_from: nil)
      text = text.strip
      return if text.empty?

      # Parse style hints (e.g. /pm = polite + male) — always strip suffix
      parsed = Hints.parse(text)
      text = parsed.text
      return if text.empty?

      voice = voice_for_gender(parsed.gender)

      unless translate_from
        # Default: assume target language, speak as-is
        speak_target(text, output_path, voice: voice)
        return
      end

      # Translation mode (-f flag or config auto)
      source = resolve_source(text, translate_from)

      if source == @config.target_language
        speak_target(text, output_path, voice: voice)
      else
        translation = forward_translate(text, from: source, hints: parsed)
        if translation == :explanation
          # Explanation shown, no speech
        elsif translation
          speak_target(translation, output_path, voice: voice)
        else
          synthesize_and_output(text, output_path, voice: voice)
        end
      end
    end

    private

    def resolve_source(text, translate_from)
      return translate_from unless translate_from == "auto"

      detected = Detector.detect(text)
      if detected.nil? && Detector.has_characteristic_chars?(text, @config.target_language)
        @config.target_language
      else
        detected
      end
    end

    def speak_target(text, output_path, voice: nil)
      addon_threads = fire_addons(text)
      synthesize_and_output(text, output_path, voice: voice)
      addon_threads.each(&:join) unless @interactive
    end

    def fire_addons(text)
      threads = []
      threads << Thread.new { reverse_translate(text) } if @config.reverse_translate

      if @config.gloss
        m = @config.phonetic ? :gloss_phonetic : :gloss
        threads << Thread.new(m) { |mode| run_and_print_gloss(mode, text) }
      end
      if @config.gloss_reverse
        m = @config.phonetic ? :gloss_translate_phonetic : :gloss_translate
        threads << Thread.new(m) { |mode| run_and_print_gloss(mode, text) }
      end

      threads << Thread.new { phonetic(text) } if @config.phonetic

      threads
    end

    def forward_translate(text, from: nil, hints: nil)
      source = from || @config.reverse_language
      translation = translator.translate(text, from: source, to: @config.target_language, hints: hints)

      # If translation matches input, the text was already in the target language —
      # return it so the caller can fire add-ons on it
      return text if translation.strip.downcase == text.strip.downcase

      tag = @config.target_language.upcase

      # If translation is much longer than input, it's likely an explanation
      # rather than a clean translation — show it but don't speak
      if Detector.explanation?(text, translation)
        $stderr.puts Colors.error("Translation returned an explanation instead of a direct translation:")
        $stderr.puts "#{Colors.tag("#{tag}:")} #{Colors.forward(translation)}"
        return :explanation
      end

      $stderr.puts "#{Colors.tag("#{tag}:")} #{Colors.forward(translation)}"
      translation
    rescue => e
      $stderr.puts Colors.error("Translation failed (speaking original): #{friendly_error(e)}")
      nil
    end

    def reverse_translate(text)
      tag = @config.reverse_language.upcase
      translation = translator.translate(text, from: @config.target_language, to: @config.reverse_language)
      $stderr.puts "#{Colors.tag("#{tag}:")} #{Colors.reverse(translation)}" unless translation.strip.downcase == text.strip.downcase
    rescue => e
      $stderr.puts Colors.error("Reverse translation failed: #{friendly_error(e)}")
    end

    GLOSS_DISPLAY = {
      gloss:                    { tag: "GL:", colorizer: :colorize_gloss },
      gloss_phonetic:           { tag: "GL:", colorizer: :colorize_gloss },
      gloss_translate:          { tag: "GR:", colorizer: :colorize_gloss_translate },
      gloss_translate_phonetic: { tag: "GR:", colorizer: :colorize_gloss_translate }
    }.freeze

    def run_and_print_gloss(mode, text)
      result = run_gloss(mode, text)
      display = GLOSS_DISPLAY[mode]
      $stderr.puts "#{Colors.tag(display[:tag])} #{Colors.send(display[:colorizer], result)}"
    rescue => e
      $stderr.puts Colors.error("Gloss failed: #{friendly_error(e)}")
    end

    def phonetic(text)
      sys = @config.phonetic_system_for(@config.target_language)
      lang = @config.target_language
      resolved = sys || Glosser.default_system(lang)

      # Japanese pipeline: AI hiragana → deterministic derivation
      result = japanese_phonetic(text, resolved) if lang == "ja"

      result ||= if resolved == "ipa" && Espeak.supports?(lang)
        Espeak.ipa(text, lang: lang)
      elsif IcuPhonetic.supports?(lang, resolved)
        IcuPhonetic.transliterate(text, lang: lang, system: resolved)
      end

      unless result
        results = Glosser.multi_model(@config.phonetic_model) do |model_id|
          build_glosser(model_id).phonetic(text, lang: lang, system: sys)
        end

        result = if results.size > 1
          build_glosser(@config.phonetic_reconciler).reconcile_phonetic(results, text, lang: lang, system: sys)
        else
          results.values.first
        end
      end

      $stderr.puts "#{Colors.tag("PH:")} #{Colors.phonetic(result)}"
    rescue => e
      $stderr.puts Colors.error("Phonetic failed: #{friendly_error(e)}")
    end

    # Japanese phonetic pipeline: single AI call for hiragana, then derive
    # hepburn/kunrei deterministically via Kana module, IPA via eSpeak.
    def japanese_phonetic(text, system)
      return nil unless %w[hiragana hepburn kunrei ipa].include?(system)

      hiragana = japanese_hiragana(text)
      return nil unless hiragana

      case system
      when "hiragana" then hiragana
      when "hepburn"  then kana_words_to_romaji(hiragana, "hepburn")
      when "kunrei"   then kana_words_to_romaji(hiragana, "kunrei")
      when "ipa"      then "/#{kana_words_to_romaji(hiragana, "ipa")}/"
      end
    end

    # Get hiragana reading via AI, cached per text for interactive reuse.
    def japanese_hiragana(text)
      @ja_hiragana_cache ||= {}
      @ja_hiragana_cache[text] ||= begin
        model_id = Array(@config.phonetic_model).first
        build_glosser(model_id).phonetic(text, lang: "ja", system: "hiragana")
      end
    end

    # Convert ・-separated hiragana words to romaji.
    def kana_words_to_romaji(hiragana, system)
      words = hiragana.split(/\s*・\s*/)
      words.map { |w| Kana.to_romaji(w, system: system) }.join(" ")
    end

    def run_gloss(mode, text)
      sys = @config.phonetic_system_for(@config.target_language)

      results = Glosser.multi_model(@config.gloss_model) do |model_id|
        build_glosser(model_id).public_send(mode, text, from: @config.target_language, to: @config.reverse_language, system: sys)
      end

      if results.size > 1
        build_glosser(@config.gloss_reconciler).reconcile(results, text, from: @config.target_language, to: @config.reverse_language, mode: mode, system: sys)
      else
        results.values.first
      end
    end

    def build_glosser(model_id)
      key = ENV["ANTHROPIC_API_KEY"]
      raise "Gloss requires ANTHROPIC_API_KEY" unless key
      @glossers ||= {}
      @glossers[model_id] ||= Glosser.new(key, model: model_id)
    end

    def translator
      @translator ||= Tell.build_translator_chain(
        @config.translation_engines, @config.engine_api_keys,
        timeout: @config.translation_timeout
      )
    end

    def tts
      @tts ||= Tell.build_tts(@config.tts_engine, @config)
    end

    def synthesize_and_output(text, output_path, voice: nil)
      audio_data = tts.synthesize(text, voice: voice)
      output_audio(audio_data, output_path)
    end

    def voice_for_gender(gender)
      case gender
      when :male   then @config.voice_male
      when :female then @config.voice_female
      end
    end

    def output_audio(audio_data, output_path)
      if output_path
        File.open(output_path, "wb") { |f| f.write(audio_data) }
        $stderr.puts Colors.status("Saved: #{output_path}")
      elsif !$stdout.tty?
        $stdout.binmode
        $stdout.write(audio_data)
      else
        play_audio(audio_data)
      end
    end

    def play_audio(audio_data)
      tmp = File.join(Dir.tmpdir, "tell_#{Process.pid}_#{Time.now.to_f}.mp3")
      File.open(tmp, "wb") { |f| f.write(audio_data) }

      if @interactive
        stop_playback
        @play_tmp = tmp
        @play_pid = spawn("afplay", tmp, [:out, :err] => "/dev/null")
        # Clean up temp file after playback finishes
        Thread.new do
          pid, file = @play_pid, tmp
          Process.wait(pid) rescue nil
          File.delete(file) if File.exist?(file)
        end
      else
        begin
          system("afplay", tmp)
        ensure
          File.delete(tmp) if File.exist?(tmp)
        end
      end
    end

    def stop_playback
      if @play_pid
        Process.kill("TERM", @play_pid) rescue nil
        Process.wait(@play_pid) rescue nil
        @play_pid = nil
      end
    end

  end
end
