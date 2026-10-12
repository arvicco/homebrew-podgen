# frozen_string_literal: true

require "date"
require_relative "base_validator"
require_relative "../yaml_loader"

module Validators
  # Content-progress invariant (P00-4, CLAUDE.md verification
  # discipline #4): the newest episode's CONTENT date vs the wall
  # clock, judged against the podcast's own cadence inferred from
  # history (median gap between distinct episode dates). A scheduled
  # producer whose published tail stops moving trips an OLD flag here
  # rather than failing silently.
  class FreshnessValidator < BaseValidator
    MIN_STALE_DAYS = 2      # never flag faster than this
    STALE_FACTOR = 2        # stale when age > factor × median gap
    RECENT_GAPS = 12        # infer cadence from this many recent gaps
    # P3-4: with no cadence (fewer than two distinct dates, no cadence_days)
    # there is no threshold, so a newest episode older than this many days is
    # noted as dormant - still a pass, but visible on `podgen status`.
    DORMANT_DAYS = 30
    DORMANT_NOTE = "dormant — no cadence"

    # Set by #validate once history has dated entries (used by `podgen status`).
    # note is DORMANT_NOTE for a dormant show, nil otherwise.
    attr_reader :newest, :age_days, :note

    def initialize(config, today: Date.today)
      super(config)
      @today = today
    end

    private

    def check
      unless @config.freshness_enabled?
        @passes << "Freshness: check disabled by guidelines (freshness: off)"
        return
      end
      return unless File.exist?(@config.history_path.to_s)

      entries = YamlLoader.load(@config.history_path, default: [])
      dates = entries.filter_map { |e| parse_date(e["date"]) if e.is_a?(Hash) }.uniq.sort
      @newest = dates.last
      @age_days = (@today - @newest).to_i if @newest
      configured = @config.cadence_days
      if configured && @newest
        cadence = configured
        cadence_label = "#{cadence}d configured"
      elsif dates.size < 2
        message = "Freshness: cannot infer cadence (#{dates.size} dated entries)"
        if @age_days && @age_days > DORMANT_DAYS
          @note = DORMANT_NOTE
          message += "; #{DORMANT_NOTE}, newest #{@newest} is #{@age_days}d old"
        end
        @passes << message
        return
      else
        gaps = dates.each_cons(2).map { |a, b| (b - a).to_i }.last(RECENT_GAPS)
        cadence = median(gaps)
        cadence_label = "~#{cadence}d"
      end
      threshold = [cadence * STALE_FACTOR, MIN_STALE_DAYS].max
      newest = @newest
      age = @age_days

      if age.negative? && -age <= @config.freshness_lead_days
        @passes << "Freshness: newest #{newest} (scheduled +#{-age}d)"
      elsif age.negative?
        @warnings << "Freshness: newest episode #{newest} is dated in the future (#{-age} days ahead)"
      elsif age > threshold
        @warnings << "Freshness: OLD — newest episode #{newest} is #{age} days old " \
          "(cadence #{cadence_label}, threshold #{threshold}d)"
      else
        @passes << "Freshness: newest #{newest} (#{age}d old, cadence #{cadence_label})"
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
