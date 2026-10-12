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
  # A truncated/corrupt *_timestamps.json (P1-4, Q-05). Subclass of StandardError so
  # existing `rescue => e` sites in the runner/regen keep their statuses.
  class CorruptSidecarError < StandardError; end

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

  # Replace segments in an existing timestamps file and mark as reconciled.
  def self.update_segments(path, segments)
    data = load(path)
    return unless data

    data["segments"] = segments
    data["reconciled"] = true
    File.write(path, JSON.pretty_generate(data))
  end

  # Load a timestamps JSON file. Returns parsed Hash or nil if file missing.
  def self.load(path)
    return nil unless File.exist?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    raise CorruptSidecarError, "corrupt timestamps sidecar #{path}: #{e.message[0, 80]}"
  end

  # Extract the best available segments from a transcription result.
  # Priority: groq > elab > open > primary result.
  # Returns [segments, engine_code] or [nil, nil] if no segments available.
  PREFERRED_ENGINES = %w[groq elab open].freeze

  def self.extract_segments(transcription_result, engine_codes:, comparison_results: nil)
    # In comparison mode, pick the best engine's segments (or words→segments)
    if comparison_results
      PREFERRED_ENGINES.each do |code|
        next unless comparison_results[code]
        segs = comparison_results[code][:segments]
        return [segs, code] if segs && !segs.empty?
      end
      # Fallback: build segments from words if available
      PREFERRED_ENGINES.each do |code|
        next unless comparison_results[code]
        words = comparison_results[code][:words]
        if words && !words.empty?
          segs = build_segments_from_words(words)
          return [segs, code] unless segs.empty?
        end
      end
    end

    # Single engine or fallback to primary result
    segs = transcription_result[:segments]
    if segs && !segs.empty?
      engine = engine_codes.first
      return [segs, engine]
    end

    # Fallback: build segments from words
    words = transcription_result[:words]
    if words && !words.empty?
      segs = build_segments_from_words(words)
      return [segs, engine_codes.first] unless segs.empty?
    end

    [nil, nil]
  end

  # Sentence terminators: ASCII .!? plus CJK full-width 。！？ (P4-3). Anchored
  # with \z so a newline inside a word does not count as a sentence end.
  SENTENCE_END = /[.!?。！？]\s*\z/

  # Build sentence-level segments from word-level timestamps. The one shared
  # builder (P4-3); ElevenlabsEngine delegates here.
  #   - text: "word" then "text", string or symbol keys, per word
  #   - tokens typed "spacing" (ElevenLabs Scribe) are skipped; untyped
  #     empty/whitespace tokens are kept as words (joined text keeps their gap)
  #   - splits on SENTENCE_END
  #   - timings: Float() coercion, nil/unparseable -> 0.0; end clamped >= start
  # Words are always joined with a single space; language-aware joining (no
  # spaces for CJK) is deferred.
  def self.build_segments_from_words(words)
    segments = []
    current_words = []
    current_start = nil
    last_end = 0.0

    words.each do |w|
      next if word_field(w, :type).to_s == "spacing"

      text = (word_field(w, :word) || word_field(w, :text)).to_s
      word_start = word_time(word_field(w, :start))
      last_end = word_time(word_field(w, :end))

      current_start ||= word_start
      current_words << text

      if text.match?(SENTENCE_END)
        segments << { start: current_start, end: [last_end, current_start].max, text: current_words.join(" ").strip }
        current_words = []
        current_start = nil
      end
    end

    # Flush remaining words as final segment
    unless current_words.empty?
      segments << { start: current_start, end: [last_end, current_start].max, text: current_words.join(" ").strip }
    end

    segments
  end

  def self.word_field(word, key)
    word.key?(key) ? word[key] : word[key.to_s]
  end
  private_class_method :word_field

  def self.word_time(value)
    Float(value)
  rescue ArgumentError, TypeError
    0.0
  end
  private_class_method :word_time
end
