# frozen_string_literal: true

# P2-0: detects an active production generate so the dev-loop can yield.
# GenerateCommand holds an exclusive flock on output/<podcast>/run.lock for
# the whole run; the files persist at 0 bytes, so only the lock means
# anything. Stdlib only — scripts/prod_guard.sh loads this without bundler.
module ProductionRun
  module_function

  # P25-1: the schedule is read from the installed launchd plists, never
  # from a constant. `podgen schedule --time HH:MM` takes the time as UTC,
  # writes Hour/Minute for the device's zone and records the UTC time and
  # the zone offset in an XML comment (schedule_note). No plist installed →
  # no time window; the lock-based yield still applies.
  LABEL_PREFIX = "com.podcastagent"
  # The daily status check is read-only and short: no window for it.
  UNGUARDED_LABELS = ["#{LABEL_PREFIX}.status"].freeze
  SCHEDULE_NOTE_RE = /<!--\s*podgen-schedule utc=(\d{2}:\d{2}) zone=(\S+)\s*-->/
  WINDOW_BEFORE_MINUTES = 5
  WINDOW_AFTER_MINUTES = 40

  # P18-5 (Q-128): the uploads batch (launchd, 20+ min) holds an
  # exclusive flock on output/uploads.lock for its lifetime — it loads its
  # YouTube code lazily, so a lib/ edit mid-batch could load half-edited code.
  UPLOADS_LOCK = "uploads.lock"

  def default_plist_dir
    File.join(Dir.home, "Library", "LaunchAgents")
  end

  def schedule_note(utc, zone)
    "<!-- podgen-schedule utc=#{utc} zone=#{zone} -->"
  end

  # [utc "HH:MM", zone] recorded in a plist's text, or nil.
  def parse_schedule_note(text)
    m = text.to_s.match(SCHEDULE_NOTE_RE)
    m ? [m[1], m[2]] : nil
  end

  # The UTC time a local Hour/Minute fires at on now's date in the device zone.
  def fires_utc(hour, minute, now:)
    day = now.getlocal
    t = Time.local(day.year, day.month, day.day, hour, minute).utc
    format("%02d:%02d", t.hour, t.min)
  end

  # Installed jobs: {label:, utc:, zone:, fires_utc:}. utc/zone come from the
  # schedule note (nil on a plist written before it); fires_utc from the
  # plist's Hour/Minute read in the device's current zone. A plist without
  # Hour/Minute is skipped. (map + compact: the guard may run on Ruby 2.6.)
  def schedules(plist_dir:, now:)
    Dir.glob(File.join(plist_dir, "#{LABEL_PREFIX}.*.plist")).sort.map do |path|
      text = File.read(path)
      hour = text[%r{<key>Hour</key>\s*<integer>(\d+)</integer>}, 1]
      minute = text[%r{<key>Minute</key>\s*<integer>(\d+)</integer>}, 1]
      next unless hour && minute

      utc, zone = parse_schedule_note(text)
      {label: File.basename(path, ".plist"), utc: utc, zone: zone,
       fires_utc: fires_utc(hour.to_i, minute.to_i, now: now)}
    rescue SystemCallError, ArgumentError
      nil
    end.compact
  end

  # Why an installed job's plist no longer fires at its UTC time, or nil.
  def schedule_warning(utc:, fires_utc:)
    return "no UTC time recorded — re-install with `podgen schedule --time HH:MM` (UTC)" unless utc
    return nil if utc == fires_utc

    "fires #{fires_utc} UTC, written for #{utc} UTC — re-install: the device zone changed"
  end

  # Podcast names whose run.lock is currently held by another process.
  # Never creates or writes a lock file; unreadable ones count as free.
  def running(output_root:)
    Dir.glob(File.join(output_root, "*", "run.lock")).sort.select { |path| locked?(path) }
      .map { |path| File.basename(File.dirname(path)) }
  end

  def active?(output_root:)
    !running(output_root: output_root).empty?
  end

  # The yield window ("HH:MM–HH:MM UTC (job)") now falls in, or nil. Both
  # the recorded UTC time and the one the plist fires at in the current zone
  # are guarded: after a zone change launchd may keep either.
  def launchd_window(now:, plist_dir: default_plist_dir)
    minute = now.utc.hour * 60 + now.utc.min
    schedules(plist_dir: plist_dir, now: now).each do |job|
      next if UNGUARDED_LABELS.include?(job[:label])

      [job[:utc], job[:fires_utc]].compact.uniq.each do |start|
        from, to = window_bounds(start, WINDOW_BEFORE_MINUTES, WINDOW_AFTER_MINUTES)
        next unless (minute - from) % 1440 <= to - from

        return "#{hhmm(from)}–#{hhmm(to)} UTC (#{job[:label].delete_prefix("#{LABEL_PREFIX}.")})"
      end
    end
    nil
  end

  # Window first: inside it nothing touches the lock — the probe's own
  # LOCK_NB attempt would make a generate starting that instant abort
  # (CRPR Gate 2 W1).
  def yield_reason(output_root:, now: Time.now, plist_dir: default_plist_dir)
    window = launchd_window(now: now, plist_dir: plist_dir)
    return "launchd window #{window}" if window

    names = running(output_root: output_root)
    return "production run active: #{names.join(", ")}" unless names.empty?

    uploads_active?(output_root: output_root) ? "uploads batch active" : nil
  end

  def uploads_active?(output_root:)
    locked?(File.join(output_root, UPLOADS_LOCK))
  end

  # flock works on a read-only descriptor, so a read-only lock file is
  # still probed (CRPR Gate 2 NIT 6).
  def locked?(path)
    File.open(path, File::RDONLY) do |f|
      next true unless f.flock(File::LOCK_EX | File::LOCK_NB)
      f.flock(File::LOCK_UN)
      false
    end
  rescue SystemCallError
    false
  end

  def window_bounds(start, before_minutes, after_minutes)
    h, m = start.split(":").map(&:to_i)
    center = h * 60 + m
    [center - before_minutes, center + after_minutes]
  end

  def hhmm(minutes)
    minutes %= 1440
    format("%02d:%02d", minutes / 60, minutes % 60)
  end
end
