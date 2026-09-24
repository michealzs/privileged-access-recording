#!/bin/sh
# Delete session recordings older than RECORDING_RETENTION_DAYS.
#
# This is the one process in the stack whose job is to destroy evidence, so it
# is deliberately small enough to read in full, it refuses to run against a
# path it was not given, and it starts in dry run mode.
#
# Run standalone to see what would go:
#   RECORDING_PATH=/var/lib/guacamole/recordings RECORDING_RETENTION_DAYS=90 \
#     PRUNE_DRY_RUN=1 PRUNE_INTERVAL_SECONDS=0 sh prune-recordings.sh

set -eu

RECORDING_PATH="${RECORDING_PATH:-/var/lib/guacamole/recordings}"
RECORDING_RETENTION_DAYS="${RECORDING_RETENTION_DAYS:-90}"
PRUNE_INTERVAL_SECONDS="${PRUNE_INTERVAL_SECONDS:-86400}"
PRUNE_DRY_RUN="${PRUNE_DRY_RUN:-1}"

log() {
  printf '%s prune-recordings: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"
}

case "$RECORDING_RETENTION_DAYS" in
  '' | *[!0-9]*)
    log "RECORDING_RETENTION_DAYS must be a whole number of days, got '$RECORDING_RETENTION_DAYS'"
    exit 1
    ;;
esac

if [ "$RECORDING_RETENTION_DAYS" -lt 1 ]; then
  log "RECORDING_RETENTION_DAYS must be at least 1, got '$RECORDING_RETENTION_DAYS'"
  exit 1
fi

if [ ! -d "$RECORDING_PATH" ]; then
  log "recording path '$RECORDING_PATH' is not a directory"
  exit 1
fi

# Refuse to treat a filesystem root or a mount point with nothing in it as a
# recording directory. An empty volume usually means the mount did not happen.
case "$RECORDING_PATH" in
  / | /var | /var/lib | /home | /root)
    log "refusing to prune '$RECORDING_PATH'"
    exit 1
    ;;
esac

prune_once() {
  count=$(find "$RECORDING_PATH" -type f -mtime "+$RECORDING_RETENTION_DAYS" | wc -l | tr -d ' ')

  if [ "$count" -eq 0 ]; then
    log "nothing older than ${RECORDING_RETENTION_DAYS}d under $RECORDING_PATH"
    return 0
  fi

  if [ "$PRUNE_DRY_RUN" = "1" ]; then
    log "dry run: $count file(s) older than ${RECORDING_RETENTION_DAYS}d would be deleted"
    find "$RECORDING_PATH" -type f -mtime "+$RECORDING_RETENTION_DAYS" -exec echo "  would delete {}" \;
    return 0
  fi

  log "deleting $count file(s) older than ${RECORDING_RETENTION_DAYS}d"
  find "$RECORDING_PATH" -type f -mtime "+$RECORDING_RETENTION_DAYS" -delete
  # Recordings are written into per-day directories, so clear the empty shells
  # left behind. -mindepth 1 keeps the mount point itself.
  find "$RECORDING_PATH" -mindepth 1 -type d -empty -delete
}

log "retention ${RECORDING_RETENTION_DAYS}d, path $RECORDING_PATH, dry run $PRUNE_DRY_RUN"

while true; do
  prune_once

  if [ "$PRUNE_INTERVAL_SECONDS" -le 0 ]; then
    log "PRUNE_INTERVAL_SECONDS is 0, exiting after one pass"
    exit 0
  fi

  sleep "$PRUNE_INTERVAL_SECONDS"
done
