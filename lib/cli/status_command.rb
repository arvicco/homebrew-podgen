# frozen_string_literal: true

require "optparse"
require "json"
require "date"

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "validators", "freshness_validator")
require_relative File.join(root, "lib", "cli", "schedule_command")
require_relative File.join(root, "lib", "episode_scanner")
require_relative File.join(root, "lib", "upload_tracker")

module PodgenCLI
  # Read-only content-progress surface (Q-27, P1-14): one verdict per podcast.
  #   OLD  - newest episode older than the cadence threshold (FreshnessValidator)
  #   WARN - last run log ended in ERROR / has a warning, or the same warning
  #          repeated across the last N run logs (silent-for-weeks failures),
  #          or the same publish warning in the last PUBLISH_REPEAT scheduled
  #          publishes (shared launchd stderr), or Twitter announcements
  #          stalled behind the newest episode (P3-2)
  #   OK   - otherwise; a show with no cadence whose newest episode is old is
  #          noted "dormant — no cadence" (P3-4)
  # Exit 0 when every podcast is OK, 1 otherwise, so a scheduled run can alert.
  class StatusCommand
    VERDICT_RANK = {"OK" => 0, "WARN" => 1, "OLD" => 2}.freeze
    DEFAULT_RUNS = 3
    LINE_MAX = 100
    WARNING_RE = /Warning:|WARNING/
    # ScriptReviewer findings are logged indented with a bracketed category
    # ("  WARNING: [COVERAGE] ...") - editorial notes, not pipeline warnings.
    REVIEWER_FINDING_RE = /\A(?:\[[^\]]*\] )?\s+WARNING: \[/
    ERROR_RE = /\A(?:\[[^\]]*\]\s*)?ERROR\b/
    STAMP_RE = /\A\[[^\]]*\]\s*/
    STATUS_LABEL = "#{ScheduleCommand::LABEL_PREFIX}.status".freeze
    INSTALL_HINT = "bin/podgen schedule --status-check --time 07:00"
    # Shared stderr of the per-podcast launchd jobs (scripts/run.sh). A dated
    # rclone line ("2026/09/20 16:52:04 NOTICE: ...") opens a publish entry;
    # undated "Warning:" lines after it belong to that publish. Generate
    # output ("[2026-10-08 19:19:21] ERROR ...", "Generate failed ...") closes
    # the entry and is ignored here - the run logs already cover it.
    PUBLISH_LOG = File.join("logs", "launchd_stderr.log")
    PUBLISH_REPEAT = 3
    PUBLISH_ENTRY_RE = %r{\A(\d{4})/(\d{2})/(\d{2}) \d{2}:\d{2}:\d{2} }
    PUBLISH_WARNING_RE = /\AWarning:/
    GENERATE_LINE_RE = /\A(?:\[\d{4}-\d{2}-\d{2}[^\]]*\]|Generate failed)/
    TWITTER_RE = /Twitter/
    DEFAULT_TWEET_SINCE = 7

    def initialize(args, options, plist_dir: ScheduleCommand::LAUNCH_AGENTS_DIR, today: Date.today, publish_log: nil)
      @options = options
      @plist_dir = plist_dir
      @today = today
      @publish_log = publish_log || File.join(PodcastConfig.root, PUBLISH_LOG)
      @json = false
      @hint = false
      @runs = DEFAULT_RUNS
      OptionParser.new do |opts|
        opts.on("--json", "Machine-readable output") { @json = true }
        opts.on("--runs N", Integer, "Run logs scanned for repeated warnings (default: #{DEFAULT_RUNS})") { |n| @runs = n }
        opts.on("--install-hint", "Print the owner command that schedules the daily check") { @hint = true }
      end.parse!(args)
      @podcast_name = args.shift
      raise OptionParser::ParseError, "unexpected argument(s): #{args.join(" ")}" unless args.empty?
    end

    def run
      return print_hint if @hint

      available = PodcastConfig.available
      names = @podcast_name ? [@podcast_name] : available
      if @podcast_name && !available.include?(@podcast_name)
        $stderr.puts "Unknown podcast: #{@podcast_name}"
        return 2
      end

      rows = order(names).map { |name| assess(name) }
      if @json
        puts JSON.pretty_generate(rows)
      else
        print_table(rows)
      end
      (rows.all? { |r| r[:verdict] == "OK" }) ? 0 : 1
    end

    private

    def print_hint
      puts "#{INSTALL_HINT}   # owner-only: installs the daily launchd status check"
      0
    end

    def print_table(rows)
      if rows.empty?
        puts "No podcasts found."
        return
      end
      width = rows.map { |r| r[:podcast].length }.max
      rows.each do |r|
        detail = r[:reasons].join("; ")
        puts format("%-#{width}s  %-4s  %s", r[:podcast], r[:verdict], detail)
      end
      puts "\nDaily check not scheduled. Owner command: #{INSTALL_HINT}" unless status_check_scheduled?
    end

    def status_check_scheduled?
      File.exist?(File.join(@plist_dir, "#{STATUS_LABEL}.plist"))
    end

    def scheduled?(name)
      File.exist?(File.join(@plist_dir, "#{ScheduleCommand::LABEL_PREFIX}.#{name}.plist"))
    end

    def order(names)
      names.partition { |n| scheduled?(n) }.flatten
    end

    def assess(name)
      verdict = "OK"
      reasons = []
      newest = age = note = nil
      escalate = ->(v, reason) {
        verdict = v if VERDICT_RANK[v] > VERDICT_RANK[verdict]
        reasons << reason
      }

      config = PodcastConfig.new(name)
      if config.freshness_enabled?
        newest, age, note = freshness(config, escalate)
      else
        reasons << "(freshness off)"
      end
      log_findings(config).each { |reason| escalate.call("WARN", reason) }
      publish_findings(config).each { |reason| escalate.call("WARN", reason) }
      announcements = announcement_progress(config, escalate)
      if verdict == "OK" && newest
        reasons << "newest #{newest} (#{age.negative? ? "scheduled +#{-age}d" : "#{age}d old"}#{"; #{note}" if note})"
      end

      {podcast: name, verdict: verdict, newest: newest&.to_s, age_days: age, reasons: reasons,
       announcements: announcements}
    rescue => e
      {podcast: name, verdict: "WARN", newest: nil, age_days: nil,
       reasons: ["status check failed: #{e.class}: #{e.message}"[0, LINE_MAX]], announcements: nil}
    end

    # Delegates the staleness rule to Validators::FreshnessValidator.
    def freshness(config, escalate)
      unless File.exist?(config.history_path.to_s)
        escalate.call("WARN", "no history (no episodes yet)")
        return [nil, nil, nil]
      end

      validator = Validators::FreshnessValidator.new(config, today: @today)
      result = validator.validate
      result[:warnings].each do |w|
        escalate.call(w.include?("OLD") ? "OLD" : "WARN", w.delete_prefix("Freshness: "))
      end
      escalate.call("WARN", "no dated episodes in history") if validator.newest.nil?
      [validator.newest, validator.age_days, validator.note]
    end

    # --- run-log findings ---

    def log_findings(config)
      logs = Dir.glob(File.join(config.log_dir, "*.log")).sort_by { |f| [File.mtime(f), f] }
      return [] if logs.empty?

      recent = logs.last(@runs).map { |f| File.read(f).scrub.lines.map(&:chomp) }
      repeated = repeated_warnings(recent)
      findings = latest_run_finding(recent.last, File.basename(logs.last), repeated)
      repeated.each_value { |raw| findings << "repeated in last #{@runs} runs: #{clip(raw)}" }
      findings
    end

    def latest_run_finding(lines, file, repeated)
      last = lines.reject { |l| l.strip.empty? }.last
      return ["#{file} ends with #{clip(last)}"] if last&.match?(ERROR_RE)

      first = lines.find { |l| warning?(l) && !repeated.key?(normalize(l)) }
      first ? ["#{file}: #{clip(first)}"] : []
    end

    # normalized warning => first raw line, for warnings present in every one
    # of the last @runs logs (needs a full window of runs).
    def repeated_warnings(runs)
      return {} if runs.size < @runs || @runs < 2

      per_run = runs.map { |lines| lines.select { |l| warning?(l) }.to_h { |l| [normalize(l), l] } }
      shared = per_run.map(&:keys).reduce(:&)
      shared.to_h { |key| [key, per_run.last[key]] }
    end

    # --- publish findings (shared launchd stderr, P3-2) ---

    # A warning in the latest publish entry that also appears in each of the
    # PUBLISH_REPEAT (or more) consecutive entries before it. The stderr names
    # no podcast: Twitter warnings go to podcasts with a ## Twitter section,
    # other warnings to podcasts with an installed launchd scheduler.
    def publish_findings(config)
      entries = publish_entries
      return [] if entries.empty?

      entries.last[:warnings].filter_map do |key, raw|
        next unless publish_warning_for?(config, raw)
        streak = entries.reverse.take_while { |e| e[:warnings].key?(key) }
        next if streak.size < PUBLISH_REPEAT

        "publish warning in last #{streak.size} publishes (since #{streak.last[:date]}): #{clip_middle(raw)}"
      end
    end

    def publish_warning_for?(config, raw)
      raw.match?(TWITTER_RE) ? !config.twitter_config.nil? : scheduled?(config.name)
    end

    def publish_entries
      @publish_entries ||= parse_publish_log
    end

    # [{date: "YYYY-MM-DD", warnings: {normalized => raw}}], oldest first.
    # Contiguous dated lines of the same day are one publish (rclone may
    # print several); clean publishes on adjacent lines stay separate.
    def parse_publish_log
      return [] unless File.exist?(@publish_log)

      entries = []
      current = nil
      previous_dated = false
      File.foreach(@publish_log) do |raw|
        line = raw.scrub.chomp
        if (m = line.match(PUBLISH_ENTRY_RE))
          date = "#{m[1]}-#{m[2]}-#{m[3]}"
          unless previous_dated && current&.dig(:date) == date
            current = {date: date, warnings: {}}
            entries << current
          end
          previous_dated = true
          next
        end
        previous_dated = false
        if line.match?(GENERATE_LINE_RE)
          current = nil
        elsif current && line.match?(PUBLISH_WARNING_RE)
          current[:warnings][normalize(line)] ||= line
        end
      end
      entries
    end

    # --- announcement progress (Twitter, P3-2) ---

    # Compares the newest episode in the announced languages with the newest
    # tweeted episode (uploads.yml twitter/posts). Stalled when the gap exceeds
    # the Twitter `since` window; never tweeted only counts once an episode is
    # older than that window (a brand-new show is not stalled).
    def announcement_progress(config, escalate)
      tc = config.twitter_config
      return nil unless tc

      since = tc[:since] || DEFAULT_TWEET_SINCE
      dates = announced_episode_dates(config, tc[:languages])
      last = tweeted_dates(config).max
      newest = dates.max
      stalled = if newest.nil?
        false
      elsif last
        (newest - last).to_i > since
      else
        (@today - dates.min).to_i > since
      end
      if stalled
        escalate.call("WARN", last ? "announcements stalled since #{last} (newest episode #{newest})" :
          "announcements never posted (newest episode #{newest})")
      end
      {last_tweeted: last&.to_s, newest_episode: newest&.to_s, stalled: stalled}
    end

    # Same language filter as R2Publisher#scan_eligible_episodes.
    def announced_episode_dates(config, languages)
      allowed = if languages == :all
        nil
      else
        Array(languages).empty? ? [config.primary_language] : languages
      end
      EpisodeScanner.scan(config.episodes_dir).filter_map do |ep|
        next if allowed && !allowed.include?(config.language_for_episode(ep[:base_name]))
        EpisodeFiltering.parse_date(ep[:base_name])
      end
    end

    # Only reads an existing tracker: UploadTracker#load would otherwise
    # migrate a legacy lingq_uploads.yml, and status never writes.
    def tweeted_dates(config)
      path = File.join(File.dirname(config.episodes_dir), "uploads.yml") # UploadTracker.for_config
      return [] unless File.exist?(path)

      UploadTracker.new(path).entries_for(:twitter, "posts").keys.filter_map { |b| EpisodeFiltering.parse_date(b) }
    end

    def clip_middle(line)
      text = line.strip
      return text if text.length <= LINE_MAX

      half = (LINE_MAX - 3) / 2
      "#{text[0, half]}...#{text[-(LINE_MAX - 3 - half)..]}"
    end

    def warning?(line)
      line.match?(WARNING_RE) && !line.match?(REVIEWER_FINDING_RE)
    end

    def normalize(line)
      line.sub(STAMP_RE, "").gsub(/\d+/, "#").strip
    end

    def clip(line)
      text = line.sub(STAMP_RE, "").strip
      (text.length > LINE_MAX) ? "#{text[0, LINE_MAX - 3]}..." : text
    end
  end
end
