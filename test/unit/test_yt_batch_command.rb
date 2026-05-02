# frozen_string_literal: true

require_relative "../test_helper"
require "cli/yt_batch_command"
require "youtube_publisher"

class TestYtBatchCommand < Minitest::Test
  Result = YouTubePublisher::Result

  def setup
    @tmpdir = Dir.mktmpdir("podgen_yt_batch_cmd")
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # ── parsing ──

  def test_parses_comma_separated_podcasts
    cmd = PodgenCLI::YtBatchCommand.new(["pod_a,pod_b,pod_c"], {})
    assert_equal %w[pod_a pod_b pod_c], cmd.send(:parse_pods, cmd.instance_variable_get(:@pods_arg))
  end

  def test_parses_mode_priority_default
    cmd = PodgenCLI::YtBatchCommand.new(["pod_a"], {})
    assert_equal :priority, cmd.instance_variable_get(:@mode)
  end

  def test_parses_mode_round_robin
    cmd = PodgenCLI::YtBatchCommand.new(["--mode", "round-robin", "pod_a"], {})
    assert_equal :round_robin, cmd.instance_variable_get(:@mode)
  end

  def test_parses_max_flag
    cmd = PodgenCLI::YtBatchCommand.new(["--max", "3", "pod_a"], {})
    assert_equal 3, cmd.instance_variable_get(:@max)
  end

  def test_rejects_empty_pods_arg
    cmd = PodgenCLI::YtBatchCommand.new([], {})
    capture_io { @code = cmd.run }
    assert_equal 2, @code
  end

  # ── priority mode ──

  def test_priority_drains_first_pod_then_moves_to_next
    cmd = stub_cmd(["pod_a,pod_b,pod_c"])
    pending = { "pod_a" => 2, "pod_b" => 3, "pod_c" => 1 }
    cmd.define_singleton_method(:pending_count_for) { |pod| pending[pod] || 0 }

    invocations = []
    cmd.define_singleton_method(:run_publish_for) do |pod, max:|
      invocations << [pod, max]
      n = pending[pod]
      pending[pod] = 0
      Result.new(uploaded: n, attempted: n, rate_limited: false, errors: [])
    end

    capture_io { cmd.run }
    assert_equal [["pod_a", nil], ["pod_b", nil], ["pod_c", nil]], invocations
  end

  def test_priority_skips_pods_with_zero_pending
    cmd = stub_cmd(["pod_a,pod_b,pod_c"])
    pending = { "pod_a" => 0, "pod_b" => 3, "pod_c" => 0 }
    cmd.define_singleton_method(:pending_count_for) { |pod| pending[pod] || 0 }

    invocations = []
    cmd.define_singleton_method(:run_publish_for) do |pod, max:|
      invocations << pod
      n = pending[pod]
      pending[pod] = 0
      Result.new(uploaded: n, attempted: n, rate_limited: false, errors: [])
    end

    capture_io { cmd.run }
    assert_equal ["pod_b"], invocations
  end

  def test_priority_caps_at_max_across_pods
    cmd = stub_cmd(["--max", "4", "pod_a,pod_b,pod_c"])
    pending = { "pod_a" => 2, "pod_b" => 3, "pod_c" => 5 }
    cmd.define_singleton_method(:pending_count_for) { |pod| pending[pod] || 0 }

    invocations = []
    cmd.define_singleton_method(:run_publish_for) do |pod, max:|
      to_upload = [pending[pod], max].compact.min
      invocations << [pod, max, to_upload]
      pending[pod] -= to_upload
      Result.new(uploaded: to_upload, attempted: to_upload, rate_limited: false, errors: [])
    end

    capture_io { cmd.run }
    # pod_a uses 2 of 4, pod_b uses 2 of remaining 2, pod_c never called
    assert_equal [["pod_a", 4, 2], ["pod_b", 2, 2]], invocations
  end

  def test_priority_halts_on_rate_limit
    cmd = stub_cmd(["pod_a,pod_b"])
    cmd.define_singleton_method(:pending_count_for) { |_| 5 }

    invocations = []
    cmd.define_singleton_method(:run_publish_for) do |pod, max:|
      invocations << pod
      Result.new(uploaded: 1, attempted: 2, rate_limited: true, errors: [])
    end

    capture_io { cmd.run }
    assert_equal ["pod_a"], invocations, "should stop after rate-limit on pod_a"
  end

  def test_priority_returns_zero_when_all_caught_up
    cmd = stub_cmd(["pod_a,pod_b"])
    cmd.define_singleton_method(:pending_count_for) { |_| 0 }

    out, _ = capture_io { @code = cmd.run }
    assert_equal 0, @code
    assert_match(/caught up/i, out)
  end

  # ── round-robin mode ──

  def test_round_robin_interleaves_one_per_pod_per_round
    cmd = stub_cmd(["--mode", "round-robin", "pod_a,pod_b,pod_c"])
    pending = { "pod_a" => 2, "pod_b" => 2, "pod_c" => 2 }
    cmd.define_singleton_method(:pending_count_for) { |pod| pending[pod] || 0 }

    invocations = []
    cmd.define_singleton_method(:run_publish_for) do |pod, max:|
      invocations << [pod, max]
      pending[pod] -= 1
      Result.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
    end

    capture_io { cmd.run }
    assert_equal [
      ["pod_a", 1], ["pod_b", 1], ["pod_c", 1],
      ["pod_a", 1], ["pod_b", 1], ["pod_c", 1]
    ], invocations
  end

  def test_round_robin_skips_drained_pods
    cmd = stub_cmd(["--mode", "round-robin", "pod_a,pod_b,pod_c"])
    pending = { "pod_a" => 1, "pod_b" => 0, "pod_c" => 2 }
    cmd.define_singleton_method(:pending_count_for) { |pod| pending[pod] || 0 }

    invocations = []
    cmd.define_singleton_method(:run_publish_for) do |pod, max:|
      invocations << pod
      pending[pod] -= 1
      Result.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
    end

    capture_io { cmd.run }
    assert_equal %w[pod_a pod_c pod_c], invocations
  end

  def test_round_robin_caps_at_max
    cmd = stub_cmd(["--mode", "round-robin", "--max", "3", "pod_a,pod_b"])
    pending = { "pod_a" => 5, "pod_b" => 5 }
    cmd.define_singleton_method(:pending_count_for) { |pod| pending[pod] || 0 }

    invocations = []
    cmd.define_singleton_method(:run_publish_for) do |pod, max:|
      invocations << pod
      pending[pod] -= 1
      Result.new(uploaded: 1, attempted: 1, rate_limited: false, errors: [])
    end

    capture_io { cmd.run }
    assert_equal %w[pod_a pod_b pod_a], invocations
  end

  def test_round_robin_halts_on_rate_limit
    cmd = stub_cmd(["--mode", "round-robin", "pod_a,pod_b"])
    cmd.define_singleton_method(:pending_count_for) { |_| 5 }

    invocations = []
    cmd.define_singleton_method(:run_publish_for) do |pod, max:|
      invocations << pod
      rl = (pod == "pod_a" && invocations.length == 1) ? false : true
      Result.new(uploaded: 1, attempted: 1, rate_limited: rl, errors: [])
    end

    capture_io { cmd.run }
    assert_equal %w[pod_a pod_b], invocations
  end

  def test_round_robin_returns_zero_when_all_caught_up
    cmd = stub_cmd(["--mode", "round-robin", "pod_a,pod_b"])
    cmd.define_singleton_method(:pending_count_for) { |_| 0 }

    out, _ = capture_io { @code = cmd.run }
    assert_equal 0, @code
    assert_match(/caught up/i, out)
  end

  private

  def stub_cmd(args)
    PodgenCLI::YtBatchCommand.new(args, {})
  end
end
