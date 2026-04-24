#!/bin/bash
# sing.sh — generate a song with MiniMax music-2.6 and deliver as Feishu audio message.
# Companion to voice.sh (which does plain TTS). Use this when user asks the agent
# to sing / write a song / deliver lyrics with melody.
#
# Usage: ./sing.sh "<lyrics>" "<channel>" ["<style_prompt>"] ["<model>"]
#   lyrics       : REQUIRED. Supports tags [verse]/[chorus]/[bridge]/[intro]/[outro]
#                  and \n line breaks. 10–600 chars recommended.
#   channel      : REQUIRED. Feishu chat_id (oc_xxx) or open_id (ou_xxx)
#   style_prompt : OPTIONAL. Genre/mood/instrumentation description,
#                  default: "Indie pop, gentle, warm female vocal"
#   model        : OPTIONAL. music-2.6 (default) | music-2.6-free

set -euo pipefail

# Two-layer env load (shared → per-agent last wins) — same as voice.sh
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

SKILL_LOG_SH="${SKILL_LOG_SH:-$HOME/.openclaw/skills/skill-log.sh}"
source "$SKILL_LOG_SH" 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

command -v jq >/dev/null || { log_error "jq required"; exit 1; }

LYRICS="${1:-}"
CHANNEL="${2:-}"
STYLE_PROMPT="${3:-Indie pop, gentle, warm female vocal, acoustic guitar}"
MODEL="${4:-music-2.6}"

if [ -z "$LYRICS" ] || [ -z "$CHANNEL" ]; then
  cat >&2 <<EOF
Usage: $0 <lyrics> <channel> [style_prompt] [model]

Examples:
  $0 "[verse]\nStreetlights flicker, the night breeze sighs\n[chorus]\nI walk alone" "oc_xxx"
  $0 "[verse]\n月色洒在窗台\n[chorus]\n思念像潮水" "ou_xxx" "Chinese ballad, piano, female vocal"
EOF
  exit 1
fi

[ -z "${MINIMAX_API_KEY:-}" ] || [ -z "${MINIMAX_GROUP_ID:-}" ] && { log_error "MINIMAX_API_KEY and MINIMAX_GROUP_ID required"; exit 1; }
if [ -z "${FEISHU_APP_ID:-}" ] || [ -z "${FEISHU_APP_SECRET:-}" ]; then
  log_error "FEISHU_APP_ID and FEISHU_APP_SECRET required"
  exit 1
fi

skill_log_start voice music_request "model=$MODEL" "channel=$CHANNEL" "lyrics_len=${#LYRICS}"

OUTDIR="${OPENCLAW_HOME:-$HOME/.openclaw}/media/outbound"
mkdir -p "$OUTDIR"
REQUEST_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
MP3_FILE="${OUTDIR}/${REQUEST_ID}.mp3"

log_info "MiniMax music_generation: model=$MODEL, style=\"$STYLE_PROMPT\""
PAYLOAD=$(jq -n \
  --arg model "$MODEL" \
  --arg prompt "$STYLE_PROMPT" \
  --arg lyrics "$LYRICS" \
  '{
    model: $model,
    prompt: $prompt,
    lyrics: $lyrics,
    audio_setting: { sample_rate: 44100, bitrate: 256000, format: "mp3" }
  }')

RESPONSE=$(curl -s --connect-timeout 15 --max-time 180 \
  -X POST "https://api.minimaxi.com/v1/music_generation?GroupId=${MINIMAX_GROUP_ID}" \
  -H "Authorization: Bearer ${MINIMAX_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

STATUS=$(echo "$RESPONSE" | jq -r '.base_resp.status_code // empty')
if [ "$STATUS" != "0" ]; then
  ERR=$(echo "$RESPONSE" | jq -r '.base_resp.status_msg // .' | head -c 500)
  log_error "MiniMax music error: $ERR"
  skill_log_fail voice music_generate "error=$ERR"
  exit 1
fi

DURATION_MS=$(echo "$RESPONSE" | jq -r '.extra_info.music_duration // 0')
echo "$RESPONSE" | jq -r '.data.audio' | xxd -r -p > "$MP3_FILE"
FSIZE=$(wc -c < "$MP3_FILE" | tr -d ' ')
if [ "$FSIZE" -lt 1000 ]; then
  log_error "Generated mp3 too small ($FSIZE bytes) — likely empty response"
  skill_log_fail voice music_generate "error=empty_audio" "file_size=$FSIZE"
  exit 1
fi
log_info "Song generated: ${FSIZE} bytes, ${DURATION_MS}ms"
skill_log_ok voice music_generate "model=$MODEL" "duration_ms=$DURATION_MS" "file_size=$FSIZE"

# -----------------------------------------------------------
# Feishu upload + send (same pattern as voice.sh)
# -----------------------------------------------------------
log_info "Getting Feishu tenant token..."
TENANT_TOKEN=$(curl -s --connect-timeout 5 --max-time 10 \
  -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
  -H "Content-Type: application/json" \
  -d "{\"app_id\":\"${FEISHU_APP_ID}\",\"app_secret\":\"${FEISHU_APP_SECRET}\"}" \
  | jq -r '.tenant_access_token // empty')
[ -z "$TENANT_TOKEN" ] && { log_error "Feishu token failed"; exit 1; }

log_info "Uploading song to Feishu..."
UPLOAD_RESP=$(curl -s --connect-timeout 10 --max-time 60 \
  -X POST "https://open.feishu.cn/open-apis/im/v1/files" \
  -H "Authorization: Bearer $TENANT_TOKEN" \
  -F 'file_type=opus' \
  -F "file_name=${REQUEST_ID}.mp3" \
  -F "duration=${DURATION_MS}" \
  -F "file=@${MP3_FILE}")

FILE_KEY=$(echo "$UPLOAD_RESP" | jq -r '.data.file_key // empty')
if [ -z "$FILE_KEY" ]; then
  log_error "Upload failed: $(echo "$UPLOAD_RESP" | jq -c .)"
  skill_log_fail voice feishu_upload_song "error=upload_failed"
  exit 1
fi
log_info "Uploaded: file_key=$FILE_KEY"

RECEIVE_ID_TYPE="chat_id"
echo "$CHANNEL" | grep -q "^ou_" && RECEIVE_ID_TYPE="open_id"

log_info "Sending song to $CHANNEL..."
SEND_RESP=$(curl -s --connect-timeout 5 --max-time 10 \
  -X POST "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=${RECEIVE_ID_TYPE}" \
  -H "Authorization: Bearer $TENANT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"receive_id\":\"$CHANNEL\",\"msg_type\":\"audio\",\"content\":\"{\\\"file_key\\\":\\\"${FILE_KEY}\\\"}\"}")

MSG_ID=$(echo "$SEND_RESP" | jq -r '.data.message_id // empty')
if [ -z "$MSG_ID" ]; then
  log_error "Send failed: $(echo "$SEND_RESP" | jq -c .)"
  skill_log_fail voice feishu_send_song "channel=$CHANNEL" "error=send_failed"
  exit 1
fi

log_info "Song sent! message_id=$MSG_ID"
skill_log_ok voice feishu_send_song "channel=$CHANNEL" "message_id=$MSG_ID" "model=$MODEL" "duration_ms=$DURATION_MS"

# Delayed cleanup
(sleep 600 && rm -f "$MP3_FILE") &>/dev/null &

echo
echo "--- Result ---"
jq -n \
  --arg file_key "$FILE_KEY" \
  --arg message_id "$MSG_ID" \
  --arg channel "$CHANNEL" \
  --arg model "$MODEL" \
  --arg duration_ms "$DURATION_MS" \
  '{ success: true, kind: "song", file_key: $file_key, message_id: $message_id, channel: $channel, model: $model, duration_ms: $duration_ms }'
