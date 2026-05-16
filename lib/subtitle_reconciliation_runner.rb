# frozen_string_literal: true

require_relative "timestamp_persister"
require_relative "transcript_parser"
require_relative "subtitle_reconciler"

# Shared runner for the "reconcile STT segments against a corrected
# transcript" step. Used by `publish --youtube`, the `youtube_publisher`
# upload loop, and `podgen regen --reconcile`.
#
# Pure value: returns a Result describing what happened (or didn't) and
# leaves printing/logging to the caller — each entry point has its own
# verbosity conventions.
module SubtitleReconciliationRunner
  # status values:
  #   :reconciled          — reconciler ran, timestamps file rewritten
  #   :already_reconciled  — file has "reconciled": true and force is false
  #   :no_timestamps       — timestamps file does not exist or is unreadable
  #   :no_api_key          — api_key was nil or empty
  #   :no_transcript       — transcript body was empty
  #   :failed              — reconciler or persister raised; message holds the cause
  Result = Struct.new(:status, :message, keyword_init: true)

  module_function

  def run(ts_path:, transcript_path:, api_key: ENV["ANTHROPIC_API_KEY"], force: false)
    data = TimestampPersister.load(ts_path)
    return Result.new(status: :no_timestamps, message: "no timestamps at #{ts_path}") if data.nil?

    if data["reconciled"] && !force
      return Result.new(status: :already_reconciled, message: "already reconciled")
    end

    if api_key.nil? || api_key.empty?
      return Result.new(status: :no_api_key, message: "ANTHROPIC_API_KEY not set")
    end

    parsed = TranscriptParser.parse(transcript_path)
    transcript_text = parsed.body
    if transcript_text.nil? || transcript_text.strip.empty?
      return Result.new(status: :no_transcript, message: "transcript at #{transcript_path} is empty")
    end

    segments = SubtitleReconciler.reconcile(data["segments"], transcript_text, api_key: api_key)
    TimestampPersister.update_segments(ts_path, segments)
    Result.new(status: :reconciled, message: "reconciled #{segments.length} segments")
  rescue => e
    Result.new(status: :failed, message: e.message)
  end
end
