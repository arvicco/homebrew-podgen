# frozen_string_literal: true

require_relative "video_generator"

# Shared runner for the "render <mp3> + <cover> into <mp4>" step.
# Used by youtube_publisher's upload loop and `podgen regen --video`.
#
# Pure value: returns a Result describing what happened (or didn't) and
# leaves printing/logging to the caller.
module VideoBuilder
  # status values:
  #   :built       — VideoGenerator ran, mp4 written (message says when a
  #                  stale mp4, older than the audio, was regenerated)
  #   :exists      — mp4 present, not older than the audio, force is false
  #   :no_cover    — cover_path was nil or did not point to an existing file
  #   :no_audio    — mp3_path did not exist
  #   :failed      — VideoGenerator raised; message holds the cause,
  #                  error_class the exception class name
  Result = Struct.new(:status, :video_path, :message, :error_class, keyword_init: true)

  module_function

  def build(mp3_path:, cover_path:, video_path:, force: false, logger: nil)
    return Result.new(status: :no_audio, message: "no audio at #{mp3_path}") unless File.exist?(mp3_path)

    if !force && reusable?(mp3_path: mp3_path, video_path: video_path)
      return Result.new(status: :exists, video_path: video_path, message: "mp4 already exists")
    end
    stale = !force && File.exist?(video_path)

    if cover_path.nil? || !File.exist?(cover_path)
      return Result.new(status: :no_cover, message: "no cover image#{cover_path ? " at #{cover_path}" : ""}")
    end

    VideoGenerator.new(logger: logger).generate(mp3_path, cover_path, video_path)
    Result.new(status: :built, video_path: video_path,
      message: stale ? "video regenerated: mp4 older than audio" : "mp4 built")
  rescue => e # skippable: returned as a :failed Result; the caller reports it
    Result.new(status: :failed, message: e.message, error_class: e.class.name)
  end

  # An existing mp4 is reused only when it is not older than its audio
  # (P4-8 rider): an older one is left over from an earlier run with the
  # same basename and would upload stale audio.
  def reusable?(mp3_path:, video_path:)
    File.exist?(video_path) && File.exist?(mp3_path) && File.mtime(video_path) >= File.mtime(mp3_path)
  end
end
