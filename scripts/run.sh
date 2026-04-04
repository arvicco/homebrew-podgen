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

# Load podcast .env for Telegram credentials
ENV_FILE="$PROJECT_DIR/podcasts/$PODCAST_NAME/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

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
bundle exec ruby bin/podgen generate --quiet "$PODCAST_NAME"
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
