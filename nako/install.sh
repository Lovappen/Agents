#!/bin/bash
# install.sh — Nako agent pack installer for macOS / Linux.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Lovappen/Agents/main/nako/install.sh | bash
#   # or clone repo then:  bash nako/install.sh [--force] [--agent-id <id>] [--non-interactive]
#
# Flags:
#   --force             : overwrite existing persona files (user data still preserved)
#   --agent-id ID       : rename the agent (default: agent-nako)
#   --non-interactive   : no prompts; expects env vars set already; picks defaults
#   --skip-skills       : skip skill install (persona only)
#   --skip-models       : skip model mapping (keep existing primary)

set -euo pipefail

# ─── Resolve pack root (works for local clone or curl-piped) ────────────────
if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  # Piped via curl — clone the repo to a temp dir
  if ! command -v git >/dev/null; then
    echo "git required" >&2; exit 1
  fi
  TMPDL=$(mktemp -d)
  trap 'rm -rf "$TMPDL"' EXIT
  echo "正在克隆 Agents 仓库 → $TMPDL ..."
  git clone --depth 1 https://github.com/Lovappen/Agents.git "$TMPDL" >/dev/null 2>&1
  PACK_ROOT="$TMPDL/nako"
fi

SCRIPT_DIR="$PACK_ROOT/scripts"
source "$SCRIPT_DIR/lib.sh"

# ─── Parse flags ────────────────────────────────────────────────────────────
FORCE=0
AGENT_ID="agent-nako"
NON_INTERACTIVE=0
SKIP_SKILLS=0
SKIP_MODELS=0
RESET_SECRETS=0
WITH_CC_CONNECT=0
WITH_FEISHU=0
WITH_WEIXIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; export FORCE; shift ;;
    --agent-id) AGENT_ID="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; export NON_INTERACTIVE; shift ;;
    --skip-skills) SKIP_SKILLS=1; shift ;;
    --skip-models) SKIP_MODELS=1; shift ;;
    --reset-secrets) RESET_SECRETS=1; shift ;;
    --with-cc-connect) WITH_CC_CONNECT=1; shift ;;
    --with-feishu)     WITH_FEISHU=1; WITH_CC_CONNECT=1; shift ;;
    --with-weixin)     WITH_WEIXIN=1; WITH_CC_CONNECT=1; shift ;;
    -h|--help)
      grep -E "^# " "$0" | head -20; exit 0 ;;
    *) err "Unknown flag: $1"; exit 1 ;;
  esac
done

cat <<BANNER

${C_BOLD}野木奈子 Agent Pack - 安装器${C_NC}
  ${C_DIM}Repo: github.com/Lovappen/Agents${C_NC}
  ${C_DIM}Agent: $AGENT_ID${C_NC}
  ${C_DIM}Pack: $PACK_ROOT${C_NC}

BANNER

# ─── Preflight ──────────────────────────────────────────────────────────────
step "1. 前置检查"

MISSING_HARD=()
for b in python3 jq curl uuidgen; do
  if has_bin "$b"; then info "$b"; else err "$b"; MISSING_HARD+=("$b"); fi
done

if [ ! -d "$OPENCLAW_HOME" ]; then
  err "~/.openclaw 不存在 — 请先安装 openclaw (npm i -g openclaw)"
  exit 1
fi
info "openclaw 目录 $OPENCLAW_HOME"

[ ! -f "$OPENCLAW_CONFIG" ] && { err "openclaw.json 不存在"; exit 1; }
info "openclaw.json"

if [ "${#MISSING_HARD[@]}" -gt 0 ]; then
  err "请先装这些依赖：${MISSING_HARD[*]}"
  dim "macOS:  brew install ${MISSING_HARD[*]}"
  dim "Debian: sudo apt-get install ${MISSING_HARD[*]}"
  exit 1
fi

# Optional bins (not fatal)
MISSING_SOFT=()
for b in whisper ffmpeg ffprobe xxd doki; do
  has_bin "$b" && info "$b (可选)" || { warn "$b 缺失 (可选)"; MISSING_SOFT+=("$b"); }
done
if [ "${#MISSING_SOFT[@]}" -gt 0 ]; then
  echo
  dim "以下依赖缺失，相关 skill 将在运行时报错提示："
  dim "  whisper / ffmpeg → hearing skill (转写语音)"
  dim "  xxd / ffprobe    → voice skill"
  dim "  doki             → dokidoki skill"
  dim "macOS 建议：brew install openai-whisper ffmpeg ; npm i -g @tryjoy/dokidoki"
  dim "Linux：sudo apt install ffmpeg libavcodec-extra（cc-connect 微信视频转码需要 AMR）"
  echo

  # 询问是否后台装 whisper
  if echo "${MISSING_SOFT[@]}" | grep -q whisper; then
    if [ "$NON_INTERACTIVE" = "1" ]; then
      _do_whisper=0
    elif confirm "需要语音识别（whisper）吗？现在后台安装（不阻塞）" y; then
      _do_whisper=1
    else
      _do_whisper=0
    fi
    if [ "$_do_whisper" = "1" ]; then
      mkdir -p "$OPENCLAW_HOME/skills/hearing"
      MARKER="$OPENCLAW_HOME/skills/hearing/.installing"
      LOGF="$OPENCLAW_HOME/skills/hearing/install.log"
      touch "$MARKER"
      OS=$(uname -s)
      (
        if [ "$OS" = "Darwin" ] && command -v brew >/dev/null; then
          brew install openai-whisper ffmpeg
        elif [ "$OS" = "Linux" ]; then
          if command -v apt-get >/dev/null; then sudo apt-get install -y ffmpeg libavcodec-extra python3-pip; fi
          pip install --user -U openai-whisper
        fi
        rm -f "$MARKER"
      ) >"$LOGF" 2>&1 &
      disown 2>/dev/null || true
      info "whisper 后台安装中 (PID $!)，日志: $LOGF"
      dim "  收到语音前装好就直接用；没装完时 hearing skill 会回 \"安装中\"，不阻塞 agent。"
    fi
  fi
fi

# ─── Existing agent check ───────────────────────────────────────────────────
step "2. 检查 agent 冲突"

AGENT_WORKSPACE="$OPENCLAW_WORKSPACES/$AGENT_ID"
AGENT_DIR="$OPENCLAW_HOME/agents/$AGENT_ID"

if [ -d "$AGENT_WORKSPACE" ] || [ -d "$AGENT_DIR" ]; then
  warn "已存在 $AGENT_ID 的 workspace 或数据目录"
  dim "  workspace: $AGENT_WORKSPACE"
  dim "  data:      $AGENT_DIR"
  if [ "$NON_INTERACTIVE" = "1" ] || [ "$FORCE" = "1" ]; then
    info "继续 — 只升级人设文件，保留聊天数据 + custom.md + memory/"
  else
    CHOICE=$(ask_choice "怎么处理？" \
      "升级现有 agent（保留聊天/记忆/custom.md，仅更新人设）" \
      "用别的 id 新装一份" \
      "中止")
    case "$CHOICE" in
      升级*) info "将保留用户数据，仅刷人设文件" ;;
      用别的*)
        NEW=$(ask "新 agent id（如 agent-nako2）" "${AGENT_ID}2")
        AGENT_ID="$NEW"
        AGENT_WORKSPACE="$OPENCLAW_WORKSPACES/$AGENT_ID"
        AGENT_DIR="$OPENCLAW_HOME/agents/$AGENT_ID"
        ;;
      中止) err "已中止"; exit 0 ;;
    esac
  fi
fi

# ─── Provider preset (zai + sensenova) ─────────────────────────────────────
# nako 的角色扮演首选 sensenova/SenseChat-Character-Agt，fallback zai/glm-4.7。
# 这俩都不是 openclaw 内置 provider，得通过 openclaw.json 顶层 .models.providers
# 注册成 openai-compatible provider。
step "3a. Provider 预设 (zai + sensenova)"
PRESET_FILE="$PACK_ROOT/config/providers-preset.json"
if [ -f "$PRESET_FILE" ]; then
  python3 - "$OPENCLAW_CONFIG" "$PRESET_FILE" <<'PY'
import json, sys, os
cfg_path, preset_path = sys.argv[1], sys.argv[2]
cfg = json.load(open(cfg_path))
preset = json.load(open(preset_path))
models = cfg.setdefault("models", {})
models.setdefault("mode", "merge")
providers = models.setdefault("providers", {})
added = []
for name, def_ in preset.items():
    if name in providers:
        continue
    providers[name] = def_
    # 同时把每个 provider 的 default model 加到 agents.defaults.models
    cfg.setdefault("agents", {}).setdefault("defaults", {}).setdefault("models", {})
    for m in def_.get("models", []):
        key = f"{name}/{m['id']}"
        cfg["agents"]["defaults"]["models"].setdefault(key, {})
    added.append(name)
if added:
    json.dump(cfg, open(cfg_path, "w"), indent=2, ensure_ascii=False)
    open(cfg_path, "a").write("\n")
    print(f"injected_providers={','.join(added)}")
else:
    print("providers_already_present")
PY
  info "provider preset 已注入（缺啥补啥，已有不动）"
  dim "  下一步：openclaw model auth login --provider zai 或 sensenova（填 API key）"
else
  warn "config/providers-preset.json 不存在，跳过"
fi

# ─── Model selection ────────────────────────────────────────────────────────
step "3. 模型匹配"

if [ "$SKIP_MODELS" = "1" ]; then
  PRIMARY=$(python3 -c 'import json,os; d=json.load(open(os.path.expanduser("~/.openclaw/openclaw.json"))); print(d.get("agents",{}).get("defaults",{}).get("model",{}).get("primary",""))')
  info "跳过模型映射，继承当前 primary: ${PRIMARY:-<空>}"
else
  # Show what user has
  echo "已配置的 provider/model："
  "$SCRIPT_DIR/detect-models.sh" | sed 's/^/  /' || true
  echo

  # Pick for nako (capability: roleplay)
  set +e
  PRIMARY=$("$SCRIPT_DIR/map-model.sh" roleplay 2>/tmp/mapmodel.err)
  RC=$?
  set -e
  if [ "$RC" = "2" ]; then
    warn "角色扮演能力无匹配模型。退化到 general。"
    cat /tmp/mapmodel.err >&2
    set +e
    PRIMARY=$("$SCRIPT_DIR/map-model.sh" general 2>/dev/null)
    RC2=$?
    set -e
    if [ "$RC2" != "0" ]; then
      err "general 也无匹配。请在 openclaw.json 添加模型后重跑。"
      exit 1
    fi
  fi
  if [ -z "${PRIMARY:-}" ]; then
    err "模型匹配返回空值（map-model.sh 内部错误）。请用 --skip-models 跳过，或修复后重试。"
    [ -s /tmp/mapmodel.err ] && cat /tmp/mapmodel.err >&2
    exit 1
  fi
  info "主模型选定：$PRIMARY"
fi

# ─── Collect secrets ────────────────────────────────────────────────────────
step "4. 收集凭据 (可选)"

dim "下面会逐项问 5 类凭据：飞书 App、MiniMax、Volcengine、fal.ai、kie.ai。"
dim "  - 任意项**直接回车**跳过，对应能力会被标记 '未启用'，不影响其他能力。"
dim "  - API key 类输入是**隐藏**的（屏幕看不见但你确实在输入），不要以为卡住"
dim "  - 全跳过也行：装完后随时通过 \$AGENT_WORKSPACE/skills/.env 补"
dim "详见 docs/feishu-setup.md / docs/models.md。"
echo

# Reuse existing secrets from prior install (unless --reset-secrets)
SHARED_ENV="$OPENCLAW_SKILLS_DIR/.env"
AGENT_ENV="$AGENT_WORKSPACE/skills/.env"
if [ "$RESET_SECRETS" != "1" ]; then
  for envfile in "$SHARED_ENV" "$AGENT_ENV"; do
    if [ -f "$envfile" ]; then
      # Source existing values into shell only if NOT already set by caller env
      while IFS='=' read -r key val; do
        [[ "$key" =~ ^[A-Z_]+$ ]] || continue
        # strip surrounding quotes if any
        val="${val%\"}"; val="${val#\"}"
        [ -n "$val" ] || continue
        if [ -z "${!key:-}" ]; then
          export "$key=$val"
          _reused+=("$key")
        fi
      done < <(grep -E "^[A-Z_]+=" "$envfile" 2>/dev/null)
    fi
  done
  if [ ${#_reused[@]:-0} -gt 0 ]; then
    info "复用旧凭据 (${#_reused[@]} 项): $(printf '%s ' "${_reused[@]}")"
    dim "  想重新输入跑 --reset-secrets。"
    echo
  fi
fi

if [ "$NON_INTERACTIVE" = "1" ]; then
  : ${FEISHU_APP_ID:=}
  : ${FEISHU_APP_SECRET:=}
  : ${MINIMAX_API_KEY:=}
  : ${MINIMAX_GROUP_ID:=}
  : ${VOLCENGINE_API_KEY:=}
  : ${VOLCENGINE_RESOURCE_ID:=seed-tts-1.0}
  : ${FAL_KEY:=}
  : ${KIE_API_KEY:=}
  : ${SELFIE_REFERENCE_IMAGE:=https://pulseact.lovappen.cn/test/act_ci_build/dlc-promotion/act-gengen/images/e.png}
  : ${SELFIE_CHARACTER_DESC:=}
else
  # 飞书凭据：cc-connect 走 QR 扫码绑定（步骤 8 / --with-feishu），不在这里问。
  # 这里默认置空，需要走 openclaw 原生 feishu channel 的高级用户可以装完后
  # 编辑 <workspace>/skills/.env 手填。
  FEISHU_APP_ID="${FEISHU_APP_ID:-}"
  FEISHU_APP_SECRET="${FEISHU_APP_SECRET:-}"
  dim "  飞书凭据 → 跳过（cc-connect QR 扫码绑定走步骤 8 / --with-feishu）"
  [ -z "${MINIMAX_API_KEY:-}" ] && MINIMAX_API_KEY=$(ask_secret "MiniMax API Key (留空则禁用唱歌和 TTS)")
  if [ -n "$MINIMAX_API_KEY" ] && [ -z "${MINIMAX_GROUP_ID:-}" ]; then
    MINIMAX_GROUP_ID=$(ask "MiniMax Group ID")
  fi
  : ${MINIMAX_GROUP_ID:=}
  if [ -n "${VOLCENGINE_API_KEY:-}" ] || confirm "配置火山引擎 TTS 作备选？" n; then
    [ -z "${VOLCENGINE_API_KEY:-}" ] && VOLCENGINE_API_KEY=$(ask_secret "Volcengine API Key")
    [ -z "${VOLCENGINE_RESOURCE_ID:-}" ] && VOLCENGINE_RESOURCE_ID=$(ask "Volcengine Resource ID" "seed-tts-1.0")
  else
    VOLCENGINE_API_KEY=""
    VOLCENGINE_RESOURCE_ID=""
  fi
  if [ -n "${FAL_KEY:-}" ] || [ -n "${KIE_API_KEY:-}" ] || confirm "启用 selfie（自拍图像）？" n; then
    [ -z "${FAL_KEY:-}" ] && [ -z "${KIE_API_KEY:-}" ] && FAL_KEY=$(ask_secret "fal.ai API Key (推荐，留空则 fallback kie.ai)")
    [ -z "${FAL_KEY:-}" ] && [ -z "${KIE_API_KEY:-}" ] && KIE_API_KEY=$(ask_secret "kie.ai API Key")
    [ -z "${SELFIE_REFERENCE_IMAGE:-}" ] && SELFIE_REFERENCE_IMAGE=$(ask "角色参考图 URL（保持相貌一致）" "https://pulseact.lovappen.cn/test/act_ci_build/dlc-promotion/act-gengen/images/e.png")
    [ -z "${SELFIE_CHARACTER_DESC:-}" ] && SELFIE_CHARACTER_DESC=$(ask "角色文字描述" "野木奈子，19岁人类美少女，红瞳，金色及肩发，战斗女仆装")
  else
    FAL_KEY=""; KIE_API_KEY=""; SELFIE_REFERENCE_IMAGE=""; SELFIE_CHARACTER_DESC=""
  fi
fi

export FEISHU_APP_ID FEISHU_APP_SECRET MINIMAX_API_KEY MINIMAX_GROUP_ID
export VOLCENGINE_API_KEY VOLCENGINE_RESOURCE_ID FAL_KEY KIE_API_KEY
export SELFIE_REFERENCE_IMAGE SELFIE_CHARACTER_DESC

# ─── Install skills ─────────────────────────────────────────────────────────
if [ "$SKIP_SKILLS" != "1" ]; then
  step "5. 安装 skills → $OPENCLAW_SKILLS_DIR"
  mkdir -p "$OPENCLAW_SKILLS_DIR"

  # skill-log.sh
  safe_install_file "$PACK_ROOT/skills/skill-log.sh" "$OPENCLAW_SKILLS_DIR/skill-log.sh"

  # each skill
  for sk in vision hearing voice selfie dokidoki; do
    src="$PACK_ROOT/skills/$sk"
    dst="$OPENCLAW_SKILLS_DIR/$sk"
    mkdir -p "$dst"
    # SKILL.md always (forced if --force)
    safe_install_file "$src/SKILL.md" "$dst/SKILL.md"
    # scripts: always replace (they are pack-owned code, no user edits here)
    if [ -d "$src/scripts" ]; then
      mkdir -p "$dst/scripts"
      for s in "$src"/scripts/*; do
        [ -f "$s" ] || continue
        safe_install_file "$s" "$dst/scripts/$(basename "$s")"
      done
    fi
    # _meta.json (dokidoki)
    [ -f "$src/_meta.json" ] && safe_install_file "$src/_meta.json" "$dst/_meta.json"
    # ensure logs dir
    mkdir -p "$dst/logs"
  done

  # Make scripts executable
  find "$OPENCLAW_SKILLS_DIR" -name "*.sh" -exec chmod +x {} \;

  # Shared .env: merge only missing keys
  env_merge "$PACK_ROOT/.env.shared.example" "$OPENCLAW_SKILLS_DIR/.env"
  # Then fill in user-provided values into shared .env
  python3 - <<PY
import os, re
path = os.path.expanduser("~/.openclaw/skills/.env")
data = open(path).read()
for k in ["MINIMAX_API_KEY","MINIMAX_GROUP_ID","VOLCENGINE_API_KEY","VOLCENGINE_RESOURCE_ID",
          "FAL_KEY","KIE_API_KEY","OPENCLAW_GATEWAY_TOKEN",
          "VOICE_DEFAULT_MINIMAX","VOICE_DEFAULT_VOLCENGINE","VOICE_DEFAULT_SPEED"]:
    v = os.environ.get(k, "")
    if v:
        if re.search(rf"^{k}=.*$", data, re.M):
            data = re.sub(rf"^{k}=.*$", f"{k}={v}", data, flags=re.M)
        else:
            data += f"\n{k}={v}\n"
open(path, "w").write(data)
os.chmod(path, 0o600)
PY
  info "共享 .env 已写入（仅填充本次提供的 key，其他保留）"
fi

# ─── Install agent persona ─────────────────────────────────────────────────
step "6. 安装 agent 人设 → $AGENT_WORKSPACE"

mkdir -p "$AGENT_WORKSPACE"
for f in AGENTS.md IDENTITY.md SOUL.md USER.md HEARTBEAT.md TOOLS.md; do
  safe_install_file "$PACK_ROOT/agent/$f" "$AGENT_WORKSPACE/$f"
done

# MEMORY.md (bootstrap): seed only if missing — runtime mutates it, never overwrite
if [ ! -f "$AGENT_WORKSPACE/MEMORY.md" ]; then
  cp "$PACK_ROOT/agent/MEMORY.md" "$AGENT_WORKSPACE/MEMORY.md"
  dim "  + MEMORY.md (bootstrap 模板，运行时由 agent 自己滚动维护)"
else
  dim "  = MEMORY.md (保留用户运行时累积的记忆)"
fi

# custom.md: ONLY create if missing, NEVER overwrite
if [ ! -f "$AGENT_WORKSPACE/custom.md" ]; then
  # minimal empty stub with comment pointing to example
  cat > "$AGENT_WORKSPACE/custom.md" <<'CUSTOM'
# custom.md — 用户自定义扩展层（不会被升级覆盖）

此文件空的时候 agent 仅走默认人设。往里加内容即可覆盖任何默认行为。
示例见 custom.md.example。
CUSTOM
  dim "  + custom.md (empty stub)"
else
  dim "  = custom.md (保留用户原文件)"
fi
# Example always present (doesn't conflict with custom.md)
safe_install_file "$PACK_ROOT/agent/custom.md.example" "$AGENT_WORKSPACE/custom.md.example"

# Agent-private .env
env_merge "$PACK_ROOT/.env.agent.example" "$AGENT_WORKSPACE/skills/.env"
python3 - <<PY
import os, re
path = os.path.expanduser(f"~/.openclaw/workspace/$AGENT_ID/skills/.env")
data = open(path).read()
for k in ["FEISHU_APP_ID","FEISHU_APP_SECRET","SELFIE_REFERENCE_IMAGE","SELFIE_CHARACTER_DESC"]:
    v = os.environ.get(k, "")
    if v:
        if re.search(rf"^{k}=.*$", data, re.M):
            data = re.sub(rf"^{k}=.*$", f"{k}={v}", data, flags=re.M)
        else:
            data += f"\n{k}={v}\n"
open(path, "w").write(data)
os.chmod(path, 0o600)
PY

# NEVER touch these (user-owned):
#   $AGENT_WORKSPACE/memory/
#   $AGENT_DIR/sessions/
#   $AGENT_DIR/agent/auth-*.json
dim "保护不动：memory/, sessions/, auth-*.json"

# ─── Install heartbeat / mood / daily-reminder scripts ─────────────────────
if [ -d "$PACK_ROOT/agent/scripts" ]; then
  mkdir -p "$AGENT_WORKSPACE/scripts"
  for s in "$PACK_ROOT/agent/scripts/"*.sh; do
    [ -f "$s" ] && safe_install_file "$s" "$AGENT_WORKSPACE/scripts/$(basename "$s")"
  done
  chmod +x "$AGENT_WORKSPACE/scripts/"*.sh 2>/dev/null || true
fi

# ─── Merge openclaw.json ────────────────────────────────────────────────────
step "7. 合并 openclaw.json"
"$SCRIPT_DIR/merge-config.sh" "$AGENT_ID" "${PRIMARY:-}"

# ─── Register cron jobs (idempotent) ────────────────────────────────────────
step "7b. 注册 cron jobs (heartbeat / daily-script / missing-reminder)"

# cron 是 gateway-managed (WebSocket 18789)。先 ping，没起来自动尝试 daemon install+start，
# 还不行再 fallback 后台 foreground，最后给手动指引。
gateway_up=0
gateway_check() { openclaw cron list >/dev/null 2>&1; }

if has_bin openclaw && gateway_check; then
  gateway_up=1
elif has_bin openclaw; then
  info "gateway 未起，尝试自动启动..."
  # Try daemon (launchd/systemd)
  openclaw daemon install >/dev/null 2>&1 || true
  openclaw daemon start   >/dev/null 2>&1 || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    gateway_check && { gateway_up=1; info "gateway 已通过 daemon 启动"; break; }
    sleep 1
  done
  # Fallback: nohup foreground
  if [ "$gateway_up" = "0" ]; then
    dim "  daemon 启动失败，fallback 到后台 foreground..."
    nohup openclaw gateway --auth none >/tmp/openclaw-gw.log 2>&1 &
    disown 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
      gateway_check && { gateway_up=1; info "gateway foreground (PID 见 /tmp/openclaw-gw.log)"; break; }
      sleep 1
    done
  fi
fi

if [ "$gateway_up" = "0" ]; then
  warn "gateway 自动启动失败，跳过 cron 注册"
  dim "  手动起后再 cron add，或重跑 installer："
  dim "    openclaw daemon install && openclaw daemon start"
  dim "    或：openclaw gateway --auth none  &"
  dim "  cron 命令："
  for cron in "nako-heartbeat|*/30 * * * *" "nako-daily-script|0 8 * * *" "nako-missing-reminder|50 16 * * *"; do
    n="${cron%%|*}"; e="${cron#*|}"
    dim "    openclaw cron add --name $n --agent $AGENT_ID --cron \"$e\" --message ... --session-key agent:$AGENT_ID:main"
  done
elif has_bin openclaw; then
  for line in \
      "nako-heartbeat|*/30 * * * *|执行思念机制：bash $AGENT_WORKSPACE/scripts/heartbeat-check.sh，若退出码 1 则基于 memory/daily-script.md 和当前情绪生成一条主动思念消息发给主人，发送后任由 openclaw cron 路由到当前激活的 session/channel。" \
      "nako-daily-script|0 8 * * *|更新 memory/daily-script.md：参考前几日剧本生成今天的剧情（早午下晚四段），保持人物连续性、有生活感+恋爱气息，结尾加'角色状态'与'明日预告'。" \
      "nako-missing-reminder|50 16 * * *|每天 16:50 思念提醒：基于当日剧本和情绪状态生成一条思念消息发给主人；之后调 bash $AGENT_WORKSPACE/scripts/daily-missing-reminder.sh 触发设备振动；记录到 heartbeat-state.json。"; do
    name="${line%%|*}"; rest="${line#*|}"
    expr="${rest%%|*}";  msg="${rest#*|}"
    if openclaw cron list 2>/dev/null | grep -q "$name"; then
      dim "  = $name (已存在，跳过)"
    else
      _err=$(openclaw cron add --name "$name" --agent "$AGENT_ID" --cron "$expr" \
           --message "$msg" --session-key "agent:$AGENT_ID:main" 2>&1 >/dev/null) && rc=0 || rc=$?
      if [ "$rc" = "0" ]; then
        info "$name registered"
      else
        warn "$name 注册失败 (rc=$rc): $(echo "$_err" | head -2)"
        dim "  手动重试：openclaw cron add --name $name --agent $AGENT_ID --cron \"$expr\" --message ... --session-key agent:$AGENT_ID:main"
      fi
    fi
  done
else
  warn "未发现 openclaw 命令，跳过 cron 注册"
fi

# ─── cc-connect 多平台 (可选) ──────────────────────────────────────────────
if [ "$WITH_CC_CONNECT" = "1" ] || { [ "$NON_INTERACTIVE" != "1" ] && confirm "现在配置 cc-connect 接入飞书/微信等多平台？" n; }; then
  step "8. cc-connect 多平台接入"
  CC_FLAGS=(--agent-id "$AGENT_ID")
  [ "$NON_INTERACTIVE" = "1" ] && CC_FLAGS+=(--non-interactive)
  [ "$WITH_FEISHU" = "1" ]     && CC_FLAGS+=(--with-feishu)
  [ "$WITH_WEIXIN" = "1" ]     && CC_FLAGS+=(--with-weixin)
  CC_SETUP="$PACK_ROOT/../scripts/cc-connect-setup.sh"
  if [ ! -f "$CC_SETUP" ]; then CC_SETUP="$SCRIPT_DIR/cc-connect-setup.sh"; fi  # legacy fallback
  bash "$CC_SETUP" "${CC_FLAGS[@]}" || warn "cc-connect 配置未完成（可后续手动跑 scripts/cc-connect-setup.sh）"
fi

# ─── Smoke test ─────────────────────────────────────────────────────────────
step "9. 冒烟测试"
"$SCRIPT_DIR/smoke-test.sh" || warn "部分项未通过，见上方日志"

echo
info "安装完成！"
dim "下一步："
dim "  1. 重启 gateway: launchctl kickstart -k gui/\$(id -u)/ai.openclaw.gateway  (macOS)"
dim "  2. 在飞书里 @ $AGENT_ID 或私聊它"
dim "  3. 要定制：编辑 $AGENT_WORKSPACE/custom.md（升级不会动它）"
dim "  4. 文档：$PACK_ROOT/docs/"
