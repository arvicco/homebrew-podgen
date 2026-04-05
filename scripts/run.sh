#!/bin/bash
# Wrapper script for launchd — runs podgen generate, optionally publishes, optionally alerts.
# Usage: scripts/run.sh <podcast_name> [--publish] [--telegram]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR" || exit 1

# Load rbenv/asdf/chruby if available
if [ -f "$HOME/.bash_profile" ]; then
  source "$HOME/.bash_profile"
elif [ -f "$HOME/.zshrc" ]; then
  source "$HOME/.zshrc"
fi

# Parse arguments
PODCAST_NAME="$1"
shift
PUBLISH=false
TELEGRAM=false
for arg in "$@"; do
  case "$arg" in
    --publish)  PUBLISH=true ;;
    --telegram) TELEGRAM=true ;;
  esac
done

# Load .env files safely (handles unquoted values with spaces, unlike source)
load_env() {
  local file="$1"
  [ -f "$file" ] || return
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue
    # Only process KEY=VALUE lines
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*) ]] || continue
    export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
  done < "$file"
}

# Load root .env, then per-podcast .env (overrides), matching Ruby load order
load_env "$PROJECT_DIR/.env"
load_env "$PROJECT_DIR/podcasts/$PODCAST_NAME/.env"

# ── Helper: send Telegram alert ──
send_telegram_alert() {
  local message="$1"
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo "Warning: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set, skipping alert" >&2
    return 1
  fi
  curl -sf -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d text="$message" \
    -d parse_mode="Markdown" \
    > /dev/null 2>&1
}

# ── Run generate ──
bundle exec ruby bin/podgen --quiet generate "$PODCAST_NAME"
GEN_EXIT=$?

if [ $GEN_EXIT -ne 0 ]; then
  echo "Generate failed with exit code $GEN_EXIT" >&2
  if [ "$TELEGRAM" = true ]; then
    send_telegram_alert "⚠️ *podgen generate* failed for \`$PODCAST_NAME\` (exit $GEN_EXIT)"
  fi
  exit $GEN_EXIT
fi

# ── Run publish (only if generate succeeded) ──
if [ "$PUBLISH" = true ]; then
  bundle exec ruby bin/podgen publish "$PODCAST_NAME"
  PUB_EXIT=$?
  if [ $PUB_EXIT -ne 0 ]; then
    echo "Publish failed with exit code $PUB_EXIT" >&2
    if [ "$TELEGRAM" = true ]; then
      send_telegram_alert "⚠️ *podgen publish* failed for \`$PODCAST_NAME\` (exit $PUB_EXIT)"
    fi
    exit $PUB_EXIT
  fi
fi

exit 0
