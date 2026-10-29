# frozen_string_literal: true

# Normalized-title comparison for the re-post guard at selection (Q-88,
# P10-0 loop call 1). Sources re-post the same story under a new audio URL
# with an extended title ("Il lupo e il pastore" → "Il lupo e il pastore.
# Una favola di Esopo"), so an exact-URL check misses it.
module TitleMatch
  SUBTITLE_SEPARATORS = [". ", " — ", " – ", " - ", ": ", " | "].freeze
  MIN_STEM_CHARS = 8
  MIN_PREFIX_CHARS = 12
  MIN_TOKEN_LETTERS = 3
  JACCARD_THRESHOLD = 0.8

  module_function

  # NFKD, strip marks, downcase, non-letters/digits → space, collapse.
  def normalize(text)
    text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase
      .gsub(/[^\p{L}\p{N}]+/, " ").strip
  end

  # The normalized part before the first subtitle separator; a stem
  # shorter than MIN_STEM_CHARS falls back to the whole normalized title.
  def stem(title)
    raw = title.to_s
    cut = SUBTITLE_SEPARATORS.filter_map { |sep| raw.index(sep) }.min
    stem = normalize(cut ? raw[0...cut] : raw)
    (stem.length < MIN_STEM_CHARS) ? normalize(raw) : stem
  end

  # A title's comparison key: its stem and the set of digit runs in the
  # whole title (P10-0b: "Planeta Przyjaźni 1" and "… 2" are two parts).
  Key = Data.define(:stem, :digits)

  def key(title) = Key.new(stem: stem(title), digits: title.to_s.scan(/\p{Nd}+/).to_set)

  # No match when the titles carry different digit runs; otherwise stems
  # equal, or one a word-aligned prefix of the other with the shorter ≥
  # MIN_PREFIX_CHARS, or token-set Jaccard ≥ JACCARD_THRESHOLD over tokens
  # of ≥ MIN_TOKEN_LETTERS letters.
  def match?(a, b) = keys_match?(key(a), key(b))

  # match? over precomputed keys (the selection guard keys history once).
  def keys_match?(ka, kb) = ka.digits == kb.digits && stems_match?(ka.stem, kb.stem)

  def stems_match?(sa, sb)
    return false if sa.empty? || sb.empty?
    return true if sa == sb

    short, long = [sa, sb].sort_by(&:length)
    return true if short.length >= MIN_PREFIX_CHARS && long.start_with?("#{short} ")

    jaccard(tokens(sa), tokens(sb)) >= JACCARD_THRESHOLD
  end

  def tokens(stem)
    stem.split.select { |t| t.scan(/\p{L}/).length >= MIN_TOKEN_LETTERS }.to_set
  end

  def jaccard(x, y)
    return 0.0 if x.empty? || y.empty?
    (x & y).size.to_f / (x | y).size
  end
end
