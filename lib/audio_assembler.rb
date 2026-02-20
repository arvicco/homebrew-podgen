# frozen_string_literal: true

require "open3"
require "json"
require "fileutils"
require "tmpdir"

class AudioAssembler
  SAMPLE_RATE = 44_100
  BITRATE = "192k"
  TARGET_LUFS = -16
  TRUE_PEAK = -1.5
  LRA = 11
  INTRO_FADE_OUT = 3 # seconds
  OUTRO_FADE_IN = 2  # seconds

  # Music stripping constants
  INTRO_SCAN_LIMIT = 120     # seconds to scan for intro music
  OUTRO_SCAN_LIMIT = 120     # seconds to scan for outro music
  MIN_MUSIC_DURATION = 3     # minimum seconds of continuous audio to count as music
  SILENCE_NOISE_DB = -30     # dB threshold for silence detection
  SILENCE_MIN_GAP = 0.7      # minimum silence gap duration (seconds)
  BANDPASS_NOISE_DB = -15    # higher threshold for bandpass-filtered detection
  BANDPASS_MIN_GAP = 0.5     # shorter min gap for bandpass (transitions can be brief)
  STRIP_PADDING = 1.5        # seconds of padding before/after detected speech

  def initialize(logger: nil)
    @logger = logger
    @root = File.expand_path("..", __dir__)
    @duration_cache = {}
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

  # Trims input audio to a target duration with a fade-out at the end.
  # Resamples to mono 44100 Hz to match assembler standard.
  def trim_to_duration(input_path, output_path, duration_seconds)
    fade_duration = 2
    fade_start = [duration_seconds - fade_duration, 0].max

    args = [
      "-i", input_path,
      "-t", duration_seconds.to_s,
      "-af", "afade=t=out:st=#{fade_start}:d=#{fade_duration},aresample=#{SAMPLE_RATE},aformat=sample_fmts=fltp:channel_layouts=mono",
      "-c:a", "libmp3lame", "-b:a", BITRATE,
      "-ar", SAMPLE_RATE.to_s,
      "-y", output_path
    ]

    log("Trimming #{input_path} to #{duration_seconds}s with fade-out")
    run_ffmpeg(args, "trim")
    output_path
  end

  # Extracts a time range from an audio file. Resamples to mono 44100 Hz.
  def extract_segment(input_path, output_path, start_time, end_time)
    extract_speech(input_path, output_path, start_time, end_time)
    output_path
  end

  # Estimates where speech starts and ends using bandpass filtering.
  # Returns [speech_start, speech_end] in seconds, with padding applied.
  # Returns [0, total_duration] if no music boundaries detected.
  def estimate_speech_boundaries(input_path)
    total_duration = probe_duration(input_path)
    speech_start, speech_end = detect_speech_boundaries(input_path, total_duration)

    speech_start = [speech_start - STRIP_PADDING, 0].max
    speech_end = [speech_end + STRIP_PADDING, total_duration].min

    if speech_end - speech_start < 30
      log("Bandpass would leave < 30s, ignoring boundaries")
      return [0, total_duration]
    end

    log("Bandpass speech estimate: #{speech_start.round(1)}s → #{speech_end.round(1)}s")
    [speech_start, speech_end]
  end

  # Detects music interludes within audio using bandpass filtering.
  # In the bandpass signal (300–3000 Hz), music is quiet and speech is loud.
  # Adjacent silence gaps with < merge_gap seconds between them are merged
  # into a single region. Regions longer than min_duration are returned.
  # Returns: [{ start: Float, end: Float }, ...]
  def detect_music_regions(input_path, min_duration: 5, merge_gap: 1.5)
    filtered_path = File.join(Dir.tmpdir, "podgen_bandpass_music_#{Process.pid}.wav")

    begin
      bp_args = [
        "-i", input_path,
        "-af", "highpass=f=300,lowpass=f=3000",
        "-ar", SAMPLE_RATE.to_s,
        "-y", filtered_path
      ]
      run_ffmpeg(bp_args, "bandpass filter (music detection)")

      silences = detect_silences(filtered_path, noise_db: BANDPASS_NOISE_DB, min_gap: BANDPASS_MIN_GAP)

      # Merge adjacent silences where the "loud" gap between them is short
      merged = []
      silences.each do |s|
        if merged.empty? || (s[:start] - merged.last[:end]) > merge_gap
          merged << { start: s[:start], end: s[:end] }
        else
          merged.last[:end] = s[:end]
        end
      end

      # Keep only regions longer than min_duration
      music_regions = merged.select { |r| (r[:end] - r[:start]) >= min_duration }

      music_regions.each do |r|
        log("Music region: #{r[:start].round(1)}s → #{r[:end].round(1)}s (#{(r[:end] - r[:start]).round(1)}s)")
      end
      log("Found #{music_regions.length} music region(s)") if music_regions.any?

      music_regions
    ensure
      File.delete(filtered_path) if File.exist?(filtered_path)
    end
  end

  # Returns the duration of an audio file in seconds (cached).
  def probe_duration(path)
    return @duration_cache[path] if @duration_cache.key?(path)

    stdout, stderr, status = Open3.capture3(
      "ffprobe", "-v", "quiet",
      "-show_entries", "format=duration",
      "-of", "csv=p=0",
      path
    )

    unless status.success?
      raise "ffprobe failed for #{path}: #{stderr}"
    end

    @duration_cache[path] = stdout.strip.to_f
  end

  # Detects silence gaps in an audio file using ffmpeg silencedetect.
  # Returns: [{ start: Float, end: Float, duration: Float }, ...]
  def detect_silences(input_path, noise_db: SILENCE_NOISE_DB, min_gap: SILENCE_MIN_GAP)
    args = [
      "-i", input_path,
      "-af", "silencedetect=noise=#{noise_db}dB:d=#{min_gap}",
      "-f", "null", "/dev/null"
    ]

    _stdout, stderr, status = run_ffmpeg_raw(args)
    unless status.success?
      log("Silence detection failed, returning empty list")
      return []
    end

    silences = []
    current_start = nil

    stderr.each_line do |line|
      if line =~ /silence_start:\s*([\d.]+)/
        current_start = $1.to_f
      elsif line =~ /silence_end:\s*([\d.]+)\s*\|\s*silence_duration:\s*([\d.]+)/
        silences << {
          start: current_start || ($1.to_f - $2.to_f),
          end: $1.to_f,
          duration: $2.to_f
        }
        current_start = nil
      end
    end

    silences
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

  # Detects speech boundaries by bandpass-filtering to speech frequencies (300–3000 Hz),
  # then running silence detection on the filtered signal. In the filtered signal,
  # instrumental music is quiet while speech remains loud.
  def detect_speech_boundaries(input_path, total_duration)
    filtered_path = File.join(Dir.tmpdir, "podgen_bandpass_#{Process.pid}.wav")

    begin
      # Bandpass filter: keep only speech frequencies
      bp_args = [
        "-i", input_path,
        "-af", "highpass=f=300,lowpass=f=3000",
        "-ar", SAMPLE_RATE.to_s,
        "-y", filtered_path
      ]
      run_ffmpeg(bp_args, "bandpass filter")

      silences = detect_silences(filtered_path, noise_db: BANDPASS_NOISE_DB, min_gap: BANDPASS_MIN_GAP)
      log("Bandpass silence detection: #{silences.length} gaps (threshold: #{BANDPASS_NOISE_DB}dB)")

      speech_start = find_speech_start(silences)
      speech_end = find_speech_end(silences, total_duration)

      [speech_start, speech_end]
    ensure
      File.delete(filtered_path) if File.exist?(filtered_path)
    end
  end

  # Finds where speech starts by looking for the first silence gap in the intro
  # region that's preceded by MIN_MUSIC_DURATION+ seconds of continuous audio (music).
  def find_speech_start(silences)
    intro_silences = silences.select { |s| s[:end] <= INTRO_SCAN_LIMIT }

    intro_silences.each do |s|
      if s[:start] >= MIN_MUSIC_DURATION
        log("Intro music detected: 0s → #{s[:end].round(1)}s")
        return s[:end]
      end
    end

    0
  end

  # Finds where speech ends by looking for the last silence gap in the outro
  # region that's followed by MIN_MUSIC_DURATION+ seconds of continuous audio (music).
  def find_speech_end(silences, total_duration)
    outro_start = [total_duration - OUTRO_SCAN_LIMIT, 0].max
    outro_silences = silences.select { |s| s[:start] >= outro_start }

    outro_silences.reverse_each do |s|
      remaining_after = total_duration - s[:end]
      if remaining_after >= MIN_MUSIC_DURATION
        log("Outro music detected: #{s[:start].round(1)}s → #{total_duration.round(1)}s")
        return s[:start]
      end
    end

    total_duration
  end

  def extract_speech(input_path, output_path, start_time, end_time)
    duration = end_time - start_time

    args = [
      "-ss", start_time.to_s,
      "-i", input_path,
      "-t", duration.to_s,
      "-af", "aresample=#{SAMPLE_RATE},aformat=sample_fmts=fltp:channel_layouts=mono",
      "-c:a", "libmp3lame", "-b:a", BITRATE,
      "-ar", SAMPLE_RATE.to_s,
      "-y", output_path
    ]

    run_ffmpeg(args, "extract speech")
  end

  def resample_to_standard(input_path, output_path)
    args = [
      "-i", input_path,
      "-af", "aresample=#{SAMPLE_RATE},aformat=sample_fmts=fltp:channel_layouts=mono",
      "-c:a", "libmp3lame", "-b:a", BITRATE,
      "-ar", SAMPLE_RATE.to_s,
      "-y", output_path
    ]

    run_ffmpeg(args, "resample")
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
