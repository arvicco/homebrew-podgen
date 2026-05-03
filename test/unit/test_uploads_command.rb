# frozen_string_literal: true

require_relative "../test_helper"
require "cli/uploads_command"
require "r2_publisher"
require "lingq_publisher"
require "youtube_publisher"

class TestUploadsCommand < Minitest::Test
  R2Result = R2Publisher::Result
  LQResult = LingQPublisher::Result
  YTResult = YouTubePublisher::Result

  def setup
    @tmpdir = Dir.mktmpdir("podgen_uploads_cmd")
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # ── parsing ──

  def test_parses_comma_separated_pods
    cmd = stub_cmd(["pod_a,pod_b"])
    assert_equal %w[pod_a pod_b], cmd.send(:parse_pods, cmd.instance_variable_get(:@pods_arg))
  end

  def test_default_mode_is_priority
    cmd = stub_cmd(["pod_a"])
    assert_equal :priority, cmd.instance_variable_get(:@mode)
  end

  def test_round_robin_flag
    cmd = stub_cmd(["--mode", "round-robin", "pod_a"])
    assert_equal :round_robin, cmd.instance_variable_get(:@mode)
  end

  def test_max_flag_parsed
    cmd = stub_cmd(["--max", "5", "pod_a"])
    assert_equal 5, cmd.instance_variable_get(:@max)
  end

  def test_rejects_empty_pods
    cmd = stub_cmd([])
    capture_io { @code = cmd.run }
    assert_equal 2, @code
  end

  def test_single_pod_works
    cmd = wire_cmd(["pod_a"], r2: ok_r2_result, lingq: nil, yt: ok_yt_result)
    capture_io { @code = cmd.run }
    assert_equal 0, @code
  end

  # ── R2 failure hard-skips pod from later phases ──

  def test_r2_failure_skips_lingq_and_yt_for_that_pod
    yt_invocations = []
    ok = ok_r2_result
    bad = fail_r2_result
    yt_ok = ok_yt_result
    cmd = stub_cmd(["pod_a,pod_b"])
    cmd.define_singleton_method(:run_r2_for) { |pod| pod == "pod_a" ? bad : ok }
    cmd.define_singleton_method(:run_lingq_for) { |_| LQResult.new(uploaded: 0, attempted: 0, errors: []) }
    cmd.define_singleton_method(:pending_count_for) { |_| 1 }
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      yt_invocations << pod
      yt_ok
    end

    capture_io { @code = cmd.run }

    assert_equal ["pod_b"], yt_invocations, "pod_a R2 fail must skip its YT phase"
    refute_equal 0, @code, "any failure should produce non-zero exit"
  end

  def test_r2_success_means_pod_reaches_yt_phase
    yt_invocations = []
    ok = ok_r2_result
    yt_ok = ok_yt_result
    cmd = stub_cmd(["pod_a,pod_b"])
    cmd.define_singleton_method(:run_r2_for) { |_| ok }
    cmd.define_singleton_method(:run_lingq_for) { |_| LQResult.new(uploaded: 0, attempted: 0, errors: []) }
    cmd.define_singleton_method(:pending_count_for) { |_| 1 }
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      yt_invocations << pod
      yt_ok
    end

    capture_io { @code = cmd.run }

    assert_equal %w[pod_a pod_b], yt_invocations
    assert_equal 0, @code
  end

  # ── LingQ failure does NOT skip YT ──

  def test_lingq_failure_keeps_pod_in_yt_phase
    yt_invocations = []
    ok = ok_r2_result
    yt_ok = ok_yt_result
    cmd = stub_cmd(["pod_a"])
    cmd.define_singleton_method(:run_r2_for) { |_| ok }
    cmd.define_singleton_method(:run_lingq_for) { |_| LQResult.new(uploaded: 0, attempted: 1, errors: [{ type: :upload, message: "503" }]) }
    cmd.define_singleton_method(:pending_count_for) { |_| 1 }
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      yt_invocations << pod
      yt_ok
    end

    capture_io { @code = cmd.run }

    assert_equal ["pod_a"], yt_invocations
  end

  # ── --max only applies to YT phase ──

  def test_max_applies_only_to_yt
    yt_calls = []
    ok = ok_r2_result
    pending = { "pod_a" => 5, "pod_b" => 5 }
    cmd = stub_cmd(["--max", "1", "pod_a,pod_b"])
    cmd.define_singleton_method(:run_r2_for) { |_| ok }
    cmd.define_singleton_method(:run_lingq_for) { |_| LQResult.new(uploaded: 5, attempted: 5, errors: []) }
    cmd.define_singleton_method(:pending_count_for) { |pod| pending[pod] || 0 }
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      yt_calls << [pod, max]
      pending[pod] -= 1
      YTResult.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
    end

    capture_io { cmd.run }

    # priority mode: pod_a uses up the 1-cap, pod_b not invoked
    assert_equal [["pod_a", 1]], yt_calls
  end

  # ── Rate limit returns 0 (expected daily occurrence) ──

  def test_rate_limit_returns_zero
    ok = ok_r2_result
    cmd = stub_cmd(["pod_a"])
    cmd.define_singleton_method(:run_r2_for) { |_| ok }
    cmd.define_singleton_method(:run_lingq_for) { |_| LQResult.new(uploaded: 0, attempted: 0, errors: []) }
    cmd.define_singleton_method(:pending_count_for) { |_| 1 }
    cmd.define_singleton_method(:run_yt_for) do |_, max:|
      YTResult.new(uploaded: 0, attempted: 1, rate_limited: true, errors: [{ type: :rate_limit }])
    end

    capture_io { @code = cmd.run }
    assert_equal 0, @code
  end

  # ── R2 fails for ALL pods → exit 1 ──

  def test_all_r2_fail_returns_one
    bad = fail_r2_result
    cmd = stub_cmd(["pod_a,pod_b"])
    cmd.define_singleton_method(:run_r2_for) { |_| bad }
    cmd.define_singleton_method(:run_lingq_for) { |_| LQResult.new(uploaded: 0, attempted: 0, errors: []) }
    cmd.define_singleton_method(:pending_count_for) { |_| 0 }
    cmd.define_singleton_method(:run_yt_for) { |_, max:| YTResult.new(uploaded: 0, attempted: 0, rate_limited: false, errors: []) }

    capture_io { @code = cmd.run }
    assert_equal 1, @code
  end

  # ── LingQ failure makes overall exit non-zero ──

  def test_lingq_failure_returns_one
    ok = ok_r2_result
    cmd = stub_cmd(["pod_a"])
    cmd.define_singleton_method(:run_r2_for) { |_| ok }
    cmd.define_singleton_method(:run_lingq_for) { |_| LQResult.new(uploaded: 0, attempted: 1, errors: [{ type: :upload, message: "x" }]) }
    cmd.define_singleton_method(:pending_count_for) { |_| 0 }
    cmd.define_singleton_method(:run_yt_for) { |_, max:| YTResult.new(uploaded: 0, attempted: 0, rate_limited: false, errors: []) }

    capture_io { @code = cmd.run }
    assert_equal 1, @code, "LingQ failure (non-rate-limit) should produce non-zero exit"
  end

  private

  def stub_cmd(args)
    PodgenCLI::UploadsCommand.new(args, {})
  end

  def wire_cmd(args, r2:, lingq:, yt:)
    lq = lingq || LQResult.new(uploaded: 0, attempted: 0, errors: [])
    cmd = stub_cmd(args)
    cmd.define_singleton_method(:run_r2_for) { |_| r2 }
    cmd.define_singleton_method(:run_lingq_for) { |_| lq }
    cmd.define_singleton_method(:pending_count_for) { |_| 1 }
    cmd.define_singleton_method(:run_yt_for) { |_, max:| yt }
    cmd
  end

  def ok_yt_result = YTResult.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
  def ok_r2_result = R2Result.new(synced: true, tweets_posted: 0, errors: [])
  def fail_r2_result = R2Result.new(synced: false, tweets_posted: 0, errors: [{ type: :rclone_failed, message: "x" }])
end
