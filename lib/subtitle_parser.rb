# frozen_string_literal: true

# Parses subtitle/transcript formats (SRT, VTT, JSON) into plain text.
# Shared utility used by YouTubeDownloader and TranscriptDiscovery.
module SubtitleParser
  # Strip timestamps and sequence numbers from SRT content, return plain text.
  def self.parse_srt(srt)
    srt.lines
      .reject { |line| line.strip =~ /^\d+$/ }                              # sequence numbers
      .reject { |line| line.strip =~ /^\d{2}:\d{2}:\d{2}[.,]\d{3}\s*-->/ }  # timestamp lines
      .map(&:strip)
      .reject(&:empty?)
      .join(" ")
      .gsub(/\s+/, " ")
      .strip
  end

  # Strip header and timestamps from VTT (WebVTT) content, return plain text.
  def self.parse_vtt(vtt)
    lines = vtt.lines
    # Skip WEBVTT header and any metadata lines until first blank line
    start = lines.index { |l| l.strip.empty? } || 0
    lines[start..].to_a
      .reject { |line| line.strip =~ /^\d{2}:\d{2}:\d{2}[.,]\d{3}\s*-->/ }  # timestamp lines
      .reject { |line| line.strip =~ /^\d+$/ }                              # optional sequence numbers
      .map(&:strip)
      .reject(&:empty?)
      .join(" ")
      .gsub(/\s+/, " ")
      .strip
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

    stripped = content.lstrip
    return :vtt if stripped.start_with?("WEBVTT")
    return :json if stripped.start_with?("[") || stripped.start_with?("{")
    return :srt if stripped.match?(/\A\d+\r?\n\d{2}:\d{2}:\d{2}/)

    :text
  end
end
