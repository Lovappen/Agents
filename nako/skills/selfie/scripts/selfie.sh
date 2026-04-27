#!/bin/bash
# grok-imagine-send.sh
# Generate an image with Grok Imagine (via fal.ai or kie.ai) and send it via OpenClaw
#
# Usage: ./selfie.sh "<prompt>" "<channel>" ["<caption>"] ["<aspect_ratio>"] ["<output_format>"] ["<provider>"]
#
# Environment variables:
#   FAL_KEY     - fal.ai API key (default provider)
#   KIE_API_KEY - kie.ai API key (alternative provider)
#   FEISHU_APP_ID     - Feishu app ID (for Feishu inline image)
#   FEISHU_APP_SECRET - Feishu app secret
#
# Providers:
#   fal (default) - Image edit with reference image, sync
#   kie           - Text-to-image, async task-based

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


# Structured logging
SKILL_LOG_SH="${SKILL_LOG_SH:-$HOME/.openclaw/skills/skill-log.sh}"
source "$SKILL_LOG_SH" 2>/dev/null || true

_detect_reference_image() {
  echo "${SELFIE_REFERENCE_IMAGE:-}"
}


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check for jq
if ! command -v jq &> /dev/null; then
  log_error "jq is required but not installed"
  exit 1
fi

# Check for openclaw
if ! command -v openclaw &> /dev/null; then
  log_warn "openclaw CLI not found - will attempt direct API call"
  USE_CLI=false
else
  USE_CLI=true
fi

# Parse arguments
PROMPT="${1:-}"
CHANNEL="${2:-}"
CAPTION="${3:-Generated with Grok Imagine}"
ASPECT_RATIO="${4:-1:1}"
OUTPUT_FORMAT="${5:-jpeg}"
PROVIDER="${6:-auto}"

if [ -z "$PROMPT" ] || [ -z "$CHANNEL" ]; then
  echo "Usage: $0 <prompt> <channel> [caption] [aspect_ratio] [output_format] [provider]"
  echo ""
  echo "Arguments:"
  echo "  prompt        - Image description (required)"
  echo "  channel       - Target channel (required)"
  echo "  caption       - Message caption (default: 'Generated with Grok Imagine')"
  echo "  aspect_ratio  - Image ratio (default: 1:1)"
  echo "  output_format - Image format (default: jpeg) [fal only]"
  echo "  provider      - fal|kie|auto (default: auto)"
  echo ""
  echo "Providers:"
  echo "  fal  - fal.ai image edit (sync, uses reference image)"
  echo "  kie  - kie.ai text-to-image (async, prompt-only)"
  echo "  auto - Use fal if FAL_KEY set, else kie"
  exit 1
fi

# Auto-detect provider: fal preferred (faster, sync), kie as fallback
if [ "$PROVIDER" = "auto" ]; then
  if [ -n "${FAL_KEY:-}" ]; then
    PROVIDER="fal"
  elif [ -n "${KIE_API_KEY:-}" ]; then
    PROVIDER="kie"
  else
    log_error "No provider API key set. Set FAL_KEY or KIE_API_KEY."
    exit 1
  fi
fi

skill_log_start selfie image_request "provider=$PROVIDER" "channel=$CHANNEL" "aspect_ratio=$ASPECT_RATIO"
log_info "Provider: $PROVIDER"
log_info "Prompt: $PROMPT"
log_info "Aspect ratio: $ASPECT_RATIO"

# ──────────────────────────────────────────────
# Provider: fal.ai (sync, image edit)
# ──────────────────────────────────────────────
generate_fal() {
  if [ -z "${FAL_KEY:-}" ]; then
    log_error "FAL_KEY not set"
    exit 1
  fi

  # Fixed reference image for character identity
  REFERENCE_IMAGE="$(_detect_reference_image)"
  if [ -z "$REFERENCE_IMAGE" ]; then
    log_error "No reference image found. Set SELFIE_REFERENCE_IMAGE or add to SKILL.md"
    exit 1
  fi

  log_info "Generating via fal.ai with reference image..."

  RESPONSE=$(curl -s -X POST "https://fal.run/xai/grok-imagine-image/edit" \
    -H "Authorization: Key $FAL_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"image_url\": \"$REFERENCE_IMAGE\",
      \"prompt\": $(echo "$PROMPT" | jq -Rs .),
      \"num_images\": 1,
      \"output_format\": \"$OUTPUT_FORMAT\"
    }")

  if echo "$RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error // .detail // "Unknown error"')
    log_error "fal.ai generation failed: $ERROR_MSG"
    skill_log_fail selfie image_generate "provider=fal" "error=$ERROR_MSG"
    return 1
  fi

  IMAGE_URL=$(echo "$RESPONSE" | jq -r '.images[0].url // empty')

  if [ -z "$IMAGE_URL" ]; then
    log_error "Failed to extract image URL from fal.ai response"
    echo "Response: $RESPONSE" >&2
    return 1
  fi

  REVISED_PROMPT=$(echo "$RESPONSE" | jq -r '.revised_prompt // empty')
  if [ -n "$REVISED_PROMPT" ]; then
    log_info "Revised prompt: $REVISED_PROMPT"
  fi
  skill_log_ok selfie image_generate "provider=fal" "image_url=$IMAGE_URL"
}

# ──────────────────────────────────────────────
# Provider: kie.ai (async, text-to-image)
# ──────────────────────────────────────────────
generate_kie() {
  if [ -z "${KIE_API_KEY:-}" ]; then
    log_error "KIE_API_KEY not set. Get key from https://kie.ai/api-key"
    exit 1
  fi

  log_info "Submitting task to kie.ai (image-to-image with reference)..."

  REFERENCE_IMAGE="$(_detect_reference_image)"
  if [ -z "$REFERENCE_IMAGE" ]; then
    log_error "No reference image found. Set SELFIE_REFERENCE_IMAGE or add to SKILL.md"
    exit 1
  fi

  SUBMIT_RESPONSE=$(curl -s -X POST "https://api.kie.ai/api/v1/jobs/createTask" \
    -H "Authorization: Bearer $KIE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"grok-imagine/image-to-image\",
      \"input\": {
        \"image_urls\": [\"$REFERENCE_IMAGE\"],
        \"prompt\": $(echo "$PROMPT" | jq -Rs .)
      }
    }")

  SUBMIT_CODE=$(echo "$SUBMIT_RESPONSE" | jq -r '.code // empty')
  if [ "$SUBMIT_CODE" != "200" ]; then
    ERROR_MSG=$(echo "$SUBMIT_RESPONSE" | jq -r '.msg // "Unknown error"')
    log_error "kie.ai task submission failed (code=$SUBMIT_CODE): $ERROR_MSG"
    skill_log_fail selfie image_generate "provider=kie" "error=$ERROR_MSG"
    return 1
  fi

  TASK_ID=$(echo "$SUBMIT_RESPONSE" | jq -r '.data.taskId')
  log_info "Task submitted: $TASK_ID"

  # Poll for result
  MAX_ATTEMPTS=40
  POLL_INTERVAL=3

  log_info "Polling for result..."

  for i in $(seq 1 $MAX_ATTEMPTS); do
    RESULT=$(curl -s "https://api.kie.ai/api/v1/jobs/recordInfo?taskId=$TASK_ID" \
      -H "Authorization: Bearer $KIE_API_KEY")

    STATUS=$(echo "$RESULT" | jq -r '.data.state // empty')

    case "$STATUS" in
      success)
        # Try multiple possible output paths
        RESULT_JSON=$(echo "$RESULT" | jq -r '.data.resultJson // empty')
        IMAGE_URL=$(echo "$RESULT_JSON" | jq -r '.resultUrls[0] // empty' 2>/dev/null)

        if [ -z "$IMAGE_URL" ] || [ "$IMAGE_URL" = "null" ]; then
          log_warn "Task completed but no image URL found in expected paths"
          log_info "Full output: $(echo "$RESULT" | jq -r '.data.output // .data')"
          # Try to find any URL in output
          IMAGE_URL=$(echo "$RESULT" | jq -r '.. | select(type == "string" and startswith("http")) | select(test("\\.(jpg|jpeg|png|webp)")) ' 2>/dev/null | head -1)
        fi

        if [ -n "$IMAGE_URL" ] && [ "$IMAGE_URL" != "null" ]; then
          log_info "Image generated: $IMAGE_URL"
          skill_log_ok selfie image_generate "provider=kie" "task_id=$TASK_ID" "image_url=$IMAGE_URL"
          return 0
        else
          log_error "Could not extract image URL from completed task"
          echo "Response: $(echo "$RESULT" | jq .)"
          exit 1
        fi
        ;;
      fail)
        log_error "kie.ai task failed"
        skill_log_fail selfie image_generate "provider=kie" "task_id=$TASK_ID" "error=task_failed"
        echo "Response: $(echo "$RESULT" | jq .)"
        exit 1
        ;;
      *)
        # Still processing
        if [ $((i % 5)) -eq 0 ]; then
          log_info "Still processing... (attempt $i/$MAX_ATTEMPTS, status=$STATUS)"
        fi
        sleep $POLL_INTERVAL
        ;;
    esac
  done

  log_error "Timed out waiting for kie.ai task (${MAX_ATTEMPTS}x${POLL_INTERVAL}s)"
  skill_log_fail selfie image_generate "provider=kie" "task_id=$TASK_ID" "error=timeout"
  exit 1
}

# Generate image based on provider, with fallback
IMAGE_URL=""
_try_generate() {
  case "$1" in
    fal) generate_fal ;;
    kie) generate_kie ;;
    *) log_error "Unknown provider: $1" ; return 1 ;;
  esac
}

if ! _try_generate "$PROVIDER"; then
  # Determine fallback
  if [ "$PROVIDER" = "fal" ] && [ -n "${KIE_API_KEY:-}" ]; then
    log_warn "fal.ai failed, falling back to kie.ai..."
    PROVIDER="kie"
    skill_log_start selfie image_fallback "from=fal" "to=kie"
    _try_generate "kie"
  elif [ "$PROVIDER" = "kie" ] && [ -n "${FAL_KEY:-}" ]; then
    log_warn "kie.ai failed, falling back to fal.ai..."
    PROVIDER="fal"
    skill_log_start selfie image_fallback "from=kie" "to=fal"
    _try_generate "fal"
  else
    log_error "Provider $PROVIDER failed and no fallback available."
    exit 1
  fi
fi

if [ -z "$IMAGE_URL" ]; then
  log_error "No image URL after generation"
  exit 1
fi

log_info "Image ready: $IMAGE_URL"

# ──────────────────────────────────────────────
# ACP mode short-circuit: emit artifact path; host fans out per-platform.
# ──────────────────────────────────────────────
if [ "${OPENCLAW_OUTPUT_MODE:-feishu}" = "acp" ]; then
  TEMP_FILE="/tmp/selfie_$(date +%s).${OUTPUT_FORMAT:-png}"
  if curl -s -o "$TEMP_FILE" "$IMAGE_URL" && [ -s "$TEMP_FILE" ]; then
    skill_log_ok selfie acp_emit "path=$TEMP_FILE" "provider=$PROVIDER"
    if command -v cc-connect >/dev/null 2>&1; then
      cc-connect send --image "$TEMP_FILE" ${OPENCLAW_CCCONNECT_PROJECT:+-p "$OPENCLAW_CCCONNECT_PROJECT"} -m "📸" >/dev/null 2>&1 \
        && skill_log_ok selfie ccconnect_send "path=$TEMP_FILE" \
        || skill_log_fail selfie ccconnect_send "path=$TEMP_FILE"
    fi
    printf '{"type":"image","path":"%s","url":"%s","provider":"%s"}\n' "$TEMP_FILE" "$IMAGE_URL" "$PROVIDER"
  else
    skill_log_ok selfie acp_emit_url "url=$IMAGE_URL" "provider=$PROVIDER"
    printf '{"type":"image","url":"%s","provider":"%s"}\n' "$IMAGE_URL" "$PROVIDER"
  fi
  exit 0
fi

# ──────────────────────────────────────────────
# Feishu special handling: upload image first for inline display
# ──────────────────────────────────────────────
_send_to_feishu() {
  log_info "Detected Feishu channel, uploading image for inline display..."
  
  # Download image to temp file
  TEMP_FILE="/tmp/selfie_$(date +%s).${OUTPUT_FORMAT}"
  curl -s -o "$TEMP_FILE" "$IMAGE_URL"
  
  if [ ! -s "$TEMP_FILE" ]; then
    log_error "Failed to download image"
    rm -f "$TEMP_FILE"
    return 1
  fi
  
  log_info "Image downloaded to $TEMP_FILE ($(wc -c < "$TEMP_FILE") bytes)"
  
  # Get Feishu credentials from env
  FEISHU_APP_ID="${FEISHU_APP_ID:-}"
  FEISHU_APP_SECRET="${FEISHU_APP_SECRET:-}"
  
  if [ -z "$FEISHU_APP_ID" ] || [ -z "$FEISHU_APP_SECRET" ]; then
    log_warn "Feishu credentials (FEISHU_APP_ID/FEISHU_APP_SECRET) not set, falling back to regular send"
    rm -f "$TEMP_FILE"
    return 1
  fi
  
  # Get tenant access token
  TOKEN_RESPONSE=$(curl -s -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
    -H "Content-Type: application/json" \
    -d "{\"app_id\":\"$FEISHU_APP_ID\",\"app_secret\":\"$FEISHU_APP_SECRET\"}")
  
  TENANT_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.tenant_access_token // empty')
  
  if [ -z "$TENANT_TOKEN" ]; then
    log_error "Failed to get Feishu tenant access token"
    echo "Response: $TOKEN_RESPONSE" >&2
    rm -f "$TEMP_FILE"
    return 1
  fi
  
  log_info "Got Feishu access token"
  
  # Upload image to Feishu
  UPLOAD_RESPONSE=$(curl -s -X POST "https://open.feishu.cn/open-apis/im/v1/images" \
    -H "Authorization: Bearer $TENANT_TOKEN" \
    -F "image_type=message" \
    -F "image=@$TEMP_FILE")
  
  IMAGE_KEY=$(echo "$UPLOAD_RESPONSE" | jq -r '.data.image_key // empty')
  
  if [ -z "$IMAGE_KEY" ]; then
    log_error "Failed to upload image to Feishu"
    echo "Response: $UPLOAD_RESPONSE" >&2
    rm -f "$TEMP_FILE"
    return 1
  fi
  
  log_info "Image uploaded to Feishu: $IMAGE_KEY"
  rm -f "$TEMP_FILE"
  
  # Extract chat_id from channel (format: "chat:oc_xxx" or just "oc_xxx")
  CHAT_ID="$CHANNEL"
  if [[ "$CHAT_ID" == chat:* ]]; then
    CHAT_ID="${CHAT_ID#chat:}"
  fi
  
  # Send image message with image_key (inline display)
  SEND_RESPONSE=$(curl -s -X POST "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id" \
    -H "Authorization: Bearer $TENANT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"receive_id\":\"$CHAT_ID\",\"msg_type\":\"image\",\"content\":\"{\\\"image_key\\\":\\\"$IMAGE_KEY\\\"}\"}")
  
  SEND_CODE=$(echo "$SEND_RESPONSE" | jq -r '.code // empty')
  if [ "$SEND_CODE" != "0" ]; then
    log_error "Failed to send image message (code=$SEND_CODE)"
    echo "Response: $SEND_RESPONSE" >&2
    return 1
  fi
  
  log_info "Image sent to Feishu chat: $CHAT_ID"
  skill_log_ok selfie image_send "channel=$CHANNEL" "provider=$PROVIDER" "image_key=$IMAGE_KEY" "method=feishu_upload"
  
  # If there's a custom caption, send it as a separate text message
  if [ -n "$CAPTION" ] && [ "$CAPTION" != "Generated with Grok Imagine" ]; then
    CAPTION_ESCAPED=$(echo "$CAPTION" | jq -Rs .)
    curl -s -X POST "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id" \
      -H "Authorization: Bearer $TENANT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"receive_id\":\"$CHAT_ID\",\"msg_type\":\"text\",\"content\":\"{\\\"text\\\":$CAPTION_ESCAPED}\"}" > /dev/null
    log_info "Caption sent separately"
  fi
  
  return 0
}

# Detect if channel is Feishu
IS_FEISHU=false
if [[ "$CHANNEL" == *feishu* ]] || [[ "$CHANNEL" == oc_* ]] || [[ "$CHANNEL" == chat:oc_* ]]; then
  IS_FEISHU=true
fi

# Send via OpenClaw
log_info "Sending to channel: $CHANNEL"

if [ "$IS_FEISHU" = true ]; then
  if _send_to_feishu; then
    log_info "Done! Image sent to $CHANNEL via Feishu API (inline display)"
  else
    log_warn "Feishu upload failed, falling back to regular OpenClaw send (may appear as file)"
    # Fall back to regular OpenClaw send
    if [ "$USE_CLI" = true ]; then
      openclaw message send \
        --action send \
        --channel "$CHANNEL" \
        --message "$CAPTION" \
        --media "$IMAGE_URL"
    else
      GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-http://localhost:18789}"
      GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
      curl -s -X POST "$GATEWAY_URL/message" \
        -H "Content-Type: application/json" \
        ${GATEWAY_TOKEN:+-H "Authorization: Bearer $GATEWAY_TOKEN"} \
        -d "{\"action\":\"send\",\"channel\":\"$CHANNEL\",\"message\":$(echo "$CAPTION" | jq -Rs .),\"media\":\"$IMAGE_URL\"}"
    fi
  fi
else
  # Non-Feishu channel, use regular send
  if [ "$USE_CLI" = true ]; then
    openclaw message send \
      --action send \
      --channel "$CHANNEL" \
      --message "$CAPTION" \
      --media "$IMAGE_URL"
  else
    GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-http://localhost:18789}"
    GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
    curl -s -X POST "$GATEWAY_URL/message" \
      -H "Content-Type: application/json" \
      ${GATEWAY_TOKEN:+-H "Authorization: Bearer $GATEWAY_TOKEN"} \
      -d "{\"action\":\"send\",\"channel\":\"$CHANNEL\",\"message\":$(echo "$CAPTION" | jq -Rs .),\"media\":\"$IMAGE_URL\"}"
  fi
fi

log_info "Done! Image sent to $CHANNEL"
skill_log_ok selfie image_send "channel=$CHANNEL" "provider=$PROVIDER" "image_url=$IMAGE_URL"

echo ""
echo "--- Result ---"
jq -n \
  --arg url "$IMAGE_URL" \
  --arg channel "$CHANNEL" \
  --arg prompt "$PROMPT" \
  --arg provider "$PROVIDER" \
  '{
    success: true,
    image_url: $url,
    channel: $channel,
    prompt: $prompt,
    provider: $provider
  }'