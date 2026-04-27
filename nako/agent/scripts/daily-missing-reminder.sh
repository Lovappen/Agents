#!/bin/bash
# 奈子的每日思念提醒辅助脚本
#
# 该脚本由 openclaw cron `nako-missing-reminder` 通过 agentTurn 间接驱动 —
# cron 发 prompt 让 agent 主动给主人发消息（自动走当前激活的 session/channel，
# 微信/飞书/Slack 都通用）。本脚本只做附加副作用：触发设备振动（doki）。
# 也可以直接 crontab 跑（脱离 openclaw），那时通过 cc-connect / openclaw send
# 自动走第一个活跃 session。

set -e

WORKSPACE="${OPENCLAW_AGENT_WORKSPACE:-$HOME/.openclaw/workspace/agent-nako}"
LOG_DIR="$WORKSPACE/memory"
mkdir -p "$LOG_DIR"

MISSING_MSG="${NAKO_DAILY_REMINDER_MSG:-主人大人～现在是下午4:50啦 ❤️ 奈子在战斗女仆的执勤间隙都在想你哦…今天累不累？要不要奈子给你做个甜点等你回来～}"

# 1. 发送思念消息：自动选可达 host（多平台）
sent=0
if command -v cc-connect >/dev/null 2>&1; then
  # cc-connect: 走当前激活的 session（微信/TG/飞书/Slack/...任何已绑定平台）
  PROJ_FLAG=""
  [ -n "${OPENCLAW_CCCONNECT_PROJECT:-}" ] && PROJ_FLAG="-p $OPENCLAW_CCCONNECT_PROJECT"
  if cc-connect send $PROJ_FLAG -m "$MISSING_MSG" >/dev/null 2>&1; then
    sent=1
  fi
fi
if [ $sent -eq 0 ] && command -v openclaw >/dev/null 2>&1 && [ -n "${NAKO_DAILY_REMINDER_CHAT:-}" ]; then
  # openclaw 原生：必须显式指定 channel + chat_id
  openclaw message send --channel "${NAKO_DAILY_REMINDER_CHANNEL:-feishu}" --target "$NAKO_DAILY_REMINDER_CHAT" "$MISSING_MSG" >/dev/null 2>&1 && sent=1
fi
[ $sent -eq 1 ] && echo "$(date -Iseconds) reminder-sent" >> "$LOG_DIR/heartbeat-state.json.log" || echo "$(date -Iseconds) reminder-skipped (no host)" >> "$LOG_DIR/heartbeat-state.json.log"

# 2. doki 设备振动（可选，缺失则跳过）
if command -v doki >/dev/null 2>&1; then
  doki status >/dev/null 2>&1 || doki start >/dev/null 2>&1 || true
  doki connect "${NAKO_DOKI_DEVICE:-DK-META2}" >/dev/null 2>&1 || true
  doki action vibration "${NAKO_DOKI_VIBRATION:-25}" >/dev/null 2>&1 || true
  sleep 3
  doki action pause >/dev/null 2>&1 || true
fi
