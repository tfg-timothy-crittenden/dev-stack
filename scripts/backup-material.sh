#!/usr/bin/env bash

set -euo pipefail

BACKUP_ROOT="./backups/material"
TIMESTAMP="$(date +'%Y-%m-%d_%H%M%S')"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"

DB_CONTAINER="material-db"
DB_USER="myuser"
DB_NAME="material_db"

MINIO_NETWORK="dev-stack_tfg-net"
MINIO_BUCKET="toefl"
MC_CONFIG="$(pwd)/mc-config"

TEMP_DB_DUMP="/tmp/material-db.dump"

cleanup() {
  docker compose exec "$DB_CONTAINER" \
    rm -f "$TEMP_DB_DUMP" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo
echo "======================================"
echo " Material backup"
echo "======================================"
echo
echo "Creating backup:"
echo "  $BACKUP_DIR"
echo

mkdir -p "$BACKUP_DIR/minio"

echo "Backing up PostgreSQL..."

docker compose exec "$DB_CONTAINER" \
  pg_dump \
  -U "$DB_USER" \
  -Fc \
  -f "$TEMP_DB_DUMP" \
  "$DB_NAME"

echo
echo "Validating PostgreSQL dump..."

docker compose exec "$DB_CONTAINER" \
  pg_restore \
  -l \
  "$TEMP_DB_DUMP" \
  >/dev/null

echo "PostgreSQL dump is valid."

echo
echo "Copying PostgreSQL dump to backup directory..."

docker cp \
  "$DB_CONTAINER:$TEMP_DB_DUMP" \
  "$BACKUP_DIR/material-db.dump"

echo "PostgreSQL backup complete."

echo
echo "Backing up MinIO bucket:"
echo "  $MINIO_BUCKET"

docker run --rm \
  --network "$MINIO_NETWORK" \
  -v "$MC_CONFIG:/root/.mc" \
  -v "$(realpath "$BACKUP_DIR"):/backup" \
  minio/mc \
  mirror \
  "local/$MINIO_BUCKET" \
  "/backup/minio/$MINIO_BUCKET"

echo
echo "MinIO backup complete."

echo
echo "Marking backup as complete..."

touch "$BACKUP_DIR/BACKUP_COMPLETE"

echo
echo "======================================"
echo " Backup completed successfully"
echo "======================================"
echo
echo "Location:"
echo "  $BACKUP_DIR"
echo
echo "Contents:"

find "$BACKUP_DIR" \
  -type f \
  -printf '  %p (%s bytes)\n'

echo