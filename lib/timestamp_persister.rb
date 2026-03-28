# frozen_string_literal: true

require "json"

# Persists transcription segment timestamps to a JSON sidecar file.
# Used by the language pipeline to enable SRT subtitle generation for YouTube.
#
# Format:
#   { "version": 1, "engine": "groq", "intro_duration": 3.5,
#     "segments": [{ "start": 3.5, "end": 7.7, "text": "..." }, ...] }
#
# Segments are adjusted: original_start + intro_duration.
module TimestampPersister
  VERSION = 1

  # Persist segments to a JSON file, adjusting timestamps for intro offset.
  # Options:
  #   segments:       Array of { start:, end:, text: } hashes
  #   engine:         Engine code that produced the segments (e.g., "groq")
  #   intro_duration: Seconds of intro music prepended during assembly
  #   output_path:    Path to write the JSON file
  #   audio_duration: Optional — total source audio duration (pre-intro) for clamping
  def self.persist(segments:, engine:, intro_duration:, output_path:, audio_duration: nil)
    adjusted = segments.filter_map do |seg|
      s = (seg[:start] || seg["start"]).to_f
      e = (seg[:end] || seg["end"]).to_f
      text = seg[:text] || seg["text"]

      # Drop segments that start past the audio duration
      next if audio_duration && s >= audio_duration

      # Clamp end to audio duration
      e = audio_duration if audio_duration && e > audio_duration

      { "start" => (s + intro_duration).round(3),
        "end" => (e + intro_duration).round(3),
        "text" => text }
    end

    data = {
      "version" => VERSION,
      "engine" => engine,
      "intro_duration" => intro_duration.round(3),
      "segments" => adjusted
    }

    File.write(output_path, JSON.pretty_generate(data))
  end

  # Load a timestamps JSON file. Returns parsed Hash or nil if file missing.
  def self.load(path)
    return nil unless File.exist?(path)
    JSON.parse(File.read(path))
  end

  # Extract the best available segments from a transcription result.
  # Priority: groq > elab > open > primary result.
  # Returns [segments, engine_code] or [nil, nil] if no segments available.
  PREFERRED_ENGINES = %w[groq elab open].freeze

  def self.extract_segments(transcription_result, engine_codes:, comparison_results: nil)
    # In comparison mode, pick the best engine's segments
    if comparison_results
      PREFERRED_ENGINES.each do |code|
        next unless comparison_results[code]
        segs = comparison_results[code][:segments]
        return [segs, code] if segs && !segs.empty?
      end
    end

    # Single engine or fallback to primary result
    segs = transcription_result[:segments]
    if segs && !segs.empty?
      engine = engine_codes.first
      return [segs, engine]
    end

    [nil, nil]
  end
end
