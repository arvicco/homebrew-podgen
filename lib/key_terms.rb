# frozen_string_literal: true

require_relative "vocab_ledger"

# Story-critical words of one episode (loop call 4): body tokens (letters
# only, ≥ 4 chars, downcased — VocabLedger.tokens) that occur at least
# MIN_TF times in the episode, are not proper nouns (capitalised in more
# than half of their mid-sentence occurrences, or never seen mid-sentence),
# and occur in at most MAX_DF_SHARE of the show's earlier episodes (ledger
# df). Score = tf × ln((N + 1) / (df + 1)); ties (and the no-ledger case,
# where every score is 0) fall back to tf. The top KEY_TERMS are returned.
module KeyTerms
  KEY_TERMS = 8
  MIN_TF = 3
  MAX_DF_SHARE = 0.15
  SENTENCE_END = /[.!?…:\n]/
  # Skipped when looking back for a sentence boundary: spaces, quotes,
  # brackets, dashes and markdown emphasis.
  OPENERS = /[[:space:]"'«»“”„‚‘’()\[\]—–\-*_]/

  def self.candidates(text, ledger: nil, limit: KEY_TERMS)
    stats = Hash.new { |h, k| h[k] = {tf: 0, mid: 0, cap_mid: 0} }
    text.to_s.scan(VocabLedger::TOKEN) do
      match = Regexp.last_match
      word = match[0]
      next if word.length < VocabLedger::MIN_TOKEN_LENGTH

      s = stats[word.downcase]
      s[:tf] += 1
      next if sentence_start?(text, match.begin(0))

      s[:mid] += 1
      s[:cap_mid] += 1 if word.match?(/\A\p{Lu}/)
    end

    n = ledger ? ledger.episodes : 0
    scored = stats.filter_map do |token, s|
      next if s[:tf] < MIN_TF
      next if s[:mid].zero? || s[:cap_mid] * 2 > s[:mid]

      df = ledger ? ledger.df(token) : 0
      next if df > MAX_DF_SHARE * n

      [token, s[:tf] * Math.log((n + 1.0) / (df + 1)), s[:tf]]
    end
    scored.sort_by { |token, score, tf| [-score, -tf, token] }.first(limit).map(&:first)
  end

  # True when only openers stand between pos and the start of the text or a
  # sentence-ending character.
  def self.sentence_start?(text, pos)
    i = pos - 1
    while i >= 0
      ch = text[i]
      return true if ch.match?(SENTENCE_END)
      return false unless ch.match?(OPENERS)

      i -= 1
    end
    true
  end
  private_class_method :sentence_start?
end
