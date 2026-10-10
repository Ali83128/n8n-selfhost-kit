#!/usr/bin/env bash
# Shared helpers. Source this file; do not execute it.

DRY_RUN="${DRY_RUN:-0}"
STEP=0

log()  { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
step() { STEP=$((STEP + 1)); printf '\n[%02d] %s\n' "$STEP" "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# run CMD...  - execute, or print it in dry-run mode
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  would run: %s\n' "$*"
  else
    "$@"
  fi
}

# run_sh 'pipeline string' - for commands that need a shell (pipes, redirects)
run_sh() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  would run: %s\n' "$1"
  else
    bash -c "$1"
  fi
}

require_root() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ "$(id -u)" -eq 0 ]] || die "run as root (sudo), or use --dry-run to preview"
}

compose() {
  run docker compose --project-directory "$KIT_DIR" "$@"
}

load_env() {
  local f="$KIT_DIR/.env"
  if [[ -f "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  elif [[ "$DRY_RUN" == "1" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$KIT_DIR/.env.example"
    set +a
  else
    die ".env not found in $KIT_DIR - run install.sh first"
  fi
}
