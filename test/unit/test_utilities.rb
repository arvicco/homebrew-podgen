# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Tests for utility classes/modules that previously lacked coverage:
# PodcastAgent::Logger, Loggable, LANGUAGE_NAMES.
class TestUtilities < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_util_test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- LANGUAGE_NAMES ---

  def test_language_names_frozen
    require "language_names"
    assert LANGUAGE_NAMES.frozen?
  end

  def test_language_names_has_common_codes
    require "language_names"
    { "en" => "English", "es" => "Spanish", "ja" => "Japanese",
      "de" => "German", "sl" => "Slovenian" }.each do |code, name|
      assert_equal name, LANGUAGE_NAMES[code], "Expected #{code} => #{name}"
    end
  end

  def test_language_names_all_two_letter_codes
    require "language_names"
    LANGUAGE_NAMES.each_key do |code|
      assert_match(/\A[a-z]{2}\z/, code, "#{code} is not a 2-letter ISO code")
    end
  end

  # --- PodcastAgent::Logger ---

  def test_logger_custom_path
    require "logger"
    log_path = File.join(@tmpdir, "custom.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    assert_equal log_path, logger.log_file_path
  end

  def test_logger_creates_parent_directory
    require "logger"
    log_path = File.join(@tmpdir, "deep", "nested", "test.log")
    PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    assert Dir.exist?(File.join(@tmpdir, "deep", "nested"))
  end

  def test_logger_log_writes_to_file
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    logger.log("hello world")

    content = File.read(log_path)
    assert_includes content, "hello world"
    assert_match(/\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]/, content)
  end

  def test_logger_log_quiet_suppresses_stdout
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    out, = capture_io { logger.log("hidden") }
    assert_empty out
  end

  def test_logger_log_normal_shows_stdout
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :normal)

    out, = capture_io { logger.log("visible") }
    assert_includes out, "visible"
  end

  def test_logger_error_writes_to_stderr_and_file
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    _, err = capture_io { logger.error("something broke") }

    assert_includes err, "ERROR something broke"
    assert_includes File.read(log_path), "ERROR something broke"
  end

  def test_logger_phase_tracking
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    logger.phase_start("TTS")
    logger.phase_end("TTS")

    content = File.read(log_path)
    assert_includes content, "START TTS"
    assert_match(/END TTS \(\d+\.\d+s\)/, content)
  end

  def test_logger_phase_end_without_start
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    logger.phase_end("Unknown")

    content = File.read(log_path)
    assert_includes content, "END Unknown (0s)"
  end

  # --- Loggable ---

  def test_loggable_with_logger
    require "loggable"

    mock_logger = Minitest::Mock.new
    mock_logger.expect(:log, nil, [String])

    obj = Class.new { include Loggable }.new
    obj.instance_variable_set(:@logger, mock_logger)
    obj.send(:log, "test message")

    mock_logger.verify
  end

  def test_loggable_tag_from_class_name
    require "loggable"

    received = nil
    logger_stub = Object.new
    logger_stub.define_singleton_method(:log) { |msg| received = msg }

    klass = Class.new { include Loggable }
    # Give it a name by assigning to a constant
    Object.const_set(:TestLoggableWidget, klass) unless defined?(TestLoggableWidget)
    obj = TestLoggableWidget.new
    obj.instance_variable_set(:@logger, logger_stub)
    obj.send(:log, "hello")

    assert_match(/\[TestLoggableWidget\] hello/, received)
  end

  def test_loggable_nested_class_uses_last_part
    require "loggable"

    received = nil
    logger_stub = Object.new
    logger_stub.define_singleton_method(:log) { |msg| received = msg }

    mod = Module.new
    klass = Class.new { include Loggable }
    mod.const_set(:InnerClass, klass)

    obj = mod::InnerClass.new
    obj.instance_variable_set(:@logger, logger_stub)
    obj.send(:log, "nested")

    assert_includes received, "[InnerClass]"
  end

  def test_loggable_without_logger_falls_back_to_puts
    require "loggable"

    obj = Class.new { include Loggable }.new
    out, = capture_io { obj.send(:log, "fallback") }

    assert_includes out, "fallback"
  end

  # --- Loggable#measure_time ---

  def test_measure_time_returns_result_and_elapsed
    require "loggable"

    obj = Class.new { include Loggable }.new
    result, elapsed = obj.send(:measure_time) { 42 }

    assert_equal 42, result
    assert_kind_of Float, elapsed
    assert elapsed >= 0
  end

  def test_measure_time_measures_elapsed
    require "loggable"

    obj = Class.new { include Loggable }.new
    _, elapsed = obj.send(:measure_time) { sleep(0.05) }

    assert elapsed >= 0.04, "Expected elapsed >= 0.04, got #{elapsed}"
  end
end
