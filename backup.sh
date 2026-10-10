#!/usr/bin/env bash
# Back up the n8n database, data volume and .env; rotate old copies; optional off-site upload.
set -Eeuo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$KIT_DIR/scripts/lib.sh"

BACKUP_ROOT="$KIT_DIR/backups"
REMOTE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --dir) BACKUP_ROOT="${2:-}"; shift 2 ;;
    --remote) REMOTE_OVERRIDE="${2:-}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

load_env
[[ -n "$REMOTE_OVERRIDE" ]] && RCLONE_REMOTE="$REMOTE_OVERRIDE"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/$STAMP"
KEEP="${BACKUP_KEEP_DAYS:-14}"
[[ "$KEEP" =~ ^[0-9]+$ ]] || die "BACKUP_KEEP_DAYS must be a number"

step "Create $DEST"
run install -d -m 700 "$DEST"

step "Dump Postgres database"
run_sh "docker compose --project-directory '$KIT_DIR' exec -T postgres pg_dump -U '$POSTGRES_USER' -d '$POSTGRES_DB' --clean --if-exists | gzip > '$DEST/db.sql.gz'"

step "Archive n8n data volume"
run_sh "docker run --rm -v n8n_n8n_data:/data:ro -v '$DEST':/backup alpine tar czf /backup/n8n_data.tar.gz -C /data ."

step "Copy .env (holds the encryption key)"
run install -m 600 "$KIT_DIR/.env" "$DEST/env.backup"

step "Write checksums"
run_sh "cd '$DEST' && sha256sum db.sql.gz n8n_data.tar.gz env.backup > SHA256SUMS"

step "Delete local backups older than $KEEP days"
run_sh "find '$BACKUP_ROOT' -mindepth 1 -maxdepth 1 -type d -mtime +$KEEP -exec rm -rf {} +"

step "Off-site copy"
if [[ -n "${RCLONE_REMOTE:-}" ]]; then
  run rclone copy "$DEST" "$RCLONE_REMOTE/$STAMP"
else
  log "RCLONE_REMOTE not set - local backup only"
fi

log "backup complete: $DEST"
