# frozen_string_literal: true

require "digest"
require "fileutils"
require "io/console"
require "json"
require "open3"
require "rubygems/package"
require "securerandom"
require "tmpdir"
require "zlib"

# One encrypted archive holding everything an installation needs to run
# (P25-3): show configs, ledgers, output text artifacts, boards, .env, the
# token directory, the launchd plists and the Hunspell dictionaries; media
# only on request. The stream is tar (Gem::Package::TarWriter) -> gzip ->
# `openssl enc -aes-256-cbc -pbkdf2`; the passphrase reaches openssl only
# through its child environment (`-pass env:NAME`), never argv.
#
# Tar entry names are short indexes ("f/000001"); the real relative paths
# live in manifest.json, the first entry. So no file name length limit
# applies, and no tar name ever decides where a file is written.
module BackupArchive
  class Error < StandardError; end

  PASSPHRASE_ENV = "PODGEN_BACKUP_PASSPHRASE"
  FORMAT = 1
  MANIFEST_NAME = "manifest.json"
  CHUNK = 1 << 20
  MEDIA_EXTENSIONS = %w[
    .mp3 .mp4 .m4a .m4v .mov .webm .wav .aif .aiff .flac .ogg .opus .aac
    .png .jpg .jpeg .gif .webp
  ].freeze

  # class => [base, glob patterns, filter]; base :root is the project root
  # (PODGEN_ROOT), :home the user's home directory.
  CLASSES = {
    "guidelines" => [:root, ["podcasts/**/*"], nil],
    "ledgers" => [:root, ["output/*/history.yml", "output/*/uploads.yml"], nil],
    "output" => [:root, ["output/**/*"], :text],
    "media" => [:root, ["output/**/*"], :media],
    "boards" => [:root, [".docs/**/*"], nil],
    "env" => [:root, [".env"], nil],
    "tokens" => [:home, [".config/podgen/**/*"], nil],
    "schedule" => [:home, ["Library/LaunchAgents/com.podcastagent.*.plist"], nil],
    "dictionaries" => [:home, ["Library/Spelling/*.dic", "Library/Spelling/*.aff"], nil]
  }.freeze

  # A backup without these could not run a show: it aborts instead.
  REQUIRED_CLASSES = %w[guidelines ledgers env].freeze
  # Restored with mode 0600 whatever the source mode was.
  SECRET_CLASSES = %w[env tokens].freeze
  LEDGER_NAMES = %w[history.yml uploads.yml].freeze

  module_function

  # The passphrase from PODGEN_BACKUP_PASSPHRASE, else a terminal prompt
  # (no echo; asked twice when confirm). Never taken from argv.
  def read_passphrase(confirm: false, env: ENV, console: IO.console)
    value = env[PASSPHRASE_ENV]
    return value unless value.to_s.empty?
    raise Error, "set #{PASSPHRASE_ENV} or run from a terminal to be prompted for the passphrase" unless console

    first = console.getpass("Backup passphrase: ")
    raise Error, "empty passphrase" if first.to_s.empty?
    raise Error, "passphrases differ" if confirm && console.getpass("Repeat passphrase: ") != first

    first
  end

  # [{"class", "base", "path", "source"}] for every regular file in the
  # selected classes, in a stable order.
  def collect(root:, home:, with_media: false)
    bases = {root: root, home: home}
    CLASSES.flat_map do |klass, (base, patterns, filter)|
      next [] if klass == "media" && !with_media

      dir = bases.fetch(base)
      rels = patterns.flat_map { Dir.glob(it, File::FNM_DOTMATCH, base: dir) }.uniq.sort
      rels.filter_map do |rel|
        next if rel.split("/").any? { %w[. ..].include?(it) }

        source = File.join(dir, rel)
        next unless File.file?(source) && !File.symlink?(source)
        next unless keep?(filter, rel)

        {"class" => klass, "base" => base.to_s, "path" => rel, "source" => source}
      end
    end
  end

  def keep?(filter, rel)
    media = MEDIA_EXTENSIONS.include?(File.extname(rel).downcase)
    case filter
    when :text then !media && !(rel.count("/") == 2 && LEDGER_NAMES.include?(File.basename(rel)))
    when :media then media
    else true
    end
  end

  def missing_required(files)
    REQUIRED_CLASSES - files.map { it["class"] }
  end

  def counts(files)
    files.each_with_object(Hash.new(0)) { |f, h| h[f["class"]] += 1 }
  end

  def file_digest(path)
    Digest::SHA256.file(path).hexdigest
  end

  # Writes the encrypted archive to `path` (which must not exist yet).
  # Every file is digested twice — for the manifest, then while it streams
  # into the archive — and a file that changed in between aborts the
  # backup, so the manifest never describes bytes the archive lacks.
  def write(files, path, passphrase:, meta: {})
    entries = files.each_with_index.map do |f, i|
      stat = File.stat(f["source"])
      f.merge("name" => format("f/%06d", i + 1), "size" => stat.size,
        "mode" => format("%04o", stat.mode & 0o777), "sha256" => file_digest(f["source"]))
    end
    manifest = meta.merge("format" => FORMAT,
      "files" => entries.map { it.except("source") })
    json = JSON.pretty_generate(manifest)

    run_openssl(%W[enc -aes-256-cbc -pbkdf2 -salt -out #{path}], passphrase) do |stdin, _stdout|
      gz = Zlib::GzipWriter.new(stdin)
      tar = Gem::Package::TarWriter.new(gz)
      tar.add_file_simple(MANIFEST_NAME, 0o600, json.bytesize) { it.write(json) }
      entries.each { |e| pack(tar, e) }
      tar.close
      gz.close
    end
    manifest
  end

  def pack(tar, entry)
    digest = Digest::SHA256.new
    written = 0
    tar.add_file_simple(entry["name"], 0o600, entry["size"]) do |io|
      File.open(entry["source"], "rb") do |src|
        while (chunk = src.read(CHUNK))
          raise Error, "#{entry["path"]} changed while packing" if written + chunk.bytesize > entry["size"]

          io.write(chunk)
          digest << chunk
          written += chunk.bytesize
        end
      end
    end
    return if written == entry["size"] && digest.hexdigest == entry["sha256"]

    raise Error, "#{entry["path"]} changed while packing"
  end

  # Reads the archive, yielding (manifest, entry, io) for every file entry.
  # Raises Error when the passphrase is wrong or the archive is damaged,
  # with no detail from openssl (whose stderr is never shown).
  def each_entry(path, passphrase:)
    manifest = nil
    run_openssl(%W[enc -d -aes-256-cbc -pbkdf2 -in #{path}], passphrase) do |stdin, stdout|
      stdin.close
      Gem::Package::TarReader.new(Zlib::GzipReader.new(stdout)).each do |entry|
        if manifest.nil?
          raise Error, "no manifest" unless entry.full_name == MANIFEST_NAME

          manifest = JSON.parse(entry.read || "")
          raise Error, "unknown backup format" unless manifest["format"] == FORMAT
        else
          yield manifest, entry
        end
      end
    end
    raise Error, "no manifest" if manifest.nil?

    manifest
  rescue Zlib::Error, Gem::Package::TarInvalidError, JSON::ParserError, EOFError, ArgumentError
    raise Error, "cannot read #{File.basename(path)}: wrong passphrase or damaged archive"
  end

  # Decrypts and digests every entry against the manifest without writing
  # anything. Returns the manifest.
  def check(path, passphrase:)
    seen = {}
    manifest = each_entry(path, passphrase: passphrase) do |m, entry|
      meta = m["files"].find { it["name"] == entry.full_name }
      raise Error, "entry not in manifest: #{entry.full_name}" unless meta

      digest = Digest::SHA256.new
      size = 0
      while (chunk = entry.read(CHUNK))
        digest << chunk
        size += chunk.bytesize
      end
      raise Error, "digest mismatch: #{meta["path"]}" unless size == meta["size"] && digest.hexdigest == meta["sha256"]

      seen[entry.full_name] = true
    end
    missing = manifest["files"].reject { seen[it["name"]] }
    raise Error, "archive lacks #{missing.size} manifest entr#{(missing.size == 1) ? "y" : "ies"}" if missing.any?

    manifest
  end

  # Target path of a manifest entry, refusing anything that would land
  # outside its base directory.
  def target_for(meta, root:, home:)
    rel = meta["path"].to_s
    parts = rel.split("/")
    if rel.empty? || rel.start_with?("/") || parts.any? { %w[. ..].include?(it) || it.empty? }
      raise Error, "unsafe path in manifest: #{rel.inspect}"
    end

    base = {"root" => root, "home" => home}.fetch(meta["base"]) { raise Error, "unknown base in manifest" }
    File.join(base, rel)
  end

  def mode_for(meta)
    SECRET_CLASSES.include?(meta["class"]) ? 0o600 : meta["mode"].to_i(8)
  end

  # Existing targets whose contents differ from the archive's.
  def conflicts(manifest, root:, home:)
    manifest["files"].select do |meta|
      target = target_for(meta, root: root, home: home)
      File.exist?(target) && !(File.file?(target) && file_digest(target) == meta["sha256"])
    end
  end

  # Restores the archive under root/home. A verification pass runs first
  # (nothing is written from an archive that does not check out); an
  # existing file with other contents is refused unless force. Identical
  # existing files are left as they are (mode set). Returns a Hash with
  # :manifest, :written, :unchanged and :conflicts.
  def restore(path, passphrase:, root:, home:, force: false, dry_run: false)
    manifest = check(path, passphrase: passphrase)
    found = conflicts(manifest, root: root, home: home)
    if found.any? && !force
      raise Error, "refusing to overwrite #{found.size} existing file(s) with other contents " \
        "(first: #{found.first["path"]}); --force overwrites"
    end

    result = {manifest: manifest, written: 0, unchanged: 0, conflicts: found}
    return result if dry_run

    each_entry(path, passphrase: passphrase) do |_m, entry|
      meta = manifest["files"].find { it["name"] == entry.full_name } # the checked manifest, not the re-read one
      raise Error, "entry not in manifest: #{entry.full_name}" unless meta

      target = target_for(meta, root: root, home: home)
      if File.file?(target) && file_digest(target) == meta["sha256"]
        File.chmod(mode_for(meta), target)
        result[:unchanged] += 1
        next
      end
      extract(entry, target, meta)
      result[:written] += 1
    end
    compare!(manifest, root: root, home: home)
    result
  end

  # Writes one entry through a temp file, renamed into place only when its
  # bytes match the manifest entry. Parent directories created for a
  # secret class are private.
  def extract(entry, target, meta)
    FileUtils.mkdir_p(File.dirname(target), mode: SECRET_CLASSES.include?(meta["class"]) ? 0o700 : nil)
    tmp = "#{target}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
    digest = Digest::SHA256.new
    File.open(tmp, "wb", 0o600) do |out|
      while (chunk = entry.read(CHUNK))
        out.write(chunk)
        digest << chunk
      end
    end
    raise Error, "digest mismatch: #{meta["path"]}" unless digest.hexdigest == meta["sha256"]

    File.chmod(mode_for(meta), tmp)
    File.rename(tmp, target)
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end

  # Every manifest entry on disk with its digest; raises naming the count
  # per class that does not match.
  def compare!(manifest, root:, home:)
    bad = manifest["files"].reject do |meta|
      target = target_for(meta, root: root, home: home)
      File.file?(target) && file_digest(target) == meta["sha256"]
    end
    return if bad.empty?

    raise Error, "restored files differ from the manifest: " +
      counts(bad).map { |k, n| "#{k} #{n}" }.join(", ")
  end

  # Round-trips the archive into a temp directory and compares it with the
  # manifest (restore runs the disk compare). Returns the manifest.
  def verify(path, passphrase:)
    Dir.mktmpdir("podgen-backup-verify") do |dir|
      restore(path, passphrase: passphrase, root: File.join(dir, "root"), home: File.join(dir, "home"))[:manifest]
    end
  end

  def sidecar_path(path)
    "#{path}.sha256"
  end

  def sidecar_line(digest, path)
    "#{digest}  #{File.basename(path)}\n"
  end

  # The archive's digest against its .sha256 sidecar.
  def check_sidecar!(path)
    sidecar = sidecar_path(path)
    raise Error, "missing #{File.basename(sidecar)} beside the archive" unless File.file?(sidecar)

    expected = File.read(sidecar)[/\A\h{64}/]
    raise Error, "#{File.basename(path)} does not match its .sha256 (damaged or altered)" unless expected == file_digest(path)
  end

  # Runs openssl with the passphrase in its environment only. The block
  # gets (stdin, stdout); openssl's stderr is collected and discarded so
  # nothing it says reaches the terminal. Raises Error on failure.
  def run_openssl(args, passphrase)
    raise Error, "empty passphrase" if passphrase.to_s.empty?

    env = {PASSPHRASE_ENV => passphrase}
    failed = nil
    status = Open3.popen3(env, "openssl", *args, "-pass", "env:#{PASSPHRASE_ENV}") do |stdin, stdout, stderr, wait|
      drain = Thread.new { stderr.read }
      begin
        yield stdin, stdout
        stdout.read
      rescue Error, Zlib::Error, Gem::Package::TarInvalidError, JSON::ParserError, ArgumentError, IOError, Errno::EPIPE => e
        failed = e
        stop(wait.pid)
      ensure
        stdin.close unless stdin.closed?
      end
      drain.join
      wait.value
    end
    raise failed if failed.is_a?(Error)
    raise Error, "openssl failed: wrong passphrase or damaged archive" if failed || !status.success?
  rescue Errno::ENOENT
    raise Error, "openssl not found"
  end

  def stop(pid)
    Process.kill("TERM", pid)
  rescue Errno::ESRCH
    nil
  end
end
