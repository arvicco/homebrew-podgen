# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require "optparse"
require "date"
require "fileutils"
require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "cli", "episode_selector")
require_relative File.join(root, "lib", "logger")
require_relative File.join(root, "lib", "script_artifact")
require_relative File.join(root, "lib", "script_renderer")

module PodgenCLI
  # Re-renders the markdown view of a script (and any per-language translations)
  # from the canonical JSON artifact when present, falling back to re-rendering
  # the existing markdown through the current ## Links config (lossy on
  # per-segment sources for legacy episodes). Free, deterministic, no API calls.
  class RenderCommand
    include PodcastCommand
    include EpisodeSelector

    def initialize(args, options)
      @options = options
      @lang_filter = nil

      OptionParser.new do |opts|
        opts.banner = "Usage: podgen render <podcast> [<date>] [--date DATE | --last N] [--lang LANG]"
        add_episode_selection_options!(opts)
        opts.on("--lang LANG", "Only re-render this language (default: all)") { |l| @lang_filter = l.downcase }
      end.parse!(args)

      @podcast_name = args.shift
      extract_positional_date!(args)
      reject_leftover_args!(args)
      validate_episode_selection!
    end

    def run
      code = require_podcast!("render <podcast>")
      return code if code

      config = load_config!
      logger = PodcastAgent::Logger.new(log_path: config.log_path(episode_date || Date.today), verbosity: @options[:verbosity])
      PodcastAgent.logger = logger

      md_paths = discover_markdown_paths(config.episodes_dir)
      md_paths = filter_by_date(md_paths, episode_date, episode_suffix) if episode_date
      md_paths = filter_by_last_n(md_paths, last_n) if last_n
      md_paths = filter_by_lang(md_paths, @lang_filter) if @lang_filter

      if md_paths.empty?
        msg = "No script files found#{episode_date ? " for #{episode_date}#{episode_suffix}" : ''}#{@lang_filter ? " (lang=#{@lang_filter})" : ''}"
        logger.log(msg)
        $stderr.puts msg unless @options[:verbosity] == :quiet
        return 1
      end

      links_config = config.links_enabled? ? config.links_config : nil
      rendered = 0

      md_paths.each do |md_path|
        script, source = ScriptArtifact.read_with_fallback(md_path)
        unless script
          logger.error("Skipping unreadable: #{md_path}")
          next
        end
        File.write(md_path, ScriptRenderer.render(script, links_config: links_config))
        logger.log("Rendered #{md_path} (from #{source == :json ? 'JSON' : 'legacy markdown'})")
        rendered += 1
      end

      logger.log("Re-rendered #{rendered} script(s)")
      puts "Re-rendered #{rendered} script(s)" unless @options[:verbosity] == :quiet
      0
    end

    private

    def discover_markdown_paths(episodes_dir)
      Dir.glob(File.join(episodes_dir, "*_script.md")).sort
    end

    # When suffix is given, narrow to that exact episode (plus its language
    # variants); otherwise match every basename on the day.
    def filter_by_date(paths, date, suffix)
      date_str = date.strftime("%Y-%m-%d")
      if suffix
        paths.select do |p|
          base = File.basename(p, "_script.md").sub(/-[a-z]{2}\z/, "")
          base.end_with?("-#{date_str}#{suffix}")
        end
      else
        paths.select { |p| File.basename(p).include?(date_str) }
      end
    end

    # Group paths by English basename (strip -<lang> suffix), keep the N most
    # recent groups (English + all language variants for those episodes).
    def filter_by_last_n(paths, n)
      groups = paths.group_by do |p|
        base = File.basename(p, "_script.md")
        base.sub(/-[a-z]{2}\z/, "")
      end
      groups.keys.sort.last(n).flat_map { |k| groups[k] }
    end

    def filter_by_lang(paths, lang)
      paths.select do |p|
        base = File.basename(p, "_script.md")
        if lang == "en"
          !base.match?(/-[a-z]{2}\z/)
        else
          base.end_with?("-#{lang}")
        end
      end
    end
  end
end
