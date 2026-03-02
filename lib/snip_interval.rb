# frozen_string_literal: true

# Represents a collection of intervals to remove from an audio file.
# Used to unify skip (remove from start), cut (remove from end), and
# snip (remove interior segments) into a single trimming pass.
#
# Parse formats:
#   "1:20-2:30"         — remove between absolute timestamps
#   "20-30"             — remove between plain seconds
#   "1:20+30"           — remove 30s starting at 1:20
#   "1:20-end"          — remove from 1:20 to end
#   "1:20-2:30,3:40+33" — multiple intervals (comma-separated)
#
class SnipInterval
  Interval = Struct.new(:from, :to)

  attr_reader :intervals

  # Parses a value into a SnipInterval.
  #   nil / empty string → nil
  #   SnipInterval        → returned as-is
  #   String              → parsed
  def self.parse(value)
    return nil if value.nil?
    return nil if value.is_a?(String) && value.strip.empty?
    return value if value.is_a?(SnipInterval)

    new(value.to_s)
  end

  def initialize(raw)
    @intervals = raw.strip.split(",").map { |part| parse_one(part.strip) }
    raise ArgumentError, "no intervals parsed from: #{raw}" if @intervals.empty?
  end

  # Appends a removal interval (used to fold in skip/cut).
  def add(from, to)
    @intervals << Interval.new(from.to_f, to&.to_f)
    self
  end

  # Given total audio duration, resolves open-ended intervals, clamps,
  # merges overlapping, and returns an array of Interval keep segments.
  def keep_segments(total_duration)
    total = total_duration.to_f

    # Resolve nil → total, clamp to [0, total]
    resolved = @intervals.map do |iv|
      f = [[iv.from, 0].max, total].min
      t = iv.to ? [[iv.to, 0].max, total].min : total
      f, t = t, f if f > t
      Interval.new(f, t)
    end

    # Sort by start, merge overlapping
    merged = merge_intervals(resolved.sort_by(&:from))

    # Invert to keep segments
    keeps = []
    cursor = 0.0
    merged.each do |iv|
      keeps << Interval.new(cursor, iv.from) if iv.from > cursor
      cursor = iv.to
    end
    keeps << Interval.new(cursor, total) if cursor < total

    keeps
  end

  def to_s
    @intervals.map { |iv|
      to_part = iv.to ? format_ts(iv.to) : "end"
      "#{format_ts(iv.from)}-#{to_part}"
    }.join(", ")
  end

  private

  RANGE_RE = /\A(\d+(?::\d{1,2})?(?:\.\d+)?)\-(\d+(?::\d{1,2})?(?:\.\d+)?)\z/
  OFFSET_RE = /\A(\d+(?::\d{1,2})?(?:\.\d+)?)\+(\d+(?::\d{1,2})?(?:\.\d+)?)\z/
  END_RE = /\A(\d+(?::\d{1,2})?(?:\.\d+)?)\-end\z/i

  def parse_one(str)
    if (m = str.match(OFFSET_RE))
      start = parse_timestamp(m[1])
      duration = parse_timestamp(m[2])
      Interval.new(start, start + duration)
    elsif (m = str.match(END_RE))
      Interval.new(parse_timestamp(m[1]), nil)
    elsif (m = str.match(RANGE_RE))
      Interval.new(parse_timestamp(m[1]), parse_timestamp(m[2]))
    else
      raise ArgumentError, "invalid snip interval: #{str.inspect}"
    end
  end

  def parse_timestamp(str)
    if str.match?(/\A\d+:\d{1,2}(?:\.\d+)?\z/)
      mins, secs = str.split(":", 2).map(&:to_f)
      mins * 60 + secs
    else
      Float(str)
    end
  end

  def merge_intervals(sorted)
    return [] if sorted.empty?

    merged = [sorted.first.dup]
    sorted[1..].each do |iv|
      last = merged.last
      if iv.from <= last.to
        last.to = [last.to, iv.to].max
      else
        merged << iv.dup
      end
    end
    merged
  end

  def format_ts(seconds)
    return "end" unless seconds

    mins = (seconds / 60).to_i
    secs = seconds % 60
    if mins > 0
      secs_i = secs.to_i
      "#{mins}:#{format('%02d', secs_i)}"
    else
      secs == secs.to_i ? secs.to_i.to_s : secs.round(1).to_s
    end
  end
end
