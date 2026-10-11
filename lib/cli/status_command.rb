# frozen_string_literal: true

require "optparse"
require "json"
require "date"

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "validators", "freshness_validator")
require_relative File.join(root, "lib", "cli", "schedule_command")

module PodgenCLI
  # Read-only content-progress surface (Q-27, P1-14): one verdict per podcast.
  #   OLD  - newest episode older than the cadence threshold (FreshnessValidator)
  #   WARN - last run log ended in ERROR / has a warning, or the same warning
  #          repeated across the last N run logs (silent-for-weeks failures)
  #   OK   - otherwise
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

    def initialize(args, options, plist_dir: ScheduleCommand::LAUNCH_AGENTS_DIR, today: Date.today)
      @options = options
      @plist_dir = plist_dir
      @today = today
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
      newest = age = nil
      escalate = ->(v, reason) {
        verdict = v if VERDICT_RANK[v] > VERDICT_RANK[verdict]
        reasons << reason
      }

      config = PodcastConfig.new(name)
      if config.freshness_enabled?
        newest, age = freshness(config, escalate)
      else
        reasons << "(freshness off)"
      end
      log_findings(config).each { |reason| escalate.call("WARN", reason) }
      reasons << "newest #{newest} (#{age.negative? ? "scheduled +#{-age}d" : "#{age}d old"})" if verdict == "OK" && newest

      {podcast: name, verdict: verdict, newest: newest&.to_s, age_days: age, reasons: reasons}
    rescue => e
      {podcast: name, verdict: "WARN", newest: nil, age_days: nil,
       reasons: ["status check failed: #{e.class}: #{e.message}"[0, LINE_MAX]]}
    end

    # Delegates the staleness rule to Validators::FreshnessValidator.
    def freshness(config, escalate)
      unless File.exist?(config.history_path.to_s)
        escalate.call("WARN", "no history (no episodes yet)")
        return [nil, nil]
      end

      validator = Validators::FreshnessValidator.new(config, today: @today)
      result = validator.validate
      result[:warnings].each do |w|
        escalate.call(w.include?("OLD") ? "OLD" : "WARN", w.delete_prefix("Freshness: "))
      end
      escalate.call("WARN", "no dated episodes in history") if validator.newest.nil?
      [validator.newest, validator.age_days]
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
