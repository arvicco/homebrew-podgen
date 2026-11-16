#!/usr/bin/env ruby
# frozen_string_literal: true

# commit-msg hook (P25-2): refuses a commit message that would put private
# working state on the public history. Installed by scripts/install_hooks.sh.
#
#   ruby scripts/commit_msg_guard.rb <message-file>   # exit 1 + reasons when refused
#
# Refused, in the subject or the body (git's "#" comment lines and anything
# below the verbose-mode scissors line are ignored; merge messages are
# checked like any other):
#   - an id of a private register: Q-<n>, I-<n>, R<n>-<n> (packet ids
#     P<n>-<m> are allowed);
#   - a clock time: H:MM / HH:MM (optionally :SS) outside code — text in
#     `backticks` or ``` fences is exempt, so a duration in a code example
#     is written `1:20`; a clock time followed by a zone word (UTC, CET, …)
#     is refused even inside code;
#   - a day-part ("overnight", "this morning", "tonight", "this evening", …);
#   - an assistant attribution line (Co-Authored-By naming an assistant,
#     "Generated with", "Claude-Session:");
#   - any term of the optional term list: one term per line, matched as a
#     case-insensitive substring; blank and "#" lines skipped. Read from
#     $PODGEN_PUBLIC_TERMS, else .docs/public-terms.txt at the repository
#     root when that file exists (absent = the generic checks only).
module CommitMsgGuard
  REGISTER_ID = /(?<![\w-])(?:[QI]-\d+|R\d+-\d+)(?![\w-])/
  CLOCK = /(?<![\d:.])(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?(?![\d:])/
  ZONE = /\b(?:UTC|GMT|CES?T|CED?T|[CEMP][SD]T|BST|IST|JST|AE[SD]T|local time)\b/
  ZONED_CLOCK = /#{CLOCK}\s*#{ZONE}/
  DAY_PART = /\b(?:overnight|tonight|last night|this (?:morning|afternoon|evening))\b/i
  ATTRIBUTION = [
    /^\s*Co-Authored-By:.*\b(?:claude|anthropic|openai|chatgpt|gpt|copilot|gemini|assistant)\b/i,
    /\bgenerated with\b/i,
    /\bClaude-Session:/i
  ].freeze
  SCISSORS = /^# -+ >8 -+$/
  DEFAULT_TERMS = File.join(".docs", "public-terms.txt")

  module_function

  # The message as git will record it: comment lines and the verbose diff
  # below the scissors line dropped.
  def message_text(raw)
    raw.split(SCISSORS, 2).first.to_s.lines.reject { it.start_with?("#") }.join
  end

  # Inline `code` spans and ``` fenced blocks blanked out.
  def without_code(text)
    text.gsub(/^```.*?^```[^\n]*$/m, "").gsub(/`[^`\n]*`/, "")
  end

  # One reason per finding; [] when the message may be committed.
  def violations(raw, terms: [])
    text = message_text(raw)
    prose = without_code(text)
    found = []
    text.scan(REGISTER_ID).uniq.each { found << "private register id '#{it}' (packet ids P<n>-<m> are allowed)" }
    zoned = text.to_enum(:scan, ZONED_CLOCK).map { Regexp.last_match[0] }.uniq
    zoned.each { found << "clock time with a zone '#{it}'" }
    prose.scan(CLOCK).uniq.each do |time|
      found << "clock time '#{time}' (a duration in a code example goes in `backticks`)" unless zoned.any? { it.start_with?(time) }
    end
    text.scan(DAY_PART).uniq.each { found << "day-part '#{it}'" }
    text.each_line do |line|
      found << "assistant attribution '#{line.strip}'" if ATTRIBUTION.any? { line.match?(it) }
    end
    down = text.downcase
    terms.each { found << "listed term '#{it}'" if down.include?(it.downcase) }
    found
  end

  def load_terms(path)
    return [] unless path && File.file?(path)

    File.readlines(path, chomp: true).map(&:strip).reject { it.empty? || it.start_with?("#") }
  end

  # $PODGEN_PUBLIC_TERMS, else the first existing .docs/public-terms.txt at
  # the given roots (the working tree, then the main checkout of a worktree).
  def terms_path(env: ENV, roots: [])
    return env["PODGEN_PUBLIC_TERMS"] if env["PODGEN_PUBLIC_TERMS"] && !env["PODGEN_PUBLIC_TERMS"].empty?

    roots.compact.map { File.join(it, DEFAULT_TERMS) }.find { File.file?(it) }
  end

  def repo_roots
    git = ->(*args) {
      out = IO.popen(["git", "rev-parse", *args], err: File::NULL, &:read).to_s.strip
      out.empty? ? nil : out
    }
    common = git.call("--path-format=absolute", "--git-common-dir")
    [git.call("--show-toplevel"), common && File.dirname(common)].uniq
  end

  def main(argv, err: $stderr)
    path = argv.first
    unless path && File.file?(path)
      err.puts "commit-msg guard: usage: commit_msg_guard.rb <message-file>"
      return 2
    end

    found = violations(File.read(path), terms: load_terms(terms_path(roots: repo_roots)))
    return 0 if found.empty?

    err.puts "commit-msg guard: the message carries text that does not belong on the public history:"
    found.each { err.puts "  - #{it}" }
    err.puts "Edit the message and commit again (the message file is #{path})."
    1
  end
end

exit(CommitMsgGuard.main(ARGV)) if $PROGRAM_NAME == __FILE__
