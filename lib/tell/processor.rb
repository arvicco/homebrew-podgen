# frozen_string_literal: true

require "open3"
require "tmpdir"

module Tell
  class Processor
    def initialize(config, interactive: false)
      @config = config
      @interactive = interactive
      @translator = nil
      @tts = nil
      @play_pid = nil
      @play_tmp = nil
    end

    def process(text, output_path: nil, no_translate: false)
      text = text.strip
      return if text.empty?

      if no_translate
        synthesize_and_output(text, output_path)
        return
      end

      detected = Detector.detect(text)

      # Fallback: if stop-word detection is inconclusive, check for
      # characteristic diacritics (e.g. č/š/ž → Slovenian, not English)
      if detected.nil? && Detector.has_characteristic_chars?(text, @config.target_language)
        detected = @config.target_language
      end

      if detected == @config.target_language
        # Already in target language — speak directly, fire add-ons in background
        fire_addons(text)
        synthesize_and_output(text, output_path)
      else
        # Translate to target language, then speak
        translation = forward_translate(text)
        synthesize_and_output(translation || text, output_path)
      end
    end

    private

    def fire_addons(text)
      Thread.new { reverse_translate(text) } if @config.reverse_translate
      Thread.new { gloss(text) } if @config.gloss
      Thread.new { gloss_translate(text) } if @config.gloss_reverse
    end

    def forward_translate(text)
      translation = translator.translate(text, from: @config.original_language, to: @config.target_language)

      # If translation matches input, the text was already in the target language
      return nil if translation.strip.downcase == text.strip.downcase

      tag = @config.target_language.upcase

      # If translation is much longer than input, it's likely an explanation
      # rather than a clean translation — show it but speak the original
      if translation.length > text.length * 3
        $stderr.puts "#{tag}: #{translation}"
        return nil
      end

      $stderr.puts "#{tag}: #{translation}"
      translation
    rescue => e
      $stderr.puts "Translation failed (speaking original): #{friendly_error(e)}"
      nil
    end

    def reverse_translate(text)
      tag = @config.original_language.upcase
      translation = translator.translate(text, from: @config.target_language, to: @config.original_language)
      $stderr.puts "#{tag}: #{translation}" unless translation.strip.downcase == text.strip.downcase
    rescue => e
      $stderr.puts "Reverse translation failed: #{friendly_error(e)}"
    end

    def gloss(text)
      result = glosser.gloss(text, from: @config.target_language, to: @config.original_language)
      $stderr.puts "GL: #{result}"
    rescue => e
      $stderr.puts "Gloss failed: #{friendly_error(e)}"
    end

    def gloss_translate(text)
      result = glosser.gloss_translate(text, from: @config.target_language, to: @config.original_language)
      $stderr.puts "GR: #{result}"
    rescue => e
      $stderr.puts "Gloss failed: #{friendly_error(e)}"
    end

    def glosser
      key = ENV["ANTHROPIC_API_KEY"]
      raise "Gloss requires ANTHROPIC_API_KEY" unless key
      @glosser ||= Glosser.new(key)
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

    def synthesize_and_output(text, output_path)
      audio_data = tts.synthesize(text)
      output_audio(audio_data, output_path)
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

    # Extract a short, human-readable message from API errors.
    # Anthropic gem errors contain the full JSON body — pull out the nested message.
    def friendly_error(err)
      msg = err.message
      if msg.include?('"overloaded_error"') || msg.include?("status: 529")
        "API overloaded (try again)"
      elsif msg.include?('"rate_limit_error"') || msg.include?("status: 429")
        "rate limited (try again)"
      elsif msg =~ /status[":]\s*(\d{3})/ && msg =~ /"message":\s*"([^"]+)"/
        "HTTP #{$1}: #{$2}"
      else
        msg.length > 80 ? "#{msg[0, 77]}..." : msg
      end
    end
  end
end
