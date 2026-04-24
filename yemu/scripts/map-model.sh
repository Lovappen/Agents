#!/bin/bash
# map-model.sh — pick the best model for a capability by consulting model-map.yaml
#                against the user's actual openclaw config.
#
# Usage: map-model.sh <capability>
#   echoes picked "provider/modelId" to stdout
#   Exit codes:
#     0 = matched first-choice or user-picked
#     1 = hard error (no openclaw)
#     2 = no match anywhere (used fallback, msg printed to stderr)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
ROOT="$(dirname "$SCRIPT_DIR")"

CAP="${1:-}"
[ -z "$CAP" ] && { err "Usage: $0 <capability>"; exit 1; }

MAP="$ROOT/config/model-map.yaml"
[ ! -f "$MAP" ] && { err "model-map.yaml not found"; exit 1; }

# Python parser handles YAML (via PyYAML if present, else manual tiny parser)
AVAILABLE=$("$SCRIPT_DIR/detect-models.sh" --json)

PICKED=$(python3 - "$MAP" "$CAP" <<PY
import sys, json, re, os
mapf, cap = sys.argv[1], sys.argv[2]
avail = json.loads(os.environ["AVAILABLE"])
avail_ids = {m["id"] for m in avail["models"]}

try:
    import yaml
    data = yaml.safe_load(open(mapf))
except ImportError:
    # Minimal YAML subset parser for our structured file
    # (fallback — not a full yaml impl)
    text = open(mapf).read()
    # extract preferred list for capability
    import re
    m = re.search(rf"  {cap}:\s*\n\s*preferred:\s*\n((?:\s+-\s+\S+\n)+)", text)
    if m:
        lines = [l.strip().lstrip("-").strip() for l in m.group(1).strip().splitlines()]
        data = {"capabilities": {cap: {"preferred": lines, "fallback_msg": ""}}}
    else:
        data = {"capabilities": {}}

caps = data.get("capabilities", {})
if cap not in caps:
    print(f"ERR: unknown capability {cap}", file=sys.stderr)
    sys.exit(1)

preferred = caps[cap].get("preferred", [])
matches = [p for p in preferred if p in avail_ids]

if not matches:
    print(f"NONE", file=sys.stderr)
    msg = caps[cap].get("fallback_msg", "")
    if msg:
        print(msg, file=sys.stderr)
    sys.exit(2)

if len(matches) == 1:
    print(matches[0])
    sys.exit(0)

# multiple — emit all, let caller interactively pick
print("\n".join(matches))
sys.exit(10)
PY
)
RC=$?
export AVAILABLE

if [ "$RC" = "0" ]; then
  echo "$PICKED"
  exit 0
elif [ "$RC" = "10" ]; then
  # Multiple matches → interactive pick
  # shellcheck disable=SC2206
  OPTS=( $PICKED )
  local_choice=$(ask_choice "$CAP 能力下发现多个可用模型，选一个：" "${OPTS[@]}")
  echo "$local_choice"
  exit 0
elif [ "$RC" = "2" ]; then
  # No match
  exit 2
else
  exit 1
fi
