# frozen_string_literal: true

require "open3"
require "json"
require "fileutils"

class AudioAssembler
  SAMPLE_RATE = 44_100
  BITRATE = "192k"
  TARGET_LUFS = -16
  TRUE_PEAK = -1.5
  LRA = 11
  INTRO_FADE_OUT = 3 # seconds
  OUTRO_FADE_IN = 2  # seconds

  def initialize(logger: nil)
    @logger = logger
    @root = File.expand_path("..", __dir__)
    verify_ffmpeg!
  end

  # Input: segment_paths (array of MP3 paths), output_path (final MP3 path)
  # Optional: intro_path, outro_path (skipped if nil or file doesn't exist)
  def assemble(segment_paths, output_path, intro_path: nil, outro_path: nil)
    intro_path = nil unless intro_path && File.exist?(intro_path)
    outro_path = nil unless outro_path && File.exist?(outro_path)

    all_inputs = []
    all_inputs << intro_path if intro_path
    all_inputs.concat(segment_paths)
    all_inputs << outro_path if outro_path

    if all_inputs.empty?
      log("No audio inputs provided")
      return nil
    end

    FileUtils.mkdir_p(File.dirname(output_path))

    # Step 1: Concatenate all inputs with resampling and crossfades
    concat_path = output_path.sub(/\.mp3$/, "_concat.mp3")
    log("Concatenating #{all_inputs.length} audio files...")
    concatenate(all_inputs, concat_path, intro: intro_path, outro: outro_path)

    # Step 2: Two-pass loudness normalization
    log("Normalizing loudness to #{TARGET_LUFS} LUFS...")
    measurements = loudnorm_analyze(concat_path)
    loudnorm_apply(concat_path, output_path, measurements)

    # Clean up intermediate file
    File.delete(concat_path) if File.exist?(concat_path)

    duration = probe_duration(output_path)
    size_mb = (File.size(output_path) / (1024.0 * 1024)).round(2)
    log("Output: #{output_path} (#{duration.round(1)}s, #{size_mb} MB)")

    output_path
  end

  private

  def concatenate(inputs, output_path, intro: nil, outro: nil)
    filter_parts = []
    stream_labels = []

    inputs.each_with_index do |input, i|
      # Resample all inputs to consistent format
      label = "[a#{i}]"
      filter = "[#{i}:a]aresample=#{SAMPLE_RATE},aformat=sample_fmts=fltp:channel_layouts=mono"

      # Apply fade-out on intro
      if input == intro
        dur = probe_duration(input)
        fade_start = [dur - INTRO_FADE_OUT, 0].max
        filter += ",afade=t=out:st=#{fade_start.round(3)}:d=#{INTRO_FADE_OUT}"
      end

      # Apply fade-in on outro
      if input == outro
        filter += ",afade=t=in:d=#{OUTRO_FADE_IN}"
      end

      filter += label
      filter_parts << filter
      stream_labels << label
    end

    n = inputs.length
    concat_filter = "#{stream_labels.join}concat=n=#{n}:v=0:a=1[out]"
    filter_parts << concat_filter

    filter_complex = filter_parts.join(";")

    args = inputs.flat_map { |p| ["-i", p] }
    args += [
      "-filter_complex", filter_complex,
      "-map", "[out]",
      "-c:a", "libmp3lame", "-b:a", BITRATE,
      "-ar", SAMPLE_RATE.to_s,
      "-y", output_path
    ]

    run_ffmpeg(args, "concatenate")
  end

  def loudnorm_analyze(input_path)
    args = [
      "-i", input_path,
      "-af", "loudnorm=I=#{TARGET_LUFS}:TP=#{TRUE_PEAK}:LRA=#{LRA}:print_format=json",
      "-f", "null", "/dev/null"
    ]

    _stdout, stderr, status = run_ffmpeg_raw(args)
    unless status.success?
      raise "Loudnorm analysis failed: #{stderr}"
    end

    # Extract JSON from ffmpeg stderr (it's printed at the end)
    json_match = stderr.match(/\{[^}]*"input_i"[^}]*\}/m)
    raise "Could not parse loudnorm measurements from ffmpeg output" unless json_match

    JSON.parse(json_match[0])
  end

  def loudnorm_apply(input_path, output_path, measurements)
    params = [
      "I=#{TARGET_LUFS}",
      "TP=#{TRUE_PEAK}",
      "LRA=#{LRA}",
      "measured_I=#{measurements['input_i']}",
      "measured_TP=#{measurements['input_tp']}",
      "measured_LRA=#{measurements['input_lra']}",
      "measured_thresh=#{measurements['input_thresh']}",
      "offset=#{measurements['target_offset']}",
      "linear=true"
    ]
    loudnorm_filter = "loudnorm=#{params.join(':')}"

    args = [
      "-i", input_path,
      "-af", loudnorm_filter,
      "-ar", SAMPLE_RATE.to_s,
      "-c:a", "libmp3lame", "-b:a", BITRATE,
      "-y", output_path
    ]

    run_ffmpeg(args, "loudnorm apply")
  end

  def probe_duration(path)
    stdout, stderr, status = Open3.capture3(
      "ffprobe", "-v", "quiet",
      "-show_entries", "format=duration",
      "-of", "csv=p=0",
      path
    )

    unless status.success?
      raise "ffprobe failed for #{path}: #{stderr}"
    end

    stdout.strip.to_f
  end

  def run_ffmpeg(args, step_name)
    _stdout, stderr, status = run_ffmpeg_raw(args)
    unless status.success?
      raise "ffmpeg #{step_name} failed (exit #{status.exitstatus}): #{stderr.split("\n").last(5).join("\n")}"
    end
  end

  def run_ffmpeg_raw(args)
    cmd = ["ffmpeg"] + args
    log("  Running: ffmpeg #{args.join(' ')}")
    Open3.capture3(*cmd)
  end

  def verify_ffmpeg!
    _out, _err, status = Open3.capture3("ffmpeg", "-version")
    return if status.success?

    raise "ffmpeg is not installed or not on $PATH. Install with: brew install ffmpeg"
  rescue Errno::ENOENT
    raise "ffmpeg is not installed or not on $PATH. Install with: brew install ffmpeg"
  end

  def log(message)
    if @logger
      @logger.log("[AudioAssembler] #{message}")
    else
      puts "[AudioAssembler] #{message}"
    end
  end
end
