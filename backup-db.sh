#!/usr/bin/env bash
# Nightly Postgres backup for the archery stack (Pi-side, tier 1).
# Dumps the `db` container to a timestamped gzip, prunes copies older than RETAIN_DAYS.
# Mirrors the game-shop mongodump pattern. The PC then pulls these via the shared
# pull-pi-backups.ps1 (tier 2) — see the deploy README.
#
# Cron (Pi), nightly at 22:15:
#   15 22 * * *  /home/<user>/archery-club-deploy/backup-db.sh >> /home/<user>/archery-club-deploy/backups/backup.log 2>&1
set -euo pipefail

cd "$(dirname "$0")"

# Load POSTGRES_* from the same .env the stack uses.
set -a
[ -f .env ] && . ./.env
set +a

RETAIN_DAYS="${RETAIN_DAYS:-14}"
OUT_DIR="./backups"
mkdir -p "$OUT_DIR"

STAMP="$(date +%Y-%m-%d_%H%M%S)"
OUT_FILE="$OUT_DIR/archery_${STAMP}.sql.gz"

echo "[$(date)] dumping archery DB -> $OUT_FILE"
# pg_dump runs INSIDE the db container (no host psql client needed).
docker compose -f docker-compose.prod.yml exec -T db \
	pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --no-owner --clean --if-exists \
	| gzip > "$OUT_FILE"

# Verify the dump isn't empty/corrupt before pruning old ones.
if [ ! -s "$OUT_FILE" ] || ! gzip -t "$OUT_FILE"; then
	echo "[$(date)] ERROR: backup is empty or corrupt — keeping old backups, not pruning."
	exit 1
fi

echo "[$(date)] OK ($(du -h "$OUT_FILE" | cut -f1)). Pruning > ${RETAIN_DAYS} days."
find "$OUT_DIR" -name 'archery_*.sql.gz' -mtime +"${RETAIN_DAYS}" -delete

echo "[$(date)] done."
