# frozen_string_literal: true

require "date"
require_relative "base_validator"
require_relative "../yaml_loader"

module Validators
  # Content-progress invariant (M00-4, CLAUDE.md verification
  # discipline #4): the newest episode's CONTENT date vs the wall
  # clock, judged against the podcast's own cadence inferred from
  # history (median gap between distinct episode dates). A scheduled
  # producer whose published tail stops moving trips an OLD flag here
  # rather than failing silently.
  class FreshnessValidator < BaseValidator
    MIN_STALE_DAYS = 2      # never flag faster than this
    STALE_FACTOR = 2        # stale when age > factor × median gap
    RECENT_GAPS = 12        # infer cadence from this many recent gaps

    def initialize(config, today: Date.today)
      super(config)
      @today = today
    end

    private

    def check
      return unless File.exist?(@config.history_path.to_s)

      entries = YamlLoader.load(@config.history_path, default: [])
      dates = entries.filter_map { |e| parse_date(e["date"]) if e.is_a?(Hash) }.uniq.sort
      if dates.size < 2
        @passes << "Freshness: cannot infer cadence (#{dates.size} dated entries)"
        return
      end

      gaps = dates.each_cons(2).map { |a, b| (b - a).to_i }.last(RECENT_GAPS)
      cadence = median(gaps)
      threshold = [cadence * STALE_FACTOR, MIN_STALE_DAYS].max
      newest = dates.last
      age = (@today - newest).to_i

      if age > threshold
        @warnings << "Freshness: OLD — newest episode #{newest} is #{age} days old " \
          "(cadence ~#{cadence}d, threshold #{threshold}d)"
      else
        @passes << "Freshness: newest #{newest} (#{age}d old, cadence ~#{cadence}d)"
      end
    end

    def parse_date(value)
      value && Date.parse(value.to_s)
    rescue Date::Error
      nil
    end

    def median(values)
      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end
  end
end
