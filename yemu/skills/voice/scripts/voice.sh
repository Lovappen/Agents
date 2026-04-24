#!/bin/bash
# voice.sh — TTS synthesis + send as Feishu voice message
#
# Usage: ./voice.sh "<text>" "<channel>" ["<provider>"] ["<voice_id>"] ["<speed>"]

set -euo pipefail

# Two-layer env load: shared defaults first, per-agent overlay last wins.
_SHARED_SKILLS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$_SHARED_SKILLS_DIR/.env" ] && set -a && source "$_SHARED_SKILLS_DIR/.env" && set +a

_AGENT_ENV=""
if [ -f "$PWD/skills/.env" ]; then
  _AGENT_ENV="$PWD/skills/.env"
elif [ -n "${OPENCLAW_AGENT_WORKSPACE:-}" ] && [ -f "$OPENCLAW_AGENT_WORKSPACE/skills/.env" ]; then
  _AGENT_ENV="$OPENCLAW_AGENT_WORKSPACE/skills/.env"
fi
[ -n "$_AGENT_ENV" ] && set -a && source "$_AGENT_ENV" && set +a

export PATH="/opt/homebrew/bin:$PATH"

# Structured logging
SKILL_LOG_SH="${SKILL_LOG_SH:-$HOME/.openclaw/skills/skill-log.sh}"
source "$SKILL_LOG_SH" 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

command -v jq &>/dev/null || { log_error "jq required"; exit 1; }

TEXT="${1:-}"
CHANNEL="${2:-}"
PROVIDER="${3:-auto}"
VOICE_ID="${4:-}"
SPEED="${5:-1.0}"

[ -z "$TEXT" ] || [ -z "$CHANNEL" ] && { echo "Usage: $0 <text> <channel> [provider] [voice_id] [speed]"; exit 1; }

if [ "$PROVIDER" = "auto" ]; then
  if [ -n "${MINIMAX_API_KEY:-}" ]; then PROVIDER="minimax"
  elif [ -n "${VOLCENGINE_API_KEY:-}" ]; then PROVIDER="volcengine"
  else log_error "No TTS API key"; exit 1; fi
fi

skill_log_start voice tts_request "provider=$PROVIDER" "channel=$CHANNEL" "text_len=${#TEXT}" "voice_id=${VOICE_ID:-default}" "speed=$SPEED"

OUTDIR="${OPENCLAW_HOME:-$HOME/.openclaw}/media/outbound"
mkdir -p "$OUTDIR"
REQUEST_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
MP3_FILE="${OUTDIR}/${REQUEST_ID}.mp3"
DURATION=""

# ============================
# TTS Generation
# ============================

generate_minimax() {
  [ -z "${MINIMAX_API_KEY:-}" ] || [ -z "${MINIMAX_GROUP_ID:-}" ] && { log_error "MINIMAX_API_KEY and MINIMAX_GROUP_ID required"; exit 1; }
  local voice="${VOICE_ID:-${VOICE_DEFAULT_MINIMAX:-female-tianmei}}"
  log_info "MiniMax TTS: voice=$voice, speed=$SPEED"

  local payload
  payload=$(jq -n --arg text "$TEXT" --arg voice "$voice" --argjson speed "$SPEED" '{
    model: "speech-02-hd", text: $text, stream: false,
    voice_setting: { voice_id: $voice, speed: $speed, vol: 1.0, pitch: 0 },
    audio_setting: { sample_rate: 32000, bitrate: 128000, format: "mp3", channel: 1 }
  }')

  local response
  response=$(curl -s --connect-timeout 10 --max-time 30 \
    -X POST "https://api.minimax.chat/v1/t2a_v2?GroupId=${MINIMAX_GROUP_ID}" \
    -H "Authorization: Bearer ${MINIMAX_API_KEY}" \
    -H "Content-Type: application/json" -d "$payload")

  local status_code
  status_code=$(echo "$response" | jq -r '.base_resp.status_code // empty')
  if [ "$status_code" != "0" ]; then
    local err_msg=$(echo "$response" | jq -r '.base_resp.status_msg // .')
    log_error "MiniMax error: $err_msg"
    skill_log_fail voice tts_generate "provider=minimax" "error=$err_msg"
    exit 1
  fi

  # Extract duration from API response (ms)
  DURATION=$(echo "$response" | jq -r '.extra_info.audio_length // empty')
  log_info "API reported duration: ${DURATION}ms"

  # MiniMax returns hex-encoded audio
  echo "$response" | jq -r '.data.audio' | xxd -r -p > "$MP3_FILE"
  local fsize=$(wc -c < "$MP3_FILE" | tr -d ' ')
  log_info "MP3 saved: ${fsize} bytes"
  skill_log_ok voice tts_generate "provider=minimax" "voice=$voice" "speed=$SPEED" "duration_ms=$DURATION" "file_size=$fsize"
}

generate_volcengine() {
  [ -z "${VOLCENGINE_API_KEY:-}" ] && { log_error "VOLCENGINE_API_KEY required"; exit 1; }
  local voice="${VOICE_ID:-${VOICE_DEFAULT_VOLCENGINE:-zh_female_shuangkuaisisi_moon_bigtts}}"
  local resource_id="${VOLCENGINE_RESOURCE_ID:-seed-tts-1.0}"
  log_info "Volcengine TTS: voice=$voice, resource=$resource_id"

  # Convert speed from multiplier to volcengine range: 1.0->0, 0.5->-50, 2.0->100
  local speech_rate
  speech_rate=$(awk "BEGIN {printf \"%.0f\", ($SPEED - 1.0) * 100}")

  local payload
  payload=$(jq -n --arg text "$TEXT" --arg voice "$voice" --argjson rate "$speech_rate" '{
    user: { uid: "openclaw-agent" },
    req_params: {
      text: $text,
      speaker: $voice,
      audio_params: { format: "mp3", sample_rate: 24000 },
      additions: "{}"
    }
  }')
  # Set speech_rate inside audio_params
  payload=$(echo "$payload" | jq --argjson rate "$speech_rate" '.req_params.audio_params.speech_rate = $rate')

  # Volcengine V3 returns chunked JSON lines with base64 audio in data field
  local response
  response=$(curl -s --connect-timeout 10 --max-time 60 \
    -X POST "https://openspeech.bytedance.com/api/v3/tts/unidirectional" \
    -H "X-Api-Key: ${VOLCENGINE_API_KEY}" \
    -H "X-Api-Resource-Id: ${resource_id}" \
    -H "Content-Type: application/json" \
    -d "$payload")

  # Extract all base64 audio chunks, decode and concatenate
  echo "$response" | jq -r 'select(.data != null and .data != "") | .data' | while read -r chunk; do
    echo "$chunk" | base64 -d
  done > "$MP3_FILE"

  # Check for errors
  local err_code
  err_code=$(echo "$response" | tail -1 | jq -r '.code // 0')
  if [ ! -s "$MP3_FILE" ]; then
    log_error "Volcengine TTS failed: $(echo "$response" | head -5)"
    skill_log_fail voice tts_generate "provider=volcengine" "error=empty_audio"
    exit 1
  fi
  log_info "MP3 saved: $(wc -c < "$MP3_FILE") bytes"

  # Use ffprobe for duration
  DURATION=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$MP3_FILE" </dev/null 2>/dev/null | awk '{printf "%.0f", $1*1000}')
  log_info "Detected duration: ${DURATION}ms"
  local fsize=$(wc -c < "$MP3_FILE" | tr -d ' ')
  skill_log_ok voice tts_generate "provider=volcengine" "voice=$voice" "resource=$resource_id" "speed=$SPEED" "duration_ms=$DURATION" "file_size=$fsize"
}

case "$PROVIDER" in
  minimax)    generate_minimax ;;
  volcengine) generate_volcengine ;;
  *)          log_error "Unknown provider: $PROVIDER"; exit 1 ;;
esac

[ ! -s "$MP3_FILE" ] && { log_error "Generated MP3 is empty"; exit 1; }

# Fallback: if duration still empty, use ffprobe
if [ -z "$DURATION" ] || [ "$DURATION" = "null" ] || [ "$DURATION" = "0" ]; then
  DURATION=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$MP3_FILE" </dev/null 2>/dev/null | awk '{printf "%.0f", $1*1000}')
  log_info "Fallback duration: ${DURATION}ms"
fi

# ============================
# Feishu: get token → upload mp3 → send audio
# ============================
[ -z "${FEISHU_APP_ID:-}" ] || [ -z "${FEISHU_APP_SECRET:-}" ] && { log_error "FEISHU_APP_ID and FEISHU_APP_SECRET required"; exit 1; }

log_info "Getting Feishu token..."
TENANT_TOKEN=$(curl -s --connect-timeout 5 --max-time 10 \
  -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
  -H "Content-Type: application/json" \
  -d "{\"app_id\":\"${FEISHU_APP_ID}\",\"app_secret\":\"${FEISHU_APP_SECRET}\"}" | jq -r '.tenant_access_token // empty')
[ -z "$TENANT_TOKEN" ] && { log_error "Failed to get token"; exit 1; }

log_info "Uploading mp3 to Feishu..."
UPLOAD_RESP=$(curl -s --connect-timeout 10 --max-time 30 \
  -X POST "https://open.feishu.cn/open-apis/im/v1/files" \
  -H "Authorization: Bearer $TENANT_TOKEN" \
  -F 'file_type=opus' \
  -F "file_name=${REQUEST_ID}.mp3" \
  -F "duration=${DURATION}" \
  -F "file=@${MP3_FILE}")

FILE_KEY=$(echo "$UPLOAD_RESP" | jq -r '.data.file_key // empty')
if [ -z "$FILE_KEY" ]; then
  log_error "Upload failed: $(echo "$UPLOAD_RESP" | jq .)"
  skill_log_fail voice feishu_upload "error=upload_failed"
  exit 1
fi
log_info "Uploaded: file_key=$FILE_KEY"
skill_log_ok voice feishu_upload "file_key=$FILE_KEY" "duration_ms=$DURATION"

RECEIVE_ID_TYPE="chat_id"
echo "$CHANNEL" | grep -q "^ou_" && RECEIVE_ID_TYPE="open_id"

log_info "Sending voice to $CHANNEL..."
SEND_RESP=$(curl -s --connect-timeout 5 --max-time 10 \
  -X POST "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=${RECEIVE_ID_TYPE}" \
  -H "Authorization: Bearer $TENANT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"receive_id\":\"$CHANNEL\",\"msg_type\":\"audio\",\"content\":\"{\\\"file_key\\\":\\\"${FILE_KEY}\\\"}\"}")

MSG_ID=$(echo "$SEND_RESP" | jq -r '.data.message_id // empty')
if [ -z "$MSG_ID" ]; then
  log_error "Send failed: $(echo "$SEND_RESP" | jq .)"
  skill_log_fail voice feishu_send "channel=$CHANNEL" "error=send_failed"
  exit 1
fi
log_info "Voice sent! message_id=$MSG_ID"
skill_log_ok voice feishu_send "channel=$CHANNEL" "message_id=$MSG_ID" "provider=$PROVIDER" "duration_ms=$DURATION"

(sleep 600 && rm -f "$MP3_FILE") &>/dev/null &

echo ""
echo "--- Result ---"
jq -n --arg file_key "$FILE_KEY" --arg message_id "$MSG_ID" --arg channel "$CHANNEL" \
  --arg provider "$PROVIDER" --arg duration_ms "$DURATION" \
  '{ success: true, file_key: $file_key, message_id: $message_id, channel: $channel, provider: $provider, duration_ms: $duration_ms }'
