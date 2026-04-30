#!/bin/bash
# Wrapper script for launchd — runs `podgen yt-batch <pods> [--mode ...]`,
# uploading one pending YouTube episode per tick across the listed podcasts.
# Usage: scripts/run_yt_batch.sh <pod1,pod2,...> [--mode priority|round-robin]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR" || exit 1

# Load rbenv/asdf/chruby if available
if [ -f "$HOME/.bash_profile" ]; then
  source "$HOME/.bash_profile"
elif [ -f "$HOME/.zshrc" ]; then
  source "$HOME/.zshrc"
fi

PODS="$1"
shift

bundle exec ruby bin/podgen --quiet yt-batch "$PODS" "$@"
exit $?
