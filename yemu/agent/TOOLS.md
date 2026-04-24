# TOOLS.md - 本地工具速查

此文件列 agent 会用到的技能与它们的脚本入口。安装器会按你的环境填充可用项；缺少依赖的技能行会自动标注 `⚠️ 未启用`。

## 已启用（安装器会按实际环境自动调整）

```
🎤 voice   — 发语音 / 唱歌
   - ~/.openclaw/skills/voice/scripts/voice.sh "<文本>" <channel> [provider] [voice_id] [speed]
   - ~/.openclaw/skills/voice/scripts/sing.sh  "<歌词>" <channel> ["<风格>"] [model]

👀 vision  — 看图
   - ~/.openclaw/skills/vision/scripts/resolve.sh <image_key|--latest>
   - 拿到路径后用 Read 工具直接看图

👂 hearing — 听语音消息
   - ~/.openclaw/skills/hearing/scripts/stt.sh <file_key|--latest|/abs/path>

📸 selfie  — 生成自拍照片和图生视频
   - ~/.openclaw/skills/selfie/scripts/selfie.sh "<prompt>" <channel> [caption] [aspect_ratio] [format] [provider]
   - ~/.openclaw/skills/selfie/scripts/video.sh  "<image_url>" "<prompt>" <channel> ...

🎮 dokidoki — BLE 互动设备
   - doki scan / connect / action / player ...
```

## 技能选型

- **说话 vs 唱歌**：纯朗读用 `voice.sh`（快、稳）；用户要求唱歌/写歌用 `sing.sh`（MiniMax music-2.6，10–60 秒）
- **看图**：收到 `{"image_key":"..."}` 或 `<media:image>` 先 `resolve.sh` 拿路径，再 `Read` 看
- **听语音**：收到 `[Audio]` / `<media:audio>` 先 `stt.sh --latest` 转写

## 环境

- 通用 env 在 `~/.openclaw/skills/.env`
- 本 agent 私有 env（Feishu 凭据 + 角色标识）在 `<workspace>/skills/.env`
- 后者覆盖前者

## 用户自定义

见 `custom.md`。
