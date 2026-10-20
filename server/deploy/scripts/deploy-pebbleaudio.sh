#!/usr/bin/env bash
# Activate a built artifact on the droplet. Run as root (GitHub Actions does it through the
# pebbleaudio-deploy user's sudo rule; it can also be run by hand).
#   deploy-pebbleaudio.sh <git-sha> <artifact.tar.gz>
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: deploy-pebbleaudio.sh <git-sha> <artifact.tar.gz>" >&2
  exit 64
fi

app="pebbleaudio"
host="pebbleaudio.okgodoit.com"
revision="$1"
artifact_path="$2"
release_root="/opt/${app}/releases"
release_dir="${release_root}/${revision}"
current_link="/opt/${app}/current"
backup_dir="/var/backups/${app}"
env_file="/etc/${app}/${app}.env"
previous_target=""

if [[ ! "$revision" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  echo "Invalid revision: ${revision}" >&2
  exit 64
fi
if [[ ! -f "$artifact_path" ]]; then
  echo "Artifact not found: ${artifact_path}" >&2
  exit 66
fi
if [[ -L "$current_link" ]]; then
  previous_target="$(readlink -f "$current_link")"
fi

rollback() {
  echo "Deploy failed; rolling back." >&2
  if [[ -n "$previous_target" && -d "$previous_target" ]]; then
    ln -sfn "$previous_target" "${current_link}.new"
    mv -Tf "${current_link}.new" "$current_link"
    systemctl restart "$app" || true
  fi
}
trap rollback ERR

install -d -o "$app" -g "$app" -m 750 "$release_root"
install -d -o postgres -g postgres -m 750 "$backup_dir"
rm -rf "$release_dir"
install -d -o "$app" -g "$app" -m 750 "$release_dir"
tar -xzf "$artifact_path" -C "$release_dir"
chown -R "$app:$app" "$release_dir"
chmod +x "${release_dir}/app/PebbleAudio.Server" "${release_dir}/efbundle"

if [[ -f "${release_dir}/nginx/${app}.conf" ]]; then
  echo "Installing nginx site."
  install -m 644 "${release_dir}/nginx/${app}.conf" "/etc/nginx/sites-available/${app}"
  ln -sfn "/etc/nginx/sites-available/${app}" "/etc/nginx/sites-enabled/${app}"
  nginx -t
  systemctl reload nginx
fi

echo "Backing up the database."
sudo -u postgres pg_dump --format=custom --file="${backup_dir}/${app}-$(date -u +%Y%m%dT%H%M%SZ).dump" "$app"

echo "Running migrations."
connection_string="$(sed -n 's/^ConnectionStrings__DefaultConnection=//p' "$env_file")"
connection_string="${connection_string%\"}"
connection_string="${connection_string#\"}"
if [[ -z "$connection_string" ]]; then
  echo "ConnectionStrings__DefaultConnection is missing from ${env_file}." >&2
  exit 78
fi
"${release_dir}/efbundle" --connection "$connection_string"

echo "Activating ${release_dir}."
ln -sfn "$release_dir" "${current_link}.new"
mv -Tf "${current_link}.new" "$current_link"
systemctl restart "$app"

echo "Waiting for the health check."
for attempt in {1..15}; do
  if curl --fail --silent --show-error --max-time 10 "https://${host}/healthz" >/dev/null 2>&1 \
     || curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:5090/healthz" >/dev/null 2>&1; then
    trap - ERR
    find "$release_root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | awk 'NR>5 {print $2}' | xargs -r rm -rf
    find "$backup_dir" -name "${app}-*.dump" -type f -mtime +14 -delete
    rm -f "$artifact_path"
    echo "Deployed ${revision}."
    exit 0
  fi
  sleep 4
done

echo "Health check never passed." >&2
false
