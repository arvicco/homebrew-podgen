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
    # Q-155: without cadence_days, no episode for more than this many days is
    # a dormant show (a pass; `podgen status` reads DORMANT), never OLD.
    DORMANT_STALE_DAYS = 60

    # Set by #validate once history has dated entries (used by `podgen status`).
    # note is DORMANT_NOTE for a dormant show, nil otherwise.
    attr_reader :newest, :age_days, :note

    # True once #validate found no cadence_days and the newest episode older
    # than DORMANT_STALE_DAYS.
    def dormant? = @dormant == true

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
      @bad_dates = []
      dates = entries.filter_map { |e| parse_date(e["date"]) if e.is_a?(Hash) }.uniq.sort
      unless @bad_dates.empty?
        @warnings << "Freshness: history date(s) not YYYY-MM-DD, ignored: #{@bad_dates.uniq.first(3).join(", ")}"
      end
      @newest = dates.last
      @age_days = (@today - @newest).to_i if @newest
      configured = @config.cadence_days
      @dormant = !configured && @age_days.to_i > DORMANT_STALE_DAYS
      if @dormant && dates.size >= 2
        @note = DORMANT_NOTE
        @passes << "Freshness: #{DORMANT_NOTE}, newest #{@newest} is #{@age_days}d old " \
          "(no episode for over #{DORMANT_STALE_DAYS} days and no cadence_days)"
        return
      elsif configured && @newest
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

    # Strict YYYY-MM-DD (Date.parse also read "2026/10/5" and the like);
    # a bad value is collected for the one-line warning in #check.
    def parse_date(value)
      return nil unless value
      return value.to_date if value.respond_to?(:to_date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      @bad_dates << value.to_s
      nil
    end

    def median(values)
      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end
  end
end
