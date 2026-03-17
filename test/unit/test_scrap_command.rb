# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "cli/scrap_command"

class TestScrapCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_scrap_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- remove_lingq_tracking ---

  def test_remove_lingq_tracking_deletes_entry
    tracking = { "123" => { "ep-a" => 1, "ep-b" => 2 } }
    tracking_path = File.join(@tmpdir, "lingq_uploads.yml")
    File.write(tracking_path, tracking.to_yaml)

    config = stub_config
    cmd = build_command(config)
    cmd.send(:remove_lingq_tracking, config, "ep-a")

    data = YAML.load_file(tracking_path)
    refute data["123"].key?("ep-a")
    assert_equal 2, data["123"]["ep-b"]
  end

  def test_remove_lingq_tracking_preserves_other_collections
    tracking = {
      "123" => { "ep-a" => 1 },
      "456" => { "ep-x" => 10 }
    }
    tracking_path = File.join(@tmpdir, "lingq_uploads.yml")
    File.write(tracking_path, tracking.to_yaml)

    config = stub_config
    cmd = build_command(config)
    cmd.send(:remove_lingq_tracking, config, "ep-a")

    data = YAML.load_file(tracking_path)
    assert_equal 10, data["456"]["ep-x"]
  end

  def test_remove_lingq_tracking_missing_file_no_error
    config = stub_config
    cmd = build_command(config)
    # Should not raise
    cmd.send(:remove_lingq_tracking, config, "ep-a")
  end

  def test_remove_lingq_tracking_no_matching_entry_no_rewrite
    tracking = { "123" => { "ep-other" => 1 } }
    tracking_path = File.join(@tmpdir, "lingq_uploads.yml")
    File.write(tracking_path, tracking.to_yaml)
    original_mtime = File.mtime(tracking_path)

    config = stub_config
    cmd = build_command(config)
    sleep 0.01
    cmd.send(:remove_lingq_tracking, config, "ep-missing")

    # File should not be rewritten since no entry was removed
    assert_equal original_mtime, File.mtime(tracking_path)
  end

  def test_remove_lingq_tracking_non_hash_file
    File.write(File.join(@tmpdir, "lingq_uploads.yml"), "just a string")

    config = stub_config
    cmd = build_command(config)
    # Should not raise
    cmd.send(:remove_lingq_tracking, config, "ep-a")
  end

  private

  StubScrapConfig = Struct.new(:episodes_dir, keyword_init: true)

  def stub_config
    StubScrapConfig.new(episodes_dir: @episodes_dir)
  end

  def build_command(config)
    cmd = PodgenCLI::ScrapCommand.allocate
    cmd.instance_variable_set(:@podcast_name, "test")
    cmd
  end
end
