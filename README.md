# Agents

可一键部署到 [openclaw](https://openclaw.ai) 的 agent 集合。每个子目录是一个独立的 agent pack，含人设 + skill + 安装器 + 文档。

## 一键安装

```bash
# 默认装 nako（目前唯一 agent），交互式问 cc-connect 接入
curl -fsSL https://raw.githubusercontent.com/Lovappen/Agents/main/install.sh | bash

# 非交互 + QR 飞书一气呵成
curl -fsSL https://raw.githubusercontent.com/Lovappen/Agents/main/install.sh | bash -s -- --with-feishu

# 选别的 agent
curl -fsSL https://raw.githubusercontent.com/Lovappen/Agents/main/install.sh | bash -s -- --agent <name>

# 看可用 agent
curl -fsSL https://raw.githubusercontent.com/Lovappen/Agents/main/install.sh | bash -s -- --list
```

完整 flag：`bash install.sh --help`。

## 现有 Agents

| Agent | 角色 | 渠道 |
|---|---|---|
| [nako](nako/) | 战斗女仆 野木奈子 | 飞书 / 微信 / Telegram / Slack /...（via [cc-connect](https://github.com/chenhg5/cc-connect)） |

## 与 agent 无关的工具

`scripts/cc-connect-setup.sh` 单独可用，给任意 openclaw agent 做 cc-connect 多平台接入：

```bash
bash scripts/cc-connect-setup.sh --agent-id agent-foo --with-feishu --with-weixin
```

## Roadmap

- [x] **多平台接入**：飞书原生 + 通过 [cc-connect](https://github.com/chenhg5/cc-connect) 接微信/Telegram/Slack/Discord/QQ/微博/钉钉/企微/LINE 等。详见 [`scripts/cc-connect-setup.sh`](scripts/cc-connect-setup.sh)
- [x] **一键 QR onboarding**：飞书 / 微信 ilink 都内置在安装脚本里
- [ ] **微信原生语音气泡**：iLink Bot API 协议级限制——`@tencent-weixin/openclaw-weixin` 不暴露 `sendVoiceMessageWeixin`，外部 bot 发 voice item 永远 `ret=-2`。等腾讯放开（[chenhg5/cc-connect#763](https://github.com/chenhg5/cc-connect/issues/763)）
- [ ] **微信 cron 主动推送**：`context_token` TTL 短，cron-driven daily-reminder 不保证送达。需要 cc-connect 实现 token 续期或换协议
- [ ] **MiniMax 国际版**（`api.minimax.io`）
- [ ] **更多 agent 模板**（办公助手、学习搭档…）
- [ ] **共享 skill 库**：把 `nako/skills/` 里通用的 vision/hearing/voice/selfie 提取到 root 让多 agent 复用

## 贡献

欢迎开 PR 加新 agent pack。格式参考 `nako/` 的目录结构：

```
your-agent/
├── install.sh           # 入口
├── install.ps1          # Windows
├── README.md            # 快装 + 定位
├── agent/               # 人设 md 文件 + custom.md 模板
├── skills/              # 本 agent 用到的 skill
├── config/
│   └── model-map.yaml   # 按能力的模型候选表
├── scripts/             # 安装器内部 helper
└── docs/                # 用户文档
```

新 pack 必须：
- 不把任何真实 key / secret 提交进仓库（`.env.*.example` 仅占位）
- 升级路径不破坏用户 `custom.md` / `memory/` / `sessions/`
- 有 `scripts/smoke-test.sh` 冒烟脚本
- 顶层 README 里加一行

## License

MIT, see [LICENSE](LICENSE).
