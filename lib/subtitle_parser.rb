# frozen_string_literal: true

# Parses subtitle/transcript formats (SRT, VTT, JSON) into plain text.
# Shared utility used by YouTubeDownloader and TranscriptDiscovery.
module SubtitleParser
  # A cue timing line; hours are optional (mm:ss.mmm is valid WebVTT).
  TIMING_LINE = /^\s*(?:\d+:)?\d{2}:\d{2}[.,]\d{3}\s*-->/
  BOM = "﻿".b.freeze

  # Strip timestamps and sequence numbers from SRT content, return plain text.
  def self.parse_srt(srt)
    srt.lines
      .reject { |line| line.strip =~ /^\d+$/ }                              # sequence numbers
      .reject { |line| line.match?(TIMING_LINE) }                           # timestamp lines
      .map(&:strip)
      .reject(&:empty?)
      .join(" ")
      .gsub(/\s+/, " ")
      .strip
  end

  # Strip header and timestamps from VTT (WebVTT) content, return plain text.
  # A cue's text is every line after its timing line, so the header, NOTE /
  # STYLE / REGION blocks and cue identifiers drop out while a cue whose text
  # is a number ("1945") survives; inline tags (<c>, <v>, <00:00:01.500>)
  # are not spoken text.
  def self.parse_vtt(vtt)
    vtt.split(/\r?\n[ \t]*\r?\n/)
      .flat_map { |block| cue_text_lines(block.lines) }
      .map { |line| line.gsub(/<[^>]*>/, "").strip }
      .reject(&:empty?)
      .join(" ")
      .gsub(/\s+/, " ")
      .strip
  end

  def self.cue_text_lines(lines)
    i = lines.index { |l| l.match?(TIMING_LINE) }
    i ? lines[(i + 1)..].reject { |l| l.match?(TIMING_LINE) } : []
  end

  # Parse Podcasting 2.0 JSON transcript format.
  # Array of {startTime, endTime, body} objects.
  def self.parse_json(json_str)
    require "json"
    data = JSON.parse(json_str)
    segments = data.is_a?(Array) ? data : data["segments"] || data["results"] || []
    segments.map { |s| s["body"] || s["text"] || "" }
      .reject(&:empty?)
      .join(" ")
      .gsub(/\s+/, " ")
      .strip
  rescue JSON::ParserError
    ""
  end

  # Detect format from content or content-type and parse accordingly.
  def self.parse(content, format: nil, content_type: nil)
    content = strip_bom(content)
    format ||= detect_format(content, content_type)
    case format
    when :srt then parse_srt(content)
    when :vtt then parse_vtt(content)
    when :json then parse_json(content)
    when :text then content.strip
    else content.strip
    end
  end

  def self.detect_format(content, content_type = nil)
    return :srt if content_type&.include?("srt") || content_type&.include?("subrip")
    return :vtt if content_type&.include?("vtt")
    return :json if content_type&.include?("json")

    stripped = strip_bom(content).lstrip
    return :vtt if stripped.start_with?("WEBVTT")
    return :json if stripped.start_with?("[") || stripped.start_with?("{")
    return :srt if stripped.match?(/\A\d+\r?\n\d{2}:\d{2}:\d{2}/)

    :text
  end

  # Byte-level check, so a BINARY-encoded body never raises.
  def self.strip_bom(content)
    content.b.start_with?(BOM) ? content.byteslice(BOM.bytesize..) : content
  end

  private_class_method :cue_text_lines, :strip_bom
end
