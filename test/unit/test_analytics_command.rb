# frozen_string_literal: true

require_relative "../test_helper"
require "cli/analytics_command"

class TestAnalyticsCommand < Minitest::Test
  def setup
    @original_worker_dir = PodgenCLI::AnalyticsCommand::WORKER_DIR
    @tmpdir = Dir.mktmpdir("podgen_analytics_test")
    # Point WORKER_DIR to temp dir
    PodgenCLI::AnalyticsCommand.send(:remove_const, :WORKER_DIR)
    PodgenCLI::AnalyticsCommand.const_set(:WORKER_DIR, @tmpdir)
    FileUtils.mkdir_p(File.join(@tmpdir, "src"))
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    PodgenCLI::AnalyticsCommand.send(:remove_const, :WORKER_DIR)
    PodgenCLI::AnalyticsCommand.const_set(:WORKER_DIR, @original_worker_dir)
  end

  # --- write_worker_js ---

  def test_worker_js_handles_range_requests
    cmd = PodgenCLI::AnalyticsCommand.new([], {})
    cmd.send(:write_worker_js)

    js = File.read(File.join(@tmpdir, "src", "index.js"))
    assert_includes js, "range"
    assert_includes js, "206"
    assert_includes js, "content-range"
  end

  def test_worker_js_passes_range_to_r2_get
    cmd = PodgenCLI::AnalyticsCommand.new([], {})
    cmd.send(:write_worker_js)

    js = File.read(File.join(@tmpdir, "src", "index.js"))
    # Should pass range option to env.BUCKET.get()
    assert_includes js, "BUCKET.get(key,"
  end

  def test_worker_js_supports_accept_ranges_header
    cmd = PodgenCLI::AnalyticsCommand.new([], {})
    cmd.send(:write_worker_js)

    js = File.read(File.join(@tmpdir, "src", "index.js"))
    assert_includes js, "accept-ranges"
    assert_includes js, "bytes"
  end

  def test_worker_js_serves_from_r2
    cmd = PodgenCLI::AnalyticsCommand.new([], {})
    cmd.send(:write_worker_js)

    js = File.read(File.join(@tmpdir, "src", "index.js"))
    assert_includes js, "env.BUCKET.get"
    assert_includes js, "audio/mpeg"
    assert_includes js, "ANALYTICS.writeDataPoint"
  end
end
