# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "colors"
require_relative "hints"
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
        if translation
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
      # rather than a clean translation — show it but speak the original
      if translation.length > text.length * 3
        $stderr.puts "#{Colors.tag("#{tag}:")} #{Colors.forward(translation)}"
        return nil
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
      result = build_glosser(@config.phonetic_model).phonetic(text, lang: @config.target_language)
      $stderr.puts "#{Colors.tag("PH:")} #{Colors.phonetic(result)}"
    rescue => e
      $stderr.puts Colors.error("Phonetic failed: #{friendly_error(e)}")
    end

    def run_gloss(mode, text)
      if @config.gloss_model.size == 1
        build_glosser(@config.gloss_reconciler).public_send(mode, text, from: @config.target_language, to: @config.reverse_language)
      else
        run_consensus(mode, text)
      end
    end

    def run_consensus(mode, text)
      mutex = Mutex.new
      glosses = {}
      errors = {}

      threads = @config.gloss_model.map do |model_id|
        Thread.new(model_id) do |mid|
          result = build_glosser(mid).public_send(mode, text, from: @config.target_language, to: @config.reverse_language)
          mutex.synchronize { glosses[mid] = result }
        rescue => e
          mutex.synchronize { errors[mid] = e }
        end
      end
      threads.each(&:join)

      raise errors.values.first if glosses.empty?

      if glosses.size == 1
        glosses.values.first
      else
        reconciler = build_glosser(@config.gloss_reconciler)
        reconciler.reconcile(glosses, text, from: @config.target_language, to: @config.reverse_language, mode: mode)
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
        system("afplay", tmp)
        File.delete(tmp) if File.exist?(tmp)
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
