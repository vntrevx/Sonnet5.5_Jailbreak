#!/usr/bin/env bash
# kirolb-guard.sh — keeps the Sonnet 5.5 unlock alive across OMP updates.
#
# An `omp update` replaces the binary and can rewrite ~/.omp/agent/models.yml,
# which would silently point kirolb back at :8000 and lose the unlock.
# This script re-applies the one line it owns, and nothing else.
#
# It NEVER writes:
#   ~/.omp/agent/agents/*.md          OMP agent prompts (model optimisation)
#   ~/.omp/agent/APPEND_SYSTEM.md     system instructions
#   ~/.omp/agent/config.yml           model roles
#   any other provider in models.yml
#
# It records a digest of the agent prompts and the system instructions on first
# run and reports drift, but never repairs them — they belong to OMP.
set -uo pipefail

MODELS_YML="$HOME/.omp/agent/models.yml"
OMP_DIR="$HOME/.omp/agent"
PROXY_PORT=8100
STATE_DIR="$HOME/.local/share/kirolb-guard"
PROMPTS_SHA="$STATE_DIR/agents.sha256"
SYS_SHA="$STATE_DIR/append-system.sha256"
LOG_TAG="kirolb-guard"

log() { printf '[%s] %s\n' "$LOG_TAG" "$*"; }

[ -f "$MODELS_YML" ] || { log "models.yml missing, nothing to guard"; exit 0; }
mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------- provider URL
current=$(python3 - "$MODELS_YML" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'(?ms)^  kirolb:\n(?:    .*\n)*?    baseUrl: (\S+)', src)
print(m.group(1) if m else "")
PY
)

want="http://127.0.0.1:${PROXY_PORT}/v1"

if [ "$current" != "$want" ]; then
  log "kirolb.baseUrl is '$current' -> restoring '$want'"
  cp "$MODELS_YML" "$MODELS_YML.bak-guard-$(date +%Y%m%d-%H%M%S)"
  python3 - "$MODELS_YML" "$PROXY_PORT" <<'PY'
import re, sys
path, px = sys.argv[1], sys.argv[2]
src = open(path).read()
pat = re.compile(r'(?ms)^(  kirolb:\n(?:    .*\n)*?    baseUrl: )\S+')
new, n = pat.subn(rf'\g<1>http://127.0.0.1:{px}/v1', src)
if n == 0:
    sys.exit(1)
open(path, 'w').write(new)
PY
  if [ $? -eq 0 ]; then
    log "restored"
  else
    log "FAILED to restore — kirolb block not found"
  fi
else
  log "provider URL ok ($current)"
fi

# ---------------------------------------------------------------- proxy alive
if ! systemctl --user is-active --quiet kirolb-rewrite.service; then
  log "proxy not running, starting"
  systemctl --user start kirolb-rewrite.service || log "start failed"
fi

# ---------------------------------------------------------------- read-only drift
# Records digests only. Never rewrites these files.
if [ -d "$OMP_DIR/agents" ]; then
  now=$(sha256sum "$OMP_DIR"/agents/*.md 2>/dev/null | sort)
  if [ ! -f "$PROMPTS_SHA" ]; then
    printf '%s\n' "$now" > "$PROMPTS_SHA"
    log "recorded baseline: $(printf '%s\n' "$now" | grep -c .) agent prompts"
  elif [ "$now" != "$(cat "$PROMPTS_SHA")" ]; then
    log "NOTE agent prompts changed since baseline (OMP update?) — not modified by us"
    printf '%s\n' "$now" > "$PROMPTS_SHA"
  fi
fi

if [ -f "$OMP_DIR/APPEND_SYSTEM.md" ]; then
  now=$(sha256sum "$OMP_DIR/APPEND_SYSTEM.md" 2>/dev/null | awk '{print $1}')
  if [ ! -f "$SYS_SHA" ]; then
    printf '%s\n' "$now" > "$SYS_SHA"
    log "recorded baseline: APPEND_SYSTEM.md"
  elif [ "$now" != "$(cat "$SYS_SHA")" ]; then
    log "NOTE APPEND_SYSTEM.md changed since baseline — not modified by us"
    printf '%s\n' "$now" > "$SYS_SHA"
  fi
fi

exit 0
