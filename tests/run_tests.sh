#!/usr/bin/env bash
# Offline test suite: ShellCheck, compose validation, dry-run behaviour and input validation.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
PY="${PYTHON:-python3}"
SHELLCHECK="${SHELLCHECK:-shellcheck}"
pass=0
fail=0

ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

expect_contains() { # name, output, needle
  if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1 (missing: $3)"; fi
}
expect_absent() {
  if grep -qF -- "$3" <<< "$2"; then bad "$1 (unexpected: $3)"; else ok "$1"; fi
}
expect_fail() { # name, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$name (should have failed)"; else ok "$name"; fi
}

echo "== ShellCheck"
if "$SHELLCHECK" -x install.sh backup.sh restore.sh update.sh scripts/lib.sh tests/run_tests.sh; then
  ok "shellcheck clean on all scripts"
else
  bad "shellcheck reported issues"
fi

echo "== docker-compose.yml"
if "$PY" tests/check_compose.py; then ok "compose static checks"; else bad "compose static checks"; fi

echo "== install.sh --dry-run"
out="$(./install.sh --domain n8n.example.com --email admin@example.com --dry-run 2>&1)"
expect_contains "dry run announced" "$out" "DRY RUN - nothing will be changed"
expect_contains "installs docker from the official repo" "$out" "download.docker.com/linux/ubuntu"
expect_contains "installs compose plugin" "$out" "docker-compose-plugin"
expect_contains "opens SSH before enabling ufw" "$out" "ufw allow OpenSSH"
expect_contains "opens 443" "$out" "ufw allow 443/tcp"
expect_contains "starts the stack" "$out" "up -d"
expect_contains "schedules nightly backup" "$out" "/etc/cron.d/n8n-backup"
expect_absent "no real secret printed in dry run" "$out" "N8N_ENCRYPTION_KEY=$(grep -o '[0-9a-f]\{64\}' .env 2>/dev/null || echo NONE)"
ssh_line=$(grep -n "ufw allow OpenSSH" <<< "$out" | cut -d: -f1)
enable_line=$(grep -n "ufw --force enable" <<< "$out" | cut -d: -f1)
if [[ -n "$ssh_line" && -n "$enable_line" && "$ssh_line" -lt "$enable_line" ]]; then ok "SSH allowed before firewall is enabled"; else bad "SSH allowed before firewall is enabled"; fi
if [[ ! -f .env ]]; then ok "dry run did not create .env"; else bad "dry run created .env"; fi

out="$(./install.sh --domain n8n.example.com --email admin@example.com --no-firewall --dry-run 2>&1)"
expect_absent "--no-firewall skips ufw" "$out" "ufw --force enable"

echo "== install.sh input validation"
expect_fail "rejects missing --domain" ./install.sh --email a@b.co --dry-run
expect_fail "rejects missing --email" ./install.sh --domain n8n.example.com --dry-run
expect_fail "rejects bad domain" ./install.sh --domain 'bad domain' --email a@b.co --dry-run
expect_fail "rejects bad email" ./install.sh --domain n8n.example.com --email nope --dry-run
expect_fail "rejects unpinned version" ./install.sh --domain n8n.example.com --email a@b.co --version latest --dry-run
expect_fail "rejects unknown flag" ./install.sh --domain n8n.example.com --email a@b.co --bogus --dry-run

echo "== backup.sh --dry-run"
out="$(./backup.sh --dry-run 2>&1)"
expect_contains "dumps postgres" "$out" "pg_dump"
expect_contains "archives n8n volume" "$out" "n8n_n8n_data"
expect_contains "keeps the .env (encryption key)" "$out" "env.backup"
expect_contains "writes checksums" "$out" "sha256sum"
expect_contains "rotates old backups" "$out" "-mtime +14"
expect_contains "reports local-only when no rclone remote" "$out" "local backup only"
out="$(./backup.sh --dry-run --remote b2:n8n-backups 2>&1)"
expect_contains "uploads off-site when rclone remote set" "$out" "would run: rclone copy"

echo "== restore.sh"
expect_fail "restore requires a backup path" ./restore.sh --dry-run
expect_fail "restore rejects missing folder" ./restore.sh /nonexistent/backup --yes
out="$(./restore.sh backups/20261010-030000 --dry-run 2>&1)"
expect_contains "verifies checksums first" "$out" "sha256sum -c SHA256SUMS"
expect_contains "stops n8n before restoring" "$out" "stop n8n"
expect_contains "verifies health after restore" "$out" "/healthz"
expect_contains "verifies workflow count" "$out" "FROM workflow_entity"
first_check=$(grep -n "sha256sum -c" <<< "$out" | cut -d: -f1)
first_restore=$(grep -n "gunzip" <<< "$out" | cut -d: -f1)
if [[ "$first_check" -lt "$first_restore" ]]; then ok "checksum verified before data is touched"; else bad "checksum verified before data is touched"; fi

echo "== update.sh"
expect_fail "update requires pinned --version" ./update.sh --dry-run
out="$(./update.sh --version 1.65.0 --dry-run 2>&1)"
expect_contains "backs up before updating" "$out" "Back up before updating"
expect_contains "pins version in .env" "$out" "N8N_VERSION=1.65.0"
expect_contains "verifies health after update" "$out" "/healthz"
backup_line=$(grep -n "Back up before updating" <<< "$out" | cut -d: -f1)
pull_line=$(grep -n "pull n8n" <<< "$out" | cut -d: -f1)
if [[ "$backup_line" -lt "$pull_line" ]]; then ok "backup happens before pull"; else bad "backup happens before pull"; fi

echo
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
