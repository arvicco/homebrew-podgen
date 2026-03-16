# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "colors"
require_relative "hints"
require_relative "engine"
require_relative "error_formatter"

module Tell
  class Processor
    include ErrorFormatter

    def initialize(config, interactive: false, tts: nil, translator: nil, glossers: nil)
      @config = config
      @interactive = interactive
      @tts = tts
      @engine = Engine.new(config, translator: translator, glossers: glossers, callbacks: build_callbacks)
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

      voice = @engine.voice_for_gender(parsed.gender)

      unless translate_from
        # Default: assume target language, speak as-is
        speak_target(text, output_path, voice: voice)
        return
      end

      # Translation mode (-f flag or config auto)
      source = @engine.resolve_source(text, translate_from)

      if source == @config.target_language
        speak_target(text, output_path, voice: voice)
      else
        from = source || @config.reverse_language
        result = @engine.forward_translate(text, from: from, to: @config.target_language, hints: parsed)

        case result[:type]
        when :same_text
          speak_target(text, output_path, voice: voice)
        when :explanation
          tag = @config.target_language.upcase
          $stderr.puts Colors.error("Translation returned an explanation instead of a direct translation:")
          $stderr.puts "#{Colors.tag("#{tag}:")} #{Colors.forward(result[:text])}"
        when :translation
          tag = @config.target_language.upcase
          $stderr.puts "#{Colors.tag("#{tag}:")} #{Colors.forward(result[:text])}"
          speak_target(result[:text], output_path, voice: voice)
        when :error
          $stderr.puts Colors.error("Translation failed (speaking original): #{friendly_error(result[:error])}")
          synthesize_and_output(text, output_path, voice: voice)
        end
      end
    end

    private

    def speak_target(text, output_path, voice: nil)
      addon_threads = @engine.fire_addons(text, **addon_opts)
      synthesize_and_output(text, output_path, voice: voice)
      addon_threads.each(&:join) unless @interactive
    end

    def addon_opts
      {
        reverse: @config.reverse_translate,
        gloss: @config.gloss && !@config.gloss_reverse,
        gloss_translate: @config.gloss_reverse,
        phonetic: @config.phonetic,
        gloss_phonetic: @config.phonetic,
        target_lang: @config.target_language,
        reverse_lang: @config.reverse_language,
      }
    end

    def build_callbacks
      fmt = method(:friendly_error)
      {
        on_reverse: ->(text:, lang:) {
          $stderr.puts "#{Colors.tag("#{lang.upcase}:")} #{Colors.reverse(text)}"
        },
        on_reverse_error: ->(error:) {
          $stderr.puts Colors.error("Reverse translation failed: #{fmt.call(error)}")
        },
        on_gloss: ->(text:) {
          $stderr.puts "#{Colors.tag("GL:")} #{Colors.colorize_gloss(text)}"
        },
        on_gloss_translate: ->(text:) {
          $stderr.puts "#{Colors.tag("GR:")} #{Colors.colorize_gloss_translate(text)}"
        },
        on_gloss_error: ->(error:) {
          $stderr.puts Colors.error("Gloss failed: #{fmt.call(error)}")
        },
        on_phonetic: ->(text:) {
          $stderr.puts "#{Colors.tag("PH:")} #{Colors.phonetic(text)}"
        },
        on_phonetic_error: ->(error:) {
          $stderr.puts Colors.error("Phonetic failed: #{fmt.call(error)}")
        },
      }
    end

    def synthesize_and_output(text, output_path, voice: nil)
      audio_data = tts.synthesize(text, voice: voice)
      output_audio(audio_data, output_path)
    end

    def tts
      @tts ||= Tell.build_tts(@config.tts_engine, @config)
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
