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
# `git` with any run of global options (-c k=v, -C dir, --no-pager, -P, …).
git_prefix='(^|[^[:alnum:]_])git[[:space:]]+((-[cC][[:space:]]+[^[:space:]]+|--?[[:alnum:]-]+(=[^[:space:]]+)?)[[:space:]]+)*'
# A command position: line start, after ; | & ( or $(, optional whitespace,
# optional sudo/xargs/git wrapper, optional /bin/ prefix.
cmd_pos='(^|[;|&(]|\$\()[[:space:]]*(sudo[[:space:]]+|xargs[[:space:]]+|git[[:space:]]+)?(/bin/)?'

matches() { grep -qE "$1" <<<"$2"; }

guarded=false
case "$tool" in
  Edit|Write|MultiEdit)
    if matches '(^|/)(lib|bin|scripts|\.claude)/' "$file"; then guarded=true; fi
    ;;
  Bash)
    # Branch moves / history rewrites.
    if matches "${git_prefix}(merge|cherry-pick|switch|checkout|rebase|pull|reset|restore)([^[:alnum:]_-]|\$)" "$cmd"; then
      guarded=true
    fi
    # `git stash` mutates unless it is `stash list|show`; strip the read-only
    # forms first so they cannot exempt the rest of the command line.
    stripped=$(sed -E 's/git[[:space:]]+(-[cC][[:space:]]+[^[:space:]]+[[:space:]]+)*stash[[:space:]]+(list|show)([^[:alnum:]_-]|$)/\3/g' <<<"$cmd")
    if matches "${git_prefix}stash([^[:alnum:]_-]|\$)" "$stripped"; then
      guarded=true
    fi
    # Writes INTO lib/ bin/ scripts/: redirect (absolute paths and heredocs
    # included), tee with any options or several files, in-place editors,
    # patch, and cp/mv/rm at a command position (also via git/xargs/sudo)
    # whose arguments name one of those trees (a source path also matches —
    # conservative).
    if matches ">>?[[:space:]]*${target}" "$cmd" \
      || matches "(^|[[:space:]|;&])tee[[:space:]][^;|&]*${target}" "$cmd" \
      || matches "(sed -i|ruby -p?i|perl -p?i|patch )[^;|&]*${target}" "$cmd" \
      || matches "${cmd_pos}(cp|mv|rm)[[:space:]][^;|&]*${target}" "$cmd"; then
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
