# frozen_string_literal: true

require "httparty"
require "json"
require "open3"
require "tmpdir"
require_relative "base_engine"

module Transcription
  class GroqEngine < BaseEngine
    ENDPOINT = "https://api.groq.com/openai/v1/audio/transcriptions"
    MAX_FILE_SIZE = 25 * 1024 * 1024 # 25 MB
    TARGET_SIZE_MB = 24.0 # leave 1 MB headroom

    def initialize(language: "sl", logger: nil)
      super
      @api_key = ENV.fetch("GROQ_API_KEY") { raise "GROQ_API_KEY not set" }
      @model = ENV.fetch("GROQ_WHISPER_MODEL", "whisper-large-v3")
      @downsampled_path = nil
    end

    def engine_name
      "groq"
    end

    def transcribe(audio_path)
      validate_audio!(audio_path)

      file_size = File.size(audio_path)
      size_mb = (file_size / (1024.0 * 1024)).round(2)

      if file_size > MAX_FILE_SIZE
        audio_path = downsample(audio_path, size_mb)
        size_mb = (File.size(audio_path) / (1024.0 * 1024)).round(2)
      end

      log("Transcribing #{audio_path} (#{size_mb} MB, model: #{@model}, language: #{@language})")

      retries = 0
      begin
        retries += 1
        start = Time.now

        body = {
          file: File.open(audio_path, "rb"),
          model: @model,
          language: @language,
          response_format: "verbose_json",
          "timestamp_granularities[]" => "word"
        }

        response = HTTParty.post(
          ENDPOINT,
          headers: { "Authorization" => "Bearer #{@api_key}" },
          multipart: true,
          body: body,
          timeout: TIMEOUT
        )

        elapsed = (Time.now - start).round(2)

        unless response.success?
          raise "Groq API error #{response.code}: #{response.body}"
        end

        result = JSON.parse(response.body)
        transcript = result["text"] || ""
        duration = result["duration"]&.round(1)
        segments = result["segments"] || []

        parsed_segments = segments.map do |s|
          {
            start: s["start"].to_f,
            end: s["end"].to_f,
            text: s["text"].to_s,
            no_speech_prob: s["no_speech_prob"].to_f,
            compression_ratio: s["compression_ratio"].to_f,
            avg_logprob: s["avg_logprob"].to_f
          }
        end

        words = (result["words"] || []).map do |w|
          { word: w["word"].to_s, start: w["start"].to_f, end: w["end"].to_f }
        end

        speech_start = parsed_segments.any? ? parsed_segments.first[:start] : 0.0
        speech_end = parsed_segments.any? ? parsed_segments.last[:end] : (duration || 0.0)

        log("Transcription complete in #{elapsed}s (audio duration: #{duration}s, #{transcript.length} chars, #{parsed_segments.length} segments, #{words.length} words)")
        log("Speech boundaries: #{speech_start.round(1)}s → #{speech_end.round(1)}s")

        { text: transcript, speech_start: speech_start, speech_end: speech_end, segments: parsed_segments, words: words }

      rescue => e
        if retries <= MAX_RETRIES && retryable?(e)
          sleep_time = 2**retries
          log("Error (attempt #{retries}/#{MAX_RETRIES}): #{e.message}. Retrying in #{sleep_time}s...")
          sleep(sleep_time)
          retry
        end
        raise "GroqEngine failed after #{retries} attempts: #{e.message}"
      ensure
        cleanup_downsample
      end
    end

    private

    def downsample(audio_path, original_mb)
      @downsampled_path = File.join(Dir.tmpdir, "podgen_groq_ds_#{Process.pid}.mp3")

      duration = probe_duration(audio_path)
      bitrate = compute_target_bitrate(duration)
      log("File too large (#{original_mb} MB > 25 MB), downsampling to #{bitrate}k for #{duration.round(0)}s audio...")

      cmd = [
        "ffmpeg", "-y", "-i", audio_path,
        "-ac", "1", "-ar", "16000", "-b:a", "#{bitrate}k",
        @downsampled_path
      ]
      _out, err, status = Open3.capture3(*cmd)

      unless status.success?
        raise "ffmpeg downsample failed: #{err}"
      end

      ds_mb = (File.size(@downsampled_path) / (1024.0 * 1024)).round(2)
      log("Downsampled: #{original_mb} MB → #{ds_mb} MB (#{bitrate} kbps)")

      if File.size(@downsampled_path) > MAX_FILE_SIZE
        raise "Downsampled file still too large for Groq (#{ds_mb} MB > 25 MB)"
      end

      @downsampled_path
    end

    def probe_duration(audio_path)
      cmd = ["ffprobe", "-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0", audio_path]
      out, _err, status = Open3.capture3(*cmd)
      raise "ffprobe failed for #{audio_path}" unless status.success?

      out.strip.to_f
    end

    # Compute the highest bitrate (in kbps) that fits under TARGET_SIZE_MB.
    # Caps at 128k — higher is pointless for speech transcription.
    # Floors at 32k — below that quality degrades too much.
    def compute_target_bitrate(duration_seconds)
      target_bits = TARGET_SIZE_MB * 1024 * 1024 * 8
      bitrate = (target_bits / duration_seconds / 1000).floor
      bitrate.clamp(32, 128)
    end

    def cleanup_downsample
      return unless @downsampled_path

      File.delete(@downsampled_path) if File.exist?(@downsampled_path)
    rescue => e
      log("Warning: failed to cleanup downsample: #{e.message}")
    end
  end
end
