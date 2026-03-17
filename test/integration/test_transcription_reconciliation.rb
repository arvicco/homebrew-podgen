# frozen_string_literal: true

# Integration test: verifies multi-engine STT reconciliation.
# Uses pre-written transcript strings (no real STT calls).
# Reconciler uses Claude to merge divergent transcripts.

require_relative "../test_helper"
require "transcription/reconciler"

class TestTranscriptionReconciliation < Minitest::Test
  def setup
    skip_unless_env("ANTHROPIC_API_KEY")
    @reconciler = Transcription::Reconciler.new(language: "English")
  end

  def test_reconciliation_merges_two_transcripts
    transcripts = {
      "engine_a" => "The quick brown fox jumped over the lazy dog. It was a beautiful day in the park.",
      "engine_b" => "The quick brown fox jumps over the lazy dog. It was a beautful day in the park."
    }

    result = @reconciler.reconcile(transcripts)

    assert_kind_of String, result
    refute_empty result
    # Should contain the core content
    assert_match(/fox/, result)
    assert_match(/lazy dog/, result)
    # Should pick "beautiful" (correct) over "beautful" (typo)
    assert_match(/beautiful/, result)
  end

  def test_reconciliation_handles_identical_transcripts
    text = "Hello world. This is a test transcript with identical content from both engines."
    transcripts = {
      "engine_a" => text,
      "engine_b" => text
    }

    result = @reconciler.reconcile(transcripts)

    assert_kind_of String, result
    refute_empty result
    # Output should closely match input when both engines agree
    assert_match(/Hello/, result)
    assert_match(/identical content/, result)
  end

  def test_reconciliation_picks_better_of_divergent
    transcripts = {
      "clean" => "The mayor announced a new transportation initiative for the downtown area. Construction will begin next month.",
      "garbled" => "The mayor the mayor announced announced a new transportation transportation initiative. Construction construction will begin."
    }

    result = @reconciler.reconcile(transcripts)

    assert_kind_of String, result
    refute_empty result
    # Should not have doubled words from the garbled version
    refute_match(/mayor.*mayor/, result.gsub(/\n/, " "))
    refute_match(/announced.*announced/, result.gsub(/\n/, " "))
    # Core content should survive
    assert_match(/transportation/, result)
  end

  def test_reconciliation_preserves_language_specific_chars
    @reconciler = Transcription::Reconciler.new(language: "Slovenian")

    transcripts = {
      "engine_a" => "Prekopiščevali so se čez reko. Šli so po široki poti.",
      "engine_b" => "Prekopiscevali so se cez reko. Sli so po siroki poti."
    }

    result = @reconciler.reconcile(transcripts)

    assert_kind_of String, result
    refute_empty result
    # Should preserve Slovenian diacritics (č, š, ž) from the better engine
    assert_match(/[čšž]/, result, "Should preserve Slovenian diacritics")
  end
end
