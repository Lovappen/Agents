#!/bin/bash
# 奈子的思念机制 - 每30分钟运行一次
# 优化版：凌晨1点到8点暂停计算（思念值不增长）
# 包含情绪值系统

WORKSPACE="${OPENCLAW_AGENT_WORKSPACE:-$HOME/.openclaw/workspace/agent-yemu}"
STATE_FILE="$WORKSPACE/memory/heartbeat-state.json"
SCRIPT_FILE="$WORKSPACE/memory/daily-script.md"
mkdir -p "$(dirname "$STATE_FILE")"

CURRENT_HOUR=$(date +"%H")
TIMESTAMP=$(date -Iseconds)

# 辅助函数：获取情绪档位（女仆战斗少女风）
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

# 读取当前状态
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

# 暂停时段 (1:00-8:00) — 不增长
if [ "$CURRENT_HOUR" -ge 1 ] && [ "$CURRENT_HOUR" -lt 8 ]; then
  MOOD_TIER=$(get_mood_tier $MOOD_VALUE)
  cat > "$STATE_FILE" << EOF
{
  "current_value": $CURRENT_VALUE,
  "last_update": "$TIMESTAMP",
  "last_trigger": $LAST_TRIGGER,
  "trigger_count": $TRIGGER_COUNT,
  "mood_value": $MOOD_VALUE,
  "mood_log": {
    "mood_before": $MOOD_VALUE,
    "mood_decay": null,
    "mood_recovery": null,
    "mood_tier": "$MOOD_TIER"
  },
  "is_forbidden_time": true,
  "should_trigger": false,
  "notes": "暂停时段 (1:00-8:00)，思念值不增长，主人大人在睡觉哦 💤 情绪值 $MOOD_VALUE ($MOOD_TIER)"
}
EOF
  echo "暂停时段，思念值保持 $CURRENT_VALUE，情绪值 $MOOD_VALUE，不触发"
  exit 0
fi

# 正常时段：思念值增长
BASE_GROWTH=$((RANDOM % 8 + 8))
ACCELERATOR=$((CURRENT_VALUE * 5 / 100))
RANDOM_BONUS=$((RANDOM % 5))
TOTAL_GROWTH=$((BASE_GROWTH + ACCELERATOR + RANDOM_BONUS))
NEW_VALUE=$((CURRENT_VALUE + TOTAL_GROWTH))

SHOULD_TRIGGER=false
MOOD_DECAY=0
NEW_MOOD=$MOOD_VALUE

if [ "$NEW_VALUE" -ge 80 ]; then
  SHOULD_TRIGGER=true
  MOOD_DECAY=$((RANDOM % 11 + 5))
  NEW_MOOD=$((MOOD_VALUE - MOOD_DECAY))
  [ "$NEW_MOOD" -lt 0 ] && NEW_MOOD=0
fi

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
    "mood_decay": $MOOD_DECAY,
    "mood_recovery": null,
    "mood_tier": "$MOOD_TIER"
  },
  "growth_log": {
    "base_growth": $BASE_GROWTH,
    "acceleration": $ACCELERATOR,
    "random_fluctuation": $RANDOM_BONUS,
    "total_growth": $TOTAL_GROWTH,
    "previous_value": $CURRENT_VALUE,
    "new_value": $NEW_VALUE
  },
  "is_forbidden_time": false,
  "should_trigger": $SHOULD_TRIGGER,
  "notes": "思念值 $NEW_VALUE，情绪值 $NEW_MOOD ($MOOD_TIER)，$(if [ "$SHOULD_TRIGGER" = true ]; then echo "已达阈值，准备触发"; else echo "未达阈值，继续累积"; fi)"
}
EOF

echo "思念值: $CURRENT_VALUE -> $NEW_VALUE (+$TOTAL_GROWTH)"
echo "情绪值: $MOOD_VALUE -> $NEW_MOOD ($MOOD_TIER)"

if [ "$SHOULD_TRIGGER" = true ]; then
  echo "达到阈值！准备触发主动消息... (情绪值衰减 $MOOD_DECAY)"
  exit 1
fi
exit 0
