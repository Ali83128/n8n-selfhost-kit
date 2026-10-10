#!/usr/bin/env bash
# Install n8n + Postgres + Caddy (automatic HTTPS) on a fresh Ubuntu 22.04/24.04 VPS.
set -Eeuo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$KIT_DIR/scripts/lib.sh"

DOMAIN=""
EMAIL=""
N8N_VERSION="1.64.3"
TZ_NAME="UTC"
SKIP_FIREWALL=0

usage() {
  cat << USAGE
Usage: sudo ./install.sh --domain n8n.example.com --email you@example.com [options]

  --domain NAME     public hostname for n8n (DNS A record must point here)
  --email ADDR      email for Let's Encrypt certificate notices
  --version VER     n8n image version to pin (default $N8N_VERSION)
  --tz ZONE         timezone, e.g. Europe/London (default UTC)
  --no-firewall     do not touch UFW
  --dry-run         print every step without changing anything
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --version) N8N_VERSION="${2:-}"; shift 2 ;;
    --tz) TZ_NAME="${2:-}"; shift 2 ;;
    --no-firewall) SKIP_FIREWALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done

[[ -n "$DOMAIN" ]] || { usage; die "--domain is required"; }
[[ -n "$EMAIL" ]] || { usage; die "--email is required"; }
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "invalid domain: $DOMAIN"
[[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "invalid email: $EMAIL"
[[ "$N8N_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "pin an exact version like 1.64.3, got: $N8N_VERSION"

[[ "$DRY_RUN" == "1" ]] && log "DRY RUN - nothing will be changed"
require_root

step "Check operating system"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  log "detected ${PRETTY_NAME:-unknown}"
  if [[ "${ID:-}" != "ubuntu" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "not Ubuntu - continuing because this is a dry run"
    else
      die "Ubuntu 22.04 or 24.04 required"
    fi
  fi
fi

step "Install Docker Engine from the official repository"
if command -v docker >/dev/null 2>&1 && [[ "$DRY_RUN" != "1" ]]; then
  log "docker already installed: $(docker --version)"
else
  run apt-get update -y
  run apt-get install -y ca-certificates curl gnupg
  run install -m 0755 -d /etc/apt/keyrings
  run_sh "curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc"
  run chmod a+r /etc/apt/keyrings/docker.asc
  run_sh "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list"
  run apt-get update -y
  run apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  run systemctl enable --now docker
fi

step "Firewall: allow SSH, HTTP, HTTPS only"
if [[ "$SKIP_FIREWALL" == "1" ]]; then
  log "skipped (--no-firewall)"
else
  run apt-get install -y ufw
  run ufw allow OpenSSH
  run ufw allow 80/tcp
  run ufw allow 443/tcp
  run ufw --force enable
fi

step "Write .env with generated secrets"
ENV_FILE="$KIT_DIR/.env"
if [[ -f "$ENV_FILE" && "$DRY_RUN" != "1" ]]; then
  log ".env exists - keeping existing secrets (the encryption key must never change)"
else
  if [[ "$DRY_RUN" == "1" ]]; then
    PG_PASS="<generated: 24 random bytes>"; ENC_KEY="<generated: 32 random bytes>"
  else
    PG_PASS="$(openssl rand -hex 24)"; ENC_KEY="$(openssl rand -hex 32)"
  fi
  printf '  N8N_HOST=%s  N8N_VERSION=%s  TZ=%s\n' "$DOMAIN" "$N8N_VERSION" "$TZ_NAME"
  printf '  POSTGRES_PASSWORD=%s  N8N_ENCRYPTION_KEY=%s\n' "$PG_PASS" "$ENC_KEY"
  if [[ "$DRY_RUN" != "1" ]]; then
    umask 077
    cat > "$ENV_FILE" << ENV
N8N_VERSION=$N8N_VERSION
N8N_HOST=$DOMAIN
ACME_EMAIL=$EMAIL
TZ=$TZ_NAME
POSTGRES_USER=n8n
POSTGRES_DB=n8n
POSTGRES_PASSWORD=$PG_PASS
N8N_ENCRYPTION_KEY=$ENC_KEY
RCLONE_REMOTE=
BACKUP_KEEP_DAYS=14
ENV
    chmod 600 "$ENV_FILE"
  fi
  run chmod 600 "$ENV_FILE"
fi

step "Start Postgres, n8n and Caddy"
compose pull
compose up -d

step "Wait for n8n to report healthy"
if [[ "$DRY_RUN" == "1" ]]; then
  printf '  would poll: docker compose ps n8n until health=healthy (max 120s)\n'
else
  for _ in $(seq 1 24); do
    state="$(docker compose --project-directory "$KIT_DIR" ps --format '{{.Health}}' n8n 2>/dev/null || true)"
    [[ "$state" == "healthy" ]] && break
    sleep 5
  done
  [[ "${state:-}" == "healthy" ]] || die "n8n did not become healthy - check: docker compose logs n8n"
fi

step "Install nightly backup (03:00 UTC)"
run_sh "echo '0 3 * * * root $KIT_DIR/backup.sh >> /var/log/n8n-backup.log 2>&1' > /etc/cron.d/n8n-backup"

step "Done"
log "open https://$DOMAIN and create the owner account"
log "back up $KIT_DIR/.env somewhere safe: without N8N_ENCRYPTION_KEY saved credentials cannot be decrypted"
