# frozen_string_literal: true

require "optparse"
require "open3"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "upload_tracker")
require_relative File.join(root, "lib", "youtube_batch")

module PodgenCLI
  # Picks one podcast from a list and uploads ONE pending YouTube episode for it,
  # rotating across the list to spread daily quota across multiple podcasts.
  # Designed to be invoked daily by `podgen schedule --youtube-batch`.
  #
  # Examples:
  #   podgen yt-batch pod_a,pod_b,pod_c
  #   podgen yt-batch pod_a,pod_b --mode round-robin
  class YtBatchCommand
    def initialize(args, options)
      @options = options
      @mode = :priority
      @max = nil

      OptionParser.new do |opts|
        opts.banner = "Usage: podgen yt-batch <pod1,pod2,...> [--mode priority|round-robin] [--max N]"
        opts.on("--mode MODE", "priority (default) or round-robin") do |m|
          @mode = m.tr("-", "_").to_sym
        end
        opts.on("--max N", Integer, "Cap uploads per tick (default: no cap)") do |n|
          @max = n
        end
      end.parse!(args)

      @pods_arg = args.shift
    end

    def run
      pods = parse_pods(@pods_arg)
      if pods.empty?
        $stderr.puts "Usage: podgen yt-batch <pod1,pod2,...> [--mode priority|round-robin]"
        return 2
      end

      batch = YoutubeBatch.new(
        podcasts: pods,
        mode: @mode,
        cursor_path: cursor_path,
        pending_lookup: method(:pending_count_for)
      )

      pod = batch.next_podcast
      if pod.nil?
        puts "All podcasts caught up on YouTube uploads."
        return 0
      end

      max_msg = @max ? " (max #{@max})" : ""
      puts "yt-batch: uploading next episode for #{pod}#{max_msg}"
      run_publish_for(pod, max: @max)
    end

    private

    def parse_pods(arg)
      return [] if arg.nil? || arg.empty?
      arg.split(",").map(&:strip).reject(&:empty?)
    end

    def cursor_path
      File.join(PodcastConfig.root, "output", "youtube_batch_cursor.yml")
    end

    def pending_count_for(pod)
      config = PodcastConfig.new(pod)
      return 0 unless config.youtube_enabled?

      playlist = config.youtube_config[:playlist] || "default"
      tracker = UploadTracker.for_config(config)
      uploaded = tracker.entries_for(:youtube, playlist)

      episodes = mp3_basenames_with_transcripts(config.episodes_dir)
      episodes.count { |b| !uploaded.key?(b) }
    rescue => e
      $stderr.puts "yt-batch: skipping #{pod} (#{e.message})"
      0
    end

    def mp3_basenames_with_transcripts(episodes_dir)
      return [] unless Dir.exist?(episodes_dir)

      Dir.glob(File.join(episodes_dir, "*.mp3")).filter_map do |mp3|
        base = File.basename(mp3, ".mp3")
        has_text = %w[_transcript.md _script.md].any? do |suffix|
          File.exist?(File.join(episodes_dir, "#{base}#{suffix}"))
        end
        base if has_text
      end
    end

    def run_publish_for(pod, max:)
      args = [File.join(PodcastConfig.root, "bin", "podgen"), "publish", pod, "--youtube"]
      args.push("--max", max.to_s) if max
      system(*args) ? 0 : 1
    end
  end
end
