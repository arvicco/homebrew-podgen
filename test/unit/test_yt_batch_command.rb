# frozen_string_literal: true

require_relative "../test_helper"
require "cli/yt_batch_command"

class TestYtBatchCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_yt_batch_cmd")
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

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

  def test_rejects_empty_pods_arg
    cmd = PodgenCLI::YtBatchCommand.new([], {})
    capture_io { @code = cmd.run }
    assert_equal 2, @code
  end

  def test_returns_zero_and_message_when_all_caught_up
    cmd = PodgenCLI::YtBatchCommand.new(["pod_a,pod_b"], {})
    cmd.define_singleton_method(:pending_count_for) { |_| 0 }

    out, _ = capture_io { @code = cmd.run }
    assert_equal 0, @code
    assert_match(/caught up/i, out)
  end

  def test_invokes_publish_without_max_by_default
    cmd = PodgenCLI::YtBatchCommand.new(["pod_a,pod_b"], {})
    cmd.define_singleton_method(:pending_count_for) { |pod| pod == "pod_b" ? 3 : 0 }
    invocations = []
    cmd.define_singleton_method(:run_publish_for) { |pod, max:| invocations << [pod, max]; 0 }

    capture_io { @code = cmd.run }
    assert_equal 0, @code
    assert_equal [["pod_b", nil]], invocations, "default should pass max=nil (no cap)"
  end

  def test_invokes_publish_with_max_when_given
    cmd = PodgenCLI::YtBatchCommand.new(["--max", "6", "pod_a,pod_b"], {})
    cmd.define_singleton_method(:pending_count_for) { |pod| pod == "pod_a" ? 10 : 0 }
    invocations = []
    cmd.define_singleton_method(:run_publish_for) { |pod, max:| invocations << [pod, max]; 0 }

    capture_io { @code = cmd.run }
    assert_equal [["pod_a", 6]], invocations
  end

  def test_parses_max_flag
    cmd = PodgenCLI::YtBatchCommand.new(["--max", "3", "pod_a"], {})
    assert_equal 3, cmd.instance_variable_get(:@max)
  end

  def test_round_robin_advances_cursor_and_picks_next_pod_on_second_call
    cursor = File.join(@tmpdir, "output", "youtube_batch_cursor.yml")
    FileUtils.mkdir_p(File.dirname(cursor))

    invocations = []
    2.times do
      cmd = PodgenCLI::YtBatchCommand.new(["--mode", "round-robin", "pod_a,pod_b"], {})
      cmd.define_singleton_method(:pending_count_for) { |_| 5 }
      cmd.define_singleton_method(:run_publish_for) { |pod, max:| invocations << pod; 0 }
      capture_io { cmd.run }
    end

    assert_equal %w[pod_a pod_b], invocations
  end
end
