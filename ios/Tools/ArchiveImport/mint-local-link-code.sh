#!/usr/bin/env bash
# Mints a link code straight into a LOCAL Pebble Audio server's database, for trying
# archive-import against `dotnet run` without going through the admin page's passkey sign-in.
# Never for production: there, the admin page (Phones › Show a code) is the only way.
#
#   ./mint-local-link-code.sh                       # database pebbleaudio_import_test
#   ./mint-local-link-code.sh pebbleaudio           # another local database
#
# It talks to the local Postgres over its Unix socket (no host), so it cannot reach a remote
# server. A database with no account yet (setup not done) gets one named "admin" with no passkey,
# which makes this a scratch database: the passkey setup would no longer be able to create its
# own admin there. The code works once and lasts ten minutes, as the server's own codes do, and
# minting one ends any earlier unused code, as the admin page does.
set -euo pipefail

DB="${1:-pebbleaudio_import_test}"
ALPHABET="ABCDEFGHJKMNPQRSTUVWXYZ23456789"

code=""
while [ ${#code} -lt 8 ]; do
  byte=$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')
  # 248 is the largest multiple of 31 below 256: no bias.
  if [ "$byte" -lt 248 ]; then
    code+="${ALPHABET:$((byte % 31)):1}"
  fi
done

psql -v ON_ERROR_STOP=1 -q -d "$DB" -v code="$code" <<'SQL' >/dev/null
INSERT INTO "AspNetUsers" ("Id", "CreatedAt", "UserName", "NormalizedUserName", "EmailConfirmed",
    "PhoneNumberConfirmed", "TwoFactorEnabled", "LockoutEnabled", "AccessFailedCount",
    "SecurityStamp", "ConcurrencyStamp")
SELECT gen_random_uuid(), now(), 'admin', 'ADMIN', false, false, false, false, 0,
    gen_random_uuid()::text, gen_random_uuid()::text
WHERE NOT EXISTS (SELECT 1 FROM "AspNetUsers");

UPDATE "LinkCodes" SET "ExpiresAt" = now()
WHERE "UsedAt" IS NULL AND "ExpiresAt" > now();

INSERT INTO "LinkCodes" ("Id", "UserId", "CodeHash", "CreatedAt", "ExpiresAt")
SELECT gen_random_uuid(), "Id", sha256(convert_to(:'code', 'UTF8')), now(),
    now() + interval '10 minutes'
FROM "AspNetUsers" ORDER BY "CreatedAt" LIMIT 1;
SQL

echo "${code:0:4}-${code:4:4}"
