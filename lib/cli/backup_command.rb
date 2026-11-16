# frozen_string_literal: true

require "open3"
require "securerandom"
require_relative "podcast_command"
require_relative "../atomic_writer"
require_relative "../backup_archive"
require_relative "../format_helper"

module PodgenCLI
  # `podgen backup [--out DIR] [--with-media]` writes one encrypted archive
  # plus its .sha256 and proves it restorable before it lands;
  # `podgen backup --verify <file>` re-runs that proof on an existing one
  # (P25-3). Only reads the installation; writes one new file pair.
  class BackupCommand
    include PodcastCommand

    CODE_ROOT = File.expand_path("../..", __dir__)

    def initialize(args, options)
      @options = options
      @with_media = false
      OptionParser.new do |opts|
        opts.banner = "Usage: podgen backup [--out DIR] [--with-media] [--home DIR] | podgen backup --verify <file>"
        opts.on("--out DIR", "Directory for the archive (default: current directory)") { |v| @out_dir = v }
        opts.on("--with-media", "Include mp3/mp4/images/source audio under output/") { @with_media = true }
        opts.on("--home DIR", "Home directory to read tokens, launchd plists and dictionaries from (default: ~)") { |v| @home = v }
        opts.on("--verify FILE", "Round-trip an existing archive into a temp dir and compare it with its manifest") { |v| @verify = v }
      end.parse!(args)
      reject_leftover_args!(args)
    end

    def run
      @verify ? run_verify : run_backup
    rescue BackupArchive::Error => e
      $stderr.puts "backup: #{e.message}"
      1
    end

    private

    def run_verify
      raise BackupArchive::Error, "no such file: #{@verify}" unless File.file?(@verify)

      BackupArchive.check_sidecar!(@verify)
      manifest = BackupArchive.verify(@verify, passphrase: BackupArchive.read_passphrase)
      puts "Verified: #{@verify} (#{manifest["files"].size} files round-tripped)"
      print_counts(manifest["files"])
      0
    end

    def run_backup
      root = PodcastConfig.root
      date = Time.now.utc.strftime("%Y-%m-%d")
      path = File.join(File.expand_path(@out_dir || Dir.pwd), "podgen-backup-#{date}.tar.gz")
      sidecar = BackupArchive.sidecar_path(path)
      raise BackupArchive::Error, "#{path} already exists; move it or pass --out" if File.exist?(path) || File.exist?(sidecar)

      files = BackupArchive.collect(root: root, home: @home || Dir.home, with_media: @with_media)
      missing = BackupArchive.missing_required(files)
      raise BackupArchive::Error, "nothing written: no files for #{missing.join(", ")} under #{root}" if missing.any?

      passphrase = BackupArchive.read_passphrase(confirm: true)
      write_verified(files, path, passphrase)
      puts "Backup: #{path} (#{FormatHelper.format_size(File.size(path))})"
      print_counts(files)
      puts "Verified: #{files.size} files round-tripped#{" (media excluded; --with-media includes it)" unless @with_media}"
      0
    end

    # The archive lands under its name only after it round-tripped.
    def write_verified(files, path, passphrase)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      BackupArchive.write(files, tmp, passphrase: passphrase, meta: meta)
      BackupArchive.verify(tmp, passphrase: passphrase)
      digest = BackupArchive.file_digest(tmp)
      File.rename(tmp, path)
      AtomicWriter.write(BackupArchive.sidecar_path(path), BackupArchive.sidecar_line(digest, path))
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def meta
      {
        "created" => Time.now.utc.strftime("%Y-%m-%d"),
        "podgen_sha" => first_line("git", "-C", CODE_ROOT, "rev-parse", "HEAD"),
        "ruby" => RUBY_VERSION,
        "ffmpeg" => first_line("ffmpeg", "-version"),
        "zone" => Time.now.zone,
        "with_media" => @with_media
      }
    end

    def first_line(*cmd)
      out, _err, status = Open3.capture3(*cmd)
      status.success? ? out.lines.first&.strip : nil
    rescue SystemCallError
      nil
    end

    def print_counts(files)
      counts = BackupArchive.counts(files)
      puts "  " + BackupArchive::CLASSES.keys.filter_map { "#{it} #{counts[it]}" if counts.key?(it) }.join(", ")
    end
  end
end
