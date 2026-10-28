# frozen_string_literal: true

require_relative "transcript_parser"
require_relative "transcript_renderer"
require_relative "episode_filtering"
require_relative "key_terms"
require_relative "vocab_ledger"

# Didactic census of a show's vocabulary sections (`podgen stats
# --vocab-health`, P9-0 / Q-95). Self-contained over the show's
# `*_transcript.md` files, chronological by basename; the vocabulary
# section is read with TranscriptRenderer#parse_vocab_entries. An entry
# counts when its parenthesis opens with a CEFR level, e.g. `(B1 noun)`.
#
# Key-term candidates are KeyTerms.candidates (the annotator's own rule,
# loop call 4) scored against the show's earlier episodes only, exactly as
# the ledger sees them at annotate time.
#
# With `last: N` the report covers the latest N transcripts; repeats and
# key-term document frequency still count every earlier episode.
class VocabHealth
  include TranscriptRenderer

  LEVELS = %w[A1 A2 B1 B2 C1 C2].freeze
  TOP_N = 12
  MISS_MIN = 3
  COVER_PREFIX = 5

  Report = Struct.new(:episodes, :total_episodes, :entries, :unlevelled, :unique_lemmas,
    :repeat_entries, :median_per_episode, :median_per_minute, :lemmas_3plus,
    :top_lemmas, :levels, :key_term_misses, :drift, :repeated_with_definitions,
    keyword_init: true) do
    def repeat_share
      entries.zero? ? 0.0 : 100.0 * repeat_entries / entries
    end
  end

  # Drops candidates sharing their first COVER_PREFIX chars with a lemma or
  # a recorded surface form of the episode's vocabulary.
  def self.uncovered(candidates, covers:)
    prefixes = covers.map { |c| c.to_s.downcase[0, COVER_PREFIX] }.to_set
    candidates.reject { |word| prefixes.include?(word[0, COVER_PREFIX]) }
  end

  # The ledger interface KeyTerms reads (`episodes`, `df`), accumulated in
  # chronological order: holds the episodes before the one being scored.
  class RunningDf
    attr_reader :episodes

    def initialize
      @episodes = 0
      @df = Hash.new(0)
    end

    def df(token)
      @df.fetch(token.to_s.downcase, 0)
    end

    def add(body)
      VocabLedger.tokens(body).uniq.each { |t| @df[t] += 1 }
      @episodes += 1
    end
  end

  # durations: basename => seconds (history.yml), for the per-minute density.
  def initialize(episodes_dir:, cutoff: nil, durations: {})
    @episodes_dir = episodes_dir
    @cutoff = cutoff
    @durations = durations || {}
  end

  def report(last: nil)
    eps = load_episodes
    window_start = last ? [eps.length - last, 0].max : 0
    window = eps[window_start..] || []

    repeat_entries = count_repeats(eps, window_start)
    misses = count_key_term_misses(eps, window_start)
    entries = window.flat_map { |e| e[:entries] }
    lemma_counts = entries.map { |e| e[:lemma] }.tally
    drift, repeated = definition_drift(entries)

    Report.new(
      episodes: window.length,
      total_episodes: eps.length,
      entries: entries.length,
      unlevelled: window.sum { |e| e[:unlevelled] },
      unique_lemmas: lemma_counts.size,
      repeat_entries: repeat_entries,
      median_per_episode: median(window.map { |e| e[:entries].length }),
      median_per_minute: median(per_minute(window)),
      lemmas_3plus: lemma_counts.count { |_, c| c >= 3 },
      top_lemmas: lemma_counts.sort_by { |l, c| [-c, l] }.first(TOP_N),
      levels: level_distribution(entries),
      key_term_misses: misses,
      drift: drift,
      repeated_with_definitions: repeated
    )
  end

  def lines(name, last: nil)
    r = report(last: last)
    return ["#{name}: no transcripts"] if r.total_episodes.zero?

    scope = last ? "last #{r.episodes} of #{r.total_episodes} episodes" : "#{r.episodes} episodes"
    density = "median #{format_number(r.median_per_episode)}/episode"
    density += ", #{format("%.1f", r.median_per_minute)}/min" if r.median_per_minute
    top = r.top_lemmas.select { |_, c| c >= 2 }.map { |l, c| "#{l}×#{c}" }.join(", ")
    out = ["#{name} (#{scope}): #{r.entries} entries (#{r.unique_lemmas} unique lemmas); #{density}"]
    out << "  repeat share #{pct(r.repeat_entries, r.entries)}% (#{r.repeat_entries} entries re-explain a lemma from an earlier episode)"
    out << "  explained ≥3×: #{r.lemmas_3plus} lemmas#{"; top: #{top}" unless top.empty?}"
    out << "  #{format_levels(r)}"
    out << "  key-term misses: #{r.key_term_misses}/#{r.episodes} episodes with ≥#{MISS_MIN} unexplained candidates"
    out << "  definition drift: #{r.drift} of #{r.repeated_with_definitions} lemmas defined more than once"
    out << "  (#{r.unlevelled} entries without a CEFR level ignored)" if r.unlevelled.positive?
    out
  end

  private

  def load_episodes
    EpisodeFiltering.all_transcripts(@episodes_dir).map do |path|
      parsed = TranscriptParser.parse_file(path)
      by_key = (parsed.vocabulary && parse_vocab_entries(parsed.vocabulary)) || {}
      entries = []
      unlevelled = 0
      by_key.values.uniq(&:object_id).each do |e|
        level = e[:pos].to_s.split.first
        unless LEVELS.include?(level)
          unlevelled += 1
          next
        end
        entries << {lemma: e[:lemma].to_s.downcase.strip, level: level,
                     definition: first_sentence(e[:definition])}
      end
      basename = File.basename(path, "_transcript.md")
      {basename: basename, body: parsed.body.to_s, covers: by_key.keys,
       entries: entries.uniq { |e| e[:lemma] }, unlevelled: unlevelled}
    end
  end

  def first_sentence(definition)
    text = definition.to_s.sub(/\..*/, "").strip.downcase
    text.empty? ? nil : text
  end

  def count_repeats(eps, window_start)
    seen = Set.new
    repeats = 0
    eps.each_with_index do |ep, i|
      lemmas = ep[:entries].map { |e| e[:lemma] }
      repeats += lemmas.count { |l| seen.include?(l) } if i >= window_start
      seen.merge(lemmas)
    end
    repeats
  end

  # Window episodes with >= MISS_MIN key-term candidates left unexplained;
  # each episode is scored against the episodes before it (O(N) overall).
  def count_key_term_misses(eps, window_start)
    running = RunningDf.new
    misses = 0
    eps.each_with_index do |ep, i|
      if i >= window_start
        candidates = KeyTerms.candidates(ep[:body], ledger: running)
        misses += 1 if self.class.uncovered(candidates, covers: ep[:covers]).size >= MISS_MIN
      end
      running.add(ep[:body])
    end
    misses
  end

  def per_minute(window)
    window.filter_map do |ep|
      seconds = @durations[ep[:basename]]
      next unless seconds.is_a?(Numeric) && seconds.positive?

      ep[:entries].length / (seconds / 60.0)
    end
  end

  def definition_drift(entries)
    defs = Hash.new { |h, k| h[k] = [] }
    entries.each { |e| defs[e[:lemma]] << e[:definition] if e[:definition] }
    repeated = defs.select { |_, d| d.size >= 2 }
    [repeated.count { |_, d| d.uniq.size >= 2 }, repeated.size]
  end

  def level_distribution(entries)
    cut = LEVELS.index(@cutoff.to_s.upcase)
    return entries.map { |e| e[:level] }.tally unless cut

    dist = {below: 0, at: 0, plus1: 0, plus2: 0}
    entries.each do |e|
      d = LEVELS.index(e[:level]) - cut
      key = if d.negative? then :below
      elsif d.zero? then :at
      elsif d == 1 then :plus1
      else :plus2
      end
      dist[key] += 1
    end
    dist
  end

  def format_levels(r)
    total = r.entries
    l = r.levels
    unless l.key?(:at)
      return "levels: " + l.sort.map { |k, v| "#{k} #{pct(v, total)}%" }.join(" · ")
    end

    "levels vs cutoff: below #{pct(l[:below], total)}% · at #{@cutoff.upcase} #{pct(l[:at], total)}% · " \
      "+1 #{pct(l[:plus1], total)}% · +2 and above #{pct(l[:plus2], total)}%"
  end

  def pct(part, whole)
    whole.zero? ? 0 : (100.0 * part / whole).round
  end

  def median(values)
    return nil if values.empty?

    sorted = values.sort
    mid = sorted.length / 2
    sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  def format_number(value)
    (value.to_f % 1).zero? ? value.to_i.to_s : format("%.1f", value)
  end
end
