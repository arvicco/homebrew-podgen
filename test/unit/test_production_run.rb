# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/production_run"

# P2-0: the dev-loop yields while a production generate holds its run lock.
class TestProductionRun < Minitest::Test
  def setup
    @root = Dir.mktmpdir("production_run_test")
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
    Time.new(2026, 10, 11, h, m, 0)
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

  def test_launchd_window_edges
    refute ProductionRun.launchd_window?(now: at("16:24"))
    assert ProductionRun.launchd_window?(now: at("16:25"))
    assert ProductionRun.launchd_window?(now: at("16:30"))
    assert ProductionRun.launchd_window?(now: at("17:10"))
    refute ProductionRun.launchd_window?(now: at("17:11"))
    refute ProductionRun.launchd_window?(now: at("03:00"))
  end

  def test_yield_reason_free_outside_window_is_nil
    lock_path("podx")

    assert_nil ProductionRun.yield_reason(output_root: @root, now: at("12:00"))
  end

  def test_yield_reason_active_run_names_podcast
    hold_lock(lock_path("fulgur_news"))

    assert_equal "production run active: fulgur_news",
      ProductionRun.yield_reason(output_root: @root, now: at("12:00"))
  end

  def test_yield_reason_inside_window_names_window
    assert_equal "launchd window 16:25–17:10",
      ProductionRun.yield_reason(output_root: @root, now: at("16:40"))
  end

  # CRPR Gate 2 W1: inside the launchd window the probe must not touch the
  # lock at all (a generate starting at that instant would see it held and
  # abort). Observable contract: the window reason wins even when a lock is
  # held, and ProductionRun.running is never called.
  def test_yield_reason_inside_window_reports_window_without_probing
    hold_lock(lock_path("podx"))
    probed = false
    ProductionRun.stub(:running, ->(**) {
      probed = true
      []
    }) do
      reason = ProductionRun.yield_reason(output_root: @root, now: Time.new(2026, 10, 11, 16, 31))

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
