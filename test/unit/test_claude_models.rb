# frozen_string_literal: true

require_relative "../test_helper"
require "claude_models"

# P1-0: one registry, one override point. ENV is isolated per test because
# test_helper loads .env (which may set CLAUDE_MODEL on the owner's box).
class TestClaudeModels < Minitest::Test
  def setup
    @saved = ENV.to_h.select { |k, _| k.start_with?("CLAUDE_") }
    @saved.each_key { |k| ENV.delete(k) }
  end

  def teardown
    ENV.keys.select { |k| k.start_with?("CLAUDE_") }.each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
  end

  def test_every_role_resolves_to_its_line_default
    ClaudeModels::ROLES.each do |role, line|
      assert_equal ClaudeModels::LINES.fetch(line), ClaudeModels.for(role), "role #{role}"
    end
  end

  def test_line_ids_are_undated_claude_ids
    ClaudeModels::LINES.each do |line, id|
      assert_match(/\Aclaude-#{line}-\d/, id)
    end
  end

  def test_unknown_role_raises_argument_error
    err = assert_raises(ArgumentError) { ClaudeModels.for(:nope) }
    assert_includes err.message, ":nope"
  end

  def test_role_env_beats_line_env_beats_default
    ENV["CLAUDE_SONNET_MODEL"] = "line-x"
    ENV["CLAUDE_VOCAB_MODEL"] = "role-x"

    assert_equal "role-x", ClaudeModels.for(:vocab)
    assert_equal "line-x", ClaudeModels.for(:description)
    assert_equal ClaudeModels::LINES[:haiku], ClaudeModels.for(:web_search)
  end

  def test_claude_model_aliases_the_opus_line_only
    ENV["CLAUDE_MODEL"] = "opus-x"

    assert_equal "opus-x", ClaudeModels.for(:script)
    assert_equal "opus-x", ClaudeModels.for(:reviewer)
    assert_equal ClaudeModels::LINES[:sonnet], ClaudeModels.for(:tell_translate), "R1-a: Tell translation left the opus alias"
  end

  def test_claude_opus_model_beats_the_claude_model_alias
    ENV["CLAUDE_MODEL"] = "alias-x"
    ENV["CLAUDE_OPUS_MODEL"] = "line-x"

    assert_equal "line-x", ClaudeModels.for(:topic)
  end

  def test_pre_registry_role_keys_still_work
    ENV["CLAUDE_RECONCILER_MODEL"] = "rec-x"
    ENV["CLAUDE_WEB_MODEL"] = "web-x"

    assert_equal "rec-x", ClaudeModels.for(:subtitle_reconciler)
    assert_equal "web-x", ClaudeModels.for(:web_search)
  end

  def test_blank_env_values_are_ignored
    ENV["CLAUDE_VOCAB_MODEL"] = "  "
    ENV["CLAUDE_SONNET_MODEL"] = ""

    assert_equal ClaudeModels::LINES[:sonnet], ClaudeModels.for(:vocab)
  end

  def test_tell_aliases_follow_the_registry_line
    ENV["CLAUDE_HAIKU_MODEL"] = "haiku-x"

    assert_equal "haiku-x", ClaudeModels.line_id(:haiku)
    assert_equal ClaudeModels::LINES[:opus], ClaudeModels.line_id(:opus)
  end

  # -- effort (P5-1) --

  def test_effort_default_policy_for_every_role
    expected = {description: "low", language_detect: "low"}
    ClaudeModels::ROLES.each_key do |role|
      assert_equal expected[role], ClaudeModels.effort(role), "role #{role}"
    end
  end

  def test_effort_unknown_role_raises_argument_error
    err = assert_raises(ArgumentError) { ClaudeModels.effort(:nope) }
    assert_includes err.message, ":nope"
  end

  def test_effort_role_env_beats_default
    ENV["CLAUDE_EFFORT_DESCRIPTION"] = "High"
    ENV["CLAUDE_EFFORT_SCRIPT"] = "medium"

    assert_equal "high", ClaudeModels.effort(:description)
    assert_equal "medium", ClaudeModels.effort(:script)
    assert_equal "low", ClaudeModels.effort(:language_detect)
  end

  def test_effort_blank_env_keeps_default
    ENV["CLAUDE_EFFORT_DESCRIPTION"] = " "

    assert_equal "low", ClaudeModels.effort(:description)
  end

  def test_effort_invalid_env_warns_and_omits
    ENV["CLAUDE_EFFORT_DESCRIPTION"] = "turbo"

    result = nil
    _out, err = capture_io { result = ClaudeModels.effort(:description) }
    assert_nil result
    assert_includes err, "CLAUDE_EFFORT_DESCRIPTION"
    assert_includes err, "turbo"
  end

  def test_effort_opt_out_values_omit_without_warning
    %w[default none off Default].each do |value|
      ENV["CLAUDE_EFFORT_DESCRIPTION"] = value

      result = :unset
      out, err = capture_io { result = ClaudeModels.effort(:description) }
      assert_nil result, value
      assert_empty out, value
      assert_empty err, value
    end
  end

  def test_no_model_id_literals_outside_the_registry
    lib = File.expand_path("../../lib", __dir__)
    offenders = Dir[File.join(lib, "**", "*.rb")]
      .reject { |f| f.end_with?("claude_models.rb") }
      .select { |f| File.read(f).match?(/claude-(opus|sonnet|haiku)-/) }
      .map { |f| f.delete_prefix(lib + "/") }

    assert_empty offenders, "model IDs belong in lib/claude_models.rb only"
  end
end
