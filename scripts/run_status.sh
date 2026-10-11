#!/bin/bash
# Wrapper script for launchd — runs `podgen status` (content-progress check)
# and sends the summary to Telegram only when it exits non-zero (any OLD/WARN).
# Usage: scripts/run_status.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR" || exit 1

# Load shell init (rbenv/asdf/chruby/etc.) so bundle resolves correctly.
if [ -f "$HOME/.bash_profile" ]; then
  source "$HOME/.bash_profile"
elif [ -f "$HOME/.zshrc" ]; then
  source "$HOME/.zshrc"
fi

# Load .env safely (same loader as run.sh; values with spaces are fine)
load_env() {
  local file="$1"
  [ -f "$file" ] || return
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*) ]] || continue
    export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
  done < "$file"
}
load_env "$PROJECT_DIR/.env"

# ── Helper: send Telegram alert (plain text; podcast names contain underscores) ──
send_telegram_alert() {
  local message="$1"
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo "Warning: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set, skipping alert" >&2
    return 1
  fi
  curl -sf -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode chat_id="$TELEGRAM_CHAT_ID" \
    --data-urlencode text="$message" \
    > /dev/null 2>&1
}

SUMMARY="$(bundle exec ruby bin/podgen --quiet status 2>&1)"
STATUS_EXIT=$?

echo "$SUMMARY"

if [ $STATUS_EXIT -ne 0 ]; then
  send_telegram_alert "podgen status (exit $STATUS_EXIT):
$SUMMARY"
fi

exit $STATUS_EXIT
