# frozen_string_literal: true

require "sinatra/base"
require "json"
require "base64"
require_relative "config"
require_relative "detector"
require_relative "translator"
require_relative "tts"
require_relative "glosser"
require_relative "hints"

module Tell
  class Web < Sinatra::Base
    set :views, File.join(__dir__, "web", "views")

    # Simple token-bucket rate limiter (per-IP, in-memory)
    class RateLimiter
      def initialize(rpm)
        @rpm = rpm.to_f
        @buckets = {}
        @mutex = Mutex.new
      end

      def allow?(ip)
        @mutex.synchronize do
          now = Time.now.to_f
          b = @buckets[ip] ||= { tokens: @rpm, last: now }
          b[:tokens] = [b[:tokens] + (now - b[:last]) * (@rpm / 60.0), @rpm].min
          b[:last] = now
          return false unless b[:tokens] >= 1
          b[:tokens] -= 1
          true
        end
      end
    end

    configure do
      set :rate_limiter, RateLimiter.new(ENV.fetch("TELL_WEB_RATE_LIMIT", 30))
      set :auth_token, ENV["TELL_WEB_TOKEN"]
    end

    helpers do
      def sse(out, event, data)
        out << "event: #{event}\ndata: #{data.to_json}\n\n"
      end

      def check_auth!
        token = settings.auth_token
        return unless token
        provided = request.env["HTTP_AUTHORIZATION"]&.sub(/\ABearer\s+/i, "") || params["token"]
        halt 401, { "Content-Type" => "application/json" }, { error: "Unauthorized" }.to_json unless provided == token
      end

      def check_rate_limit!
        halt 429, { "Content-Type" => "application/json" }, { error: "Rate limited" }.to_json unless settings.rate_limiter.allow?(request.ip)
      end
    end

    before { check_auth! }

    get "/" do
      config = settings.tell_config
      erb :index, locals: {
        default_from: config.original_language,
        default_to: config.target_language
      }
    end

    get "/speak" do
      check_rate_limit!

      text = params["text"]&.strip
      halt 400, { "Content-Type" => "application/json" }, { error: "Text required" }.to_json if text.nil? || text.empty?
      halt 400, { "Content-Type" => "application/json" }, { error: "Text too long (max 500)" }.to_json if text.length > 500

      config = settings.tell_config

      content_type "text/event-stream"
      headers "Cache-Control" => "no-cache", "X-Accel-Buffering" => "no"

      stream do |out|
        handle_speak(out, config)
      end
    end

    private

    def handle_speak(out, config)
      no_tts = params["no_tts"] == "true"
      hint = params["hint"]
      text = params["text"].strip

      # Per-request language overrides
      from_lang    = params["from"] || config.original_language
      target_lang  = params["to"]   || config.target_language
      reverse_lang = from_lang == "auto" ? "en" : from_lang

      # Parse style hints
      input = hint && !hint.empty? ? "#{text} /#{hint}" : text
      parsed = Hints.parse(input)
      clean_text = parsed.text
      return sse(out, "error", { message: "Empty input" }) if clean_text.empty?

      voice = case parsed.gender
              when :male then config.voice_male
              when :female then config.voice_female
              end

      # --- Translation phase (skip for addon-only requests) ---
      speak_text = clean_text

      unless no_tts || params["no_translate"] == "true"
        source = resolve_source(clean_text, from_lang, target_lang) || "en"

        if source != target_lang
          begin
            translation = build_translator(config)
              .translate(clean_text, from: source, to: target_lang, hints: parsed)

            unless translation.strip.downcase == clean_text.strip.downcase
              tag = target_lang.upcase
              if translation.length > clean_text.length * 3
                sse(out, "translation", { lang: tag, text: translation, explanation: true })
              else
                sse(out, "translation", { lang: tag, text: translation })
                speak_text = translation
              end
            end
          rescue => e
            sse(out, "error", { message: "Translation: #{e.message}" })
          end
        end
      end

      # Tell the client what text is being processed (for addon-only follow-ups)
      sse(out, "speak_text", { text: speak_text }) unless no_tts

      # --- Parallel phase: TTS + addons ---
      threads = []
      mutex = Mutex.new

      # TTS
      unless no_tts
        threads << Thread.new do
          tts = Tell.build_tts(config.tts_engine, config)
          audio = tts.synthesize(speak_text, voice: voice)
          mutex.synchronize { sse(out, "audio", { base64: Base64.strict_encode64(audio) }) }
        rescue => e
          mutex.synchronize { sse(out, "error", { message: "TTS: #{e.message}" }) }
        end
      end

      # Addon flags from individual params
      do_reverse         = params["reverse"] == "true"
      do_phonetic        = params["phonetic"] == "true"
      do_gloss           = params["gloss"] == "true"
      do_gloss_phonetic  = params["gloss_phonetic"] == "true" && do_gloss
      do_gloss_translate = params["gloss_translate"] == "true" && do_gloss

      if do_reverse
        threads << Thread.new do
          result = build_translator(config)
            .translate(speak_text, from: target_lang, to: reverse_lang)
          unless result.strip.downcase == speak_text.strip.downcase
            mutex.synchronize { sse(out, "reverse", { lang: reverse_lang.upcase, text: result }) }
          end
        rescue => e
          mutex.synchronize { sse(out, "error", { message: "Reverse: #{e.message}" }) }
        end
      end

      if do_phonetic && do_gloss_phonetic
        # Run phonetic + base gloss (without phonetic) in parallel,
        # then try mechanical merge. Fall back to AI if counts don't align.
        base_mode = do_gloss_translate ? :gloss_translate : :gloss
        full_mode = do_gloss_translate ? :gloss_translate_phonetic : :gloss_phonetic
        gloss_event = do_gloss_translate ? "gloss_translate" : "gloss"

        ph_thread = Thread.new do
          Glosser.new(ENV["ANTHROPIC_API_KEY"], model: config.phonetic_model)
            .phonetic(speak_text, lang: target_lang)
        rescue => e
          mutex.synchronize { sse(out, "error", { message: "Phonetic: #{e.message}" }) }
          nil
        end

        gloss_thread = Thread.new do
          run_gloss(config, base_mode, speak_text, target_lang, reverse_lang)
        rescue => e
          mutex.synchronize { sse(out, "error", { message: "Gloss: #{e.message}" }) }
          nil
        end

        threads << Thread.new do
          ph_result = ph_thread.value
          base_result = gloss_thread.value

          mutex.synchronize { sse(out, "phonetic", { text: ph_result }) } if ph_result

          if ph_result && base_result
            merged = Glosser.merge_phonetic(base_result, ph_result, lang: target_lang)
            if merged
              mutex.synchronize { sse(out, gloss_event, { text: merged }) }
            else
              # Counts didn't align — re-run gloss with phonetic as reference
              result = run_gloss(config, full_mode, speak_text, target_lang, reverse_lang, phonetic_ref: ph_result)
              mutex.synchronize { sse(out, gloss_event, { text: result }) }
            end
          elsif base_result
            mutex.synchronize { sse(out, gloss_event, { text: base_result }) }
          end
        rescue => e
          mutex.synchronize { sse(out, "error", { message: "Gloss: #{e.message}" }) }
        end
      else
        if do_gloss
          gloss_mode = if do_gloss_translate
                         do_gloss_phonetic ? :gloss_translate_phonetic : :gloss_translate
                       else
                         do_gloss_phonetic ? :gloss_phonetic : :gloss
                       end

          threads << Thread.new do
            result = run_gloss(config, gloss_mode, speak_text, target_lang, reverse_lang)
            event = do_gloss_translate ? "gloss_translate" : "gloss"
            mutex.synchronize { sse(out, event, { text: result }) }
          rescue => e
            mutex.synchronize { sse(out, "error", { message: "Gloss: #{e.message}" }) }
          end
        end

        if do_phonetic
          threads << Thread.new do
            g = Glosser.new(ENV["ANTHROPIC_API_KEY"], model: config.phonetic_model)
            result = g.phonetic(speak_text, lang: target_lang)
            mutex.synchronize { sse(out, "phonetic", { text: result }) }
          rescue => e
            mutex.synchronize { sse(out, "error", { message: "Phonetic: #{e.message}" }) }
          end
        end
      end

      threads.each(&:join)
      sse(out, "done", {})
    rescue => e
      sse(out, "error", { message: e.message }) rescue nil
    end

    def resolve_source(text, translate_from, target_lang)
      return translate_from unless translate_from == "auto"

      detected = Detector.detect(text)
      if detected.nil? && Detector.has_characteristic_chars?(text, target_lang)
        target_lang
      else
        detected
      end
    end

    def build_translator(config)
      Tell.build_translator_chain(
        config.translation_engines, config.engine_api_keys,
        timeout: config.translation_timeout
      )
    end

    def run_gloss(config, mode, text, target, reverse, phonetic_ref: nil)
      api_key = ENV["ANTHROPIC_API_KEY"]
      raise "Gloss requires ANTHROPIC_API_KEY" unless api_key

      kwargs = { from: target, to: reverse }
      kwargs[:phonetic_ref] = phonetic_ref if phonetic_ref && %i[gloss_phonetic gloss_translate_phonetic].include?(mode)

      if config.gloss_model.size == 1
        Glosser.new(api_key, model: config.gloss_reconciler)
          .public_send(mode, text, **kwargs)
      else
        run_consensus(config, mode, text, api_key, target, reverse, phonetic_ref: phonetic_ref)
      end
    end

    def run_consensus(config, mode, text, api_key, target, reverse, phonetic_ref: nil)
      glosses = {}
      errors = {}
      gmutex = Mutex.new

      kwargs = { from: target, to: reverse }
      kwargs[:phonetic_ref] = phonetic_ref if phonetic_ref && %i[gloss_phonetic gloss_translate_phonetic].include?(mode)

      gthreads = config.gloss_model.map do |model_id|
        Thread.new(model_id) do |mid|
          r = Glosser.new(api_key, model: mid)
            .public_send(mode, text, **kwargs)
          gmutex.synchronize { glosses[mid] = r }
        rescue => e
          gmutex.synchronize { errors[mid] = e }
        end
      end
      gthreads.each(&:join)

      raise errors.values.first if glosses.empty?
      return glosses.values.first if glosses.size == 1

      Glosser.new(api_key, model: config.gloss_reconciler)
        .reconcile(glosses, text, from: target, to: reverse, mode: mode)
    end
  end
end
