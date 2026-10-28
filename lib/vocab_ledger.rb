# frozen_string_literal: true

require_relative "episode_filtering"
require_relative "transcript_parser"
require_relative "transcript_renderer"

# Explained-lemma ledger for one show, derived on the fly from the show's
# *_transcript.md files (basename order = chronological). Nothing is cached:
# every run re-reads the transcripts, so the ledger is never stale.
#
# Spaced re-exposure: a lemma explained k times may be explained again once
# REEXPOSURE_GAPS[k - 1] episodes have passed since its last explanation;
# after REEXPOSURE_GAPS.length + 1 explanations it is excluded for good.
#
# Also the show's document frequency per body token (letters only, ≥ 4
# chars, downcased) for the key-terms and band-selection scores.
class VocabLedger
  REEXPOSURE_GAPS = [8, 20, 50].freeze
  MIN_TOKEN_LENGTH = 4
  TOKEN = /\p{L}+/

  # Vocabulary-section parser shared with the renderer (no second parser).
  PARSER = Object.new.extend(TranscriptRenderer)

  attr_reader :episodes

  def self.for_config(config, before: nil)
    build(config.episodes_dir, before: before)
  end

  # before: exclusive basename cutoff — only transcripts whose basename sorts
  # before it are read (revocab of an old episode sees only its past).
  def self.build(episodes_dir, before: nil)
    cutoff = before&.delete_suffix("_transcript.md")
    ledger = new
    EpisodeFiltering.all_transcripts(episodes_dir)
      .map { |path| [File.basename(path, "_transcript.md"), path] }
      .sort_by(&:first)
      .each do |basename, path|
        break if cutoff && basename >= cutoff

        parsed = TranscriptParser.parse_file(path)
        ledger.add(basename, lemmas: vocab_lemmas(parsed.vocabulary), body: parsed.body)
      end
    ledger
  end

  # Letters-only tokens of text, ≥ MIN_TOKEN_LENGTH chars, downcased, in order.
  def self.tokens(text)
    text.to_s.scan(TOKEN).select { |t| t.length >= MIN_TOKEN_LENGTH }.map(&:downcase)
  end

  def self.vocab_lemmas(vocabulary)
    entries = vocabulary && PARSER.parse_vocab_entries(vocabulary)
    return [] unless entries

    entries.each_value.map { |e| e[:lemma].to_s.downcase.strip }.reject(&:empty?).uniq
  end
  private_class_method :vocab_lemmas

  def initialize
    @episodes = 0
    @explained = Hash.new { |h, k| h[k] = [] } # lemma → [[index, basename], ...]
    @df = Hash.new(0)
  end

  # Appends one episode (in chronological order).
  def add(basename, lemmas:, body:)
    lemmas.each { |lemma| @explained[lemma] << [@episodes, basename] }
    self.class.tokens(body).uniq.each { |t| @df[t] += 1 }
    @episodes += 1
    self
  end

  # Chronological basenames of the episodes that explained lemma.
  def explained(lemma)
    (@explained.fetch(key(lemma), nil) || []).map(&:last)
  end

  def exposures(lemma)
    @explained.fetch(key(lemma), nil)&.length || 0
  end

  # May lemma be explained in the next episode (index = episodes)?
  def allowed?(lemma)
    history = @explained.fetch(key(lemma), nil)
    return true if history.nil? || history.empty?

    gap = REEXPOSURE_GAPS[history.length - 1]
    return false unless gap

    @episodes - history.last.first >= gap
  end

  # Number of episodes whose body contains token.
  def df(token)
    @df.fetch(token.to_s.downcase, 0)
  end

  # Lemmas explained at least min times, most-explained first:
  # [{lemma:, count:, last:}, ...]
  def top_explained(min: 3)
    @explained
      .select { |_lemma, history| history.length >= min }
      .map { |lemma, history| {lemma: lemma, count: history.length, last: history.last.last} }
      .sort_by { |h| [-h[:count], h[:lemma]] }
  end

  private

  def key(lemma)
    lemma.to_s.downcase.strip
  end
end
