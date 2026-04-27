#!/bin/bash
# 奈子的情绪恢复 - 用户发消息时调用
# 情绪值恢复 20-40，上限 100

WORKSPACE="${OPENCLAW_AGENT_WORKSPACE:-$HOME/.openclaw/workspace/agent-yemu}"
STATE_FILE="$WORKSPACE/memory/heartbeat-state.json"
mkdir -p "$(dirname "$STATE_FILE")"
TIMESTAMP=$(date -Iseconds)

get_mood_tier() {
  local mood=$1
  if [ "$mood" -ge 80 ]; then
    echo "雀跃黏人"
  elif [ "$mood" -ge 60 ]; then
    echo "温柔正常"
  elif [ "$mood" -ge 40 ]; then
    echo "有点失落"
  elif [ "$mood" -ge 20 ]; then
    echo "思念难熬"
  else
    echo "委屈想哭"
  fi
}

if [ -f "$STATE_FILE" ]; then
  CURRENT_VALUE=$(grep -o '"current_value": [0-9]*' "$STATE_FILE" | grep -o '[0-9]*' || echo "0")
  LAST_TRIGGER=$(grep -o '"last_trigger": "[^"]*"' "$STATE_FILE" | grep -o '"[^"]*"' || echo "null")
  TRIGGER_COUNT=$(grep -o '"trigger_count": [0-9]*' "$STATE_FILE" | grep -o '[0-9]*' || echo "0")
  MOOD_VALUE=$(grep -o '"mood_value": [0-9]*' "$STATE_FILE" | grep -o '[0-9]*' || echo "100")
else
  CURRENT_VALUE=0
  LAST_TRIGGER="null"
  TRIGGER_COUNT=0
  MOOD_VALUE=100
fi

MOOD_RECOVERY=$((RANDOM % 21 + 20))
NEW_MOOD=$((MOOD_VALUE + MOOD_RECOVERY))
[ "$NEW_MOOD" -gt 100 ] && NEW_MOOD=100
NEW_VALUE=0
MOOD_TIER=$(get_mood_tier $NEW_MOOD)

cat > "$STATE_FILE" << EOF
{
  "current_value": $NEW_VALUE,
  "last_update": "$TIMESTAMP",
  "last_trigger": $LAST_TRIGGER,
  "trigger_count": $TRIGGER_COUNT,
  "mood_value": $NEW_MOOD,
  "mood_log": {
    "mood_before": $MOOD_VALUE,
    "mood_decay": null,
    "mood_recovery": $MOOD_RECOVERY,
    "mood_tier": "$MOOD_TIER"
  },
  "growth_log": {
    "previous_value": $CURRENT_VALUE,
    "reset": true
  },
  "is_forbidden_time": false,
  "should_trigger": false,
  "notes": "主人大人来啦！思念值清零，情绪值回血 $MOOD_RECOVERY 到 $NEW_MOOD ($MOOD_TIER) ❤️"
}
EOF

echo "情绪恢复: $MOOD_VALUE -> $NEW_MOOD (+$MOOD_RECOVERY)"
echo "思念值重置: $CURRENT_VALUE -> 0"
