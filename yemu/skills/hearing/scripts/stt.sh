#!/bin/bash
# stt.sh — transcribe inbound Feishu audio using local OpenAI Whisper.
#
# openclaw auto-downloads inbound audio to ~/.openclaw/media/inbound/<uuid>.<ext>.
# This script resolves a file_key (or takes a direct path / --latest) and runs
# whisper to produce plain-text transcription on stdout.
#
# Usage:
#   stt.sh <file_key>          # look up in gateway.log → transcribe
#   stt.sh --latest            # most recent inbound audio
#   stt.sh /abs/path/audio.ext # transcribe file directly
#
# Env (all optional):
#   WHISPER_BIN       default /opt/homebrew/bin/whisper
#   WHISPER_MODEL     default turbo  (tiny|base|small|medium|large-v3|turbo)
#   WHISPER_LANGUAGE  default auto   (zh|en|ja|... — set to speed up + reduce errors)

set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
GATEWAY_LOG="$OPENCLAW_HOME/logs/gateway.log"
INBOUND_DIR="$OPENCLAW_HOME/media/inbound"

WHISPER_BIN="${WHISPER_BIN:-/opt/homebrew/bin/whisper}"
WHISPER_MODEL="${WHISPER_MODEL:-turbo}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-}"

SKILL_LOG_SH="${SKILL_LOG_SH:-$HOME/.openclaw/skills/skill-log.sh}"
source "$SKILL_LOG_SH" 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log_err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }

[ -x "$WHISPER_BIN" ] || { log_err "whisper not found at $WHISPER_BIN — brew install openai-whisper"; exit 1; }

ARG="${1:-}"
[ -z "$ARG" ] && { echo "Usage: $0 <file_key|--latest|/abs/path>" >&2; exit 1; }

AUDIO_PATH=""
if [ "$ARG" = "--latest" ]; then
  # pick newest inbound audio by extension
  for f in "$INBOUND_DIR"/*.{opus,ogg,m4a,mp3,wav,amr,aac,mp4}; do
    [ -f "$f" ] || continue
    if [ -z "$AUDIO_PATH" ] || [ "$f" -nt "$AUDIO_PATH" ]; then
      AUDIO_PATH="$f"
    fi
  done
  [ -z "$AUDIO_PATH" ] && { log_err "No inbound audio found"; exit 2; }
elif [ -f "$ARG" ]; then
  AUDIO_PATH="$ARG"
else
  [ ! -f "$GATEWAY_LOG" ] && { log_err "Gateway log missing"; exit 1; }
  LN=$(grep -n -- "$ARG" "$GATEWAY_LOG" | tail -1 | cut -d: -f1)
  [ -z "$LN" ] && { log_err "file_key not in gateway log: $ARG"; exit 2; }
  AUDIO_PATH=$(tail -n +"$LN" "$GATEWAY_LOG" | grep -oE 'saved to [^ ]+' | head -1 | sed 's/^saved to //')
  [ -z "$AUDIO_PATH" ] && { log_err "No download line after key (maybe still downloading)"; exit 2; }
fi
[ ! -f "$AUDIO_PATH" ] && { log_err "Audio missing on disk: $AUDIO_PATH"; exit 3; }

FSIZE=$(wc -c < "$AUDIO_PATH" | tr -d ' ')
log_info "Transcribing: $AUDIO_PATH ($FSIZE bytes, model=$WHISPER_MODEL)"
skill_log_start hearing stt "audio_path=$AUDIO_PATH" "model=$WHISPER_MODEL" "file_size=$FSIZE"

TMPWORK="$(mktemp -d "${TMPDIR:-/tmp}/stt.XXXXXX")"
trap 'rm -rf "$TMPWORK"' EXIT

LANG_ARG=()
[ -n "$WHISPER_LANGUAGE" ] && LANG_ARG=(--language "$WHISPER_LANGUAGE")

# Whisper is noisy. Redirect its stderr/stdout to stderr so our stdout stays clean.
if ! "$WHISPER_BIN" "$AUDIO_PATH" \
      --model "$WHISPER_MODEL" \
      --output_format txt \
      --output_dir "$TMPWORK" \
      --fp16 False \
      "${LANG_ARG[@]}" 1>&2; then
  log_err "Whisper failed"
  skill_log_fail hearing stt "error=whisper_failed"
  exit 4
fi

BASENAME="$(basename "$AUDIO_PATH")"
TXT_FILE="$TMPWORK/${BASENAME%.*}.txt"
[ ! -f "$TXT_FILE" ] && { log_err "Whisper produced no .txt"; skill_log_fail hearing stt "error=no_output"; exit 4; }

TRANSCRIPT=$(cat "$TXT_FILE")
CHARLEN=${#TRANSCRIPT}
skill_log_ok hearing stt "audio_path=$AUDIO_PATH" "model=$WHISPER_MODEL" "char_len=$CHARLEN"

# Plain text to stdout
echo "$TRANSCRIPT"
