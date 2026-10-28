# frozen_string_literal: true

require "optparse"
require_relative "option_dry_parse"

module PodgenCLI
  # The single definition of `podgen publish`'s options. PublishCommand
  # parses with it; the owner guard in lib/cli.rb dry-parses with it, so its
  # dry-run exemption is exactly what the real parser reads (P8-10). Keep
  # requires light: the guard loads this before any command class.
  module PublishOptions
    # The block receives --date's value (the command keeps it as its
    # episode id, not in options).
    def self.define(opts, options, &on_date)
      opts.on("--lingq", "Publish to LingQ instead of R2") { options[:lingq] = true }
      opts.on("--youtube", "Publish to YouTube") { options[:youtube] = true }
      opts.on("--all", "Publish to every configured target (R2 + LingQ + YouTube); unconfigured ones are skipped") { options[:all] = true }
      opts.on("--force", "Re-upload even if already tracked") { options[:force] = true }
      opts.on("--newest", "Publish newest episodes first") { options[:newest] = true }
      opts.on("--max N", Integer, "Cap number of YouTube uploads per invocation") { |n| options[:max] = n }
      opts.on("--dry-run", "Show what would be published") { options[:dry_run] = true }
      opts.on("--date DATE", "Episode date (YYYY-MM-DD)") { |v| on_date&.call(v) }
    end

    def self.dry_parse(argv)
      OptionDryParse.call(argv) { |opts, options| define(opts, options) }
    end
  end
end
