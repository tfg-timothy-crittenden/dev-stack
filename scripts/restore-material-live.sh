#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

BACKUP_DIR="${1:-}"

DB_CONTAINER="material-db"
DB_USER="myuser"
DB_NAME="material_db"

MATERIAL_SERVICE="material-service"

MINIO_NETWORK="dev-stack_tfg-net"
MINIO_BUCKET="toefl"
MC_CONFIG="$PROJECT_ROOT/mc-config"

TEMP_DB_DUMP="/tmp/material-db-restore.dump"

cleanup() {
  docker compose exec "$DB_CONTAINER" \
    rm -f "$TEMP_DB_DUMP" >/dev/null 2>&1 || true
}

trap cleanup EXIT

if [[ -z "$BACKUP_DIR" ]]; then
  echo "Usage:"
  echo "  ./scripts/restore-material-live.sh backups/material/<timestamp>"
  exit 1
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "Backup directory does not exist:"
  echo "  $BACKUP_DIR"
  exit 1
fi

BACKUP_DIR="$(realpath "$BACKUP_DIR")"

SOURCE_DB_DUMP="$BACKUP_DIR/material-db.dump"
SOURCE_MINIO_DIR="$BACKUP_DIR/minio/$MINIO_BUCKET"

if [[ ! -f "$BACKUP_DIR/BACKUP_COMPLETE" ]]; then
  echo "ERROR: Backup is incomplete or was interrupted."
  echo "Missing:"
  echo "  $BACKUP_DIR/BACKUP_COMPLETE"
  exit 1
fi

if [[ ! -f "$BACKUP_DIR/BACKUP_VERIFIED" ]]; then
  echo "ERROR: Backup has not passed restore verification."
  echo
  echo "Run first:"
  echo "  ./scripts/verify-material-backup.sh \"$BACKUP_DIR\""
  exit 1
fi

if [[ ! -f "$SOURCE_DB_DUMP" ]]; then
  echo "Database dump not found:"
  echo "  $SOURCE_DB_DUMP"
  exit 1
fi

if [[ ! -d "$SOURCE_MINIO_DIR" ]]; then
  echo "MinIO backup not found:"
  echo "  $SOURCE_MINIO_DIR"
  exit 1
fi

echo
echo "=================================================="
echo "          LIVE MATERIAL RESTORE"
echo "=================================================="
echo
echo "WARNING:"
echo
echo "This will DELETE AND REPLACE:"
echo
echo "  PostgreSQL database: $DB_NAME"
echo "  MinIO bucket:        $MINIO_BUCKET"
echo
echo "Restore source:"
echo "  $BACKUP_DIR"
echo
echo "This backup has:"
echo "  BACKUP_COMPLETE"
echo "  BACKUP_VERIFIED"
echo

read -r -p "Type RESTORE MATERIAL LIVE to continue: " CONFIRMATION

if [[ "$CONFIRMATION" != "RESTORE MATERIAL LIVE" ]]; then
  echo
  echo "Confirmation did not match."
  echo "Restore cancelled."
  exit 1
fi

echo
echo "Validating PostgreSQL dump one final time..."

docker cp \
  "$SOURCE_DB_DUMP" \
  "$DB_CONTAINER:$TEMP_DB_DUMP"

docker compose exec "$DB_CONTAINER" \
  pg_restore \
  -l \
  "$TEMP_DB_DUMP" \
  >/dev/null

echo "PostgreSQL dump is valid."

echo
echo "Counting backed-up MinIO objects..."

OBJECT_COUNT="$(find "$SOURCE_MINIO_DIR" -type f | wc -l)"

echo "Objects found:"
echo "  $OBJECT_COUNT"

echo
echo "Stopping material-service to prevent writes..."

docker compose stop "$MATERIAL_SERVICE"

echo
echo "Creating safety backup of current live state..."

"$SCRIPT_DIR/backup-material.sh"

echo
echo "Safety backup completed."

echo
echo "=================================================="
echo " Restoring PostgreSQL"
echo "=================================================="

echo
echo "Dropping live database..."

docker compose exec "$DB_CONTAINER" \
  dropdb \
  -U "$DB_USER" \
  --if-exists \
  --force \
  "$DB_NAME"

echo
echo "Creating clean live database..."

docker compose exec "$DB_CONTAINER" \
  createdb \
  -U "$DB_USER" \
  "$DB_NAME"

echo
echo "Restoring database..."

docker compose exec "$DB_CONTAINER" \
  pg_restore \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  "$TEMP_DB_DUMP"

echo
echo "Database restore complete."

echo
echo "Restored tables:"

docker compose exec "$DB_CONTAINER" \
  psql \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -c '\dt'

echo
echo "=================================================="
echo " Restoring MinIO"
echo "=================================================="

echo
echo "Deleting live MinIO bucket:"
echo "  $MINIO_BUCKET"

docker run --rm \
  --network "$MINIO_NETWORK" \
  -v "$MC_CONFIG:/root/.mc" \
  minio/mc \
  rb \
  --force \
  "local/$MINIO_BUCKET"

echo
echo "Creating clean MinIO bucket..."

docker run --rm \
  --network "$MINIO_NETWORK" \
  -v "$MC_CONFIG:/root/.mc" \
  minio/mc \
  mb \
  "local/$MINIO_BUCKET"

echo
echo "Restoring MinIO objects..."

docker run --rm \
  --network "$MINIO_NETWORK" \
  -v "$MC_CONFIG:/root/.mc" \
  -v "$BACKUP_DIR:/backup:ro" \
  minio/mc \
  mirror \
  "/backup/minio/$MINIO_BUCKET" \
  "local/$MINIO_BUCKET"

echo
echo "Restored MinIO objects:"

docker run --rm \
  --network "$MINIO_NETWORK" \
  -v "$MC_CONFIG:/root/.mc" \
  minio/mc \
  ls \
  --recursive \
  "local/$MINIO_BUCKET"

echo
echo "Starting material-service..."

docker compose start "$MATERIAL_SERVICE"

echo
echo "Waiting for material-service..."
sleep 5

echo
echo "=================================================="
echo " LIVE MATERIAL RESTORE COMPLETE"
echo "=================================================="
echo
echo "Restored from:"
echo "  $BACKUP_DIR"
echo
echo "A safety backup of the previous live state was"
echo "created before the restore."