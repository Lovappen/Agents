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
export AVAILABLE

set +e
PICKED=$(python3 - "$MAP" "$CAP" <<PY
import sys, json, re, os
mapf, cap = sys.argv[1], sys.argv[2]
avail = json.loads(os.environ["AVAILABLE"])
avail_ids = {m["id"] for m in avail["models"]}

try:
    import yaml
    data = yaml.safe_load(open(mapf))
except ImportError:
    # Minimal YAML subset parser. Walks the file line-by-line, tracks indent
    # of each capability block, and collects '- item' lists under 'preferred:'.
    # Tolerates trailing '# comment' on item lines.
    text = open(mapf).read()
    caps_out = {}
    state = None  # None | 'in_caps' | 'in_cap' | 'in_preferred'
    cur_cap = None
    cur_indent = 0
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if state is None:
            if stripped == "capabilities:":
                state = "in_caps"
            continue
        if state == "in_caps":
            if indent == 2 and stripped.endswith(":"):
                cur_cap = stripped[:-1].strip()
                caps_out[cur_cap] = {"preferred": [], "fallback_msg": ""}
                state = "in_cap"
                cur_indent = indent
            continue
        if state == "in_cap":
            if indent <= 2 and stripped.endswith(":"):
                # new capability sibling
                cur_cap = stripped[:-1].strip()
                caps_out[cur_cap] = {"preferred": [], "fallback_msg": ""}
                continue
            if stripped == "preferred:":
                state = "in_preferred"
                continue
            continue
        if state == "in_preferred":
            if stripped.startswith("- "):
                item = stripped[2:].split("#", 1)[0].strip()
                if item:
                    caps_out[cur_cap]["preferred"].append(item)
            elif indent <= 2 and stripped.endswith(":"):
                # left this capability into a new sibling
                cur_cap = stripped[:-1].strip()
                caps_out[cur_cap] = {"preferred": [], "fallback_msg": ""}
                state = "in_cap"
            elif indent == 4 and stripped.endswith(":"):
                # other key at capability level (e.g., fallback_msg:)
                state = "in_cap"
    data = {"capabilities": caps_out}

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
set -e

if [ "$RC" = "0" ]; then
  echo "$PICKED"
  exit 0
elif [ "$RC" = "10" ]; then
  # Multiple matches → first wins in non-interactive, else prompt
  # shellcheck disable=SC2206
  OPTS=( $PICKED )
  if [ "${NON_INTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    echo "${OPTS[0]}"
    exit 0
  fi
  local_choice=$(ask_choice "$CAP 能力下发现多个可用模型，选一个：" "${OPTS[@]}")
  echo "$local_choice"
  exit 0
elif [ "$RC" = "2" ]; then
  # No match
  exit 2
else
  exit 1
fi
