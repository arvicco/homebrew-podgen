# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "priority_links")

module PodgenCLI
  class AddCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      @note = nil

      require "optparse"
      OptionParser.new do |opts|
        opts.on("--note TEXT", "Add a note about this link") { |n| @note = n }
      end.parse!(args)

      @podcast_name = args.shift
      @url = args.shift
    end

    def run
      code = require_podcast!("add")
      return code if code

      unless @url
        $stderr.puts "Usage: podgen add <podcast> <url> [--note \"...\"]"
        return 2
      end

      config = PodcastConfig.new(@podcast_name)
      links = PriorityLinks.new(config.links_path)

      if links.add(@url, note: @note)
        puts "\u2713 Added to #{@podcast_name}: #{@url}"
        puts "  Note: #{@note}" if @note
        puts "  #{links.count} link(s) queued"
      else
        puts "Already queued: #{@url}"
      end

      0
    end
  end
end
