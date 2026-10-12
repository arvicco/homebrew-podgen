# frozen_string_literal: true

require_relative "../test_helper"
require "cli"
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

  # ── run_round_robin (characterization, private) ──

  def test_round_robin_rotates_one_upload_per_pod_per_round
    yt_calls = []
    pending = { "pod_a" => 2, "pod_b" => 2 }
    cmd = round_robin_cmd(["pod_a,pod_b"], yt_calls, pending)

    tick = nil
    capture_io { tick = cmd.send(:run_round_robin, %w[pod_a pod_b]) }

    assert_equal %w[pod_a pod_b pod_a pod_b], yt_calls
    assert_equal 2, tick.per_pod["pod_a"][:uploaded]
    assert_equal 2, tick.per_pod["pod_b"][:uploaded]
    refute tick.rate_limited
  end

  def test_round_robin_stops_when_max_reached
    yt_calls = []
    pending = { "pod_a" => 5, "pod_b" => 5 }
    cmd = round_robin_cmd(["--max", "3", "pod_a,pod_b"], yt_calls, pending)

    tick = nil
    capture_io { tick = cmd.send(:run_round_robin, %w[pod_a pod_b]) }

    assert_equal %w[pod_a pod_b pod_a], yt_calls
    assert_equal 3, tick.per_pod.values.sum { |v| v[:uploaded] }
  end

  def test_round_robin_halts_on_rate_limit
    yt_calls = []
    cmd = stub_cmd(["pod_a,pod_b"])
    cmd.define_singleton_method(:pending_count_for) { |_| 5 }
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      yt_calls << pod
      if pod == "pod_b"
        YTResult.new(uploaded: 0, attempted: 1, rate_limited: true, errors: [{ type: :rate_limit }])
      else
        YTResult.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
      end
    end

    tick = nil
    capture_io { tick = cmd.send(:run_round_robin, %w[pod_a pod_b]) }

    assert_equal %w[pod_a pod_b], yt_calls, "rate limit must halt the whole YT phase"
    assert tick.rate_limited
  end

  def test_round_robin_skips_pod_with_no_pending_without_yt_call
    yt_calls = []
    pending = { "pod_a" => 0, "pod_b" => 1 }
    cmd = round_robin_cmd(["pod_a,pod_b"], yt_calls, pending)

    tick = nil
    capture_io { tick = cmd.send(:run_round_robin, %w[pod_a pod_b]) }

    assert_equal %w[pod_b], yt_calls
    assert_equal 0, tick.per_pod["pod_a"][:uploaded]
  end

  def test_round_robin_missing_cover_only_drains_pod_permanently
    yt_calls = []
    cmd = stub_cmd(["pod_a,pod_b"])
    pending = { "pod_a" => 5, "pod_b" => 1 }
    cmd.define_singleton_method(:pending_count_for) { |pod| pending[pod] }
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      yt_calls << pod
      if pod == "pod_a"
        # uploads nothing, only missing_cover errors — permanent skip
        YTResult.new(uploaded: 0, attempted: 1, rate_limited: false, errors: [{ type: :missing_cover }])
      else
        pending[pod] -= 1
        YTResult.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
      end
    end

    tick = nil
    capture_io { tick = cmd.send(:run_round_robin, %w[pod_a pod_b]) }

    assert_equal %w[pod_a pod_b], yt_calls, "pod_a must not be retried after missing-cover-only round"
    assert_equal 0, tick.per_pod["pod_a"][:uploaded]
    assert_equal 1, tick.per_pod["pod_a"][:errors]
    assert_equal 1, tick.per_pod["pod_b"][:uploaded]
  end

  def test_round_robin_caps_rounds_at_initial_pending_total
    yt_calls = []
    cmd = stub_cmd(["pod_a,pod_b"])
    cmd.define_singleton_method(:pending_count_for) { |_| 2 } # never drains
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      yt_calls << pod
      YTResult.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
    end

    capture_io { cmd.send(:run_round_robin, %w[pod_a pod_b]) }

    # initial pending sum = 4 -> at most 4 rounds x 2 pods
    assert_equal 8, yt_calls.length
  end

  def test_round_robin_permanent_skip_logs_one_line_per_pod
    logs = []
    cmd = PodgenCLI::UploadsCommand.new(%w[pod_a,pod_b], { log: ->(m) { logs << m } })
    pending = { "pod_a" => 5, "pod_b" => 3 }
    cmd.define_singleton_method(:pending_count_for) { |pod| pending[pod] }
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      if pod == "pod_a"
        YTResult.new(uploaded: 0, attempted: 1, rate_limited: false, errors: [{ type: :missing_cover }])
      else
        pending[pod] -= 1
        YTResult.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
      end
    end

    capture_io { cmd.send(:run_round_robin, %w[pod_a pod_b]) }

    assert_equal 1, logs.length
    assert_includes logs.first, "pod_a"
    assert_includes logs.first, "missing_cover"
  end

  # ── same error two rounds running → permanent skip (P3-3) ──

  def test_round_robin_same_error_two_rounds_logs_one_permanent_skip_line
    logs = []
    yt_calls = []
    cmd = PodgenCLI::UploadsCommand.new(%w[pod_a,pod_b], { log: ->(m) { logs << m } })
    pending = { "pod_a" => 5, "pod_b" => 4 }
    cmd.define_singleton_method(:pending_count_for) { |pod| pending[pod] }
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      yt_calls << pod
      if pod == "pod_a"
        YTResult.new(uploaded: 0, attempted: 1, rate_limited: false,
          errors: [{ type: :upload, message: "A lesson with the same URL already exists" }])
      else
        pending[pod] -= 1
        YTResult.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
      end
    end

    tick = nil
    capture_io { tick = cmd.send(:run_round_robin, %w[pod_a pod_b]) }

    skip_lines = logs.grep(/permanently skipped/)
    assert_equal 1, skip_lines.length
    assert_equal "uploads: pod_a permanently skipped — upload: A lesson with the same URL already exists " \
                 "(same error 2 rounds running)", skip_lines.first
    assert_equal 2, yt_calls.count("pod_a"), "pod_a must not be retried after the second identical failure"
    assert_equal 4, tick.per_pod["pod_b"][:uploaded]
    assert_equal 2, tick.per_pod["pod_a"][:errors]
  end

  def test_round_robin_publisher_crash_same_class_names_exception_class
    logs = []
    ok = ok_yt_result
    cmd = PodgenCLI::UploadsCommand.new(%w[pod_a,pod_b], { log: ->(m) { logs << m } })
    cmd.define_singleton_method(:pending_count_for) { |_| 3 }
    # pod_a goes through the real crash path: no such podcast under PODGEN_ROOT
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      pod == "pod_a" ? super(pod, max: max) : ok
    end

    capture_io { cmd.send(:run_round_robin, %w[pod_a pod_b]) }

    skip_lines = logs.grep(/permanently skipped/)
    assert_equal 1, skip_lines.length
    assert_includes skip_lines.first, "pod_a permanently skipped — RuntimeError: Unknown podcast: pod_a"
    assert_includes skip_lines.first, "(same error 2 rounds running)"
  end

  def test_round_robin_fail_once_then_succeed_is_not_skipped
    logs = []
    yt_calls = []
    cmd = PodgenCLI::UploadsCommand.new(%w[pod_a,pod_b], { log: ->(m) { logs << m } })
    pending = { "pod_a" => 2, "pod_b" => 3 }
    failed_once = false
    cmd.define_singleton_method(:pending_count_for) { |pod| pending[pod] }
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      yt_calls << pod
      if pod == "pod_a" && !failed_once
        failed_once = true
        YTResult.new(uploaded: 0, attempted: 1, rate_limited: false, errors: [{ type: :upload, message: "503" }])
      else
        pending[pod] -= 1
        YTResult.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
      end
    end

    tick = nil
    capture_io { tick = cmd.send(:run_round_robin, %w[pod_a pod_b]) }

    assert_empty logs.grep(/permanently skipped/)
    assert_equal 2, tick.per_pod["pod_a"][:uploaded]
    assert_equal 3, tick.per_pod["pod_b"][:uploaded]
  end

  def test_round_robin_alternating_error_classes_not_skipped_but_capped
    logs = []
    yt_calls = []
    cmd = PodgenCLI::UploadsCommand.new(%w[pod_a,pod_b], { log: ->(m) { logs << m } })
    cmd.define_singleton_method(:pending_count_for) { |_| 2 } # never drains
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      yt_calls << pod
      if pod == "pod_a"
        type = yt_calls.count("pod_a").odd? ? :upload : :video
        YTResult.new(uploaded: 0, attempted: 1, rate_limited: false, errors: [{ type: type, message: "x" }])
      else
        YTResult.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
      end
    end

    capture_io { cmd.send(:run_round_robin, %w[pod_a pod_b]) }

    assert_empty logs.grep(/permanently skipped/)
    # initial pending sum = 4 -> bounded by the round cap
    assert_equal 4, yt_calls.count("pod_a")
  end

  # ── mode validation happens before side effects ──

  def test_bogus_mode_raises_parse_error_at_construction
    assert_raises(OptionParser::ParseError) { stub_cmd(["--mode", "bogus", "pod_a"]) }
  end

  def test_bogus_mode_exits_2_with_no_collaborator_calls
    calls = []
    publishers = [R2Publisher, LingQPublisher, YouTubePublisher]
    publishers.each do |k|
      k.singleton_class.send(:alias_method, :__orig_new, :new)
      k.define_singleton_method(:new) { |*a, **kw|
        calls << k
        raise "must not be constructed"
      }
    end

    code = nil
    saved = ENV.delete("CLAUDECODE") # else the owner-action guard would also return 2
    capture_io { code = PodgenCLI.run(%w[uploads --mode bogus pod_a]) }

    assert_equal 2, code
    assert_empty calls
  ensure
    ENV["CLAUDECODE"] = saved if saved
    publishers.each do |k|
      k.singleton_class.send(:alias_method, :new, :__orig_new)
      k.singleton_class.send(:remove_method, :__orig_new)
    end
  end

  private

  # Round-robin harness: each yt call uploads 1 and decrements pending.
  def round_robin_cmd(args, yt_calls, pending)
    cmd = stub_cmd(args)
    cmd.define_singleton_method(:pending_count_for) { |pod| pending[pod] || 0 }
    cmd.define_singleton_method(:run_yt_for) do |pod, max:|
      yt_calls << pod
      pending[pod] -= 1
      YouTubePublisher::Result.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
    end
    cmd
  end

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
