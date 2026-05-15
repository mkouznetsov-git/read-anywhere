#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: readarc_update_relay.sh /tmp/readarc-update.zip" >&2
  exit 2
fi

ZIP="$1"
ROOT="${READARC_RELAY_ROOT:-/opt/readarc}"
APP="$ROOT/app"
PROJECT="${READARC_COMPOSE_PROJECT:-readarc}"
DATA_DIR="${READARC_RELAY_HOST_DATA_DIR:-$ROOT/server_data/relay}"
STAMP="$(date +%Y%m%d_%H%M%S)"
EXTRACT="$ROOT/extract_$STAMP"
NEXT="$ROOT/app_next_$STAMP"
BACKUP="$ROOT/app_backup_$STAMP"
FAILED="$ROOT/app_failed_$STAMP"
ROLLBACK_READY=0

compose_in() {
  local dir="$1"
  shift
  READARC_RELAY_HOST_DATA_DIR="$DATA_DIR" docker compose -p "$PROJECT" -f "$dir/docker-compose.yml" "$@"
}

cleanup_extract() {
  rm -rf "$EXTRACT" "$NEXT" 2>/dev/null || true
}

force_remove_stale_compose_objects() {
  docker rm -f \
    "${PROJECT}-relay-1" \
    "${PROJECT}_relay_1" \
    "readarc-relay-1" \
    "readarc_relay_1" \
    >/dev/null 2>&1 || true
  docker network rm "${PROJECT}_default" >/dev/null 2>&1 || true
}

rollback() {
  local exit_code=$?
  trap - ERR
  echo
  echo "Update failed. Rolling back..." >&2
  if [[ "$ROLLBACK_READY" != "1" ]]; then
    cleanup_extract
    exit "$exit_code"
  fi
  if [[ -d "$APP" && -f "$APP/docker-compose.yml" ]]; then
    compose_in "$APP" down --remove-orphans >/dev/null 2>&1 || true
  fi
  force_remove_stale_compose_objects
  if [[ -d "$APP" ]]; then
    rm -rf "$FAILED"
    mv "$APP" "$FAILED"
    echo "Failed version moved to: $FAILED" >&2
  fi
  if [[ -d "$BACKUP" ]]; then
    mv "$BACKUP" "$APP"
    echo "Restored backup: $BACKUP" >&2
    compose_in "$APP" up -d --build --remove-orphans || true
  else
    echo "No backup was available." >&2
  fi
  cleanup_extract
  exit "$exit_code"
}

trap rollback ERR

if [[ ! -f "$ZIP" ]]; then
  echo "Archive not found: $ZIP" >&2
  exit 2
fi

mkdir -p "$ROOT" "$DATA_DIR"

echo "ReadArc relay update"
echo "Archive: $ZIP"
echo "Root:    $ROOT"
echo "Data:    $DATA_DIR"
echo

# One-time migration from old in-app compose data location to stable host data.
if [[ -d "$APP/server_data/relay" ]] && [[ -z "$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]]; then
  echo "Migrating relay data to stable host data directory..."
  cp -a "$APP/server_data/relay/." "$DATA_DIR/" 2>/dev/null || true
fi

echo "Extracting archive..."
rm -rf "$EXTRACT" "$NEXT"
mkdir -p "$EXTRACT"
unzip -q "$ZIP" -d "$EXTRACT"

SRC="$EXTRACT"
if [[ ! -f "$SRC/docker-compose.yml" ]]; then
  COMPOSE_PATH="$(find "$EXTRACT" -maxdepth 3 -type f -name docker-compose.yml -print -quit)"
  if [[ -z "$COMPOSE_PATH" ]]; then
    echo "docker-compose.yml not found in archive." >&2
    exit 1
  fi
  SRC="$(dirname "$COMPOSE_PATH")"
fi

if [[ ! -f "$SRC/server/rendezvous_relay/main.py" ]]; then
  echo "Relay source server/rendezvous_relay/main.py not found in archive root: $SRC" >&2
  exit 1
fi

cp -a "$SRC" "$NEXT"
printf 'READARC_RELAY_HOST_DATA_DIR=%s\n' "$DATA_DIR" > "$NEXT/.env"

echo "Validating docker compose config..."
compose_in "$NEXT" config >/dev/null

echo "Stopping current relay and removing stale compose objects..."
if [[ -d "$APP" && -f "$APP/docker-compose.yml" ]]; then
  compose_in "$APP" down --remove-orphans || true
fi
force_remove_stale_compose_objects

if [[ -d "$APP" ]]; then
  mv "$APP" "$BACKUP"
  echo "Backup created: $BACKUP"
  ROLLBACK_READY=1
fi
mv "$NEXT" "$APP"
ROLLBACK_READY=1

echo "Starting new relay..."
compose_in "$APP" up -d --build --remove-orphans

echo "Checking local health..."
for attempt in {1..30}; do
  if [[ "$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null | tr -d '\r\n')" == "ok" ]]; then
    echo "Relay health: ok"
    cleanup_extract
    echo "Relay update finished successfully."
    exit 0
  fi
  sleep 1
done

echo "Relay did not become healthy in time." >&2
false
