# frozen_string_literal: true

require_relative "episode_naming"

# Enumerates the on-disk artifacts that make up a single episode, given its
# basename (e.g. "bajke-2026-05-16d") and the episodes directory.
#
# The three glob patterns capture every artifact category the pipelines
# produce while keeping each base strictly scoped — `pod-2026-05-16` matches
# its own files but NOT `pod-2026-05-16a.*` (sibling suffix) or
# `pod-2026-05-16a_script.md`:
#
#   <base>.*    →  .mp3, .mp4, .srt
#   <base>_*    →  _script.{md,html,json}, _transcript.{md,html},
#                  _timestamps.json, _cover*.{jpg,png,jpeg}
#   <base>-*    →  per-language variants (-jp.mp3, -jp_script.md, …)
#
# With `languages:` (the podcast's configured codes) a `<base>-*` file is a
# variant only when its tail is a configured code (EpisodeNaming rule), so
# `pod-D-ai.mp3` is its own episode, not a variant of `pod-D` (P4-9, Q-44).
# Without it every `<base>-*` file counts (legacy).
#
# `_concat*` intermediates are excluded (scratch files produced during
# audio assembly). Used by `scrap`, `move`, and any other command that
# needs to act on every artifact belonging to one episode.
module EpisodeArtifacts
  PATTERNS = %w[.* _* -*].freeze
  EXCLUDE_RE = /_concat/

  module_function

  # Returns sorted, unique absolute paths to all artifact files for the
  # given basename in episodes_dir. Returns [] when no files match.
  def for_basename(episodes_dir, basename, languages: nil)
    PATTERNS.flat_map { |pat|
      Dir.glob(File.join(episodes_dir, "#{basename}#{pat}"))
    }.uniq.reject { |f| File.basename(f).match?(EXCLUDE_RE) }
      .select { |f| variant_of?(File.basename(f), basename, languages) }.sort
  end

  # Non-dash artifacts always belong to the base; a dash artifact must be
  # `<base>-<code>` followed by `.` or `_` with <code> configured.
  def variant_of?(filename, basename, languages)
    return true if languages.nil? || languages.empty?

    tail = filename.delete_prefix(basename)
    return true unless tail.start_with?("-")

    code = tail[/\A-([a-z]{2})[._]/, 1]
    !code.nil? && EpisodeNaming.language_suffix("#{basename}-#{code}", languages: languages) == code
  end
end
