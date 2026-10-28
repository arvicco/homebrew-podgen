# frozen_string_literal: true

require "optparse"
require_relative "option_dry_parse"

module PodgenCLI
  # The single definition of `podgen tweet`'s options. TweetCommand parses
  # with it; the owner guard in lib/cli.rb dry-parses with it (P8-10). Keep
  # requires light: the guard loads this before any command class.
  module TweetOptions
    def self.define(opts, options)
      opts.on("--force", "Tweet even if already tweeted") { options[:force] = true }
      opts.on("--dry-run", "Show tweet text without posting") { options[:dry_run] = true }
      opts.on("--template TEXT", "Override tweet template") { |t| options[:template] = t }
    end

    def self.dry_parse(argv)
      OptionDryParse.call(argv) { |opts, options| define(opts, options) }
    end
  end
end
