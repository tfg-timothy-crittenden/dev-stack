#!/usr/bin/env bash

set -euo pipefail

BACKUP_DIR=""
KEEP=false

for arg in "$@"; do
  case "$arg" in
    --keep)
      KEEP=true
      ;;
    *)
      if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="$arg"
      else
        echo "Unknown argument: $arg"
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$BACKUP_DIR" ]]; then
  echo "Usage:"
  echo "  ./scripts/verify-material-backup.sh backups/material/<timestamp> [--keep]"
  exit 1
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "Backup directory does not exist:"
  echo "  $BACKUP_DIR"
  exit 1
fi

if [[ ! -f "$BACKUP_DIR/BACKUP_COMPLETE" ]]; then
  echo "ERROR: Backup is incomplete or was interrupted."
  echo "Missing:"
  echo "  $BACKUP_DIR/BACKUP_COMPLETE"
  exit 1
fi

DB_CONTAINER="material-db"
DB_USER="myuser"
RESTORE_DB="material_restore_test"

SOURCE_DB_DUMP="$BACKUP_DIR/material-db.dump"

MINIO_NETWORK="dev-stack_tfg-net"
MINIO_SOURCE_BUCKET="toefl"
MINIO_RESTORE_BUCKET="toefl-restore-test"
MC_CONFIG="$(pwd)/mc-config"

TEMP_DB_DUMP="/tmp/material-db-verify.dump"

cleanup_temp_dump() {
  docker compose exec "$DB_CONTAINER" \
    rm -f "$TEMP_DB_DUMP" >/dev/null 2>&1 || true
}

trap cleanup_temp_dump EXIT

if [[ ! -f "$SOURCE_DB_DUMP" ]]; then
  echo "Database dump not found:"
  echo "  $SOURCE_DB_DUMP"
  exit 1
fi

if [[ ! -d "$BACKUP_DIR/minio/$MINIO_SOURCE_BUCKET" ]]; then
  echo "MinIO backup not found:"
  echo "  $BACKUP_DIR/minio/$MINIO_SOURCE_BUCKET"
  exit 1
fi

echo
echo "======================================"
echo " Material backup verification"
echo "======================================"
echo
echo "Backup:"
echo "  $BACKUP_DIR"
echo
echo "Live data will NOT be modified."
echo

echo "Copying PostgreSQL dump into container..."

docker cp \
  "$SOURCE_DB_DUMP" \
  "$DB_CONTAINER:$TEMP_DB_DUMP"

echo
echo "Validating PostgreSQL archive..."

docker compose exec "$DB_CONTAINER" \
  pg_restore \
  -l \
  "$TEMP_DB_DUMP" \
  >/dev/null

echo "PostgreSQL archive is valid."

echo
echo "Removing previous temporary restore database..."

docker compose exec "$DB_CONTAINER" \
  dropdb \
  -U "$DB_USER" \
  --if-exists \
  --force \
  "$RESTORE_DB"

echo
echo "Creating temporary restore database:"
echo "  $RESTORE_DB"

docker compose exec "$DB_CONTAINER" \
  createdb \
  -U "$DB_USER" \
  "$RESTORE_DB"

echo
echo "Restoring PostgreSQL backup..."

docker compose exec "$DB_CONTAINER" \
  pg_restore \
  -U "$DB_USER" \
  -d "$RESTORE_DB" \
  "$TEMP_DB_DUMP"

echo
echo "Database restore complete."

echo
echo "Tables in restored database:"

docker compose exec "$DB_CONTAINER" \
  psql \
  -U "$DB_USER" \
  -d "$RESTORE_DB" \
  -c '\dt'

echo
echo "Removing previous temporary MinIO bucket..."

docker run --rm \
  --network "$MINIO_NETWORK" \
  -v "$MC_CONFIG:/root/.mc" \
  minio/mc \
  rb \
  --force \
  "local/$MINIO_RESTORE_BUCKET" \
  2>/dev/null || true

echo
echo "Creating temporary MinIO bucket:"
echo "  $MINIO_RESTORE_BUCKET"

docker run --rm \
  --network "$MINIO_NETWORK" \
  -v "$MC_CONFIG:/root/.mc" \
  minio/mc \
  mb \
  "local/$MINIO_RESTORE_BUCKET"

echo
echo "Restoring MinIO objects..."

docker run --rm \
  --network "$MINIO_NETWORK" \
  -v "$MC_CONFIG:/root/.mc" \
  -v "$(realpath "$BACKUP_DIR"):/backup:ro" \
  minio/mc \
  mirror \
  "/backup/minio/$MINIO_SOURCE_BUCKET" \
  "local/$MINIO_RESTORE_BUCKET"

echo
echo "Restored MinIO objects:"

docker run --rm \
  --network "$MINIO_NETWORK" \
  -v "$MC_CONFIG:/root/.mc" \
  minio/mc \
  ls \
  --recursive \
  "local/$MINIO_RESTORE_BUCKET"

echo
echo "======================================"
echo " Backup verification succeeded"
echo "======================================"

touch "$BACKUP_DIR/BACKUP_VERIFIED"

if [[ "$KEEP" == true ]]; then
  echo
  echo "Temporary restore targets kept:"
  echo "  Database:     $RESTORE_DB"
  echo "  MinIO bucket: $MINIO_RESTORE_BUCKET"
else
  echo
  echo "Cleaning up temporary restore targets..."

  docker compose exec "$DB_CONTAINER" \
    dropdb \
    -U "$DB_USER" \
    --if-exists \
    --force \
    "$RESTORE_DB"

  docker run --rm \
    --network "$MINIO_NETWORK" \
    -v "$MC_CONFIG:/root/.mc" \
    minio/mc \
    rb \
    --force \
    "local/$MINIO_RESTORE_BUCKET"

  echo "Temporary restore targets deleted."
fi

echo
echo "Created:"
echo "  $BACKUP_DIR/BACKUP_VERIFIED"
echo
echo "Your live material_db and toefl bucket were NOT modified."