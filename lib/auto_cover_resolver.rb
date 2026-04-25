# frozen_string_literal: true

require "fileutils"
require_relative "image_searcher"
require_relative "image_ranker"

# Orchestrator for the --image auto flow:
#   1. Search candidates via ImageSearcher (size-filtered)
#   2. Rank candidates via ImageRanker (Claude vision)
#   3. Persist top 3 to <episodes_dir>/<basename>_cover{1,2,3}.<ext>
#   4. If top is non-vetoed and score >= threshold → declare winner
#   5. Cleanup tmp files
#
# Returns: { winner_path:, top_paths:, candidates: }
#   winner_path  — path of the cover to use, or nil (caller falls back)
#   top_paths    — paths of the persisted top 3 (always preserved for inspection)
#   candidates   — full ranked array as returned by ImageRanker
class AutoCoverResolver
  DEFAULTS = {
    auto_cover_min_bytes: 20_000,
    auto_cover_min_score: 14,
    auto_cover_candidates: 5,
    auto_cover_model: "claude-sonnet-4-6"
  }.freeze

  def initialize(config: nil, searcher: nil, ranker: nil, logger: nil)
    @config = DEFAULTS.merge(config || {})
    @logger = logger
    @searcher = searcher
    @ranker = ranker
  end

  def try(title:, description:, episodes_dir:, basename:)
    candidates = searcher.search(
      title,
      count: @config[:auto_cover_candidates],
      min_bytes: @config[:auto_cover_min_bytes]
    )
    return empty_result if candidates.empty?

    ranked = ranker.rank(candidates, title: title, description: description)
    if ranked.empty?
      cleanup(candidates)
      return empty_result
    end

    top_paths = persist_top(ranked.first(3), episodes_dir, basename)
    cleanup(candidates)

    top = ranked.first
    winner = top && !top[:vetoed] && top[:score] >= @config[:auto_cover_min_score]
    { winner_path: winner ? top_paths.first : nil, top_paths: top_paths, candidates: ranked }
  end

  private

  def searcher
    @searcher ||= ImageSearcher.new(logger: @logger)
  end

  def ranker
    @ranker ||= ImageRanker.new(model: @config[:auto_cover_model], logger: @logger)
  end

  def persist_top(top, episodes_dir, basename)
    FileUtils.mkdir_p(episodes_dir)
    top.each_with_index.map do |c, i|
      dest = File.join(episodes_dir, "#{basename}_cover#{i + 1}#{c[:ext]}")
      FileUtils.cp(c[:path], dest)
      dest
    end
  end

  def cleanup(candidates)
    candidates.each { |c| File.delete(c[:path]) if File.exist?(c[:path]) }
  end

  def empty_result
    { winner_path: nil, top_paths: [], candidates: [] }
  end
end
