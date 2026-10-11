#!/usr/bin/env bash
# P2-0 PreToolUse hook: the dev-loop YIELDS while a production generate holds
# output/<podcast>/run.lock (or during the 16:25–17:10 launchd window).
# Blocks Edit/Write/MultiEdit under lib/ bin/ scripts/ .claude/, and Bash
# branch moves/merges or writes into lib/ bin/ scripts/. Exit 2 = blocked.
# Safe by default: no output/ dir under cwd -> no-op.
# PROD_GUARD_NOW (ISO time) overrides the clock, for tests.
set -uo pipefail

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // "."')

repo=$(cd "$cwd" 2>/dev/null && pwd -P) || exit 0
[ -d "$repo/output" ] || exit 0

guarded=false
case "$tool" in
  Edit|Write|MultiEdit)
    if printf '%s' "$file" | grep -qE '(^|/)(lib|bin|scripts|\.claude)/'; then guarded=true; fi
    ;;
  Bash)
    if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])git[[:space:]]+(merge|cherry-pick|switch|checkout|rebase|stash|pull)([^[:alnum:]_-]|$)'; then
      guarded=true
    elif printf '%s' "$cmd" | grep -qE '(lib|bin|scripts)/' \
      && printf '%s' "$cmd" | grep -qE '>|sed -i|ruby -i|cp |mv |rm '; then
      guarded=true
    fi
    ;;
esac
$guarded || exit 0

script_dir=$(cd "$(dirname "$0")" && pwd -P)
lib_dir="$script_dir/../lib"

ruby -I"$lib_dir" -r production_run -r time -e '
  now = ENV["PROD_GUARD_NOW"].to_s.empty? ? Time.now : Time.parse(ENV["PROD_GUARD_NOW"])
  r = ProductionRun.yield_reason(output_root: ARGV[0], now: now)
  if r
    warn("YIELD: #{r} — dev-loop defers to the production run")
    exit 2
  end
' "$repo/output"
status=$?
[ "$status" -eq 2 ] && exit 2
exit 0
