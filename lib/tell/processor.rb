# frozen_string_literal: true

require "open3"
require "tmpdir"

module Tell
  class Processor
    def initialize(config)
      @config = config
      @translator = nil
      @tts = nil
    end

    def process(text, output_path: nil, no_translate: false)
      text = text.strip
      return if text.empty?

      translated = if no_translate
        nil
      else
        maybe_translate(text)
      end

      speak_text = translated || text
      audio_data = tts.synthesize(speak_text)
      output_audio(audio_data, output_path)
    end

    private

    def maybe_translate(text)
      detected = Detector.detect(text)

      # Skip translation only if we positively detect the target language
      return nil if detected == @config.target_language

      # Translate if detected as original language OR if detection is inconclusive
      translation = translator.translate(text, from: @config.original_language, to: @config.target_language)

      # If translation matches input, the text was already in the target language
      return nil if translation.strip.downcase == text.strip.downcase

      target_name = LANGUAGE_NAMES.fetch(@config.target_language, @config.target_language)

      # If translation is much longer than input, it's likely an explanation
      # rather than a clean translation — show it but speak the original
      if translation.length > text.length * 3
        $stderr.puts "#{target_name}: #{translation}"
        return nil
      end

      $stderr.puts "#{target_name}: #{translation}"
      translation
    rescue => e
      $stderr.puts "Translation failed (speaking original): #{e.message}"
      nil
    end

    def translator
      @translator ||= Tell.build_translator(@config.translation_engine, @config.engine_api_key)
    end

    def tts
      @tts ||= Tell.build_tts(@config.tts_engine, @config)
    end

    def output_audio(audio_data, output_path)
      if output_path
        File.open(output_path, "wb") { |f| f.write(audio_data) }
        $stderr.puts "Saved: #{output_path}"
      elsif !$stdout.tty?
        $stdout.binmode
        $stdout.write(audio_data)
      else
        play_audio(audio_data)
      end
    end

    def play_audio(audio_data)
      tmp = File.join(Dir.tmpdir, "tell_#{Process.pid}.mp3")
      File.open(tmp, "wb") { |f| f.write(audio_data) }
      system("afplay", tmp)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end
  end
end
