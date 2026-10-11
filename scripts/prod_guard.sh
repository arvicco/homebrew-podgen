#!/usr/bin/env bash
# P2-0 PreToolUse hook: the dev-loop YIELDS while a production generate holds
# output/<podcast>/run.lock (or during the 16:25–17:10 launchd window).
# Blocks Edit/Write/MultiEdit under lib/ bin/ scripts/ .claude/, and Bash
# branch moves/merges or writes into lib/ bin/ scripts/. Exit 2 = blocked.
# Safe by default: no output/ dir under cwd -> no-op.
# PROD_GUARD_NOW (ISO time) overrides the clock, for tests.
# Fails OPEN: missing jq/ruby, bad JSON or a bad PROD_GUARD_NOW allow the call
# (only exit 2 blocks). `ruby` is whatever is first on the hook's PATH; the
# probe needs only stdlib and runs on Ruby 2.6+.
set -uo pipefail

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // "."')

repo=$(cd "$cwd" 2>/dev/null && pwd -P) || exit 0
[ -d "$repo/output" ] || exit 0

# A guarded target: optional quote, optional path prefix, then one of the trees.
target='["'"'"']?([^[:space:]"'"'"']*/)?(lib|bin|scripts)/'
# `git` with any run of -c key=val / -C <dir> options before the subcommand.
git_prefix='(^|[^[:alnum:]_])git[[:space:]]+(-[cC][[:space:]]+[^[:space:]]+[[:space:]]+)*'

guarded=false
case "$tool" in
  Edit|Write|MultiEdit)
    if printf '%s' "$file" | grep -qE '(^|/)(lib|bin|scripts|\.claude)/'; then guarded=true; fi
    ;;
  Bash)
    # Branch moves / history rewrites.
    if printf '%s' "$cmd" | grep -qE "${git_prefix}(merge|cherry-pick|switch|checkout|rebase|pull|reset|restore)([^[:alnum:]_-]|\$)"; then
      guarded=true
    fi
    # `git stash` mutates unless it is `stash list|show`; strip the read-only
    # forms first so they cannot exempt the rest of the command line.
    stripped=$(printf '%s' "$cmd" | sed -E 's/git[[:space:]]+(-[cC][[:space:]]+[^[:space:]]+[[:space:]]+)*stash[[:space:]]+(list|show)//g')
    if printf '%s' "$stripped" | grep -qE "${git_prefix}stash([^[:alnum:]_-]|\$)"; then
      guarded=true
    fi
    # Writes INTO lib/ bin/ scripts/: redirect or tee (absolute paths and
    # heredocs included), in-place editors, patch, and cp/mv/rm at a command
    # position whose arguments name one of those trees (a source path also
    # matches — conservative).
    if printf '%s' "$cmd" | grep -qE "(>>?|(^|[[:space:]|;&])tee([[:space:]]+-a)?)[[:space:]]*${target}"; then
      guarded=true
    elif printf '%s' "$cmd" | grep -qE "(sed -i|ruby -p?i|perl -p?i|patch )[^;|&]*${target}"; then
      guarded=true
    elif printf '%s' "$cmd" | grep -qE "(^|[;|&][[:space:]]*)(sudo[[:space:]]+)?(cp|mv|rm)[[:space:]][^;|&]*${target}"; then
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
