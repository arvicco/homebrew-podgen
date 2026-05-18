# frozen_string_literal: true

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
# `_concat*` intermediates are excluded (scratch files produced during
# audio assembly). Used by `scrap`, `move`, and any other command that
# needs to act on every artifact belonging to one episode.
module EpisodeArtifacts
  PATTERNS = %w[.* _* -*].freeze
  EXCLUDE_RE = /_concat/

  module_function

  # Returns sorted, unique absolute paths to all artifact files for the
  # given basename in episodes_dir. Returns [] when no files match.
  def for_basename(episodes_dir, basename)
    PATTERNS.flat_map { |pat|
      Dir.glob(File.join(episodes_dir, "#{basename}#{pat}"))
    }.uniq.reject { |f| File.basename(f).match?(EXCLUDE_RE) }.sort
  end
end
