# frozen_string_literal: true

# Backward-compatibility shim — delegates to Transcription::OpenaiEngine.
require_relative "../transcription/openai_engine"
TranscriptionAgent = Transcription::OpenaiEngine
