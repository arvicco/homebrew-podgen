# frozen_string_literal: true

require "json"

# Generates SRT subtitle files from persisted timestamp data.
# SRT is the standard format accepted by YouTube for caption uploads.
module SubtitleGenerator
  MAX_LINE_LENGTH = 80

  # Generate an SRT file from a timestamps JSON file.
  # Returns the output path, or nil if timestamps file is missing.
  def self.generate_srt(timestamps_path, output_path)
    return nil unless File.exist?(timestamps_path)

    data = JSON.parse(File.read(timestamps_path))
    segments = data["segments"] || []

    entries = []
    segments.each do |seg|
      sub_segments = split_segment(seg)
      entries.concat(sub_segments)
    end

    srt = entries.each_with_index.map do |entry, i|
      "#{i + 1}\n#{format_srt_time(entry[:start])} --> #{format_srt_time(entry[:end])}\n#{entry[:text]}"
    end.join("\n\n")

    File.write(output_path, srt.empty? ? "" : "#{srt}\n")
    output_path
  end

  # Format seconds as SRT timestamp: HH:MM:SS,mmm
  def self.format_srt_time(seconds)
    total_ms = (seconds.to_f * 1000).round
    millis = total_ms % 1000
    total_secs = total_ms / 1000
    secs = total_secs % 60
    minutes = (total_secs / 60) % 60
    hours = total_secs / 3600

    format("%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
  end

  # Split a segment into sub-segments if text exceeds MAX_LINE_LENGTH.
  # Time is distributed proportionally by character count.
  def self.split_segment(segment)
    text = segment["text"].to_s.strip
    start_time = segment["start"].to_f
    end_time = segment["end"].to_f

    return [{ start: start_time, end: end_time, text: text }] if text.length <= MAX_LINE_LENGTH

    parts = split_text(text)
    return [{ start: start_time, end: end_time, text: text }] if parts.length <= 1

    total_chars = parts.sum(&:length)
    duration = end_time - start_time
    current = start_time

    parts.map do |part|
      ratio = part.length.to_f / total_chars
      part_duration = duration * ratio
      part_end = current + part_duration
      entry = { start: current, end: part_end, text: part }
      current = part_end
      entry
    end
  end

  # Split text at sentence or comma boundaries, keeping parts under MAX_LINE_LENGTH.
  def self.split_text(text)
    # Try sentence boundaries first
    sentences = text.scan(/[^.!?]+[.!?]+/).map(&:strip)
    sentences << text.split(/[.!?]+/).last&.strip if sentences.join(" ").length < text.length

    return recombine(sentences.compact.reject(&:empty?)) if sentences.length > 1

    # Fall back to comma boundaries
    clauses = text.split(/,\s*/).map(&:strip)
    return recombine(clauses.reject(&:empty?)) if clauses.length > 1

    # Last resort: split at word boundaries near midpoint
    words = text.split
    mid = words.length / 2
    [words[0...mid].join(" "), words[mid..].join(" ")]
  end

  # Recombine fragments so each chunk stays under MAX_LINE_LENGTH.
  def self.recombine(fragments)
    result = []
    current = +""

    fragments.each do |frag|
      candidate = current.empty? ? frag : "#{current} #{frag}"
      if candidate.length > MAX_LINE_LENGTH && !current.empty?
        result << current
        current = frag
      else
        current = candidate
      end
    end
    result << current unless current.empty?
    result
  end

  private_class_method :split_text, :recombine
end
