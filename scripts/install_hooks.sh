#!/bin/sh
# Installs the commit-msg guard (scripts/commit_msg_guard.rb) as this
# repository's commit-msg hook (P25-2). Run from the main checkout or any
# worktree: hooks live in the common git dir, so one install covers both.
# Idempotent; refuses to replace a hook it did not write unless --force.
#
#   scripts/install_hooks.sh [--force]
set -eu

MARKER="# podgen commit-msg guard (scripts/install_hooks.sh)"

force=0
case "${1:-}" in
  --force) force=1 ;;
  "") ;;
  *) echo "usage: scripts/install_hooks.sh [--force]" >&2; exit 2 ;;
esac

hooks_dir=$(git rev-parse --path-format=absolute --git-path hooks)
hook="$hooks_dir/commit-msg"

if [ -e "$hook" ] && ! grep -qF "$MARKER" "$hook" && [ "$force" -ne 1 ]; then
  echo "install_hooks: $hook exists and was not written by this script; rerun with --force to replace it" >&2
  exit 1
fi

mkdir -p "$hooks_dir"
tmp="$hook.tmp.$$"
cat > "$tmp" <<EOF
#!/bin/sh
$MARKER
# The guard is read from the tree being committed; a branch that predates
# it is committed unchecked, with a note.
guard="\$(git rev-parse --show-toplevel)/scripts/commit_msg_guard.rb"
if [ ! -f "\$guard" ]; then
  echo "commit-msg: \$guard not in this tree; message not checked" >&2
  exit 0
fi
exec ruby "\$guard" "\$1"
EOF
chmod +x "$tmp"
mv "$tmp" "$hook"
echo "install_hooks: commit-msg guard installed at $hook"
