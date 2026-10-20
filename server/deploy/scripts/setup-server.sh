#!/usr/bin/env bash
# One-time (and re-runnable) server setup for Pebble Audio on the shared droplet.
# Run as root from a copy of the server/deploy directory:
#   sudo ./scripts/setup-server.sh [path-to-deploy-public-key]
# Idempotent: every step checks before it changes anything. Never touches other apps.
set -euo pipefail

app="pebbleaudio"
host="pebbleaudio.okgodoit.com"
port="5090"
deploy_user="${app}-deploy"
deploy_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deploy_pubkey="${1:-}"
# Npgsql's default is 100, the shared Postgres's whole max_connections.
pool_size=15

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

echo "== packages"
if ! command -v ffmpeg >/dev/null 2>&1; then
  apt-get update -qq
  # Without recommends: about 140 packages and 100 MB less (X11, OpenCL), as CI installs it.
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ffmpeg
fi
# Ubuntu 22.04's ffmpeg 4.4 decodes Speex only through libspeex (Sync/ClipTranscodeJob.cs).
ffmpeg -hide_banner -decoders 2>/dev/null | grep -q ' libspeex ' || { echo "ffmpeg lists no libspeex decoder; clips cannot be converted" >&2; exit 1; }
command -v dotnet >/dev/null || { echo "dotnet runtime missing (expected aspnetcore-runtime-10.0)"; exit 1; }

echo "== users"
if ! id "$app" >/dev/null 2>&1; then
  useradd --system --home-dir "/var/lib/${app}" --shell /usr/sbin/nologin "$app"
fi
if ! id "$deploy_user" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$deploy_user"
fi
install -d -o "$deploy_user" -g "$deploy_user" -m 700 "/home/${deploy_user}/.ssh"
if [[ -n "$deploy_pubkey" ]]; then
  if [[ ! -f "$deploy_pubkey" ]]; then echo "public key not found: $deploy_pubkey" >&2; exit 1; fi
  touch "/home/${deploy_user}/.ssh/authorized_keys"
  if ! grep -qxF "$(cat "$deploy_pubkey")" "/home/${deploy_user}/.ssh/authorized_keys"; then
    cat "$deploy_pubkey" >> "/home/${deploy_user}/.ssh/authorized_keys"
  fi
  chown "$deploy_user:$deploy_user" "/home/${deploy_user}/.ssh/authorized_keys"
  chmod 600 "/home/${deploy_user}/.ssh/authorized_keys"
fi

echo "== directories"
install -d -o "$app" -g "$app" -m 750 "/opt/${app}" "/opt/${app}/releases"
install -d -o "$app" -g "$app" -m 750 "/var/lib/${app}" "/var/lib/${app}/clips" "/var/lib/${app}/data-protection-keys"
install -d -o postgres -g postgres -m 750 "/var/backups/${app}"
install -d -o root -g "$app" -m 750 "/etc/${app}"

echo "== environment file"
env_file="/etc/${app}/${app}.env"
if [[ ! -f "$env_file" ]]; then
  db_password="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-40)"
  cat > "$env_file" <<EOF
ASPNETCORE_ENVIRONMENT=Production
ASPNETCORE_URLS=http://127.0.0.1:${port}
ConnectionStrings__DefaultConnection=Host=127.0.0.1;Port=5432;Database=${app};Username=${app};Password=${db_password};Maximum Pool Size=${pool_size}
PebbleAudio__PublicOrigin=https://${host}
PebbleAudio__ClipsPath=/var/lib/${app}/clips
DataProtection__KeysPath=/var/lib/${app}/data-protection-keys
EOF
  chown root:"$app" "$env_file"
  chmod 640 "$env_file"
  echo "   wrote ${env_file}"
else
  echo "   ${env_file} exists, left as is"
fi
if ! grep -q '^ConnectionStrings__DefaultConnection=.*Maximum Pool Size=' "$env_file"; then
  sed -i -E "s/^(ConnectionStrings__DefaultConnection=\"?[^\"]*[^\";])(;?)(\"?)\$/\1;Maximum Pool Size=${pool_size}\3/" "$env_file"
  echo "   capped the connection pool at ${pool_size} (restart ${app} to apply)"
fi
db_password="$(sed -n 's/^ConnectionStrings__DefaultConnection=.*Password=\([^;]*\).*/\1/p' "$env_file")"

echo "== postgres role and database"
if ! sudo -u postgres psql -Atqc "select 1 from pg_roles where rolname='${app}'" | grep -q 1; then
  sudo -u postgres psql -qc "create role ${app} login password '${db_password}'"
fi
if ! sudo -u postgres psql -Atqc "select 1 from pg_database where datname='${app}'" | grep -q 1; then
  sudo -u postgres createdb --owner="$app" "$app"
fi

echo "== scripts, unit, timers"
install -m 755 "${deploy_dir}/scripts/deploy-${app}.sh" "/opt/${app}/deploy-${app}.sh"
install -m 755 "${deploy_dir}/scripts/healthcheck-${app}.sh" "/opt/${app}/healthcheck-${app}.sh"
install -m 755 "${deploy_dir}/scripts/backup-${app}-db.sh" "/opt/${app}/backup-${app}-db.sh"
install -m 644 "${deploy_dir}/${app}.service" "/etc/systemd/system/${app}.service"
install -m 644 "${deploy_dir}/systemd/${app}-healthcheck.service" "/etc/systemd/system/${app}-healthcheck.service"
install -m 644 "${deploy_dir}/systemd/${app}-healthcheck.timer" "/etc/systemd/system/${app}-healthcheck.timer"
install -m 644 "${deploy_dir}/systemd/${app}-backup.service" "/etc/systemd/system/${app}-backup.service"
install -m 644 "${deploy_dir}/systemd/${app}-backup.timer" "/etc/systemd/system/${app}-backup.timer"
systemctl daemon-reload
systemctl enable "${app}.service" >/dev/null 2>&1 || true
systemctl enable --now "${app}-healthcheck.timer" "${app}-backup.timer" >/dev/null

echo "== sudoers"
cat > "/etc/sudoers.d/${deploy_user}" <<EOF
${deploy_user} ALL=(root) NOPASSWD: /opt/${app}/deploy-${app}.sh *
EOF
chmod 440 "/etc/sudoers.d/${deploy_user}"
visudo -cf "/etc/sudoers.d/${deploy_user}" >/dev/null

echo "== nginx"
# The site is installed from this checkout only, never by a deploy: nginx opens the log paths a site names as
# root, so a site file from an artifact would be root on the shared droplet.
site="/etc/nginx/sites-available/${app}"
if [[ -f "/etc/letsencrypt/live/${host}/fullchain.pem" ]]; then
  if cmp -s "${deploy_dir}/nginx/${app}.conf" "$site"; then
    echo "   ${site} matches the repo"
  else
    previous="$(mktemp)"
    [[ -f "$site" ]] && cp "$site" "$previous"
    install -m 644 "${deploy_dir}/nginx/${app}.conf" "$site"
    ln -sfn "$site" "/etc/nginx/sites-enabled/${app}"
    if nginx -t; then
      systemctl reload nginx
      echo "   installed ${site} from the repo"
    else
      if [[ -s "$previous" ]]; then install -m 644 "$previous" "$site"; else rm -f "$site" "/etc/nginx/sites-enabled/${app}"; fi
      rm -f "$previous"
      echo "   the repo's site failed nginx -t; the previous one is back" >&2
      exit 1
    fi
    rm -f "$previous"
  fi
elif [[ ! -f "$site" ]]; then
  # First install: HTTP only, so certbot can take over and add the TLS server block.
  cat > "$site" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${host};

    access_log /var/log/nginx/${app}-access.log;
    error_log /var/log/nginx/${app}-error.log;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  ln -sfn "$site" "/etc/nginx/sites-enabled/${app}"
  nginx -t
  systemctl reload nginx
  echo "   installed HTTP site; run: certbot certonly --nginx -d ${host}, then this script again for the TLS site"
else
  echo "   ${site} exists and there is no certificate yet; left as is"
fi

echo "done"
