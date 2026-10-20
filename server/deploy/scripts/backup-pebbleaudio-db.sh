#!/usr/bin/env bash
# Nightly logical dump of the pebbleaudio database to the local backups directory.
# Offsite copies are a later step (decided 2026-10-20: not yet).
set -euo pipefail
backup_dir="${1:-/var/backups/pebbleaudio}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_path="${backup_dir}/pebbleaudio-${timestamp}.dump"
mkdir -p "$backup_dir"
if [[ "$(id -un)" == "postgres" ]]; then
  pg_dump --format=custom --file="$backup_path" pebbleaudio
else
  sudo -u postgres pg_dump --format=custom --file="$backup_path" pebbleaudio
fi
chmod 640 "$backup_path"
find "$backup_dir" -name 'pebbleaudio-*.dump' -type f -mtime +14 -delete
printf '%s\n' "$backup_path"
