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
      @missing_only = false
      @overrides = {}

      OptionParser.new do |opts|
        opts.on("--missing-only", "Only generate covers for episodes without one") { @missing_only = true }
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
      # Second arg: episode id (date pattern) or manual title
      second = args.first
      if second && second.match?(/\d{4}-\d{2}-\d{2}/)
        @episode_id = args.shift
        @title = nil
      else
        @episode_id = nil
        @title = args.join(" ")
      end
      @dry_run = options[:dry_run] || false
    end

    def run
      code = require_podcast!("cover")
      return code if code

      config = load_config!

      # Manual title mode: podgen cover <podcast> My Custom Title
      if @title && !@title.empty?
        return run_manual_title(config)
      end

      # Episode mode (single or batch)
      return run_episode_mode(config)
    end

    private

    def run_manual_title(config)
      base_image, cover_opts = resolve_cover_config(config)
      return 1 unless base_image

      output = @output_path || "cover_preview.jpg"

      CoverAgent.new.generate(
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

    def run_episode_mode(config)
      episodes = resolve_episodes(config)
      if episodes.empty?
        $stderr.puts "No episodes found#{@episode_id ? " matching '#{@episode_id}'" : ""}"
        return 1
      end

      base_image, cover_opts = resolve_cover_config(config)
      return 1 unless base_image

      agent = CoverAgent.new
      puts "Generating covers for #{episodes.length} episode(s)"

      processed = 0
      episodes.each do |ep|
        if @dry_run
          puts "  [dry-run] #{ep[:basename]}: #{ep[:title]}"
          next
        end

        puts "  #{ep[:basename]}..."
        agent.generate(
          title: ep[:title],
          base_image: base_image,
          output_path: ep[:output],
          options: cover_opts
        )
        processed += 1
      end

      puts "Generated #{processed} cover(s)" unless @dry_run
      0
    rescue => e
      $stderr.puts "Cover generation failed: #{e.message}"
      1
    end

    def resolve_episodes(config)
      dir = config.episodes_dir
      pattern = if @episode_id
        File.join(dir, "*#{@episode_id}_transcript.md")
      else
        File.join(dir, "*_transcript.md")
      end

      Dir.glob(pattern).sort.filter_map do |path|
        basename = File.basename(path, "_transcript.md")

        if @missing_only && !Dir.glob(File.join(dir, "#{basename}_cover.*")).empty?
          next
        end

        first_line = File.foreach(path).first
        title = first_line&.strip&.sub(/^#\s+/, "")
        next unless title && !title.empty?

        output = File.join(dir, "#{basename}_cover.jpg")
        { basename: basename, title: title, output: output }
      end
    end

    def resolve_cover_config(config)
      base_image = @overrides.delete(:base_image) || config.cover_base_image
      unless base_image && File.exist?(base_image)
        $stderr.puts "No base_image available for cover generation."
        $stderr.puts "  Configure in guidelines.md under ## Image, or pass --base-image PATH"
        return nil
      end

      cover_opts = config.cover_options.merge(@overrides)
      [base_image, cover_opts]
    end
  end
end
