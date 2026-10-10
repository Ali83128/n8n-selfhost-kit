#!/usr/bin/env bash
# Update n8n to a pinned version: back up first, then pull and restart.
set -Eeuo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$KIT_DIR/scripts/lib.sh"

NEW_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --version) NEW_VERSION="${2:-}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: ./update.sh --version 1.65.0 [--dry-run]"

load_env
log "current n8n: ${N8N_VERSION:-unknown} -> target: $NEW_VERSION"

step "Back up before updating"
if [[ "$DRY_RUN" == "1" ]]; then
  run "$KIT_DIR/backup.sh"
else
  "$KIT_DIR/backup.sh"
fi

step "Pin the new version in .env"
run sed -i "s/^N8N_VERSION=.*/N8N_VERSION=$NEW_VERSION/" "$KIT_DIR/.env"

step "Pull and restart n8n"
compose pull n8n
compose up -d n8n

step "Verify health"
run_sh "docker compose --project-directory '$KIT_DIR' exec -T n8n wget -qO- http://127.0.0.1:5678/healthz"

log "rollback: set N8N_VERSION back to ${N8N_VERSION:-previous} in .env and run: docker compose up -d n8n"
