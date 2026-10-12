# frozen_string_literal: true

require "date"

# The episode basename scheme (FROZEN DOMAIN, CLAUDE.md rule 4) in one
# place (P4-9, Q-44):
#
#   <podcast>-<YYYY-MM-DD><slot>[-<lang>]
#
# slot: "" for the first episode of a day, then a..z; a 28th same-day
# history entry falls back to its numeric index. lang: a two-letter tail
# naming a non-primary language variant. With `languages:` (the podcast's
# configured codes, primary first) only a CONFIGURED code counts as a
# language tail, so a title-like "-ai" belongs to the primary language
# (P1-15, Q-06); with no configuration (nil or []) any two-letter tail
# counts (legacy rule). The primary language is languages.first ("en"
# when nothing is configured).
module EpisodeNaming
  SUFFIXES = ([""] + ("a".."z").to_a).freeze
  DATE_RE = /(\d{4}-\d{2}-\d{2})/
  # Date followed by an optional single day letter (filename or path).
  DAY_LETTER_RE = /(\d{4}-\d{2}-\d{2})([a-z])?/
  # A bare episode identifier: "2026-03-31" or "2026-03-31b".
  EPISODE_ID_RE = /\A(\d{4}-\d{2}-\d{2})([a-z])?\z/
  BASENAME_RE = /\A(.+?)-(\d{4}-\d{2}-\d{2})([a-z])?/
  LANG_TAIL_RE = /-([a-z]{2})\z/
  # Day slot of an explicit history basename (letter or numeric fallback).
  HISTORY_SLOT_RE = /\d{4}-\d{2}-\d{2}([a-z]|\d+)?(?:-[a-z]{2})?\z/
  DEFAULT_PRIMARY = "en"

  module_function

  # Day slot for the 0-based position among same-day entries.
  def suffix_for(index)
    SUFFIXES[index] || index.to_s
  end

  # 0-based same-day position of a slot letter ("" → 0, "a" → 1), or nil.
  def index_for(letter)
    SUFFIXES.index(letter.to_s)
  end

  # basename_for("pod", "2026-01-15", 1, language: "es") → "pod-2026-01-15a-es"
  # `slot` is a 0-based same-day index or the slot letter itself.
  def basename_for(podcast, date, slot = 0, language: nil)
    suffix = slot.is_a?(Integer) ? suffix_for(slot) : slot.to_s
    base = "#{podcast}-#{date}#{suffix}"
    language ? with_language(base, language) : base
  end

  # Non-primary variant of a primary basename ("pod-D", "es" → "pod-D-es").
  def with_language(basename, code)
    "#{basename}-#{code}"
  end

  def primary_language(languages = nil)
    languages&.first || DEFAULT_PRIMARY
  end

  # The raw two-letter tail, configured or not ("pod-D-ai" → "ai").
  def language_tail(basename)
    basename[LANG_TAIL_RE, 1]
  end

  # The tail when it counts as a language under the rule above, else nil.
  def language_suffix(basename, languages: nil)
    tail = language_tail(basename)
    return nil unless tail
    return tail if languages.nil? || languages.empty?

    languages.include?(tail) ? tail : nil
  end

  # The language an episode basename belongs to.
  def language_of(basename, languages: nil)
    language_suffix(basename, languages: languages) || primary_language(languages)
  end

  # Whether a basename is listed under `code`: the primary language owns
  # every basename without a language tail; any other code owns the
  # basenames ending in "-<code>".
  def matches_language?(basename, code, languages: nil)
    if code == primary_language(languages)
      language_suffix(basename, languages: languages).nil?
    else
      basename.end_with?("-#{code}")
    end
  end

  # Primary-language basename of a variant ("pod-D-es" → "pod-D").
  def primary_basename(basename, languages: nil)
    suffix = language_suffix(basename, languages: languages)
    suffix ? basename.delete_suffix("-#{suffix}") : basename
  end

  # "pod-2026-01-15a-es" → {podcast: "pod", date: "2026-01-15", letter: "a", language: "es"}
  # nil when the name carries no <podcast>-<date>.
  def parse(basename, languages: nil)
    m = basename.match(BASENAME_RE)
    return nil unless m

    {podcast: m[1], date: m[2], letter: m[3].to_s, language: language_of(basename, languages: languages)}
  end

  # Date of an episode filename or path, or nil when none / not a real date.
  def parse_date(filename)
    match = File.basename(filename).match(DATE_RE)
    return nil unless match

    Date.parse(match[1])
  rescue Date::Error
    nil
  end

  # "2026-03-31b" → ["2026-03-31", "b"]; nil when not an episode identifier.
  def parse_episode_id(id)
    m = id.to_s.match(EPISODE_ID_RE)
    m && [m[1], m[2].to_s]
  end

  # Primary episode basenames of `podcast` (no tail of any kind).
  def primary_basename_re(podcast)
    /\A#{Regexp.escape(podcast)}-(\d{4}-\d{2}-\d{2})([a-z])?\z/
  end

  # Any well-formed episode mp3 filename of `podcast`.
  def filename_re(podcast)
    /^#{Regexp.escape(podcast)}-\d{4}-\d{2}-\d{2}[a-z]?(-[a-z]{2})?\.mp3$/
  end

  # Yields [entry, basename] for each dated history entry, in history order
  # grouped by date: an explicit "basename" wins, otherwise the slot is the
  # entry's position among same-day entries.
  def each_history_basename(entries, podcast_name)
    return enum_for(:each_history_basename, entries, podcast_name) unless block_given?

    by_date = {}
    entries.each do |entry|
      date = entry["date"]
      next unless date
      (by_date[date] ||= []) << entry
    end

    by_date.each do |date, date_entries|
      date_entries.each_with_index do |entry, idx|
        yield entry, entry["basename"] || basename_for(podcast_name, date, idx)
      end
    end
  end

  # Slot of a history entry at same-day position `index`, under the same
  # mapping as each_history_basename (explicit basename wins).
  def history_slot(entry, index)
    m = entry["basename"]&.match(HISTORY_SLOT_RE)
    m ? m[1].to_s : suffix_for(index)
  end

  # Index into `entries` of the entry whose mapped name carries `date` and
  # day slot `slot` ("" / "a".."z"), or nil. When several entries map to
  # the slot, the LAST wins — the one HistoryMaps (and so the feed) shows
  # (P5-2a, Q-54).
  def history_entry_index(entries, date, slot)
    pos = -1
    found = nil
    entries.each_with_index do |entry, global|
      next unless entry["date"].to_s == date.to_s
      pos += 1
      found = global if history_slot(entry, pos) == slot.to_s
    end
    found
  end
end
