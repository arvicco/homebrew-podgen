# frozen_string_literal: true

require "optparse"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "agents", "cover_agent")

module PodgenCLI
  class CoverCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      @output_path = nil
      @overrides = {}

      OptionParser.new do |opts|
        opts.on("--base-image PATH", "Override base image") { |v| @overrides[:base_image] = v }
        opts.on("--output PATH", "Output file path") { |v| @output_path = v }
        opts.on("--font NAME", "Override font family") { |v| @overrides[:font] = v }
        opts.on("--font-color COLOR", "Override font color") { |v| @overrides[:font_color] = v }
        opts.on("--font-size N", Integer, "Override font size") { |v| @overrides[:font_size] = v }
        opts.on("--gravity POS", "Override gravity (Center, South, etc.)") { |v| @overrides[:gravity] = v }
        opts.on("--x-offset N", Integer, "Override horizontal offset") { |v| @overrides[:x_offset] = v }
        opts.on("--y-offset N", Integer, "Override vertical offset") { |v| @overrides[:y_offset] = v }
      end.parse!(args)

      @podcast_name = args.shift
      @title = args.join(" ") # remaining args are the title
    end

    def run
      code = require_podcast!("cover")
      return code if code

      if @title.to_s.strip.empty?
        $stderr.puts "Usage: podgen cover <podcast> <title> [options]"
        $stderr.puts
        $stderr.puts "Options:"
        $stderr.puts "  --base-image PATH   Override base image"
        $stderr.puts "  --output PATH       Output file path (default: cover_preview.jpg)"
        $stderr.puts "  --font NAME         Override font family"
        $stderr.puts "  --font-color COLOR  Override font color (e.g. #2B3A67)"
        $stderr.puts "  --font-size N       Override font size in pixels"
        $stderr.puts "  --gravity POS       Override gravity (Center, South, etc.)"
        $stderr.puts "  --x-offset N        Override horizontal offset"
        $stderr.puts "  --y-offset N        Override vertical offset"
        return 2
      end

      config = load_config!

      # Resolve base image: CLI override > config
      base_image = @overrides.delete(:base_image) || config.cover_base_image
      unless base_image && File.exist?(base_image)
        $stderr.puts "No base_image available for cover generation."
        $stderr.puts "  Configure in guidelines.md under ## Image, or pass --base-image PATH"
        return 1
      end

      # Merge config options with CLI overrides
      cover_opts = config.cover_options.merge(@overrides)

      output = @output_path || "cover_preview.jpg"

      agent = CoverAgent.new
      agent.generate(
        title: @title,
        base_image: base_image,
        output_path: output,
        options: cover_opts
      )

      puts "Cover generated: #{output}"
      0
    rescue => e
      $stderr.puts "Cover generation failed: #{e.message}"
      1
    end
  end
end
