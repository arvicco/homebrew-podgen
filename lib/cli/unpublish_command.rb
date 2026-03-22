# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "cli", "podcast_command")

module PodgenCLI
  class UnpublishCommand
    include PodcastCommand
    REQUIRED_ENV = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET].freeze

    def initialize(args, options)
      @options = options
      @podcast_name = args.shift
    end

    def run
      code = require_podcast!("unpublish")
      return code if code

      missing = REQUIRED_ENV.select { |var| ENV[var].nil? || ENV[var].empty? }
      unless missing.empty?
        $stderr.puts "Missing required environment variables: #{missing.join(', ')}"
        return 2
      end

      unless rclone_available?
        $stderr.puts "rclone is not installed. Install with: brew install rclone"
        return 2
      end

      bucket = ENV["R2_BUCKET"]
      dest = "r2:#{bucket}/#{@podcast_name}/"

      args = ["rclone", "purge", dest]
      args.push("--dry-run") if @options[:dry_run]
      args.push("-v") if @options[:verbosity] == :verbose

      if @options[:dry_run]
        puts "Would remove all files from #{dest} (dry-run)"
      else
        puts "Removing all files from #{dest}"
      end

      success = run_rclone(args)

      unless success
        $stderr.puts "rclone purge failed."
        return 1
      end

      if @options[:dry_run]
        puts "Done (dry-run, no files removed)."
      else
        puts "Unpublished '#{@podcast_name}' from R2."
      end
      0
    end

    private

    def run_rclone(args)
      rclone_env = {
        "RCLONE_CONFIG_R2_TYPE" => "s3",
        "RCLONE_CONFIG_R2_PROVIDER" => "Cloudflare",
        "RCLONE_CONFIG_R2_ACCESS_KEY_ID" => ENV["R2_ACCESS_KEY_ID"],
        "RCLONE_CONFIG_R2_SECRET_ACCESS_KEY" => ENV["R2_SECRET_ACCESS_KEY"],
        "RCLONE_CONFIG_R2_ENDPOINT" => ENV["R2_ENDPOINT"],
        "RCLONE_CONFIG_R2_ACL" => "private"
      }
      system(rclone_env, *args)
    end

    def rclone_available?
      _out, _err, status = Open3.capture3("rclone", "--version")
      status.success?
    rescue Errno::ENOENT
      false
    end
  end
end
