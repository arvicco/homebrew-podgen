# frozen_string_literal: true

# Single source of truth for Claude model selection (P1-0).
#
# LINES holds the newest model in each line — the ONLY place a generation
# bump lands. ROLES maps each call site to a line. Resolution for a role:
#   1. per-role ENV   CLAUDE_<ROLE>_MODEL (historical names kept, ROLE_ENV)
#   2. per-line ENV   CLAUDE_OPUS_MODEL / CLAUDE_SONNET_MODEL /
#                     CLAUDE_HAIKU_MODEL; CLAUDE_MODEL aliases the opus
#                     line (ruling R1-a)
#   3. LINES[line]
# A drift check against the live Models API lives in test/api (R1-c).
module ClaudeModels
  LINES = {
    opus: "claude-opus-4-7",
    sonnet: "claude-sonnet-4-6",
    haiku: "claude-haiku-4-5-20251001"
  }.freeze

  ROLES = {
    script: :opus,
    topic: :opus,
    translation: :opus,
    reviewer: :opus,
    transcript_reconciler: :opus,
    gloss: :opus,
    description: :sonnet,
    vocab: :sonnet,
    subtitle_reconciler: :sonnet,
    image_rank: :sonnet,
    tell_translate: :sonnet,
    web_search: :haiku,
    language_detect: :haiku
  }.freeze

  # Pre-registry key names that stay valid.
  ROLE_ENV = {
    subtitle_reconciler: "CLAUDE_RECONCILER_MODEL",
    web_search: "CLAUDE_WEB_MODEL"
  }.freeze

  LINE_ENV = {
    opus: "CLAUDE_OPUS_MODEL",
    sonnet: "CLAUDE_SONNET_MODEL",
    haiku: "CLAUDE_HAIKU_MODEL"
  }.freeze

  module_function

  def for(role)
    line = ROLES.fetch(role) { raise ArgumentError, "unknown Claude model role: #{role.inspect}" }
    env(role_env(role)) || line_id(line)
  end

  def line_id(line)
    key = LINE_ENV.fetch(line) { raise ArgumentError, "unknown Claude model line: #{line.inspect}" }
    env(key) || (line == :opus && env("CLAUDE_MODEL")) || LINES.fetch(line)
  end

  def role_env(role)
    ROLE_ENV.fetch(role) { "CLAUDE_#{role.to_s.upcase}_MODEL" }
  end

  def env(key)
    value = ENV[key]
    value unless value.nil? || value.strip.empty?
  end
end
