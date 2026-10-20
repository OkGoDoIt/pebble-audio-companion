#!/usr/bin/env bash
# Build the release artifact CI builds, on this Mac, and deploy it by hand as root, for when CI is not wanted.
#   deploy/scripts/publish-local.sh                     # deploys HEAD to root@pebbleaudio.okgodoit.com
#   PEBBLEAUDIO_DEPLOY_TARGET=root@134.209.0.150 PEBBLEAUDIO_DEPLOY_PORT=22 deploy/scripts/publish-local.sh
# Runs the full test suite first (it needs the local Postgres). The packaging mirrors the "Package deployment
# artifact" step of .github/workflows/server-deploy.yml; keep the two in step.
set -euo pipefail

server_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target="${PEBBLEAUDIO_DEPLOY_TARGET:-root@pebbleaudio.okgodoit.com}"
port="${PEBBLEAUDIO_DEPLOY_PORT:-22}"
artifact_name="pebbleaudio-production"
project="src/PebbleAudio.Server/PebbleAudio.Server.csproj"

cd "$server_dir"
revision="$(git rev-parse HEAD)"
if [[ -n "$(git status --porcelain -- .)" ]]; then
  echo "Note: server/ has uncommitted changes; they deploy under ${revision:0:12}." >&2
fi

echo "== build and test"
dotnet restore PebbleAudio.Server.slnx
dotnet build PebbleAudio.Server.slnx --configuration Release --no-restore
dotnet test PebbleAudio.Server.slnx --configuration Release --no-build

echo "== publish"
rm -rf artifacts
dotnet tool restore
dotnet publish "$project" \
  --configuration Release \
  --runtime linux-x64 \
  --self-contained false \
  --output artifacts/app
ConnectionStrings__DefaultConnection="Host=127.0.0.1;Port=5432;Database=pebbleaudio;Username=pebbleaudio;Password=placeholder" \
  dotnet ef migrations bundle \
    --project "$project" \
    --startup-project "$project" \
    --configuration Release \
    --target-runtime linux-x64 \
    --output artifacts/efbundle-real

echo "== package"
# The nginx site is not in the artifact: setup-server.sh installs it from the repo. `efbundle` is for a
# droplet whose deploy script predates running efbundle-real as the service user itself.
mkdir -p artifacts/package
cp -R artifacts/app artifacts/package/app
cp artifacts/efbundle-real artifacts/package/efbundle-real
cat > artifacts/package/efbundle <<'BUNDLE'
#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(id -u)" -eq 0 ]]; then
  exec runuser -u pebbleaudio -- "${script_dir}/efbundle-real" "$@"
fi
exec "${script_dir}/efbundle-real" "$@"
BUNDLE
chmod +x artifacts/package/efbundle artifacts/package/efbundle-real
printf '%s\n' "$revision" > artifacts/package/REVISION
tarball="${artifact_name}-${revision}.tar.gz"
# No macOS extended attributes or AppleDouble files: GNU tar on the droplet would warn about each one.
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C artifacts/package -czf "artifacts/${tarball}" .

echo "== deploy ${revision:0:12} to ${target}"
scp -P "$port" "artifacts/${tarball}" "${target}:/tmp/${tarball}"
ssh -p "$port" "$target" "/opt/pebbleaudio/deploy-pebbleaudio.sh '${revision}' '/tmp/${tarball}'"
