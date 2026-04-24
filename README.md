# Agents

可一键部署到 [openclaw](https://openclaw.ai) 的 agent 集合。每个子目录是一个独立的 agent pack，含人设 + skill + 安装器 + 文档。

## 现有 Agents

| Agent | 角色 | 渠道 | 快装 |
|---|---|---|---|
| [yemu](yemu/) | 战斗女仆 野木奈子 | 飞书 | `curl -fsSL https://raw.githubusercontent.com/Lovappen/Agents/main/yemu/install.sh \| bash` |

## Roadmap

- [ ] 微信 channel 兼容（via `@tencent-weixin/openclaw-weixin`）
- [ ] MiniMax 国际版（`api.minimax.io`）
- [ ] 更多 agent 模板（办公助手、学习搭档…）

## 贡献

欢迎开 PR 加新 agent pack。格式参考 `yemu/` 的目录结构：

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
