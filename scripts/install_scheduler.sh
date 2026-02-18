#!/bin/bash
# Install a launchd scheduler for a specific podcast.
# Usage: scripts/install_scheduler.sh <podcast_name>

set -e

PODCAST_NAME="$1"

if [ -z "$PODCAST_NAME" ]; then
  echo "Usage: scripts/install_scheduler.sh <podcast_name>"
  echo
  echo "Available podcasts:"
  for dir in "$(cd "$(dirname "$0")/.." && pwd)"/podcasts/*/; do
    [ -d "$dir" ] && echo "  - $(basename "$dir")"
  done
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LABEL="com.podcastagent.${PODCAST_NAME}"
PLIST_SRC="$PROJECT_DIR/com.podcastagent.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"

echo "Installing podcast scheduler..."
echo "  Podcast: $PODCAST_NAME"
echo "  Project: $PROJECT_DIR"
echo "  Label:   $LABEL"
echo "  Plist:   $PLIST_DEST"
echo "  Schedule: daily at 6:00 AM"
echo

# Unload existing if present
if launchctl list | grep -q "$LABEL"; then
  echo "Unloading existing scheduler..."
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

# Copy plist and replace placeholders with actual values
sed -e "s|PODGEN_DIR|$PROJECT_DIR|g" \
    -e "s|PODCAST_NAME|$PODCAST_NAME|g" \
    -e "s|com.podcastagent</string>|${LABEL}</string>|g" \
    "$PLIST_SRC" > "$PLIST_DEST"

# Load the scheduler
launchctl load "$PLIST_DEST"

echo "Scheduler installed and loaded."
echo "Verify with: launchctl list | grep podcastagent"
echo
echo "To uninstall:"
echo "  launchctl unload $PLIST_DEST"
echo "  rm $PLIST_DEST"
