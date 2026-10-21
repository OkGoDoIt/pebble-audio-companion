#!/usr/bin/env bash
# Run every five minutes by pebbleaudio-healthcheck.timer, as root.
#   healthcheck-pebbleaudio.sh [public-url]
# The app is checked on loopback, so trouble in nginx, TLS, or DNS never restarts it. When it fails to answer at all
# (no connection, a timeout) several checks in a row, it is restarted. Every failure is logged; the one that reaches
# the limit is an error in journald (journalctl -t pebbleaudio-healthcheck -p err). A 503 is the database: the app
# answered, so it is reported, not restarted. The public URL is checked last and only reported.
set -uo pipefail

app="pebbleaudio"
limit="${PEBBLEAUDIO_HEALTH_FAILURES:-3}"
local_url="${PEBBLEAUDIO_HEALTH_URL:-http://127.0.0.1:5090/healthz}"
public_url="${1:-https://pebbleaudio.okgodoit.com/healthz}"
# On tmpfs: a reboot starts the count again.
state="/run/${app}-healthcheck.failures"

log() {
  logger -t "${app}-healthcheck" -p "user.$1" -- "$2"
  echo "$2" >&2
}

code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 "$local_url" || true)"
if [[ "$code" != "200" ]]; then
  failures=$(( $(cat "$state" 2>/dev/null || echo 0) + 1 ))
  echo "$failures" > "$state"
  what="answered ${local_url} with ${code}"
  [[ "$code" == "000" ]] && what="did not answer ${local_url}"
  if (( failures < limit )); then
    log warning "${app} ${what} (${failures} of ${limit} in a row)."
  elif [[ "$code" == "000" ]]; then
    log err "${app} ${what} ${failures} times in a row; restarting it."
    rm -f "$state"
    systemctl restart "$app"
  else
    log err "${app} ${what} ${failures} times in a row; it answers, so it is not restarted (a 503 is the database)."
  fi
  exit 1
fi
rm -f "$state"

if ! curl --fail --silent --show-error --max-time 10 "$public_url" >/dev/null; then
  log err "${public_url} failed while ${app} answers on loopback: check nginx, the certificate, or DNS."
  exit 1
fi
