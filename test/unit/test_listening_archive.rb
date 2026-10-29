# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "date"
require "fileutils"
require "listening_archive"

# P11-0 (Q-104): the owner's listening work as labelled examples — the
# untrimmed source + the typed cut (kept), or the rejected download + why.
class TestListeningArchive < Minitest::Test
  FIXED = Time.new(2026, 10, 29, 21, 5, 0, "+01:00")

  def setup
    @tmpdir = Dir.mktmpdir("podgen_archive_test")
    @root = File.join(@tmpdir, "archive")
    @source = File.join(@tmpdir, "podgen_source_1.m4a")
    File.binwrite(@source, "\x00\x01audio-bytes\xFF".b)
    @archive = ListeningArchive.new(root: @root, clock: -> { FIXED })
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_keep_copies_source_byte_identical_with_its_extension
    @archive.keep(@source, basename: "fiabe-2026-10-29", record: {audio_url: "https://ex.com/a.m4a"})

    copy = File.join(@root, "fiabe-2026-10-29.source.m4a")
    assert File.exist?(copy), "source copy must exist"
    assert_equal File.binread(@source), File.binread(copy)
    assert File.exist?(@source), "the pipeline's own file must stay where it was"
  end

  def test_keep_writes_sidecar_with_string_keys_and_recorded_at
    @archive.keep(@source, basename: "fiabe-2026-10-29",
      record: {audio_url: "https://ex.com/a.m4a", skip: 49.0, cut: nil})

    data = YAML.load_file(File.join(@root, "fiabe-2026-10-29.trim.yml"))
    assert_equal "https://ex.com/a.m4a", data["audio_url"]
    assert_equal 49.0, data["skip"]
    assert data.key?("cut"), "blank values are recorded as nil, not dropped"
    assert_nil data["cut"]
    assert_equal FIXED.iso8601, data["recorded_at"]
  end

  def test_reject_copies_download_and_appends_row
    @archive.reject(@source, date: Date.new(2026, 10, 29),
      record: {audio_url: "https://ex.com/a.m4a", title: "Žabica in Zmaj!", reason: "listened", prompt: "skip"})

    file = File.join(@root, "rejected", "2026-10-29-zabica-in-zmaj.m4a")
    assert File.exist?(file), "rejected download must be kept"
    assert_equal File.binread(@source), File.binread(file)
    rows = YAML.load_file(File.join(@root, "rejected.yml"))
    assert_equal 1, rows.length
    row = rows.first
    assert_equal "https://ex.com/a.m4a", row["audio_url"]
    assert_equal "listened", row["reason"]
    assert_equal "skip", row["prompt"]
    assert_equal "rejected/2026-10-29-zabica-in-zmaj.m4a", row["file"]
    assert_equal FIXED.iso8601, row["recorded_at"]
  end

  def test_reject_twice_same_title_keeps_both_files_and_rows
    2.times do
      @archive.reject(@source, date: Date.new(2026, 10, 29), record: {title: "Same", reason: "listened"})
    end

    rows = YAML.load_file(File.join(@root, "rejected.yml"))
    assert_equal 2, rows.length
    assert_equal ["rejected/2026-10-29-same-2.m4a", "rejected/2026-10-29-same.m4a"], rows.map { it["file"] }.sort
    rows.each { |r| assert File.exist?(File.join(@root, r["file"])) }
  end

  def test_reject_without_a_file_still_records_the_row
    @archive.reject(nil, date: Date.new(2026, 10, 29), record: {title: "Gone", reason: "interrupted"})

    rows = YAML.load_file(File.join(@root, "rejected.yml"))
    assert_equal 1, rows.length
    assert_nil rows.first["file"]
  end

  def test_reject_with_corrupt_rejected_yml_raises_and_leaves_it_untouched
    FileUtils.mkdir_p(@root)
    path = File.join(@root, "rejected.yml")
    ["- audio_url: a\n  reason: [unclosed\n", "just: a hash\n"].each do |body|
      File.write(path, body)
      assert_raises(RuntimeError) do
        @archive.reject(@source, date: Date.new(2026, 10, 29), record: {title: "New", reason: "listened"})
      end
      assert_equal body, File.read(path), "earlier owner labels must never be replaced"
    end
  end

  def test_keep_same_url_other_extension_leaves_one_source
    FileUtils.mkdir_p(@root)
    File.write(File.join(@root, "fiabe-2026-10-29.source.mp3"), "old")
    File.write(File.join(@root, "fiabe-2026-10-29.trim.yml"), {"audio_url" => "https://ex.com/a.m4a"}.to_yaml)

    @archive.keep(@source, basename: "fiabe-2026-10-29", record: {audio_url: "https://ex.com/a.m4a"})

    assert_equal ["fiabe-2026-10-29.source.m4a", "fiabe-2026-10-29.trim.yml"], Dir.children(@root).sort
  end

  def test_keep_other_url_moves_the_existing_pair_aside
    FileUtils.mkdir_p(@root)
    File.write(File.join(@root, "fiabe-2026-10-29.source.mp3"), "first")
    File.write(File.join(@root, "fiabe-2026-10-29.trim.yml"), {"audio_url" => "https://ex.com/first.mp3"}.to_yaml)
    File.write(File.join(@root, "fiabe-2026-10-29.1.trim.yml"), {"audio_url" => "https://ex.com/zero.mp3"}.to_yaml)

    @archive.keep(@source, basename: "fiabe-2026-10-29", record: {audio_url: "https://ex.com/a.m4a"})

    assert_equal "first", File.read(File.join(@root, "fiabe-2026-10-29.2.source.mp3"))
    assert_equal "https://ex.com/first.mp3", YAML.load_file(File.join(@root, "fiabe-2026-10-29.2.trim.yml"))["audio_url"]
    assert_equal "https://ex.com/zero.mp3", YAML.load_file(File.join(@root, "fiabe-2026-10-29.1.trim.yml"))["audio_url"]
    assert_equal "https://ex.com/a.m4a", YAML.load_file(File.join(@root, "fiabe-2026-10-29.trim.yml"))["audio_url"]
    assert_equal File.binread(@source), File.binread(File.join(@root, "fiabe-2026-10-29.source.m4a"))
    refute File.exist?(File.join(@root, "fiabe-2026-10-29.source.mp3"))
  end
end
