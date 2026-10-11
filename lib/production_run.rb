# frozen_string_literal: true

# P2-0: detects an active production generate so the dev-loop can yield.
# GenerateCommand holds an exclusive flock on output/<podcast>/run.lock for
# the whole run; the files persist at 0 bytes, so only the lock means
# anything. Stdlib only — scripts/prod_guard.sh loads this without bundler.
module ProductionRun
  module_function

  # The installed launchd schedule (com.podcastagent.fulgur_news: 16:30).
  # Keep in step with `podgen schedule --time`.
  LAUNCHD_START = "16:30"

  # Podcast names whose run.lock is currently held by another process.
  # Never creates or writes a lock file; unreadable ones count as free.
  def running(output_root:)
    Dir.glob(File.join(output_root, "*", "run.lock")).sort.select { |path| locked?(path) }
      .map { |path| File.basename(File.dirname(path)) }
  end

  def active?(output_root:)
    !running(output_root: output_root).empty?
  end

  def launchd_window?(now:, start: LAUNCHD_START, before_minutes: 5, after_minutes: 40)
    from, to = window_bounds(start, before_minutes, after_minutes)
    minute = now.hour * 60 + now.min
    minute.between?(from, to)
  end

  # Window first: inside it nothing touches the lock — the probe's own
  # LOCK_NB attempt would make a generate starting that instant abort
  # (CRPR Gate 2 W1).
  def yield_reason(output_root:, now: Time.now)
    if launchd_window?(now: now)
      from, to = window_bounds(LAUNCHD_START, 5, 40)
      return "launchd window #{hhmm(from)}–#{hhmm(to)}"
    end

    names = running(output_root: output_root)
    names.empty? ? nil : "production run active: #{names.join(", ")}"
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
    format("%02d:%02d", minutes / 60, minutes % 60)
  end
end
