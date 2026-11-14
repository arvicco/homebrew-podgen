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
  KEY_GROUP_TITLE = "Key words" # VocabularyAnnotator::KEY_GROUP_HEADING without "### "

  SAMPLE_SIZE = 10
  PROMINENT_MIN = 3

  # within_repeats: re-explanations of a lemma explained earlier in the same
  # window; prominent_entries: entries whose lemma (or a recorded form, by
  # the COVER_PREFIX rule) is in the title or >= PROMINENT_MIN times in the body.
  Report = Struct.new(:episodes, :total_episodes, :entries, :unlevelled, :unique_lemmas,
    :repeat_entries, :median_per_episode, :median_per_minute, :lemmas_3plus,
    :top_lemmas, :levels, :key_term_misses, :drift, :repeated_with_definitions,
    :within_repeats, :mean_uncovered, :median_gloss_words, :prominent_entries, :entry_list,
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
    build_report(eps, (window_start...eps.length).to_a)
  end

  # Three cohorts around `split` (a Date), by the basename date: :before
  # (< split), :after (>= split), :before_last (the after-cohort's size of
  # episodes immediately preceding the split); nil when empty. Repeats and
  # key-term document frequency count every earlier episode, as in #report.
  # :would_have — [basename, count] per after-episode, nil without a cutoff.
  def split_report(split:)
    eps = load_episodes
    dated = eps.each_index.map { |i| [i, EpisodeFiltering.parse_date(eps[i][:basename])] }
    before = dated.select { |_, d| d && d < split }.map(&:first)
    after = dated.select { |_, d| d && d >= split }.map(&:first)
    before_last = after.empty? ? [] : before.last(after.length)
    cohorts = {before: before, after: after, before_last: before_last}
      .transform_values { |idx| idx.empty? ? nil : build_report(eps, idx) }
    cohorts.merge(undated: dated.count { |_, d| d.nil? }, would_have: would_have(eps, after))
  end

  # Row labels of the split table, in order (identical for every cohort).
  def self.split_labels(cutoff)
    levels = if LEVELS.include?(cutoff.to_s.upcase)
      ["levels: below #{cutoff.upcase}", "levels: at #{cutoff.upcase}", "levels: +1", "levels: +2 and above"]
    else
      LEVELS.map { |l| "levels: #{l}" }
    end
    ["episodes", "entries", "entries per episode (median)", "entries per minute (median)",
      "unique lemmas", "repeat share vs all earlier episodes", "re-explanations within cohort",
      "lemmas explained ≥3×", *levels, "key-term misses (≥#{MISS_MIN} uncovered)",
      "uncovered candidates (mean)", "definition drift", "gloss length (median words)",
      "key-term share (title or ≥#{PROMINENT_MIN}× in body)"]
  end

  def split_lines(name, split:, seed: 1)
    s = split_report(split: split)
    return ["#{name}: no transcripts"] if [s[:before], s[:after]].none? && s[:undated].zero?

    day = split.iso8601
    cohorts = [["before", s[:before]], ["after", s[:after]]]
    cohorts << ["before, last #{s[:before_last].episodes}", s[:before_last]] if s[:before_last]
    cohorts.select!(&:last)
    n = s[:before_last]&.episodes
    out = ["#{name} --split #{day}: before = dated before #{day}; after = dated #{day} or later" \
      "#{"; before, last #{n} = the #{n} episodes immediately preceding the split" if n}"]
    out << "  no episodes before #{day}" unless s[:before]
    out << "  no episodes on or after #{day}" unless s[:after]
    out << "  (#{s[:undated]} transcripts without a date in the name left out of every cohort)" if s[:undated].positive?
    return out if cohorts.empty?

    out << ""
    out.concat(split_table(cohorts))
    out << ""
    out.concat(split_note(s)) if s[:after]
    cohorts.each do |label, r|
      out << ""
      out << "sample, #{label} (seed #{seed}):"
      r.entry_list.sample(SAMPLE_SIZE, random: Random.new(seed)).each do |e|
        out << "    #{e[:lemma]} · #{e[:level]} · #{e[:gloss] || "(no gloss)"}"
      end
    end
    out
  end

  private def build_report(eps, indices)
    window = eps.values_at(*indices)
    in_window = indices.to_set

    repeat_entries, within_repeats = count_repeats(eps, in_window)
    misses, uncovered = count_key_term_misses(eps, in_window)
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
      repeated_with_definitions: repeated,
      within_repeats: within_repeats,
      mean_uncovered: uncovered.empty? ? 0.0 : uncovered.sum.to_f / uncovered.size,
      median_gloss_words: median(entries.filter_map { |e| e[:gloss]&.split&.size }),
      prominent_entries: entries.count { |e| e[:prominent] },
      entry_list: entries
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
    out << "  repeat share #{pct(r.repeat_entries, r.entries)}% (#{r.repeat_entries} entries re-explain a lemma from an earlier episode, key words aside)"
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
      keys = key_lemmas(parsed.vocabulary)
      body_prefixes = word_prefixes(parsed.body).tally
      title_prefixes = word_prefixes(parsed.title).to_set
      entries = []
      unlevelled = 0
      by_key.values.uniq(&:object_id).each do |e|
        level = e[:pos].to_s.split.first
        unless LEVELS.include?(level)
          unlevelled += 1
          next
        end
        lemma = e[:lemma].to_s.downcase.strip
        forms = by_key.select { |_, v| v.equal?(e) }.keys
        prefixes = forms.map { |k| k[0, COVER_PREFIX] }.to_set
        gloss = first_sentence(e[:definition])
        entries << {lemma: lemma, level: level, key: keys.include?(lemma),
                     definition: gloss&.downcase, gloss: gloss,
                     forms: forms.map { |k| word_list(k).join(" ") }.reject(&:empty?),
                     prominent: prefixes.intersect?(title_prefixes) || prefixes.sum { |p| body_prefixes.fetch(p, 0) } >= PROMINENT_MIN}
      end
      basename = File.basename(path, "_transcript.md")
      {basename: basename, body: parsed.body.to_s, covers: by_key.keys,
       entries: entries.uniq { |e| e[:lemma] }, unlevelled: unlevelled}
    end
  end

  def first_sentence(definition)
    text = definition.to_s.sub(/\..*/, "").strip
    text.empty? ? nil : text
  end

  # COVER_PREFIX-char prefixes of the letter words of text, downcased.
  def word_prefixes(text)
    word_list(text).map { |w| w[0, COVER_PREFIX] }
  end

  # The letter words of text, downcased, in order.
  def word_list(text)
    text.to_s.downcase.scan(/\p{L}+/)
  end

  # Lemmas listed under the `### Key words` sub-heading (the annotator's
  # KEY_GROUP_HEADING): pinned entries that bypass the ledger and the cap.
  def key_lemmas(vocabulary)
    return Set.new unless vocabulary

    languages, body = extract_vocab_languages(vocabulary)
    prefix = languages ? " (#{languages.join(", ")})\n" : ""
    vocab_groups(body).select { |title, _| title == KEY_GROUP_TITLE }
      .flat_map { |_, text| (parse_vocab_entries(prefix + text) || {}).values }
      .map { |e| e[:lemma].to_s.downcase.strip }.to_set
  end

  # Re-explanations of a lemma from an earlier episode, pinned key words
  # aside (they bypass the re-exposure cap; Q-157). Returns [repeats against
  # every earlier episode, repeats against earlier window episodes only].
  def count_repeats(eps, in_window)
    seen = Set.new
    seen_in_window = Set.new
    repeats = 0
    within = 0
    eps.each_with_index do |ep, i|
      lemmas = ep[:entries].map { |e| e[:lemma] }
      if in_window.include?(i)
        candidates = ep[:entries].reject { |e| e[:key] }
        repeats += candidates.count { |e| seen.include?(e[:lemma]) }
        within += candidates.count { |e| seen_in_window.include?(e[:lemma]) }
        seen_in_window.merge(lemmas)
      end
      seen.merge(lemmas)
    end
    [repeats, within]
  end

  # Window episodes with >= MISS_MIN key-term candidates left unexplained,
  # and the uncovered count per window episode; each episode is scored
  # against the episodes before it (O(N) overall).
  def count_key_term_misses(eps, in_window)
    running = RunningDf.new
    uncovered = []
    eps.each_with_index do |ep, i|
      if in_window.include?(i)
        candidates = KeyTerms.candidates(ep[:body], ledger: running)
        uncovered << self.class.uncovered(candidates, covers: ep[:covers]).size
      end
      running.add(ep[:body])
    end
    [uncovered.count { |n| n >= MISS_MIN }, uncovered]
  end

  # Per after-episode, the lemmas explained in an earlier episode at or above
  # the cutoff whose lemma or a recorded form occurs in its body as whole
  # words (case-insensitive; a multi-word lemma as the same word sequence):
  # the approximate count the pre-ledger selector would have re-explained.
  # nil without a CEFR cutoff (nothing to compare against).
  def would_have(eps, after)
    cut = LEVELS.index(@cutoff.to_s.upcase)
    return nil unless cut

    ledger = {}
    after_set = after.to_set
    eps.each_with_index.filter_map do |ep, i|
      row = if after_set.include?(i)
        words = word_list(ep[:body])
        text = " #{words.join(" ")} "
        set = words.to_set
        [ep[:basename], ledger.count { |_, forms| forms.any? { |f| f.include?(" ") ? text.include?(" #{f} ") : set.include?(f) } }]
      end
      ep[:entries].each do |e|
        (ledger[e[:lemma]] ||= Set.new).merge(e[:forms]) if LEVELS.index(e[:level]) >= cut
      end
      row
    end
  end

  def split_table(cohorts)
    rows = [["metric", *cohorts.map(&:first)]]
    self.class.split_labels(@cutoff).each_with_index do |label, n|
      rows << [label, *cohorts.map { |_, r| split_cells(r)[n] }]
    end
    widths = rows.transpose.map { |col| col.map(&:length).max }
    rows.map do |row|
      row.each_with_index.map { |cell, i| i.zero? ? cell.ljust(widths[i]) : cell.rjust(widths[i]) }.join("  ")
    end
  end

  # One cell per split_labels row, same order.
  def split_cells(r)
    l = r.levels
    levels = l.key?(:at) ? %i[below at plus1 plus2].map { |k| l[k] } : LEVELS.map { |k| l.fetch(k, 0) }
    [r.episodes.to_s, r.entries.to_s, r.median_per_episode ? format_number(r.median_per_episode) : "n/a",
      r.median_per_minute ? format("%.1f", r.median_per_minute) : "n/a", r.unique_lemmas.to_s,
      "#{pct(r.repeat_entries, r.entries)}% (#{r.repeat_entries})", r.within_repeats.to_s, r.lemmas_3plus.to_s,
      *levels.map { |v| "#{pct(v, r.entries)}%" }, "#{r.key_term_misses}/#{r.episodes}",
      format("%.1f", r.mean_uncovered), "#{r.drift} of #{r.repeated_with_definitions}",
      r.median_gloss_words ? format_number(r.median_gloss_words) : "n/a",
      "#{pct(r.prominent_entries, r.entries)}% (#{r.prominent_entries})"]
  end

  def split_note(s)
    out = ["note: the after cohort's low repeat share is partly by construction: the ledger leaves out",
      "  lemmas explained in earlier episodes, so a low figure there does not by itself show a better selection."]
    rows = s[:would_have]
    unless rows
      return out << "  would-have-re-explained count: cannot be derived from the transcripts (the show has no CEFR level cutoff)."
    end

    out << "  would have re-explained under the old rule (approximation: lemmas explained in an earlier episode"
    out << "  at #{@cutoff.upcase} or above, by exact lemma/form match in the body, whole words, case-insensitive):"
    out << "  #{rows.map { |b, n| "#{b} #{n}" }.join(", ")}"
    out << "  #{rows.count { |_, n| n.positive? }} of #{rows.size} after-episodes have at least one; median #{format_number(median(rows.map(&:last)))} per episode"
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
