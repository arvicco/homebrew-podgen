# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "colors"

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

    def process(text, output_path: nil, translate_from: nil)
      text = text.strip
      return if text.empty?

      unless translate_from
        # Default: assume target language, speak as-is
        speak_target(text, output_path)
        return
      end

      # Translation mode (-f flag or config auto)
      source = resolve_source(text, translate_from)

      if source == @config.target_language
        speak_target(text, output_path)
      else
        translation = forward_translate(text, from: source)
        if translation
          speak_target(translation, output_path)
        else
          synthesize_and_output(text, output_path)
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

    def speak_target(text, output_path)
      addon_threads = fire_addons(text)
      synthesize_and_output(text, output_path)
      addon_threads.each(&:join) unless @interactive
    end

    def fire_addons(text)
      threads = []
      threads << Thread.new { reverse_translate(text) } if @config.reverse_translate
      threads << Thread.new { gloss(text) } if @config.gloss
      threads << Thread.new { gloss_translate(text) } if @config.gloss_reverse
      threads
    end

    def forward_translate(text, from: nil)
      source = from || @config.reverse_language
      translation = translator.translate(text, from: source, to: @config.target_language)

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

    def gloss(text)
      result = run_gloss(:gloss, text)
      $stderr.puts "#{Colors.tag("GL:")} #{Colors.colorize_gloss(result)}"
    rescue => e
      $stderr.puts Colors.error("Gloss failed: #{friendly_error(e)}")
    end

    def gloss_translate(text)
      result = run_gloss(:gloss_translate, text)
      $stderr.puts "#{Colors.tag("GR:")} #{Colors.colorize_gloss_translate(result)}"
    rescue => e
      $stderr.puts Colors.error("Gloss failed: #{friendly_error(e)}")
    end

    def run_gloss(mode, text)
      if @config.gloss_models.size == 1
        build_glosser(@config.gloss_model).public_send(mode, text, from: @config.target_language, to: @config.reverse_language)
      else
        run_consensus(mode, text)
      end
    end

    def run_consensus(mode, text)
      mutex = Mutex.new
      glosses = {}
      errors = {}

      threads = @config.gloss_models.map do |model_id|
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

    def synthesize_and_output(text, output_path)
      audio_data = tts.synthesize(text)
      output_audio(audio_data, output_path)
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

    # Extract a short, human-readable message from API errors.
    # Anthropic gem errors contain the full JSON body — pull out the nested message.
    def friendly_error(err)
      msg = err.message
      if msg.include?('"overloaded_error"') || msg.include?("status: 529")
        "API overloaded (try again)"
      elsif msg.include?('"rate_limit_error"') || msg.include?("status: 429")
        "rate limited (try again)"
      elsif (status = msg[/status[":]\s*(\d{3})/, 1]) && (detail = msg[/"message":\s*"([^"]+)"/, 1])
        "HTTP #{status}: #{detail}"
      else
        msg.length > 80 ? "#{msg[0, 77]}..." : msg
      end
    end
  end
end
