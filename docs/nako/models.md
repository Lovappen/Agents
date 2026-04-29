# 模型选型与切换

## 安装器怎么挑模型

安装器根据 `config/model-map.yaml` 决定给 agent 配哪个 primary model：

```
1. 读你的 ~/.openclaw/openclaw.json，拿到 agents.defaults.models 下所有 provider/model
2. 对照 model-map 的 capabilities.roleplay.preferred 列表，按顺序挑第一个你已配置的
3. 若 preferred 里多个都已配置 → 交互让你选
4. 若一个都没命中 → 退化到 capabilities.general.preferred，并打印说明
5. 还没命中 → 报错退出，让你先加模型
```

## 推荐模型（按 nako 角色扮演的契合度）

| 模型 | 提供商 | 评价 |
|---|---|---|
| `sensenova/SenseChat-Character-Agt` | 商汤日日新 | **最佳** — 角色一致性强，中文口语化，情感拿捏到位 |
| `zhipu/glm-4-plus` | 智谱 | 次优 — 综合好，角色稍淡 |
| `zai/glm-5` | Z.ai | 可用 — 综合模型，角色 flavor 弱 |
| `anthropic/claude-sonnet-4` | Anthropic | 可用 — 英文强，中文角色一般 |
| `openai/gpt-4o` | OpenAI | 可用 — 视觉强，角色需大量 prompt |

## 查当前已配模型

```bash
bash nako/scripts/detect-models.sh
```

输出：

```
sensenova/SenseChat-Character-Agt    
zai/glm-4.7                           
zai/glm-5                    GLM
zai/glm-4.7                 * (primary)
```

`*` 表示当前 `agents.defaults.model.primary`。

## 手动切换 agent 的主模型

编辑 `~/.openclaw/openclaw.json`，找到 `agents.list` 里你的 agent：

```json
{
  "id": "agent-nako",
  "model": { "primary": "sensenova/SenseChat-Character-Agt" }
}
```

改完重启 gateway。

或重跑 `install.sh` 让它重新交互选。

## 加新模型到 openclaw

先在 `openclaw.json` 的 `agents.defaults.models` 下加：

```json
"agents": {
  "defaults": {
    "models": {
      "sensenova/SenseChat-Character-Agt": {}
    }
  }
}
```

再到 `agents.defaults` 补 provider 定义（走 `openclaw setup` 交互式添加最省事），或去 `~/.openclaw/agents/<id>/agent/models.json` 和 `auth-profiles.json` 加 API key。

详见 openclaw 官方文档的 provider 设置。

## 加 provider 到 model-map.yaml

想让安装器自动识别更多模型，编辑 `config/model-map.yaml`：

```yaml
capabilities:
  roleplay:
    preferred:
      - sensenova/SenseChat-Character-Agt
      - your_provider/your_model      # ← 加到偏好顺序
      - zhipu/glm-4-plus
```

往 preferred 列表靠前加 = 优先级高。

## 不同 skill 对模型的要求

| Skill | 模型需求 | 不满足时 |
|---|---|---|
| voice / sing | 无（跟 LLM 无关） | — |
| hearing | 无（本地 whisper） | — |
| vision | primary 必须多模态 | 路径能拿到，但 agent 无法理解图像内容 |
| selfie | 无 | — |
| dokidoki | 无 | — |

若 primary 不多模态、你又想 agent 看图，换个多模态 primary，或者在 `custom.md` 里说明「遇到图片时只报告路径，不做解读」。

## 上下文窗口

角色扮演类 agent 对话往往很长。推荐 primary 至少 128K 上下文。nako 默认 `sensenova/SenseChat-Character-Agt` 是 198K。

如果用小上下文模型（< 32K），必要时调 openclaw 的 compaction：

```json
"agents": {
  "defaults": {
    "compaction": {
      "mode": "safeguard",
      "reserveTokensFloor": 30000
    }
  }
}
```
