# frozen_string_literal: true

require "optparse"

module PodgenCLI
  # Dry parse for the owner guard in lib/cli.rb (P8-10): parses a COPY of
  # argv with a command's own option definitions (yielded parser + options
  # hash) and returns the options hash that parse would build, or nil when
  # the real parse would fail (invalid, ambiguous or needless option, bad
  # value) or would print and exit instead of running (--help, --version).
  module OptionDryParse
    def self.call(argv)
      options = {}
      parser = OptionParser.new { yield it, options }
      # Shadow the built-in help/version switches so a dry parse never prints.
      %w[--help --version].each { |name| parser.on(name) { throw :option_dry_parse_exit } }
      parsed = catch(:option_dry_parse_exit) do
        parser.parse!(argv.dup)
        true
      end
      parsed ? options : nil
    rescue OptionParser::ParseError, ArgumentError, SystemExit
      nil
    end
  end
end
