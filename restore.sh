#!/usr/bin/env bash
# Restore a backup made by backup.sh, then verify n8n is healthy and workflows are present.
set -Eeuo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$KIT_DIR/scripts/lib.sh"

SRC=""
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -*) die "unknown option: $1" ;;
    *) SRC="$1"; shift ;;
  esac
done
[[ -n "$SRC" ]] || die "usage: ./restore.sh backups/<timestamp> [--yes] [--dry-run]"

if [[ "$DRY_RUN" != "1" ]]; then
  [[ -d "$SRC" ]] || die "backup folder not found: $SRC"
  for f in db.sql.gz n8n_data.tar.gz env.backup SHA256SUMS; do
    [[ -f "$SRC/$f" ]] || die "missing $f in $SRC"
  done
fi
load_env

step "Verify checksums"
run_sh "cd '$SRC' && sha256sum -c SHA256SUMS"

if [[ "$ASSUME_YES" != "1" && "$DRY_RUN" != "1" ]]; then
  read -r -p "This replaces the current n8n data with $SRC. Type RESTORE to continue: " answer
  [[ "$answer" == "RESTORE" ]] || die "aborted"
fi

step "Stop n8n (Postgres keeps running)"
compose stop n8n

step "Restore database"
run_sh "gunzip -c '$SRC/db.sql.gz' | docker compose --project-directory '$KIT_DIR' exec -T postgres psql -v ON_ERROR_STOP=1 -U '$POSTGRES_USER' -d '$POSTGRES_DB'"

step "Restore n8n data volume"
run_sh "docker run --rm -v n8n_n8n_data:/data -v '$SRC':/backup:ro alpine sh -c 'rm -rf /data/* && tar xzf /backup/n8n_data.tar.gz -C /data'"

step "Start n8n"
compose start n8n

step "Verify: health endpoint and workflow count"
run_sh "docker compose --project-directory '$KIT_DIR' exec -T n8n wget -qO- http://127.0.0.1:5678/healthz"
run_sh "docker compose --project-directory '$KIT_DIR' exec -T postgres psql -U '$POSTGRES_USER' -d '$POSTGRES_DB' -tAc 'SELECT count(*) FROM workflow_entity'"

log "restore complete - if credentials fail to decrypt, compare N8N_ENCRYPTION_KEY with $SRC/env.backup"
