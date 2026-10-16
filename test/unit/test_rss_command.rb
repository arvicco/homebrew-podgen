# frozen_string_literal: true

require_relative "../test_helper"
require "rexml/document"
require "cli/rss_command"

# P7-6 (Q-62, ruling R6-01 (a)): the PRIMARY language's feed is always
# feed.xml with the primary code in <language>; every other configured
# language gets feed-<code>.xml.
class TestRssCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_rss_cmd")
    @podcast_dir = File.join(@tmpdir, "podcasts", "pod")
    @output_dir = File.join(@tmpdir, "output", "pod")
    @episodes_dir = File.join(@output_dir, "episodes")
    FileUtils.mkdir_p(@podcast_dir)
    FileUtils.mkdir_p(@episodes_dir)
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  def test_run_primary_es_writes_feed_xml_with_language_es
    write_guidelines(%w[es])
    write_mp3("pod-2026-01-15")

    run_rss

    assert_equal %w[feed.xml], feed_files
    assert_equal "es", channel_language("feed.xml")
    assert_equal 1, item_count("feed.xml")
  end

  def test_run_en_es_writes_feed_xml_en_and_feed_es_xml
    write_guidelines(%w[en es])
    write_mp3("pod-2026-01-15")
    write_mp3("pod-2026-01-15-es")

    run_rss

    assert_equal %w[feed-es.xml feed.xml], feed_files
    assert_equal "en", channel_language("feed.xml")
    assert_equal "es", channel_language("feed-es.xml")
  end

  def test_run_sl_en_writes_primary_sl_feed_xml_and_feed_en_xml
    write_guidelines(%w[sl en])
    write_mp3("pod-2026-01-15")
    write_mp3("pod-2026-01-15-en")

    run_rss

    assert_equal %w[feed-en.xml feed.xml], feed_files
    assert_equal "sl", channel_language("feed.xml")
    assert_equal "en", channel_language("feed-en.xml")
    assert_equal ["pod-2026-01-15.mp3"], guids("feed.xml")
    assert_equal ["pod-2026-01-15-en.mp3"], guids("feed-en.xml")
  end

  private

  def write_guidelines(codes)
    File.write(File.join(@podcast_dir, "guidelines.md"),
      "## Podcast\n- name: Pod\n- language:\n#{codes.map { |c| "  - #{c}\n" }.join}")
  end

  def write_mp3(basename)
    File.write(File.join(@episodes_dir, "#{basename}.mp3"), "x" * 100)
  end

  def run_rss
    capture_io { assert_equal 0, PodgenCLI::RssCommand.new(["pod"], {verbosity: :quiet}).run }
  end

  def feed_files
    Dir.glob(File.join(@output_dir, "feed*.xml")).map { |f| File.basename(f) }.sort
  end

  def doc(name)
    REXML::Document.new(File.read(File.join(@output_dir, name)))
  end

  def channel_language(name)
    doc(name).root.elements["channel/language"].text
  end

  def item_count(name)
    doc(name).root.get_elements("channel/item").length
  end

  def guids(name)
    doc(name).root.get_elements("channel/item").map { |i| i.elements["guid"].text }
  end
end
