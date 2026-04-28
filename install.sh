#!/bin/bash
# install.sh — Lovappen/Agents 一键安装入口
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Lovappen/Agents/main/install.sh | bash
#   # 装默认 agent (nako) + 走交互问 cc-connect 接入
#
#   curl -fsSL https://raw.githubusercontent.com/Lovappen/Agents/main/install.sh | bash -s -- --agent nako --with-feishu
#   # 非交互装 nako + 自动 QR 飞书
#
#   bash install.sh --list
#   # 查看可用 agent
#
# Flags:
#   --agent <name>      要装哪个 agent (默认 nako；目前只有 nako)
#   --with-cc-connect   装 cc-connect 但不自动 QR 任何平台
#   --with-feishu       装 cc-connect + QR 飞书
#   --with-weixin       装 cc-connect + QR 微信
#   --non-interactive   全程不询问
#   --force             override existing
#   --list              列出可用 agent 后退出
#   -h | --help         help

set -euo pipefail

# PATH augment so child install.sh and openclaw/npm/node are reachable from
# SSH default shells that don't load brew/nvm.
[ -d /opt/homebrew/bin ] && export PATH="/opt/homebrew/bin:$PATH"
[ -d /usr/local/bin    ] && export PATH="/usr/local/bin:$PATH"
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"
if [ -d "$HOME/.nvm/versions/node" ]; then
  NVM_LATEST=$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1 || true)
  [ -n "${NVM_LATEST:-}" ] && export PATH="$HOME/.nvm/versions/node/$NVM_LATEST/bin:$PATH"
fi

AGENT="nako"
PASS_ARGS=()
LIST=0
HELP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)            AGENT="$2"; shift 2 ;;
    --list)             LIST=1; shift ;;
    -h|--help)
      cat <<'HELP'
install.sh — Lovappen/Agents 一键安装入口

Usage:
  curl -fsSL https://raw.githubusercontent.com/Lovappen/Agents/main/install.sh | bash
  curl -fsSL ... | bash -s -- --agent nako --with-feishu
  bash install.sh [options]

Flags:
  --agent <name>      要装哪个 agent (默认 nako；--list 看完整列表)
  --with-cc-connect   装 cc-connect 但不自动 QR 任何平台
  --with-feishu       装 cc-connect + QR 飞书
  --with-weixin       装 cc-connect + QR 微信
  --non-interactive   全程不询问
  --force             override existing
  --list              列出可用 agent 后退出
  -h, --help          本帮助
HELP
      exit 0 ;;
    --with-cc-connect|--with-feishu|--with-weixin|--non-interactive|--force)
                        PASS_ARGS+=("$1"); shift ;;
    *)                  PASS_ARGS+=("$1"); shift ;;
  esac
done

# ─── Resolve repo root (lazy: only after we know we need files) ────────────
if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  command -v git >/dev/null || { echo "git required" >&2; exit 1; }
  TMPDL=$(mktemp -d)
  trap 'rm -rf "$TMPDL"' EXIT
  echo "正在克隆 Lovappen/Agents → $TMPDL ..."
  git clone --depth 1 https://github.com/Lovappen/Agents.git "$TMPDL" >/dev/null 2>&1
  REPO_ROOT="$TMPDL"
fi

if [ "$LIST" = "1" ]; then
  echo "可用 agent:"
  for d in "$REPO_ROOT"/*/install.sh; do
    [ -f "$d" ] || continue
    name="$(basename "$(dirname "$d")")"
    echo "  - $name"
  done
  exit 0
fi

AGENT_DIR="$REPO_ROOT/$AGENT"
if [ ! -d "$AGENT_DIR" ] || [ ! -f "$AGENT_DIR/install.sh" ]; then
  echo "Agent '$AGENT' 不存在 (找不到 $AGENT_DIR/install.sh)" >&2
  echo "可用 agent (--list 看完整列表):" >&2
  for d in "$REPO_ROOT"/*/install.sh; do
    [ -f "$d" ] && echo "  - $(basename "$(dirname "$d")")" >&2
  done
  exit 1
fi

echo "→ 装 agent: $AGENT"
exec bash "$AGENT_DIR/install.sh" "${PASS_ARGS[@]}"
