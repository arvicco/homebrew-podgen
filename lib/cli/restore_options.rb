# frozen_string_literal: true

require "optparse"
require_relative "option_dry_parse"

module PodgenCLI
  # The single definition of `podgen restore`'s options. RestoreCommand
  # parses with it; the owner guard in lib/cli.rb dry-parses with it, so
  # `restore --force` is refused exactly when the real parser would read
  # --force (P25-3). Keep requires light: the guard loads this first.
  module RestoreOptions
    def self.define(opts, options)
      opts.on("--into ROOT", "Project root to restore into (default: the current project root)") { |v| options[:into] = v }
      opts.on("--home DIR", "Home directory for tokens, launchd plists and dictionaries (default: ~)") { |v| options[:home] = v }
      opts.on("--dry-run", "List what would be written; write nothing") { options[:dry_run] = true }
      opts.on("--force", "Overwrite existing files whose contents differ") { options[:force] = true }
    end

    def self.dry_parse(argv)
      OptionDryParse.call(argv) { |opts, options| define(opts, options) }
    end
  end
end
