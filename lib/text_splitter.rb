# frozen_string_literal: true

# Splits long text into chunks that respect natural boundaries.
# Split priority: paragraph → sentence → comma/semicolon → whitespace → UTF-8-safe char boundary.
class TextSplitter
  DEFAULT_MAX_CHARS = 9_500 # Safety margin below ElevenLabs' 10k limit

  def initialize(max_chars: DEFAULT_MAX_CHARS)
    @max_chars = max_chars
  end

  # Returns an array of text chunks, each <= max_chars.
  def split(text)
    return [text] if text.length <= @max_chars

    chunks = []
    remaining = text.dup

    while remaining.length > @max_chars
      split_at = remaining.rindex(/\n\n/, @max_chars) ||
                 remaining.rindex(/(?<=[.!?])\s+/, @max_chars) ||
                 remaining.rindex(/[,;:]\s+/, @max_chars) ||
                 remaining.rindex(/\s+/, @max_chars) ||
                 find_safe_split_point(remaining, @max_chars)
      split_at = [split_at, 1].max

      chunks << remaining[0...split_at].strip
      remaining = remaining[split_at..].strip
    end

    chunks << remaining unless remaining.empty?
    chunks
  end

  private

  # Walk backward from max_pos to find a safe split point that doesn't
  # break a multi-byte UTF-8 character or grapheme cluster.
  def find_safe_split_point(text, max_pos)
    pos = max_pos
    while pos > 0
      char = text[pos]
      break if char && (char.ascii_only? || char.match?(/\s/))
      pos -= 1
    end
    pos > 0 ? pos : max_pos
  end
end
