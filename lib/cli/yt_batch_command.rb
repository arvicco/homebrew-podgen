# frozen_string_literal: true

require "optparse"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "upload_tracker")
require_relative File.join(root, "lib", "youtube_publisher")

module PodgenCLI
  # Iterates pending YouTube uploads across multiple podcasts in one process.
  #
  # Modes:
  #   priority    — drain pods in list order; later pods only run when earlier
  #                 ones are caught up (or --max bound is reached).
  #   round-robin — upload one episode per pod per round, looping until all
  #                 pods are drained or --max / rate-limit halts.
  #
  # --max caps the TOTAL uploads across the tick (not per-pod). Without it,
  # the loop runs until everything is uploaded or YouTube rate-limits us.
  #
  # Replaces the old "one pod per tick, one cursor file" design which left
  # later pods starved when earlier ones always had pending work.
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
        opts.on("--max N", Integer, "Cap TOTAL uploads across the tick (default: no cap)") do |n|
          @max = n
        end
      end.parse!(args)

      @pods_arg = args.shift
    end

    def run
      pods = parse_pods(@pods_arg)
      if pods.empty?
        $stderr.puts "Usage: podgen yt-batch <pod1,pod2,...> [--mode priority|round-robin] [--max N]"
        return 2
      end

      pending_pods = pods.select { |pod| pending_count_for(pod) > 0 }
      if pending_pods.empty?
        puts "All podcasts caught up on YouTube uploads."
        return 0
      end

      max_msg = @max ? " (max #{@max})" : ""
      puts "yt-batch: #{@mode} mode across #{pods.join(', ')}#{max_msg}"

      tick = case @mode
             when :priority    then run_priority(pods)
             when :round_robin then run_round_robin(pods)
             else
               $stderr.puts "Unknown mode: #{@mode}"
               return 2
             end

      print_summary(tick)
      0
    end

    private

    Tick = Struct.new(:per_pod, :rate_limited, keyword_init: true)

    def run_priority(pods)
      remaining = @max
      per_pod = Hash.new { |h, k| h[k] = { uploaded: 0, errors: 0 } }
      rate_limited = false

      pods.each do |pod|
        break if remaining == 0
        next if pending_count_for(pod) == 0

        result = run_publish_for(pod, max: remaining)
        per_pod[pod][:uploaded] += result.uploaded
        per_pod[pod][:errors] += result.errors.length
        remaining -= result.uploaded if remaining

        if result.rate_limited
          rate_limited = true
          break
        end
      end

      Tick.new(per_pod: per_pod, rate_limited: rate_limited)
    end

    def run_round_robin(pods)
      remaining = @max
      per_pod = Hash.new { |h, k| h[k] = { uploaded: 0, errors: 0 } }
      rate_limited = false
      drained = {}

      catch(:stop) do
        loop do
          uploaded_this_round = 0
          pods.each do |pod|
            throw :stop if remaining == 0
            next if drained[pod]
            if pending_count_for(pod) == 0
              drained[pod] = true
              next
            end

            result = run_publish_for(pod, max: 1)
            per_pod[pod][:uploaded] += result.uploaded
            per_pod[pod][:errors] += result.errors.length
            remaining -= result.uploaded if remaining
            uploaded_this_round += result.uploaded

            if result.rate_limited
              rate_limited = true
              throw :stop
            end

            # Drained when nothing left, OR when this round made no progress
            # (e.g. a permanently-skipping episode like "no cover image"):
            # avoid hammering the same broken pod every round.
            if pending_count_for(pod) == 0 || result.uploaded == 0
              drained[pod] = true
            end
          end
          break if uploaded_this_round == 0
        end
      end

      Tick.new(per_pod: per_pod, rate_limited: rate_limited)
    end

    def parse_pods(arg)
      return [] if arg.nil? || arg.empty?
      arg.split(",").map(&:strip).reject(&:empty?)
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
      config = PodcastConfig.new(pod)
      YouTubePublisher.new(
        config: config,
        options: { max: max, verbosity: @options[:verbosity] }
      ).run
    rescue => e
      $stderr.puts "yt-batch: publisher error for #{pod} (#{e.message})"
      YouTubePublisher::Result.new(uploaded: 0, attempted: 0, rate_limited: false,
                                   errors: [{ type: :publisher_crash, message: e.message }])
    end

    def print_summary(tick)
      total = tick.per_pod.values.sum { |v| v[:uploaded] }
      tick.per_pod.each do |pod, v|
        puts "  #{pod}: uploaded #{v[:uploaded]}#{v[:errors] > 0 ? " (#{v[:errors]} error(s))" : ''}"
      end
      puts "yt-batch: total uploaded #{total}#{tick.rate_limited ? ' — STOPPED on YouTube rate limit' : ''}"
    end
  end
end
