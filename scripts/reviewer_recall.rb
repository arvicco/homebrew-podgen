#!/usr/bin/env ruby
# frozen_string_literal: true

# Manual measurement, dispatched via `podgen test reviewer_recall` (live API).
# Not part of the Minitest suite under test/.
#
# Blocker recall of the script reviewer at low effort (Q-138): for each
# saved review bundle, one AI review at CLAUDE_EFFORT_REVIEWER=low, compared
# with the BLOCKERs the production (default-effort) review found on the same
# script. Measurement only: nothing in the pipeline changes.
#
# Usage: podgen test reviewer_recall [--rerun-default] BUNDLE.json...
#   --rerun-default  also re-run the default-effort review (else the bundle's
#                    default_issues, less the deterministic checks, are the
#                    baseline)
#
# A bundle is the input of one first-attempt review, as JSON:
#   {"name": "fulgur_news-2026-10-17", "date": "2026-10-17",
#    "script": {"title": "...", "segments": [{"name": "...", "text": "..."}],
#               "sources": [{"title": "...", "url": "..."}]},
#    "research_data": [{"topic": "...", "findings": [{"title": "...",
#                       "url": "...", "summary": "..."}]}],
#    "priority_urls": [],
#    "default_issues": [{"severity": "BLOCKER", "check": "...",
#                        "segment": "...", "message": "..."}]}
#
# Cost: one reviewer call per bundle per effort, opus line; the production
# review measures ~23k input and ~2.5k output tokens.

require "date"
require "json"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "agents/script_reviewer"

module ReviewerRecall
  EFFORT_ENV = "CLAUDE_EFFORT_REVIEWER"
  REQUIRED_KEYS = %i[date script research_data].freeze
  TOKENS_LINE = /Input: (\d+) tokens \| Output: (\d+) tokens/
  # BLOCKER checks of the reviewer's deterministic layer: the bundle's
  # default_issues hold them too, the low run (AI layer only) never does.
  DETERMINISTIC_CHECKS = %w[weekday title_missing priority_url].freeze

  Row = Struct.new(:name, :default_blockers, :low_blockers, :input_tokens, :output_tokens, keyword_init: true)

  # Collects the reviewer's log lines (its token counts among them).
  class TokenLog
    attr_reader :lines

    def initialize
      @lines = []
    end

    def log(message)
      @lines << message
    end

    def tokens
      @lines.filter_map { |l| l[TOKENS_LINE] && [$1.to_i, $2.to_i] }
        .reduce([0, 0]) { |(i, o), (di, d_o)| [i + di, o + d_o] }
    end
  end

  module_function

  def load_bundle(path)
    bundle = JSON.parse(File.read(path), symbolize_names: true)
    missing = REQUIRED_KEYS.reject { |k| bundle.key?(k) }
    raise ArgumentError, "#{path}: missing #{missing.join(", ")}" unless missing.empty?

    bundle[:name] ||= File.basename(path, ".json")
    bundle
  end

  def blockers(issues)
    Array(issues).count { |i| i[:severity].to_s == ScriptReviewer::BLOCKER }
  end

  def ai_issues(issues)
    Array(issues).reject { |i| DETERMINISTIC_CHECKS.include?(i[:check].to_s) }
  end

  # One AI review of the bundle's script at effort (nil = API default).
  # Returns [issues, [input_tokens, output_tokens]].
  def review(bundle, effort:, client: nil)
    previous = ENV[EFFORT_ENV]
    effort ? ENV[EFFORT_ENV] = effort : ENV.delete(EFFORT_ENV)
    log = TokenLog.new
    reviewer = ScriptReviewer.new(date: Date.parse(bundle[:date]), research_data: bundle[:research_data],
      priority_urls: bundle[:priority_urls] || [], logger: log)
    reviewer.instance_variable_set(:@client, client) if client
    issues = reviewer.send(:run_ai_review, bundle[:script])
    [issues, log.tokens]
  ensure
    previous ? ENV[EFFORT_ENV] = previous : ENV.delete(EFFORT_ENV)
  end

  def measure(paths, rerun_default: false, client: nil)
    paths.map do |path|
      bundle = load_bundle(path)
      default_issues = rerun_default ? review(bundle, effort: nil, client: client).first : ai_issues(bundle[:default_issues])
      low_issues, (input, output) = review(bundle, effort: "low", client: client)
      Row.new(name: bundle[:name], default_blockers: blockers(default_issues), low_blockers: blockers(low_issues),
        input_tokens: input, output_tokens: output)
    end
  end

  # Recall is episode-level: a BLOCKER is what triggers the regenerate, so
  # a script counts as caught when low finds at least one BLOCKER on a
  # script where the default review found one.
  def table(rows)
    lines = ["bundle | default BLOCKERs | low BLOCKERs | low tokens in/out"]
    rows.each do |r|
      lines << "#{r.name} | #{r.default_blockers} | #{r.low_blockers} | #{r.input_tokens}/#{r.output_tokens}"
    end
    flagged = rows.select { |r| r.default_blockers.positive? }
    caught = flagged.count { |r| r.low_blockers.positive? }
    lines << "recall at low: #{caught}/#{flagged.size} scripts with a default BLOCKER also get one at low " \
             "(BLOCKERs #{flagged.sum(&:low_blockers)} low vs #{flagged.sum(&:default_blockers)} default)"
    lines
  end

  def main(argv)
    rerun_default = !argv.delete("--rerun-default").nil?
    if argv.empty?
      warn "Usage: podgen test reviewer_recall [--rerun-default] BUNDLE.json..."
      return 2
    end
    puts table(measure(argv, rerun_default: rerun_default))
    0
  end
end

exit(ReviewerRecall.main(ARGV.dup)) if $PROGRAM_NAME == __FILE__
