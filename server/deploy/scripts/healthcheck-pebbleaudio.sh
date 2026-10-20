#!/usr/bin/env bash
set -euo pipefail
url="${1:-https://pebbleaudio.okgodoit.com/healthz}"
curl --fail --silent --show-error --max-time 10 "$url" >/dev/null
