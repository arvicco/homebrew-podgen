# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/production_run"

# P2-0: the dev-loop yields while a production generate holds its run lock.
class TestProductionRun < Minitest::Test
  def setup
    @root = Dir.mktmpdir("production_run_test")
    @plist_dir = File.join(@root, "LaunchAgents")
    FileUtils.mkdir_p(@plist_dir)
    @holder = nil
  end

  def teardown
    release_lock
    FileUtils.rm_rf(@root)
  end

  def lock_path(pod)
    dir = File.join(@root, pod)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "run.lock")
    File.write(path, "") unless File.exist?(path)
    path
  end

  # A thread in this process can't contend with our own flock on macOS —
  # the lock must be held by a separate process.
  def hold_lock(path)
    reader, writer = IO.pipe
    @holder = fork do
      reader.close
      f = File.open(path, File::RDWR)
      f.flock(File::LOCK_EX)
      writer.write("1")
      writer.close
      sleep 30
    end
    writer.close
    reader.read(1)
    reader.close
  end

  def release_lock
    return unless @holder
    Process.kill(:KILL, @holder)
    Process.wait(@holder)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @holder = nil
  end

  def at(hhmm)
    h, m = hhmm.split(":").map(&:to_i)
    Time.utc(2026, 10, 11, h, m, 0)
  end

  def with_tz(zone)
    saved = ENV["TZ"]
    ENV["TZ"] = zone
    yield
  ensure
    ENV["TZ"] = saved
  end

  # A plist as `podgen schedule` writes it: local Hour/Minute plus the
  # schedule note (UTC time and zone offset), or none for an older install.
  def write_plist(name, hour, minute, note: nil)
    body = <<~PLIST
      <plist version="1.0"><dict>
      #{ProductionRun.schedule_note(*note) if note}
      <key>StartCalendarInterval</key>
      <dict>
        <key>Hour</key>
        <integer>#{hour}</integer>
        <key>Minute</key>
        <integer>#{minute}</integer>
      </dict>
      </dict></plist>
    PLIST
    File.write(File.join(@plist_dir, "com.podcastagent.#{name}.plist"), body)
  end

  def yield_at(hhmm)
    ProductionRun.yield_reason(output_root: @root, now: at(hhmm), plist_dir: @plist_dir)
  end

  def test_running_held_lock_returns_podcast
    hold_lock(lock_path("podx"))
    lock_path("pody")

    assert_equal ["podx"], ProductionRun.running(output_root: @root)
    assert ProductionRun.active?(output_root: @root)
  end

  def test_running_free_lock_returns_empty
    path = lock_path("podx")

    assert_equal [], ProductionRun.running(output_root: @root)
    refute ProductionRun.active?(output_root: @root)
    assert_equal 0, File.size(path)
  end

  def test_running_missing_lock_file_returns_empty_and_creates_nothing
    FileUtils.mkdir_p(File.join(@root, "podx"))

    assert_equal [], ProductionRun.running(output_root: @root)
    refute File.exist?(File.join(@root, "podx", "run.lock"))
  end

  def test_running_missing_output_root_returns_empty
    assert_equal [], ProductionRun.running(output_root: File.join(@root, "nope"))
  end

  # P25-1: the recorded UTC time governs, whatever the device zone is.
  def test_yield_window_is_evaluated_in_utc
    write_plist("my_show", 15, 0, note: ["14:00", "+01:00"])

    ["Etc/GMT-1", "Asia/Tokyo"].each do |zone|
      with_tz(zone) do
        assert_equal "launchd window 13:55–14:40 UTC (my_show)", yield_at("14:00"), zone
        assert_nil yield_at("12:00"), zone
      end
    end
  end

  def test_launchd_window_edges_in_utc
    with_tz("UTC") do
      write_plist("my_show", 14, 0, note: ["14:00", "+00:00"])

      assert_nil yield_at("13:54")
      assert yield_at("13:55")
      assert yield_at("14:40")
      assert_nil yield_at("14:41")
    end
  end

  def test_launchd_window_wraps_midnight
    with_tz("UTC") do
      write_plist("my_show", 0, 2, note: ["00:02", "+00:00"])

      assert_equal "launchd window 23:57–00:42 UTC (my_show)", yield_at("23:58")
      assert yield_at("00:30")
    end
  end

  # After a zone change launchd may keep the recorded instant or move to the
  # plist's Hour/Minute in the new zone: both are guarded.
  def test_launchd_window_covers_the_plist_time_in_the_current_zone_too
    write_plist("my_show", 15, 0, note: ["14:00", "+01:00"])

    with_tz("Etc/GMT-2") do
      assert yield_at("14:10")
      assert yield_at("13:10")
      assert_nil yield_at("12:00")
    end
  end

  def test_launchd_window_older_plist_without_note_uses_its_hour_in_the_current_zone
    with_tz("Etc/GMT+3") do
      write_plist("my_show", 5, 0)

      assert_equal "launchd window 07:55–08:40 UTC (my_show)", yield_at("08:00")
    end
  end

  def test_launchd_window_skips_the_status_check_job
    write_plist("status", 14, 0, note: ["14:00", "+00:00"])

    with_tz("UTC") { assert_nil yield_at("14:00") }
  end

  def test_yield_reason_no_schedule_installed_has_no_window
    FileUtils.rm_rf(@plist_dir)

    assert_nil yield_at("14:00")
  end

  def test_schedules_reads_note_and_current_zone_time
    write_plist("my_show", 15, 0, note: ["14:00", "+01:00"])
    File.write(File.join(@plist_dir, "com.podcastagent.other.plist"), "<plist/>")

    with_tz("Etc/GMT-2") do
      assert_equal [{label: "com.podcastagent.my_show", utc: "14:00", zone: "+01:00", fires_utc: "13:00"}],
        ProductionRun.schedules(plist_dir: @plist_dir, now: at("12:00"))
    end
  end

  def test_schedule_warning_names_zone_change_and_missing_note
    assert_nil ProductionRun.schedule_warning(utc: "14:00", fires_utc: "14:00")
    assert_equal "fires 13:00 UTC, written for 14:00 UTC — re-install: the device zone changed",
      ProductionRun.schedule_warning(utc: "14:00", fires_utc: "13:00")
    assert_match(/no UTC time recorded/, ProductionRun.schedule_warning(utc: nil, fires_utc: "13:00"))
  end

  def test_yield_reason_free_outside_window_is_nil
    lock_path("podx")

    assert_nil yield_at("12:00")
  end

  def test_yield_reason_active_run_names_podcast
    hold_lock(lock_path("my_show"))

    assert_equal "production run active: my_show", yield_at("12:00")
  end

  # P18-5 (Q-128): the uploads batch holds output/uploads.lock for its
  # lifetime and loads YouTube code lazily — the yield covers it too.
  def uploads_lock_path
    path = File.join(@root, ProductionRun::UPLOADS_LOCK)
    File.write(path, "") unless File.exist?(path)
    path
  end

  def test_yield_reason_uploads_batch_held_names_batch
    hold_lock(uploads_lock_path)

    assert_equal "uploads batch active", yield_at("12:00")
  end

  def test_yield_reason_uploads_lock_free_is_nil
    uploads_lock_path

    assert_nil yield_at("12:00")
  end

  def test_running_ignores_uploads_lock
    hold_lock(uploads_lock_path)

    assert_equal [], ProductionRun.running(output_root: @root)
  end

  def test_yield_reason_inside_window_names_window
    write_plist("my_show", 14, 0, note: ["14:00", "+00:00"])

    with_tz("UTC") { assert_equal "launchd window 13:55–14:40 UTC (my_show)", yield_at("14:10") }
  end

  # CRPR Gate 2 W1: inside the launchd window the probe must not touch the
  # lock at all (a generate starting at that instant would see it held and
  # abort). Observable contract: the window reason wins even when a lock is
  # held, and ProductionRun.running is never called.
  def test_yield_reason_inside_window_reports_window_without_probing
    write_plist("my_show", 14, 0, note: ["14:00", "+00:00"])
    hold_lock(lock_path("podx"))
    probed = false
    ProductionRun.stub(:running, ->(**) {
      probed = true
      []
    }) do
      reason = with_tz("UTC") { yield_at("14:01") }

      assert_match(/launchd window/, reason)
      refute probed, "running must not be called inside the window"
    end
  end

  # CRPR Gate 2 NIT 6: a read-only lock file is still probed (flock works on
  # a read-only descriptor), so a held lock is detected.
  def test_running_detects_held_lock_on_readonly_file
    path = lock_path("podx")
    hold_lock(path)
    File.chmod(0o444, path)

    assert_equal ["podx"], ProductionRun.running(output_root: @root)
  ensure
    File.chmod(0o644, path) if path && File.exist?(path)
  end
end
