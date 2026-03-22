# frozen_string_literal: true

require "sinatra/base"
require "json"
require "base64"
require_relative "config"
require_relative "glosser"
require_relative "hints"
require_relative "tts"
require_relative "engine"
require_relative "engine_pool"

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
      set :engine_pool, EnginePool.new
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

    get "/systems" do
      lang = params["lang"]
      halt 400, { "Content-Type" => "application/json" }, { error: "lang required" }.to_json unless lang
      systems = Glosser.systems_for(lang)
      content_type :json
      systems.map { |key, cfg| { key: key, label: cfg[:label], separator: cfg[:separator] } }.to_json
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

      # Apply per-language config (voice, TTS engine, etc.)
      config = config.for_language(target_lang)

      # Parse style hints
      input = hint && !hint.empty? ? "#{text} /#{hint}" : text
      parsed = Hints.parse(input)
      clean_text = parsed.text
      return sse(out, "error", { message: "Empty input" }) if clean_text.empty?

      voice = case parsed.gender
              when :male then config.voice_male
              when :female then config.voice_female
              end

      # Build Engine with SSE callbacks, reusing cached glossers/translator
      mutex = Mutex.new
      pool = settings.engine_pool
      translator = pool.translator(
        engines: config.translation_engines,
        api_keys: config.engine_api_keys,
        timeout: config.translation_timeout
      )
      engine = Engine.new(config,
        translator: translator,
        glosser_pool: pool,
        callbacks: build_sse_callbacks(out, mutex)
      )

      # --- Translation phase (skip for addon-only requests) ---
      speak_text = clean_text

      unless no_tts || params["no_translate"] == "true"
        source = engine.resolve_source(clean_text, from_lang, target_lang) || "en"

        if source != target_lang
          result = engine.forward_translate(clean_text, from: source, to: target_lang, hints: parsed)

          case result[:type]
          when :explanation
            sse(out, "error", { message: "Translation returned an explanation instead of a direct translation" })
            sse(out, "translation", { lang: target_lang.upcase, text: result[:text], explanation: true })
            sse(out, "done", {})
            return
          when :translation
            sse(out, "translation", { lang: target_lang.upcase, text: result[:text] })
            speak_text = result[:text]
          when :error
            sse(out, "error", { message: "Translation: #{result[:error].message}" })
          end
        end
      end

      # Tell the client what text is being processed (for addon-only follow-ups)
      sse(out, "speak_text", { text: speak_text }) unless no_tts

      # --- Parallel phase: TTS + addons ---
      threads = []

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
      ph_system          = params["phonetic_system"]&.then { |s| s.empty? ? nil : s }
      ph_system          = Glosser.resolve_phonetic_system(target_lang, ph_system) if ph_system

      threads += engine.fire_addons(
        speak_text,
        reverse: do_reverse,
        gloss: do_gloss && !do_gloss_translate,
        gloss_translate: do_gloss_translate,
        phonetic: do_phonetic,
        gloss_phonetic: do_gloss_phonetic,
        target_lang: target_lang,
        reverse_lang: reverse_lang,
        phonetic_system: ph_system
      )

      threads.each(&:join)
      sse(out, "done", {})
    rescue => e
      sse(out, "error", { message: e.message }) rescue nil
    end

    def build_sse_callbacks(out, mutex)
      # Each callback rescues broken-pipe errors — client can disconnect at any time.
      safe = ->(block) { ->(**kw) { block.call(**kw) rescue nil } }

      {
        on_reverse: safe.call(->(text:, lang:) {
          mutex.synchronize { sse(out, "reverse", { lang: lang.upcase, text: text }) }
        }),
        on_reverse_error: safe.call(->(error:) {
          mutex.synchronize { sse(out, "error", { message: "Reverse: #{error.message}" }) }
        }),
        on_gloss: safe.call(->(text:) {
          mutex.synchronize { sse(out, "gloss", { text: text }) }
        }),
        on_gloss_translate: safe.call(->(text:) {
          mutex.synchronize { sse(out, "gloss_translate", { text: text }) }
        }),
        on_gloss_error: safe.call(->(error:) {
          mutex.synchronize { sse(out, "error", { message: "Gloss: #{error.message}" }) }
        }),
        on_phonetic: safe.call(->(text:) {
          mutex.synchronize { sse(out, "phonetic", { text: text }) }
        }),
        on_phonetic_sisters: safe.call(->(sisters:) {
          sisters.each do |sys_key, sys_text|
            mutex.synchronize { sse(out, "phonetic_cache", { system: sys_key, text: sys_text }) }
          end
        }),
        on_phonetic_error: safe.call(->(error:) {
          mutex.synchronize { sse(out, "error", { message: "Phonetic: #{error.message}" }) }
        }),
        on_gloss_bracket_cache: safe.call(->(brackets:) {
          mutex.synchronize { sse(out, "gloss_phonetic_cache", { brackets: brackets }) }
        }),
      }
    end
  end
end
