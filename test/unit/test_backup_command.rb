# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "cli"
require "cli/backup_command"
require "cli/restore_command"
require "backup_archive"

# `podgen backup` / `podgen restore` over a fake installation in a tmp dir:
# a project root (podcasts/, output/, .docs/, .env) and a home directory
# (.config/podgen, Library/LaunchAgents, Library/Spelling). Every value in
# it is a dummy; openssl is the only process run.
class TestBackupCommand < Minitest::Test
  PASSPHRASE = "fixture-passphrase-1"
  SECRET = "FAKE_KEY_VALUE_7f3c"

  def setup
    skip_unless_command("openssl")
    @dir = Dir.mktmpdir("podgen_backup")
    @root = File.join(@dir, "root")
    @home = File.join(@dir, "home")
    @out = File.join(@dir, "out")
    build_fixture
    @saved_env = ENV.to_h.slice("PODGEN_ROOT", BackupArchive::PASSPHRASE_ENV)
    ENV["PODGEN_ROOT"] = @root
    ENV[BackupArchive::PASSPHRASE_ENV] = PASSPHRASE
  end

  def teardown
    %w[PODGEN_ROOT].push(BackupArchive::PASSPHRASE_ENV).each do |key|
      @saved_env&.key?(key) ? ENV[key] = @saved_env[key] : ENV.delete(key)
    end
    FileUtils.rm_rf(@dir) if @dir
  end

  # --- backup ---

  def test_backup_manifest_lists_every_class_from_the_fixture_tree
    code, out, = backup

    assert_equal 0, code
    classes = manifest(archive_path)["files"].map { it["class"] }.uniq.sort

    assert_equal %w[boards dictionaries env guidelines ledgers output schedule tokens], classes
    assert_match(/Backup: .*podgen-backup-\d{4}-\d{2}-\d{2}\.tar\.gz/, out)
    assert_match(/guidelines 2, ledgers 2, output 2, boards 1, env 1, tokens 1, schedule 1, dictionaries 2/, out)
    assert_match(/Verified: 12 files round-tripped/, out)
    assert File.file?("#{archive_path}.sha256")
  end

  def test_backup_aborts_when_a_required_class_is_missing
    File.delete(File.join(@root, ".env"))

    code, _, err = backup

    assert_equal 1, code
    assert_match(/nothing written: no files for env/, err)
    assert_empty Dir.glob(File.join(@out, "*"))
  end

  def test_backup_excludes_media_without_the_flag
    backup

    paths = manifest(archive_path)["files"].map { it["path"] }

    refute_includes paths, "output/my_show/episodes/my_show-2026-01-01.mp3"
    refute_includes paths, "output/my_show/listening/my_show-2026-01-01.source.m4a"
  end

  def test_backup_with_media_includes_media_files
    backup("--with-media")

    media = manifest(archive_path)["files"].select { it["class"] == "media" }.map { it["path"] }.sort

    assert_equal %w[output/my_show/episodes/my_show-2026-01-01.mp3 output/my_show/listening/my_show-2026-01-01.source.m4a], media
  end

  def test_backup_refuses_to_overwrite_an_existing_archive
    backup
    before = File.binread(archive_path)

    code, _, err = backup

    assert_equal 1, code
    assert_match(/already exists/, err)
    assert_equal before, File.binread(archive_path)
  end

  def test_backup_leaves_no_file_when_the_round_trip_fails
    fail_verify = ->(*, **) { raise BackupArchive::Error, "digest mismatch: x" }

    code, _, err = BackupArchive.stub(:verify, fail_verify) { backup }

    assert_equal 1, code
    assert_equal "backup: digest mismatch: x\n", err
    assert_empty Dir.glob(File.join(@out, "*"))
  end

  def test_backup_never_passes_the_passphrase_in_argv
    argvs = []
    real = Open3.method(:popen3)
    spy = ->(*args, **kw, &blk) {
      argvs << args.drop_while { it.is_a?(Hash) }
      real.call(*args, **kw, &blk)
    }

    Open3.stub(:popen3, spy) { backup }

    openssl = argvs.select { it.first == "openssl" }

    assert_equal 3, openssl.size # encrypt, then the two decrypt passes of the round trip
    openssl.each do |argv|
      refute(argv.any? { it.include?(PASSPHRASE) }, "passphrase in argv: #{argv.inspect}")
      assert_includes argv, "env:#{BackupArchive::PASSPHRASE_ENV}"
    end
  end

  # --- verify ---

  def test_verify_round_trips_a_good_archive
    backup

    code, out, = run_cmd(PodgenCLI::BackupCommand, ["--verify", archive_path])

    assert_equal 0, code
    assert_match(/Verified: .* \(12 files round-tripped\)/, out)
  end

  def test_verify_fails_on_a_tampered_archive
    backup
    tamper(archive_path)

    code, _, err = run_cmd(PodgenCLI::BackupCommand, ["--verify", archive_path])

    assert_equal 1, code
    assert_match(/does not match its \.sha256/, err)
  end

  def test_verify_fails_on_a_tampered_archive_with_a_matching_sidecar
    backup
    tamper(archive_path)
    File.write("#{archive_path}.sha256", BackupArchive.sidecar_line(BackupArchive.file_digest(archive_path), archive_path))

    code, _, err = run_cmd(PodgenCLI::BackupCommand, ["--verify", archive_path])

    assert_equal 1, code
    assert_match(/wrong passphrase or damaged archive|digest mismatch/, err)
  end

  def test_verify_with_a_wrong_passphrase_fails_cleanly
    backup
    ENV[BackupArchive::PASSPHRASE_ENV] = "not-the-passphrase"

    code, out, err = run_cmd(PodgenCLI::BackupCommand, ["--verify", archive_path])

    assert_equal 1, code
    assert_equal "", out
    assert_equal "backup: openssl failed: wrong passphrase or damaged archive\n", err
  end

  # --- restore ---

  def test_restore_round_trip_restores_every_manifest_entry
    backup
    into = File.join(@dir, "fresh", "root")
    home = File.join(@dir, "fresh", "home")

    code, out, = restore(archive_path, "--into", into, "--home", home)

    assert_equal 0, code
    entries = manifest(archive_path)["files"]
    entries.each do |meta|
      base = (meta["base"] == "root") ? [@root, into] : [@home, home]
      src, dst = base.map { File.join(it, meta["path"]) }

      assert_equal File.binread(src), File.binread(dst), meta["path"]
      expected_mode = BackupArchive::SECRET_CLASSES.include?(meta["class"]) ? 0o600 : File.stat(src).mode & 0o777
      assert_equal format("%o", expected_mode), format("%o", File.stat(dst).mode & 0o777), meta["path"]
    end
    assert_equal 0o640, File.stat(File.join(into, "podcasts/my_show/guidelines.md")).mode & 0o777
    assert_equal 0o600, File.stat(File.join(into, ".env")).mode & 0o777
    assert_equal 0o600, File.stat(File.join(home, ".config/podgen/youtube_token.json")).mode & 0o777
    assert_match(/Restored 12 files into .* \(12 written, 0 already identical\)/, out)
    assert_match(/Left for the owner:\n  1\. Load the launchd agents/, out)
  end

  def test_restore_refuses_a_target_holding_other_contents_without_force
    backup
    into = File.join(@dir, "busy")
    FileUtils.mkdir_p(File.join(into, "output/my_show"))
    File.write(File.join(into, "output/my_show/history.yml"), "other\n")

    code, _, err = restore(archive_path, "--into", into, "--home", File.join(@dir, "h2"))

    assert_equal 1, code
    assert_match(/refusing to overwrite 1 existing file\(s\) with other contents \(first: output\/my_show\/history.yml\); --force overwrites/, err)
    assert_equal "other\n", File.read(File.join(into, "output/my_show/history.yml"))
    refute File.exist?(File.join(into, ".env"))
  end

  def test_restore_force_overwrites_differing_files
    backup
    into = File.join(@dir, "busy")
    FileUtils.mkdir_p(File.join(into, "output/my_show"))
    File.write(File.join(into, "output/my_show/history.yml"), "other\n")

    code, = restore(archive_path, "--into", into, "--home", File.join(@dir, "h2"), "--force")

    assert_equal 0, code
    assert_equal File.read(File.join(@root, "output/my_show/history.yml")), File.read(File.join(into, "output/my_show/history.yml"))
  end

  def test_restore_leaves_identical_existing_files_and_proceeds
    backup
    into = File.join(@dir, "checkout")
    FileUtils.mkdir_p(File.join(into, "podcasts/my_show"))
    FileUtils.cp(File.join(@root, "podcasts/my_show/guidelines.md"), File.join(into, "podcasts/my_show/guidelines.md"))
    File.write(File.join(into, "unrelated.txt"), "x")

    code, out, = restore(archive_path, "--into", into, "--home", File.join(@dir, "h2"))

    assert_equal 0, code
    assert_match(/\(11 written, 1 already identical\)/, out)
  end

  def test_restore_dry_run_lists_targets_and_writes_nothing
    backup
    into = File.join(@dir, "dry")

    code, out, = restore(archive_path, "--into", into, "--home", File.join(@dir, "h2"), "--dry-run")

    assert_equal 0, code
    assert_match(/Would restore 12 files \(dry run, nothing written\)/, out)
    assert_includes out, "#{into}/.env [env]"
    refute File.exist?(into)
  end

  def test_restore_without_sidecar_refuses
    backup
    File.delete("#{archive_path}.sha256")

    code, _, err = restore(archive_path, "--into", File.join(@dir, "x"))

    assert_equal 1, code
    assert_match(/missing .*\.sha256 beside the archive/, err)
  end

  def test_no_secret_or_passphrase_appears_in_any_output
    outputs = [backup]
    outputs << run_cmd(PodgenCLI::BackupCommand, ["--verify", archive_path])
    outputs << restore(archive_path, "--into", File.join(@dir, "r"), "--home", File.join(@dir, "h"))
    outputs << restore(archive_path, "--into", File.join(@dir, "r"), "--home", File.join(@dir, "h"), "--dry-run")
    ENV[BackupArchive::PASSPHRASE_ENV] = "wrong-one"
    outputs << run_cmd(PodgenCLI::BackupCommand, ["--verify", archive_path])

    text = outputs.flat_map { it.drop(1) }.join

    refute_includes text, SECRET
    refute_includes text, PASSPHRASE
    refute_includes text, "wrong-one"
  end

  # --- module seams ---

  def test_read_passphrase_without_env_or_terminal_raises
    error = assert_raises(BackupArchive::Error) { BackupArchive.read_passphrase(env: {}, console: nil) }

    assert_match(/set PODGEN_BACKUP_PASSPHRASE or run from a terminal/, error.message)
  end

  def test_read_passphrase_confirm_rejects_differing_entries
    console = Object.new
    answers = %w[one two]
    console.define_singleton_method(:getpass) { |_prompt| answers.shift }

    assert_raises(BackupArchive::Error) { BackupArchive.read_passphrase(confirm: true, env: {}, console: console) }
  end

  def test_target_for_refuses_paths_outside_the_base
    ["../x", "/etc/x", "a/../../x", ""].each do |rel|
      assert_raises(BackupArchive::Error, rel) do
        BackupArchive.target_for({"base" => "root", "path" => rel}, root: @root, home: @home)
      end
    end
  end

  private

  def build_fixture
    write(@root, "podcasts/my_show/guidelines.md", "## Podcast\n- name: My Show\n", 0o640)
    write(@root, "podcasts/my_show/queue.yml", "- topic\n")
    write(@root, "output/my_show/history.yml", "---\n- date: '2026-01-01'\n")
    write(@root, "output/my_show/uploads.yml", "---\nyoutube: {}\n")
    write(@root, "output/my_show/episodes/my_show-2026-01-01_transcript.md", "Transcript\n")
    write(@root, "output/my_show/episodes/my_show-2026-01-01.mp3", "ID3fake")
    write(@root, "output/my_show/listening/my_show-2026-01-01.trim.yml", "start: 1\n")
    write(@root, "output/my_show/listening/my_show-2026-01-01.source.m4a", "fakeaudio")
    write(@root, ".docs/board.md", "board\n")
    write(@root, ".env", "ANTHROPIC_API_KEY=#{SECRET}\n", 0o600)
    write(@home, ".config/podgen/youtube_token.json", "{\"token\":\"#{SECRET}\"}", 0o644)
    write(@home, "Library/LaunchAgents/com.podcastagent.my_show.plist", "<plist/>\n")
    write(@home, "Library/LaunchAgents/com.other.app.plist", "<plist/>\n")
    write(@home, "Library/Spelling/xx_XX.dic", "1\nword\n")
    write(@home, "Library/Spelling/xx_XX.aff", "SET UTF-8\n")
  end

  def write(base, rel, content, mode = 0o644)
    path = File.join(base, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    File.chmod(mode, path)
  end

  def tamper(path)
    bytes = File.binread(path)
    bytes.setbyte(bytes.bytesize / 2, bytes.getbyte(bytes.bytesize / 2) ^ 0xFF)
    File.binwrite(path, bytes)
  end

  def archive_path
    Dir.glob(File.join(@out, "podgen-backup-*.tar.gz")).first
  end

  def manifest(path)
    BackupArchive.check(path, passphrase: PASSPHRASE)
  end

  def backup(*args)
    run_cmd(PodgenCLI::BackupCommand, ["--out", @out, "--home", @home, *args])
  end

  def restore(*args)
    run_cmd(PodgenCLI::RestoreCommand, args)
  end

  def run_cmd(klass, args)
    code = nil
    out, err = capture_io { code = klass.new(args.dup, {}).run }
    [code, out, err]
  end
end
