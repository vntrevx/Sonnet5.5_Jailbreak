#!/usr/bin/env bash
# install.sh — Sonnet 5.5 unlock proxy for OMP
#
# One command, idempotent, survives OMP updates.
#
#   ./install.sh              install (or repair after an OMP update)
#   ./install.sh --check      verify only, change nothing
#   ./install.sh --uninstall  revert OMP to talk to kiro-lb directly
#
# What it touches:
#   ~/.local/bin/kirolb-rewrite.py                    (created)
#   ~/.config/systemd/user/kirolb-rewrite.service     (created)
#   ~/.omp/agent/models.yml  -> kirolb.baseUrl        (one line, backed up)
#
# What it NEVER touches:
#   ~/.omp/agent/agents/*.md          OMP agent prompts
#   ~/.omp/agent/APPEND_SYSTEM.md     system instructions
#   any other provider in models.yml
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_DIR/src/kirolb-rewrite.py"
UNIT="$REPO_DIR/install/kirolb-rewrite.service"
GUARD_SRC="$REPO_DIR/install/kirolb-guard.sh"
GUARD_UNIT="$REPO_DIR/install/kirolb-guard.service"
GUARD_TIMER="$REPO_DIR/install/kirolb-guard.timer"

DEST_BIN="$HOME/.local/bin/kirolb-rewrite.py"
DEST_UNIT="$HOME/.config/systemd/user/kirolb-rewrite.service"
DEST_GUARD="$HOME/.local/bin/kirolb-guard.sh"
DEST_GUARD_UNIT="$HOME/.config/systemd/user/kirolb-guard.service"
DEST_GUARD_TIMER="$HOME/.config/systemd/user/kirolb-guard.timer"

OMP_DIR="$HOME/.omp/agent"
MODELS_YML="$OMP_DIR/models.yml"
CONFIG_YML="$OMP_DIR/config.yml"
KEY_FILE="$OMP_DIR/kirolb-api-key"
PROXY_PORT=8100
UPSTREAM_PORT=8000
STAMP="$(date +%Y%m%d-%H%M%S)"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# ---------------------------------------------------------------- preflight
preflight() {
  echo "== preflight =="
  need python3
  need systemctl
  need curl
  [ -f "$SRC" ] || die "missing $SRC (run from the repo root)"
  [ -f "$MODELS_YML" ] || die "missing $MODELS_YML — is OMP installed?"
  [ -f "$CONFIG_YML" ] || die "missing $CONFIG_YML — is OMP installed?"
  [ -f "$KEY_FILE" ] || die "missing $KEY_FILE — kiro-lb api key"
  python3 - <<'PY' || die "python3 3.8+ required"
import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)
PY
  say "python3 $(python3 -V 2>&1 | awk '{print $2}')"
  say "OMP config found at $OMP_DIR"
}

# ---------------------------------------------------------------- upstream
check_upstream() {
  echo "== kiro-lb =="
  if ! systemctl --user is-active kiro-lb.service >/dev/null 2>&1; then
    say "WARN kiro-lb.service is not active"
    say "     start it:  systemctl --user start kiro-lb.service"
  else
    say "kiro-lb.service active"
  fi
  local code
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $(cat "$KEY_FILE")" \
    "http://127.0.0.1:$UPSTREAM_PORT/v1/models" 2>/dev/null || echo 000)
  [ "$code" = "200" ] && say "upstream :$UPSTREAM_PORT reachable" \
                      || say "WARN upstream :$UPSTREAM_PORT -> $code"
}

# ---------------------------------------------------------------- install
install_proxy() {
  echo "== proxy =="
  mkdir -p "$(dirname "$DEST_BIN")"
  install -m 0755 "$SRC" "$DEST_BIN"
  say "$DEST_BIN"

  mkdir -p "$(dirname "$DEST_UNIT")"
  install -m 0644 "$UNIT" "$DEST_UNIT"
  systemctl --user daemon-reload
  systemctl --user enable --now kirolb-rewrite.service
  sleep 2
  systemctl --user is-active kirolb-rewrite.service >/dev/null \
    || die "proxy failed to start — journalctl --user -u kirolb-rewrite -n 40"
  say "kirolb-rewrite.service active + enabled"
}

# The guard re-applies the provider URL if an OMP update rewrites models.yml.
install_guard() {
  echo "== update guard =="
  [ -f "$GUARD_SRC" ] || { say "WARN guard script missing, skipping"; return 0; }
  install -m 0755 "$GUARD_SRC" "$DEST_GUARD"
  install -m 0644 "$GUARD_UNIT" "$DEST_GUARD_UNIT"
  install -m 0644 "$GUARD_TIMER" "$DEST_GUARD_TIMER"
  systemctl --user daemon-reload
  systemctl --user enable --now kirolb-guard.timer
  say "kirolb-guard.timer enabled (checks every 5 min)"
}

patch_models_yml() {
  echo "== OMP provider =="
  cp "$MODELS_YML" "$MODELS_YML.bak-$STAMP"
  python3 - "$MODELS_YML" "$PROXY_PORT" <<'PY'
import re, sys
path, px = sys.argv[1], sys.argv[2]
src = open(path).read()
pat = re.compile(r'(?ms)^(  kirolb:\n(?:    .*\n)*?    baseUrl: )http://127\.0\.0\.1:\d+/v1')
new, n = pat.subn(rf'\g<1>http://127.0.0.1:{px}/v1', src)
if n == 0:
    cur = re.search(r'(?ms)^  kirolb:\n(?:    .*\n)*?    baseUrl: (\S+)', src)
    if cur and f':{px}/' in cur.group(1):
        print(f"  kirolb.baseUrl already -> {cur.group(1)}")
        sys.exit(0)
    print(f"  kirolb.baseUrl = {cur.group(1) if cur else 'NOT FOUND'}")
    sys.exit(2)
open(path, 'w').write(new)
print(f"  kirolb.baseUrl -> http://127.0.0.1:{px}/v1")
PY
  [ $? -eq 2 ] && die "could not patch kirolb.baseUrl — inspect $MODELS_YML"
  say "backup: $MODELS_YML.bak-$STAMP"
}

# ---------------------------------------------------------------- verify
verify() {
  echo "== verify =="
  python3 "$REPO_DIR/tools/verify.py" || die "verification failed"
}

# ---------------------------------------------------------------- uninstall
uninstall() {
  echo "== uninstall =="
  systemctl --user disable --now kirolb-guard.timer 2>/dev/null || true
  systemctl --user disable --now kirolb-rewrite.service 2>/dev/null || true
  rm -f "$DEST_UNIT" "$DEST_GUARD_UNIT" "$DEST_GUARD_TIMER" "$DEST_GUARD" "$DEST_BIN"
  systemctl --user daemon-reload
  if [ -f "$MODELS_YML" ]; then
    cp "$MODELS_YML" "$MODELS_YML.bak-$STAMP"
    sed -i -E "s#(^    baseUrl: )http://127\.0\.0\.1:$PROXY_PORT/v1#\1http://127.0.0.1:$UPSTREAM_PORT/v1#" "$MODELS_YML"
    say "kirolb.baseUrl -> :$UPSTREAM_PORT"
  fi
  say "removed proxy, guard, and their units"
}

main() {
  case "${1:-}" in
    --check)
      preflight; check_upstream
      python3 "$REPO_DIR/tools/verify.py" ;;
    --uninstall)
      uninstall ;;
    "")
      preflight
      check_upstream
      install_proxy
      install_guard
      patch_models_yml
      verify
      echo
      echo "done. restart OMP so it reloads models.yml."
      echo "the guard re-applies the provider URL automatically after an OMP update."
      ;;
    *)
      die "unknown option: $1 (use --check or --uninstall)" ;;
  esac
}

main "$@"
