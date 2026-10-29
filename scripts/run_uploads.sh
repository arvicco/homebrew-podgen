#!/bin/bash
# Wrapper script for launchd — runs `podgen uploads <pods> [--mode ...] [--max ...]`,
# performing per-pod regen+R2+LingQ then a YouTube batch phase across pods.
# Usage: scripts/run_uploads.sh <pod1,pod2,...> [--mode priority|round-robin] [--max N]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR" || exit 1

# Load shell init (rbenv/asdf/chruby/etc.) so bundle resolves correctly.
if [ -f "$HOME/.bash_profile" ]; then
  source "$HOME/.bash_profile"
elif [ -f "$HOME/.zshrc" ]; then
  source "$HOME/.zshrc"
fi

PODS="$1"
shift

# Dated markers bracket each batch in the shared stderr (as scripts/run.sh
# does for publishes): `podgen status` scans only the latest batch. The
# begin marker also goes to stdout so the batch counts there pair with it.
echo "$(date '+%Y/%m/%d %H:%M:%S') podgen uploads $PODS begin"
echo "$(date '+%Y/%m/%d %H:%M:%S') podgen uploads $PODS begin" >&2

# Hold system + idle sleep off for the batch's lifetime (I-10, P10-6).
KEEP_AWAKE=()
command -v caffeinate > /dev/null 2>&1 && KEEP_AWAKE=(caffeinate -is)

"${KEEP_AWAKE[@]}" bundle exec ruby bin/podgen --quiet uploads "$PODS" "$@"
UP_EXIT=$?
echo "$(date '+%Y/%m/%d %H:%M:%S') podgen uploads $PODS end exit=$UP_EXIT" >&2
exit $UP_EXIT
