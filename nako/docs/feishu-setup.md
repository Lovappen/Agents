# 飞书机器人设置

每个 openclaw agent 都应该有**独立**的飞书 App（一个 App 一个 agent，避免串扰）。

## 步骤

1. 进 [https://open.feishu.cn](https://open.feishu.cn) 登录飞书账号
2. 「开发者后台」→「创建企业自建应用」
3. 填应用名称、描述、图标
4. 进入应用详情，记下两个值：
   - **App ID**（形如 `cli_xxxxxxxxx`）
   - **App Secret**
5. 左侧菜单「凭证与基础信息」底部的 **App Secret** 处点显示即可复制

## 授权

左侧「权限管理」搜索并开启：

| 权限 | 用途 |
|---|---|
| `im:message` | 收发消息 |
| `im:message.group_at_msg` | 群内 @机器人 触发 |
| `im:message.p2p_msg` | 私聊消息 |
| `im:resource` | 上传图片/音频/文件 |
| `im:chat` | 获取群信息 |
| `im:message:send_as_bot` | 以机器人名义发消息 |

开启完记得右上「发布版本」申请开发版审批通过。

## 事件订阅

左侧「事件与回调」→「事件配置」：

- **订阅方式**：选 `长连接（WebSocket）` — openclaw 走这种模式，无需公网域名
- **事件**：加
  - `im.message.receive_v1`（接收消息）
  - `im.chat.member.bot.added_v1`（机器人被加群）

## 启用机器人

左侧「应用能力」→「机器人」→「启用」

## 填回安装器

安装过程中问到：

```
? 飞书 App ID: cli_xxxxxxxxx
? 飞书 App Secret (hidden): ****
```

## 把机器人拉进聊天

- **群聊**：群设置 → 群机器人 → 添加 → 选你刚建的
- **私聊**：在飞书搜索 App 名字，直接发消息即可（需应用发布通过）

## 常见问题

**「Bot can NOT be out of chat」**
→ agent 用的飞书 App 和你发消息的聊天不匹配。每个 agent 要用自己的 App ID / Secret。

**机器人不回复**
→ 检查
1. 事件订阅是否开启
2. `openclaw-gateway` 进程在跑（`ps aux | grep openclaw-gateway`）
3. gateway.log 有没有报错

**消息发得出但收不到**
→ 长连接未建立。看 gateway.log 搜 `feishu` + `connect`，常见是 App Secret 填错。
