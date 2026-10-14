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
require_relative File.join(root, "lib", "run_outcome")
require_relative File.join(root, "lib", "served_feed")

module PodgenCLI
  # Read-only content-progress surface (Q-27, P1-14): one verdict per podcast.
  #   OLD  - newest episode older than the cadence threshold (FreshnessValidator)
  #   WARN - last run log's RUN-OUTCOME line reports warnings/errors (P7-0),
  #          or it ended in ERROR / has a warning, or the same warning
  #          repeated across the last N run logs (silent-for-weeks failures),
  #          or the same publish warning in the last PUBLISH_REPEAT scheduled
  #          publishes (shared launchd stderr), or Twitter announcements
  #          stalled behind the newest episode (P3-2), or YouTube/LingQ
  #          uploads stalled the same way, or the upload batch's stderr
  #          names a not-authorized / quota condition (P7-1), or the served
  #          base_url/feed.xml lags the newest local episode or cannot be
  #          fetched (P7-2; the one network read, skipped with --offline)
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
    # run.sh now brackets each publish with dated markers ("... podgen publish
    # <pod> begin" / "... end exit=N"): a marked entry is named and owns every
    # "Warning:" line up to its end marker; the legacy rule covers older lines.
    PUBLISH_LOG = File.join("logs", "launchd_stderr.log")
    PUBLISH_REPEAT = 3
    PUBLISH_ENTRY_RE = %r{\A(\d{4})/(\d{2})/(\d{2}) \d{2}:\d{2}:\d{2} }
    PUBLISH_MARKER_RE = %r{\A(\d{4})/(\d{2})/(\d{2}) \d{2}:\d{2}:\d{2} podgen publish (\S+) (begin|end)\b}
    PUBLISH_WARNING_RE = /\AWarning:/
    GENERATE_LINE_RE = /\A(?:\[\d{4}-\d{2}-\d{2}[^\]]*\]|Generate failed)/
    TWITTER_RE = /Twitter/
    DEFAULT_TWEET_SINCE = 7
    SERVED_FEED_SLACK = 1 # days the served feed may trail the newest local episode
    # Upload progress (P7-1): per configured platform, the newest tracked
    # upload vs the newest episode, stalled past UPLOAD_SINCE days. The upload
    # batch's shared stderr (launchd, logs/uploads_stderr.log) is scanned only
    # while written within that window; it names conditions, never bodies.
    UPLOAD_SINCE = 7
    UPLOAD_LOG = File.join("logs", "uploads_stderr.log")
    UPLOAD_LOG_TAIL = 200
    UPLOAD_CONDITIONS = {
      /not authorized/i => "YouTube not authorized",
      /uploadLimitExceeded|quotaExceeded/ => "YouTube upload quota exceeded"
    }.freeze

    def initialize(args, options, plist_dir: ScheduleCommand::LAUNCH_AGENTS_DIR, today: Date.today, publish_log: nil,
      uploads_log: nil, served_feed: nil)
      @options = options
      @plist_dir = plist_dir
      @today = today
      @publish_log = publish_log || File.join(PodcastConfig.root, PUBLISH_LOG)
      @uploads_log = uploads_log || File.join(PodcastConfig.root, UPLOAD_LOG)
      @served_feed = served_feed || ServedFeed.new
      @offline = false
      @json = false
      @hint = false
      @runs = DEFAULT_RUNS
      OptionParser.new do |opts|
        opts.on("--json", "Machine-readable output") { @json = true }
        opts.on("--runs N", Integer, "Run logs scanned for repeated warnings (default: #{DEFAULT_RUNS})") { |n| @runs = n }
        opts.on("--offline", "Skip the served-feed read-back (the only network call)") { @offline = true }
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
      uploads = upload_progress(config, escalate)
      served_feed_findings(config).each { |reason| escalate.call("WARN", reason) }
      if verdict == "OK" && newest
        reasons << "newest #{newest} (#{age.negative? ? "scheduled +#{-age}d" : "#{age}d old"}#{"; #{note}" if note})"
      end

      {podcast: name, verdict: verdict, newest: newest&.to_s, age_days: age, reasons: reasons,
       announcements: announcements, uploads: uploads}
    rescue => e
      {podcast: name, verdict: "WARN", newest: nil, age_days: nil,
       reasons: ["status check failed: #{e.class}: #{e.message}"[0, LINE_MAX]], announcements: nil,
       uploads: nil}
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

    # A log ending in a RUN-OUTCOME line (P7-0) is judged by it first; an ok
    # outcome, or an older log without one, falls back to the regex scan.
    def latest_run_finding(lines, file, repeated)
      last = lines.reject { |l| l.strip.empty? }.last
      if (outcome = RunOutcome.parse(last))
        finding = outcome_finding(outcome, file)
        return [finding] if finding
      elsif last&.match?(ERROR_RE)
        return ["#{file} ends with #{clip(last)}"]
      end

      first = lines.find { |l| warning?(l) && !repeated.key?(normalize(l)) }
      first ? ["#{file}: #{clip(first)}"] : []
    end

    def outcome_finding(outcome, file)
      return nil if outcome[:status] == "ok" && outcome[:warnings].zero? && outcome[:errors].zero?

      text = outcome[:first] || "warnings=#{outcome[:warnings]} errors=#{outcome[:errors]}"
      "#{file}: #{"run failed: " if outcome[:status] == "error"}#{clip(text)}"
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
    # PUBLISH_REPEAT (or more) consecutive entries before it, counted over the
    # entries named for this podcast plus the unnamed (pre-marker) ones. A
    # named entry's warnings are its podcast's; unnamed entries name no
    # podcast: Twitter warnings go to podcasts with a ## Twitter section,
    # other warnings to podcasts with an installed launchd scheduler. An
    # unnamed latest entry counts only while it is the newest entry in the
    # whole log; once marked publishes follow, a legacy streak is history.
    def publish_findings(config)
      entries = publish_entries.select { |e| e[:podcast].nil? || e[:podcast] == config.name }
      return [] if entries.empty?

      latest = entries.last
      return [] unless latest[:podcast] || latest.equal?(publish_entries.last)
      latest[:warnings].filter_map do |key, raw|
        next unless latest[:podcast] || publish_warning_for?(config, raw)
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

    # [{date: "YYYY-MM-DD", podcast: name_or_nil, warnings: {normalized => raw}}],
    # oldest first. A begin marker opens a named entry that owns every
    # "Warning:" line up to its end marker (an end marker naming another
    # podcast does not close it; a missing one closes at generate output or a
    # later day's dated line). Outside markers (legacy lines):
    # contiguous dated lines of the same day are one unnamed publish (rclone
    # may print several); clean publishes on adjacent lines stay separate.
    def parse_publish_log
      return [] unless File.exist?(@publish_log)

      entries = []
      current = nil
      previous_dated = false
      File.foreach(@publish_log) do |raw|
        line = raw.scrub.chomp
        if (m = line.match(PUBLISH_MARKER_RE))
          previous_dated = false
          if m[5] == "begin"
            current = {date: "#{m[1]}-#{m[2]}-#{m[3]}", podcast: m[4], warnings: {}}
            entries << current
          elsif [nil, m[4]].include?(current&.dig(:podcast))
            current = nil
          end
          next
        end
        if current&.dig(:podcast)
          # A named entry whose end marker never came (publish killed) closes
          # on generate output or on a dated line from a later day.
          if line.match?(GENERATE_LINE_RE)
            current = nil
            next
          end
          m = line.match(PUBLISH_ENTRY_RE)
          if m.nil? || "#{m[1]}-#{m[2]}-#{m[3]}" <= current[:date]
            current[:warnings][normalize(line)] ||= line if line.match?(PUBLISH_WARNING_RE)
            next
          end
          current = nil
        end
        if (m = line.match(PUBLISH_ENTRY_RE))
          date = "#{m[1]}-#{m[2]}-#{m[3]}"
          unless previous_dated && current&.dig(:date) == date
            current = {date: date, podcast: nil, warnings: {}}
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
      stalled = progress_stalled?(dates, last, since)
      if stalled
        escalate.call("WARN", last ? "announcements stalled since #{last} (newest episode #{newest})" :
          "announcements never posted (newest episode #{newest})")
      end
      {last_tweeted: last&.to_s, newest_episode: newest&.to_s, stalled: stalled}
    end

    # Stalled when the newest episode is more than `since` days past the last
    # one sent; never sent only counts once an episode is older than `since`
    # (a brand-new show is not stalled).
    def progress_stalled?(dates, last, since)
      newest = dates.max
      if newest.nil?
        false
      elsif last
        (newest - last).to_i > since
      else
        (@today - dates.min).to_i > since
      end
    end

    # --- served feed read-back (P7-2) ---

    # base_url/feed.xml vs the newest local primary-language episode dated
    # today or earlier (feed.xml carries the primary language; pre-generated
    # future episodes are not expected to be served yet). Fetch errors name
    # the exception class or the HTTP code only, never a body.
    def served_feed_findings(config)
      return [] if @offline || config.base_url.to_s.strip.empty?

      local = announced_episode_dates(config, []).select { |d| d <= @today }.max
      return [] unless local

      served = @served_feed.newest_date("#{config.base_url.to_s.chomp("/")}/feed.xml")
      return ["served feed has no dated items (local #{local})"] unless served

      behind = (local - served).to_i
      (behind > SERVED_FEED_SLACK) ? ["served feed behind local by #{behind}d (served #{served}, local #{local})"] : []
    rescue => e
      root = e.cause || e
      ["served feed fetch failed: #{root.is_a?(ServedFeed::StatusError) ? root.message : root.class.name}"]
    end

    # --- upload progress (YouTube, LingQ; P7-1) ---

    # {platform => {last_uploaded:, newest_episode:, stalled:}} for each
    # platform the podcast configures, nil when none. Eligible episodes and
    # tracker groups mirror YouTubePublisher / LingQPublisher (every scanned
    # episode; playlist or "default", collection id).
    def upload_progress(config, escalate)
      platforms = upload_platforms(config)
      return nil if platforms.empty?

      dates = EpisodeScanner.scan(config.episodes_dir).filter_map { |ep| EpisodeFiltering.parse_date(ep[:base_name]) }
      newest = dates.max
      progress = platforms.to_h do |platform, group|
        last = tracked_dates(config, platform, group).max
        stalled = progress_stalled?(dates, last, UPLOAD_SINCE)
        if stalled
          escalate.call("WARN", last ? "#{platform} uploads stalled since #{last} (newest episode #{newest})" :
            "#{platform} uploads never made (newest episode #{newest})")
        end
        [platform, {last_uploaded: last&.to_s, newest_episode: newest&.to_s, stalled: stalled}]
      end
      if platforms.key?("youtube")
        upload_log_conditions.each { |condition| escalate.call("WARN", "#{File.basename(@uploads_log)}: #{condition}") }
      end
      progress
    end

    def upload_platforms(config)
      platforms = {}
      platforms["youtube"] = (config.youtube_config[:playlist] || "default").to_s if config.youtube_config
      collection = config.lingq_config&.dig(:collection)
      platforms["lingq"] = collection.to_s if collection
      platforms
    end

    # Condition names found in the tail of the upload batch's stderr, when it
    # was written within UPLOAD_SINCE days. Never the matched line itself.
    def upload_log_conditions
      return [] unless File.exist?(@uploads_log)
      return [] if (@today - File.mtime(@uploads_log).to_date).to_i > UPLOAD_SINCE

      tail = File.readlines(@uploads_log).last(UPLOAD_LOG_TAIL).map(&:scrub)
      UPLOAD_CONDITIONS.filter_map { |re, condition| condition if tail.any? { |l| l.match?(re) } }
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
      tracked_dates(config, :twitter, "posts")
    end

    def tracked_dates(config, platform, group)
      path = File.join(File.dirname(config.episodes_dir), "uploads.yml") # UploadTracker.for_config
      return [] unless File.exist?(path)

      UploadTracker.new(path).entries_for(platform, group).keys.filter_map { |b| EpisodeFiltering.parse_date(b) }
    end

    def clip_middle(line)
      text = line.strip
      return text if text.length <= LINE_MAX

      half = (LINE_MAX - 3) / 2
      "#{text[0, half]}...#{text[-(LINE_MAX - 3 - half)..]}"
    end

    # The RUN-OUTCOME line quotes a warning in first=; it is judged as an
    # outcome, never counted as a warning line itself.
    def warning?(line)
      line.match?(WARNING_RE) && !line.match?(REVIEWER_FINDING_RE) && RunOutcome.parse(line).nil?
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
