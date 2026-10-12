#!/usr/bin/env bash
# P2-0 PreToolUse hook: the dev-loop YIELDS while a production generate holds
# output/<podcast>/run.lock (or during the 16:25–17:10 launchd window).
# Blocks Edit/Write/MultiEdit under lib/ bin/ scripts/ .claude/, and Bash
# branch moves/merges/history rewrites or writes into lib/ bin/ scripts/
# (redirect, tee, sed/ruby/perl -i, patch, cp/mv/rm). Exit 2 = blocked.
# A seatbelt, not a sandbox: eval, variables holding paths, stdin-fed
# xargs, exec/nice/timeout wrappers, abbreviated git long options,
# touch/ln/rsync/dd/File.write and the like are out of scope.
# Heredoc bodies (commit messages, file contents) are NOT scanned — only
# the command lines around them.
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
# A run of git global options (-c k=v, -C dir, --no-pager, -P, --x=y, …).
git_opts='((-[cC][[:space:]]+[^[:space:]]+|--?[[:alnum:]-]+(=[^[:space:]]+)?)[[:space:]]+)*'
git_prefix="(^|[^[:alnum:]_])git[[:space:]]+${git_opts}"
# A command position: line start, after ; | & ( { ! $( or a then/do/else
# word, optional whitespace, optional VAR=val assignments, optional wrapper
# (sudo/xargs/command/env/nohup/time with options or assignments) or git,
# optional /usr/bin or /bin prefix.
cmd_pos='(^|[;|&({!]|\$\(|(^|[[:space:];])(then|do|else)[[:space:]])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((sudo|xargs|command|env|nohup|time)([[:space:]]+(-[^[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*))*[[:space:]]+|git[[:space:]]+)?(/usr)?(/bin/)?'

matches() { grep -qE "$1" <<<"$2"; }

# Command lines only: drop every heredoc body (from the line after a
# `<<WORD` / `<<-'WORD'` opener up to and including the WORD line; a
# `<<-` body ends at a tab-indented WORD too). `<<<` here-strings are not
# heredocs. A heredoc-looking token inside quoted text or `$((1<<n))` still
# hides the lines after it (seatbelt).
strip_heredocs() {
  awk '
    skip { t = $0; if (dash) { sub(/^\t+/, "", t) }; if (t == term) { skip = 0 }; next }
    { print }
    match($0, /(^|[^<])<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*/) {
      term = substr($0, RSTART, RLENGTH)
      sub(/^[^<]/, "", term)
      dash = (term ~ /^<<-/)
      sub(/^<<-?[[:space:]]*["'"'"']?/, "", term)
      skip = 1
    }' <<<"$1"
}

guarded=false
case "$tool" in
  Edit|Write|MultiEdit)
    if matches '(^|/)(lib|bin|scripts|\.claude)/' "$file"; then guarded=true; fi
    ;;
  Bash)
    lines=$(strip_heredocs "$cmd")
    # Branch moves / tree and history rewrites. `update-ref refs/cr/…` (the
    # review marker) stays allowed; HEAD or refs/heads/ is a branch move.
    if matches "${git_prefix}(merge|cherry-pick|revert|switch|checkout|rebase|pull|reset|restore|apply|am|clean|checkout-index|read-tree)([^[:alnum:]_-]|\$)" "$lines" \
      || matches "${git_prefix}branch[[:space:]]+(-f|--force|--delete|--move|--copy|-[mMcCdD])" "$lines" \
      || matches "${git_prefix}commit[^;|&]*--amend" "$lines" \
      || matches "${git_prefix}(update-ref|symbolic-ref)([[:space:]]+-[^[:space:]]+)*[[:space:]]+(HEAD|refs/heads/)" "$lines"; then
      guarded=true
    fi
    # `git stash` mutates unless it is `stash list|show`; strip the read-only
    # forms first so they cannot exempt the rest of the command line.
    stripped=$(sed -E "s/git[[:space:]]+${git_opts}stash[[:space:]]+(list|show)([^[:alnum:]_-]|\$)/\\5/g" <<<"$lines")
    if matches "${git_prefix}stash([^[:alnum:]_-]|\$)" "$stripped"; then
      guarded=true
    fi
    # Writes INTO lib/ bin/ scripts/: redirect (absolute paths, heredoc
    # openers and >| included; `=>` is not a redirect), tee with any options
    # or several files, in-place editors (sed/perl with -i anywhere in the
    # options, ruby -i/-pi), patch, and cp/mv/rm at a command position whose
    # arguments name one of those trees (a source path also matches —
    # conservative).
    if matches "(^|[^=])>>?\|?[[:space:]]*${target}" "$lines" \
      || matches "(^|[[:space:]|;&/])tee[[:space:]][^;|&]*${target}" "$lines" \
      || matches "((sed|perl)([[:space:]]+-[^[:space:]]*)*[[:space:]]+(-[[:alnum:]]*i|--in-place)|ruby -p?i|patch )[^;|&]*${target}" "$lines" \
      || matches "${cmd_pos}(cp|mv|rm)[[:space:]][^;|&]*${target}" "$lines"; then
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
