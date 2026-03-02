# frozen_string_literal: true

# Lightweight wrapper around Float that carries an `absolute?` flag.
# DelegateClass(Float) means all numeric operations (>, +, -, round, to_f, etc.)
# work transparently — existing code like `skip > 0` or `total - cut` is unchanged.
#
# Parse formats:
#   "30"   → 30.0 seconds (relative)
#   "1:20" → 80.0 seconds (absolute — means "at 1m20s")
#
class TimeValue < DelegateClass(Float)
  attr_reader :absolute

  def initialize(seconds, absolute: false)
    super(Float(seconds))
    @absolute = absolute
  end

  def absolute?
    @absolute
  end

  # Parses a value into a TimeValue.
  #   nil / empty string → nil
  #   TimeValue           → returned as-is
  #   "1:20" / "11:20"   → minutes:seconds, absolute
  #   "30" / 30 / 30.0   → plain seconds, relative
  def self.parse(value)
    return nil if value.nil?
    return nil if value.is_a?(String) && value.strip.empty?
    return value if value.is_a?(TimeValue)

    str = value.to_s.strip
    if str.match?(/\A\d+:\d{1,2}\z/)
      mins, secs = str.split(":", 2).map(&:to_f)
      new(mins * 60 + secs, absolute: true)
    else
      new(Float(str), absolute: false)
    end
  end
end
