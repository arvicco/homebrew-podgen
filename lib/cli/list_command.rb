# frozen_string_literal: true

require_relative "../podcast_config"
require_relative "podcast_command"

module PodgenCLI
  class ListCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      # list takes no arguments; reject leftovers like every other command (P4-6).
      reject_leftover_args!(args)
    end

    def run
      podcasts = PodcastConfig.available

      if podcasts.empty?
        puts "No podcasts found. Create a directory under podcasts/ with guidelines.md and queue.yml."
        return 0
      end

      puts "Available podcasts:"
      podcasts.each do |name|
        config = PodcastConfig.new(name)
        if File.exist?(config.guidelines_path)
          title = config.title
          if title != name
            puts "  #{name} — #{title}"
          else
            puts "  #{name}"
          end
        else
          puts "  #{name} (missing guidelines.md)"
        end
      end
      0
    end
  end
end
