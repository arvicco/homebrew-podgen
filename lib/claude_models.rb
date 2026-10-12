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
#
# Effort (P5-1): EFFORT lists the roles sent a non-default effort level;
# every other role resolves to nil (the parameter is omitted). Per-role
# ENV CLAUDE_EFFORT_<ROLE> overrides; an invalid value warns and omits.
module ClaudeModels
  LINES = {
    opus: "claude-opus-5-5",
    sonnet: "claude-sonnet-5-5",
    haiku: "claude-haiku-5-5"
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

  EFFORT_LEVELS = %w[low medium high].freeze

  # Short-output roles: a title, a description, a one-word language name.
  EFFORT = {
    description: "low",
    language_detect: "low"
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

  def effort(role)
    ROLES.fetch(role) { raise ArgumentError, "unknown Claude model role: #{role.inspect}" }
    key = "CLAUDE_EFFORT_#{role.to_s.upcase}"
    value = env(key)
    return EFFORT[role] unless value

    level = value.strip.downcase
    return level if EFFORT_LEVELS.include?(level)

    warn "Warning: #{key}=#{value.inspect} is not one of #{EFFORT_LEVELS.join("/")}; omitting effort"
    nil
  end

  def role_env(role)
    ROLE_ENV.fetch(role) { "CLAUDE_#{role.to_s.upcase}_MODEL" }
  end

  def env(key)
    value = ENV[key]
    value unless value.nil? || value.strip.empty?
  end
end
