# frozen_string_literal: true

require_relative "../test_helper"
require "logger"

class TestPodcastAgentLogger < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("logger_test")
    @log_path = File.join(@tmpdir, "test.log")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- log ---

  def test_log_writes_to_file
    logger = PodcastAgent::Logger.new(log_path: @log_path)
    capture_io { logger.log("test message") }

    content = File.read(@log_path)
    assert_includes content, "test message"
    assert_match(/\[\d{4}-\d{2}-\d{2}/, content)
  end

  def test_log_prints_to_stdout_by_default
    logger = PodcastAgent::Logger.new(log_path: @log_path)
    output = capture_io { logger.log("visible") }.first

    assert_includes output, "visible"
  end

  def test_log_suppresses_stdout_when_quiet
    logger = PodcastAgent::Logger.new(log_path: @log_path, verbosity: :quiet)
    output = capture_io { logger.log("silent") }.first

    assert_empty output
    assert_includes File.read(@log_path), "silent"
  end

  # --- error ---

  def test_error_writes_to_stderr_and_file
    logger = PodcastAgent::Logger.new(log_path: @log_path)
    _, stderr = capture_io { logger.error("bad thing") }

    assert_includes stderr, "ERROR bad thing"
    assert_includes File.read(@log_path), "ERROR bad thing"
  end

  # --- phase timing ---

  def test_phase_start_and_end_logs_elapsed
    logger = PodcastAgent::Logger.new(log_path: @log_path, verbosity: :quiet)
    capture_io do
      logger.phase_start("Test")
      sleep 0.01
      logger.phase_end("Test")
    end

    content = File.read(@log_path)
    assert_includes content, "START Test"
    assert_match(/END Test \(\d+\.\d+s\)/, content)
  end

  def test_phase_end_without_start_logs_zero
    logger = PodcastAgent::Logger.new(log_path: @log_path, verbosity: :quiet)
    capture_io { logger.phase_end("Orphan") }

    content = File.read(@log_path)
    assert_includes content, "END Orphan (0s)"
  end

  # --- log_file_path ---

  def test_log_file_path_returns_configured_path
    logger = PodcastAgent::Logger.new(log_path: @log_path)
    assert_equal @log_path, logger.log_file_path
  end

  def test_default_log_path_creates_directory
    # Use a fresh tmpdir to simulate default path
    logger = PodcastAgent::Logger.new(log_path: File.join(@tmpdir, "sub", "nested.log"))
    capture_io { logger.log("test") }

    assert File.exist?(File.join(@tmpdir, "sub", "nested.log"))
  end
end
