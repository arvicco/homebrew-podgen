# frozen_string_literal: true

# Reads the legacy markdown view (<basename>_script.md) back into the
# structured script hash that the rest of the pipeline uses.
#
# Used as a fallback when the canonical <basename>_script.json doesn't
# exist (i.e. for episodes generated before the JSON artifact was added).
#
# Recovers source link metadata from rendered link lists:
#   - inline mode: bullet lists that follow a segment's body become that
#     segment's :sources, and are stripped from the speech text.
#   - bottom mode: a trailing section whose body is only bullets (e.g.
#     "## More info") is treated as the script-level :sources rather than
#     a real segment.
module LegacyScriptParser
  LINK_BULLET = /\A- \[([^\]]+)\]\(([^)]+)\)/.freeze

  # Parse a script markdown file. Returns
  #   { title:, segments: [{name:, text:, sources?: [{title:, url:}]}], sources: [...] }
  def self.parse(path)
    content = File.read(path)
    title = content[/^# (.+)$/, 1].to_s.strip
    segments = []
    bottom_sources = []

    content.scan(/^## (.+?)\n\n(.*?)(?=^## |\z)/m) do |name, raw|
      body, link_lines = split_body_and_links(raw.strip)

      if body.empty? && link_lines.any?
        # Whole section is a link list — treat as bottom "More info" sources.
        bottom_sources.concat(parse_link_lines(link_lines))
        next
      end

      seg = { name: name.strip, text: body }
      sources = parse_link_lines(link_lines)
      seg[:sources] = sources unless sources.empty?
      segments << seg
    end

    {
      title: title,
      segments: segments,
      sources: bottom_sources.empty? ? aggregate_segment_sources(segments) : bottom_sources
    }
  end

  # Splits a segment body into (text, link_lines):
  # walks back from the end, peeling off blank lines and `- [title](url)` bullets.
  def self.split_body_and_links(text)
    lines = text.lines
    link_lines = []
    while !lines.empty? && (lines.last.strip.empty? || lines.last.strip.match?(LINK_BULLET))
      line = lines.pop
      link_lines.unshift(line) if line.strip.match?(LINK_BULLET)
    end
    [lines.join.strip, link_lines]
  end

  def self.parse_link_lines(lines)
    lines.map do |line|
      if (m = line.strip.match(LINK_BULLET))
        { title: m[1].strip, url: m[2].strip }
      end
    end.compact
  end

  # When no bottom "More info" section exists, derive script-level sources by
  # union'ing per-segment sources. Preserves first-seen order; deduplicates by URL.
  def self.aggregate_segment_sources(segments)
    seen = {}
    segments.each do |seg|
      Array(seg[:sources]).each { |src| seen[src[:url]] ||= src }
    end
    seen.values
  end
end
