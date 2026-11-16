# frozen_string_literal: true

require "open3"
require_relative "podcast_command"
require_relative "restore_options"
require_relative "../backup_archive"

module PodgenCLI
  # `podgen restore <file> [--into ROOT] [--home DIR] [--dry-run] [--force]`
  # unpacks a `podgen backup` archive to the same relative paths (P25-3).
  # The archive is checked (digest, passphrase, every entry) before any
  # write; an existing file with other contents is refused unless --force,
  # which is an owner action inside an agent session (lib/cli.rb).
  class RestoreCommand
    include PodcastCommand

    OWNER_ACTS = [
      "Load the launchd agents: run `podgen schedule` for each show (owner-only).",
      "Re-consent YouTube from a terminal if the restored token has lapsed.",
      "Run `podgen status` and check every show reads as expected."
    ].freeze

    def initialize(args, options)
      @options = options
      @opts = {}
      OptionParser.new do |opts|
        opts.banner = "Usage: podgen restore <file> [--into ROOT] [--home DIR] [--dry-run] [--force]"
        RestoreOptions.define(opts, @opts)
      end.parse!(args)
      @file = args.shift
      reject_leftover_args!(args)
    end

    def run
      unless @file
        $stderr.puts "Usage: podgen restore <file> [--into ROOT] [--home DIR] [--dry-run] [--force]"
        return 2
      end
      raise BackupArchive::Error, "no such file: #{@file}" unless File.file?(@file)

      BackupArchive.check_sidecar!(@file)
      root = File.expand_path(@opts[:into] || PodcastConfig.root)
      home = File.expand_path(@opts[:home] || Dir.home)
      dry_run = @opts[:dry_run] || @options[:dry_run]
      result = BackupArchive.restore(@file, passphrase: BackupArchive.read_passphrase,
        root: root, home: home, force: @opts[:force], dry_run: dry_run)
      dry_run ? print_plan(result, root, home) : print_done(result, root)
      0
    rescue BackupArchive::Error => e
      $stderr.puts "restore: #{e.message}"
      1
    end

    private

    def print_plan(result, root, home)
      conflicting = result[:conflicts].map { it["name"] }
      puts "Would restore #{result[:manifest]["files"].size} files (dry run, nothing written):"
      result[:manifest]["files"].each do |meta|
        mark = conflicting.include?(meta["name"]) ? " (overwrites: contents differ)" : ""
        puts "  #{BackupArchive.target_for(meta, root: root, home: home)} [#{meta["class"]}]#{mark}"
      end
    end

    def print_done(result, root)
      files = result[:manifest]["files"]
      counts = BackupArchive.counts(files)
      puts "Restored #{files.size} files into #{root} (#{result[:written]} written, #{result[:unchanged]} already identical)"
      puts "  " + BackupArchive::CLASSES.keys.filter_map { "#{it} #{counts[it]}" if counts.key?(it) }.join(", ")
      puts "Manifest compared with disk: every file matches its digest"
      bundle_install(root)
      puts "Left for the owner:"
      OWNER_ACTS.each_with_index { |act, i| puts "  #{i + 1}. #{act}" }
    end

    # Installs the gems when the target is a checkout whose bundle is not
    # satisfied; a target without a Gemfile is skipped.
    def bundle_install(root)
      return unless File.file?(File.join(root, "Gemfile"))

      _out, _err, status = Open3.capture3("bundle", "check", chdir: root)
      return if status.success?

      _out, err, status = Open3.capture3("bundle", "install", chdir: root)
      puts status.success? ? "Gems installed (bundle install)" : "WARN: bundle install failed: #{err.lines.last&.strip}"
    rescue SystemCallError => e
      puts "WARN: bundle not run: #{e.class}"
    end
  end
end
