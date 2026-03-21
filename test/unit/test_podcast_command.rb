# frozen_string_literal: true

require_relative "../test_helper"
require "cli/podcast_command"

# Test class that includes the mixin
class StubCommand
  include PodgenCLI::PodcastCommand

  attr_accessor :podcast_name

  def initialize(podcast_name)
    @podcast_name = podcast_name
  end

  # Expose private methods for testing
  def test_require_podcast!(cmd)
    require_podcast!(cmd)
  end

  def test_load_config!
    load_config!
  end
end

class TestPodcastCommand < Minitest::Test
  def test_require_podcast_returns_nil_when_name_present
    cmd = StubCommand.new("my_podcast")
    PodcastConfig.stub(:available, ["my_podcast"]) do
      assert_nil cmd.test_require_podcast!("test")
    end
  end

  def test_require_podcast_returns_2_when_name_missing
    cmd = StubCommand.new(nil)
    assert_equal 2, cmd.test_require_podcast!("test")
  end

  def test_require_podcast_prints_usage_to_stderr
    cmd = StubCommand.new(nil)
    PodcastConfig.stub(:available, []) do
      output = capture_io { cmd.test_require_podcast!("generate") }
      assert_includes output[1], "Usage: podgen generate <podcast_name>"
    end
  end

  def test_require_podcast_lists_available_podcasts
    cmd = StubCommand.new(nil)
    PodcastConfig.stub(:available, ["alpha", "beta"]) do
      output = capture_io { cmd.test_require_podcast!("rss") }
      assert_includes output[1], "alpha"
      assert_includes output[1], "beta"
    end
  end

  def test_require_podcast_silent_when_no_podcasts
    cmd = StubCommand.new(nil)
    PodcastConfig.stub(:available, []) do
      output = capture_io { cmd.test_require_podcast!("rss") }
      assert_includes output[1], "Usage:"
      refute_includes output[1], "Available podcasts:"
    end
  end

  def test_require_podcast_unknown_name_returns_2
    cmd = StubCommand.new("nonexistent")
    PodcastConfig.stub(:available, ["alpha", "beta"]) do
      code = nil
      capture_io { code = cmd.test_require_podcast!("generate") }
      assert_equal 2, code
    end
  end

  def test_require_podcast_unknown_name_lists_available
    cmd = StubCommand.new("nonexistent")
    PodcastConfig.stub(:available, ["alpha", "beta"]) do
      output = capture_io { cmd.test_require_podcast!("generate") }
      assert_includes output[1], "Unknown podcast: nonexistent"
      assert_includes output[1], "Available podcasts:"
      assert_includes output[1], "alpha"
      assert_includes output[1], "beta"
    end
  end

  def test_require_podcast_typo_suggests_did_you_mean
    cmd = StubCommand.new("lahco_noc")
    PodcastConfig.stub(:available, ["fulgur_news", "lahko_noc", "ruby_world"]) do
      output = capture_io { cmd.test_require_podcast!("generate") }
      assert_includes output[1], "Unknown podcast: lahco_noc"
      assert_includes output[1], "lahko_noc"
      assert_includes output[1], "Did you mean?"
    end
  end

  def test_require_podcast_valid_name_passes
    cmd = StubCommand.new("alpha")
    PodcastConfig.stub(:available, ["alpha", "beta"]) do
      assert_nil cmd.test_require_podcast!("generate")
    end
  end
end
