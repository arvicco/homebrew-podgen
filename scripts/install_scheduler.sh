#!/bin/bash
# Install a launchd scheduler for a specific podcast.
# Usage: scripts/install_scheduler.sh <podcast_name> <hour> <minute> [--publish] [--telegram] [--utc=HH:MM --zone=+HH:MM]
# <hour> <minute> are device-local (launchd reads them in the device zone).
# `podgen schedule` passes --utc/--zone; they are recorded in the plist as
# the schedule note that `schedule --status`, `podgen status` and the
# dev-loop yield guard read back (lib/production_run.rb).

set -e

PODCAST_NAME="$1"
HOUR="${2:-6}"
MINUTE="${3:-0}"
# Shift past positional args to leave only flags (--publish, --telegram)
if [ $# -ge 3 ]; then shift 3; else shift $#; fi

if [ -z "$PODCAST_NAME" ]; then
  echo "Usage: scripts/install_scheduler.sh <podcast_name> <hour> <minute> [--publish] [--telegram]"
  echo
  echo "Available podcasts:"
  for dir in "$(cd "$(dirname "$0")/.." && pwd)"/podcasts/*/; do
    [ -d "$dir" ] && echo "  - $(basename "$dir")"
  done
  exit 1
fi

# Collect flags for ProgramArguments
EXTRA_ARGS=""
FLAGS=""
UTC_TIME=""
ZONE=""
for arg in "$@"; do
  case "$arg" in
    --publish)  EXTRA_ARGS="${EXTRA_ARGS}        <string>--publish</string>\n"; FLAGS="$FLAGS --publish" ;;
    --telegram) EXTRA_ARGS="${EXTRA_ARGS}        <string>--telegram</string>\n"; FLAGS="$FLAGS --telegram" ;;
    --utc=*)    UTC_TIME="${arg#--utc=}" ;;
    --zone=*)   ZONE="${arg#--zone=}" ;;
  esac
done
NOTE=""
if [ -n "$UTC_TIME" ]; then
  NOTE="<!-- podgen-schedule utc=${UTC_TIME} zone=${ZONE} -->"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LABEL="com.podcastagent.${PODCAST_NAME}"
PLIST_SRC="$PROJECT_DIR/com.podcastagent.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"

printf "Installing podcast scheduler...\n"
printf "  Podcast:  %s\n" "$PODCAST_NAME"
printf "  Project:  %s\n" "$PROJECT_DIR"
printf "  Label:    %s\n" "$LABEL"
printf "  Plist:    %s\n" "$PLIST_DEST"
printf "  Schedule: daily at %d:%02d device time\n" "$HOUR" "$MINUTE"
[ -n "$UTC_TIME" ] && printf "  UTC:      %s (written for zone %s)\n" "$UTC_TIME" "$ZONE"
[ -n "$FLAGS" ] && printf "  Flags:   %s\n" "$FLAGS"
echo

# Unload existing if present
if launchctl list | grep -q "$LABEL"; then
  echo "Unloading existing scheduler..."
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

# Build plist from template with placeholder substitutions
sed -e "s|PODGEN_DIR|$PROJECT_DIR|g" \
    -e "s|PODCAST_NAME|$PODCAST_NAME|g" \
    -e "s|com.podcastagent</string>|${LABEL}</string>|g" \
    -e "s|SCHEDULE_HOUR|$HOUR|g" \
    -e "s|SCHEDULE_MINUTE|$MINUTE|g" \
    -e "s|SCHEDULE_NOTE|$NOTE|" \
    "$PLIST_SRC" > "$PLIST_DEST"

# Replace EXTRA_ARGS placeholder with flag entries (or remove if empty)
if [ -n "$EXTRA_ARGS" ]; then
  # Trim trailing \n to avoid blank line in plist
  EXTRA_ARGS="${EXTRA_ARGS%\\n}"
  perl -pi -e "s|.*EXTRA_ARGS.*|${EXTRA_ARGS}|" "$PLIST_DEST"
else
  perl -pi -e 's|.*EXTRA_ARGS.*\n||' "$PLIST_DEST"
fi

# Load the scheduler
launchctl load "$PLIST_DEST"

echo "Scheduler installed and loaded."
echo
echo "Check status:"
echo "  podgen schedule $PODCAST_NAME --status"
echo
echo "Remove:"
echo "  podgen schedule $PODCAST_NAME --remove"
