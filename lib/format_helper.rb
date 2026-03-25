# frozen_string_literal: true

# Shared formatting helpers for human-readable sizes and durations.
# Use as module methods (FormatHelper.format_size) or mixin (include FormatHelper).
module FormatHelper
  # Format byte count as human-readable string.
  # mb_precision: decimal places for MB (default 1). GB always uses 1 decimal.
  def self.format_size(bytes, mb_precision: 1)
    if bytes >= 1_000_000_000
      format("%.1f GB", bytes / 1_000_000_000.0)
    elsif bytes >= 1_000_000
      format("%.#{mb_precision}f MB", bytes / 1_000_000.0)
    elsif bytes >= 1_000
      format("%d KB", (bytes / 1_000.0).round)
    else
      "#{bytes} B"
    end
  end

  # Format seconds as M:SS (e.g., "3:05", "10:00").
  def self.format_duration_mmss(seconds)
    minutes = (seconds / 60).to_i
    secs = (seconds % 60).to_i
    format("%d:%02d", minutes, secs)
  end

  # Instance method delegates for mixin use.
  def format_size(bytes, mb_precision: 1)
    FormatHelper.format_size(bytes, mb_precision: mb_precision)
  end

  def format_duration_mmss(seconds)
    FormatHelper.format_duration_mmss(seconds)
  end
end
