#!/bin/bash
# cc-connect-setup.sh — 把 openclaw 上任意 agent 接到 cc-connect 多平台 host
#
# 这个脚本与具体 agent 无关，可独立使用：
#   1. 装/复用 cc-connect
#   2. 在 ~/.cc-connect/config.toml idempotent 写入指向
#      `openclaw acp --session agent:<id>:main` 的 project
#   3. 引导 QR-onboarding 飞书/微信等平台
#
# Usage:
#   bash scripts/cc-connect-setup.sh [options]
#
# Flags:
#   --agent-id <id>      openclaw agent id (默认 agent-nako)
#   --display-name <n>   cc-connect 内显示名 (默认 OpenClaw <id>)
#   --with-feishu        自动跑 feishu QR 引导（若未配 feishu）
#   --with-weixin        自动跑 weixin QR 引导（若未配 weixin）
#   --non-interactive    不询问，缺什么就跳过

set -euo pipefail

# ─── PATH augment for SSH 默认 shell（brew/nvm bin 不一定 inherits） ────────
[ -d /opt/homebrew/bin ] && export PATH="/opt/homebrew/bin:$PATH"
[ -d /usr/local/bin    ] && export PATH="/usr/local/bin:$PATH"
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"
if [ -d "$HOME/.nvm/versions/node" ]; then
  NVM_LATEST=$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1 || true)
  [ -n "${NVM_LATEST:-}" ] && [ -d "$HOME/.nvm/versions/node/$NVM_LATEST/bin" ] && \
    export PATH="$HOME/.nvm/versions/node/$NVM_LATEST/bin:$PATH"
fi

# ─── Self-contained logging / prompt helpers ────────────────────────────────
if [ -t 1 ]; then
  C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
  C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_DIM='\033[2m'; C_NC='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_DIM=''; C_NC=''
fi
info(){ echo -e "${C_GREEN}[✓]${C_NC} $*"; }
warn(){ echo -e "${C_YELLOW}[!]${C_NC} $*"; }
err(){  echo -e "${C_RED}[✗]${C_NC} $*" >&2; }
step(){ echo -e "\n${C_BOLD}${C_CYAN}▸ $*${C_NC}"; }
dim(){  echo -e "${C_DIM}$*${C_NC}"; }
has_bin(){ command -v "$1" >/dev/null 2>&1; }
confirm(){
  local q="$1" def="${2:-n}" reply hint="[y/N]"
  [ "$def" = "y" ] && hint="[Y/n]"
  echo -en "${C_CYAN}?${C_NC} $q $hint: "
  read -r reply </dev/tty || reply=""
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

WITH_FEISHU=0
WITH_WEIXIN=0
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
AGENT_ID="agent-nako"
DISPLAY_NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --with-feishu) WITH_FEISHU=1; shift ;;
    --with-weixin) WITH_WEIXIN=1; shift ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --agent-id) AGENT_ID="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    -h|--help)
      cat <<'HELP'
cc-connect-setup.sh — 把 openclaw 上任意 agent 接到 cc-connect 多平台 host

Usage:
  curl -fsSL https://raw.githubusercontent.com/Lovappen/Agents/main/scripts/cc-connect-setup.sh | bash
  curl -fsSL ... | bash -s -- --agent-id agent-foo --with-feishu --with-weixin
  bash scripts/cc-connect-setup.sh [options]

Flags:
  --agent-id <id>      openclaw agent id (默认 agent-nako)
  --display-name <n>   cc-connect 内显示名 (默认 "OpenClaw <id>")
  --with-feishu        自动跑 feishu QR 引导（若未配 feishu）
  --with-weixin        自动跑 weixin QR 引导（若未配 weixin）
  --non-interactive    不询问，缺什么就跳过
  -h, --help           本帮助
HELP
      exit 0 ;;
    *) err "Unknown flag: $1"; exit 1 ;;
  esac
done
: ${DISPLAY_NAME:="OpenClaw $AGENT_ID"}

CC_CONFIG="$HOME/.cc-connect/config.toml"
WORKSPACE="$HOME/.openclaw/workspace/$AGENT_ID"

# ── 1. 装 cc-connect ──────────────────────────────────────────────────
# 既然你跑了这个脚本，说明你想用 cc-connect — 默认直接装，不再问。
step "1. 检查 cc-connect"
if ! has_bin cc-connect; then
  if ! has_bin npm; then
    err "需要 npm 来装 cc-connect。先装 Node 22+ 再重跑（macOS: brew install node ；Linux: see https://nodejs.org）"
    exit 1
  fi
  info "cc-connect 未装，npm i -g cc-connect ..."
  npm i -g cc-connect 2>&1 | tail -3 || { err "cc-connect 安装失败"; exit 1; }
fi
info "cc-connect $(cc-connect --version 2>&1 | head -1 | awk '{print $2}')"

# ── 2. 初始化 / merge config.toml ─────────────────────────────────────
step "2. 配置 cc-connect 项目: $AGENT_ID"
mkdir -p "$(dirname "$CC_CONFIG")"

if [ ! -f "$CC_CONFIG" ]; then
  cat > "$CC_CONFIG" <<EOF
[server]
data_dir = "$HOME/.cc-connect/data"
log_level = "info"

[[projects]]
name = "$AGENT_ID"

[projects.agent]
type = "acp"

[projects.agent.options]
work_dir = "$HOME/.openclaw"
command = "openclaw"
args = ["acp", "--session", "agent:$AGENT_ID:main"]
display_name = "$DISPLAY_NAME"
env = { OPENCLAW_OUTPUT_MODE = "acp", OPENCLAW_CCCONNECT_PROJECT = "$AGENT_ID" }
EOF
  info "新建 $CC_CONFIG"
else
  if grep -q "name = \"$AGENT_ID\"" "$CC_CONFIG"; then
    info "已存在 $AGENT_ID project，跳过 config 写入"
  else
    cat >> "$CC_CONFIG" <<EOF

[[projects]]
name = "$AGENT_ID"

[projects.agent]
type = "acp"

[projects.agent.options]
work_dir = "$HOME/.openclaw"
command = "openclaw"
args = ["acp", "--session", "agent:$AGENT_ID:main"]
display_name = "$DISPLAY_NAME"
env = { OPENCLAW_OUTPUT_MODE = "acp", OPENCLAW_CCCONNECT_PROJECT = "$AGENT_ID" }
EOF
    info "追加 $AGENT_ID project 到 $CC_CONFIG"
  fi
fi

# ── 3. 引导平台 QR onboarding ─────────────────────────────────────────
has_platform() {
  python3 - "$1" "$AGENT_ID" "$CC_CONFIG" <<'PY'
import sys, re
ptype, agent, cfg = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(cfg).read()
# Naive scan: look for [[projects.platforms]] type=ptype within agent's project block
in_proj = False
for line in text.splitlines():
    if line.strip().startswith("[[projects]]"):
        in_proj = False
    if f'name = "{agent}"' in line:
        in_proj = True
    if in_proj and f'type = "{ptype}"' in line:
        print("yes"); sys.exit(0)
print("no")
PY
}

setup_platform() {
  local platform="$1" desc="$2"
  if [ "$(has_platform "$platform")" = "yes" ]; then
    info "$desc 已配，跳过"
    return 0
  fi
  if [ "$NON_INTERACTIVE" = "1" ]; then
    dim "未配 $desc — 手动跑：cc-connect $platform setup --project $AGENT_ID"
    return 0
  fi
  echo
  warn "$desc 未配置，开始 QR onboarding..."
  dim "扫码完成后 cc-connect 会把凭据写进 config.toml，无需手动复制。"
  cc-connect "$platform" setup --project "$AGENT_ID" --timeout 600 || warn "$desc onboarding 失败/超时（不影响其他流程）"
}

step "3. 平台 QR onboarding"
if [ "$WITH_FEISHU" = "1" ]; then
  setup_platform feishu "飞书"
fi
if [ "$WITH_WEIXIN" = "1" ]; then
  setup_platform weixin "微信"
fi
if [ "$WITH_FEISHU" = "0" ] && [ "$WITH_WEIXIN" = "0" ]; then
  if [ "$NON_INTERACTIVE" = "1" ]; then
    dim "未指定 --with-feishu / --with-weixin — 跳过 onboarding"
  else
    echo
    if confirm "现在 QR onboarding 飞书？" n; then setup_platform feishu "飞书"; fi
    if confirm "现在 QR onboarding 微信（个人 ilink）？" n; then setup_platform weixin "微信"; fi
  fi
fi

echo
# ── 4. 启动 cc-connect (daemon 优先，fallback 后台 nohup) ────────────────
step "4. 启动 cc-connect"
if pgrep -f "cc-connect" >/dev/null 2>&1 && ! pgrep -f "cc-connect (feishu|weixin) setup" >/dev/null 2>&1; then
  info "cc-connect 已在跑，跳过"
else
  if cc-connect daemon install --force >/dev/null 2>&1 && cc-connect daemon start >/dev/null 2>&1; then
    info "cc-connect daemon 已启动 (launchd/systemd)"
    dim "  状态: cc-connect daemon status   日志: cc-connect daemon logs -f"
  else
    nohup cc-connect >"$HOME/.cc-connect/cc-connect.log" 2>&1 &
    disown 2>/dev/null || true
    info "cc-connect 后台已启 (PID $!)，日志: ~/.cc-connect/cc-connect.log"
  fi
  sleep 2
fi
echo
info "全部就绪 — 在已绑定的平台里 @ $AGENT_ID 找她"
