# CC-CLAW

**C**laude **C**ode on **L**inux, **A**ccess from **W**eb.

One-script setup: Claude Code + code-server (VS Code Web) + cc-connect (IM bridge) on any Linux server. Optionally add CloudFront for HTTPS.

```
Your Phone/Browser
     │
     ├─ HTTPS ──▶ CloudFront ──▶ code-server (VS Code Web IDE)
     │                                   │
     └─ IM ────▶ cc-connect ────────▶ Claude Code CLI
       (Feishu/Telegram/                 │
        Slack/Discord/                   ▼
        DingTalk/WeChat)          Amazon Bedrock / Anthropic API
```

## Quick Start

### Option 1: Bash Script (any Linux server)

```bash
curl -fsSL https://raw.githubusercontent.com/HanqingAWS/cc-claw-on-aws/main/install.sh -o install.sh
sudo bash install.sh
```

The script interactively configures:
- **Claude Code** — provider (Bedrock or API key), model selection
- **code-server** — password, systemd service on port 8080, dark theme by default
- **cc-connect** — IM platform (Feishu/Telegram/Slack/Discord/DingTalk/WeChat Work), agent permission mode

Optional: add HTTPS via CloudFront:

```bash
bash setup-cloudfront.sh
```

### Option 2: CloudFormation (one-click on AWS)

Deploy the full stack (VPC + EC2 + CloudFront) with one click:

[![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home#/stacks/new?stackName=CC-CLAW&templateURL=<your-template-url>)

Or deploy via CLI:

```bash
aws cloudformation create-stack \
  --stack-name CC-CLAW \
  --template-body file://cloudformation/template.yaml \
  --parameters \
    ParameterKey=SysPassword,ParameterValue=YourPassword123 \
    ParameterKey=BedrockModel,ParameterValue=global.anthropic.claude-sonnet-4-6 \
  --capabilities CAPABILITY_IAM
```

## Architecture

### What Gets Installed

| Component | Purpose | Port |
|-----------|---------|------|
| **Claude Code** | AI coding agent CLI | — |
| **code-server** | VS Code in browser (dark theme) | 8080 |
| **cc-connect** | Bridge IM → Claude Code | — |
| **CloudFront** (optional) | HTTPS termination, no custom domain needed | 443 |

### Authentication & Security

- **Bedrock**: EC2 IAM Instance Profile — no API keys to manage
- **code-server**: password auth
- **CloudFront**: restricts origin access via AWS prefix list (only CloudFront IPs can reach port 8080)
- **SSH**: EC2 Instance Connect (no key pair needed) or standard SSH key

## Configuration

### Claude Code (`~/.claude/settings.json`)

```json
{
    "env": {
        "CLAUDE_CODE_USE_BEDROCK": "1",
        "ANTHROPIC_MODEL": "global.anthropic.claude-sonnet-4-6",
        "AWS_REGION": "us-east-1"
    }
}
```

Available models:

| Model | ID | Notes |
|-------|----|-------|
| Sonnet 4.6 | `global.anthropic.claude-sonnet-4-6` | Balanced, default |
| Opus 4.6 | `global.anthropic.claude-opus-4-6-v1` | Most capable |
| Opus 4.7 | `us.anthropic.claude-opus-4-7` | Latest, US regions only |
| Haiku 4.5 | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | Fastest, cheapest |

> `global.` prefix models work in all AWS regions. `us.` prefix models only work in US regions (us-east-1, us-west-2, etc.).

### cc-connect (`~/.cc-connect/config.toml`)

See [config/config.example.toml](config/config.example.toml) for full reference.

```toml
[[projects]]
name = "my-project"

[projects.agent]
type = "claudecode"

[projects.agent.options]
mode = "bypassPermissions"  # no permission prompts in IM
work_dir = "/home/ec2-user/projects"

[[projects.platforms]]
type = "feishu"
[projects.platforms.options]
app_id = "cli_xxx"
app_secret = "xxx"
allow_from = "*"
```

Agent modes:

| Mode | Behavior |
|------|----------|
| `default` | Ask before every action (reply "allow"/"允许" in IM) |
| `acceptEdits` | Auto-approve file edits, ask for shell commands |
| `bypassPermissions` | Auto-approve everything |

## Platform Setup Guides

### Feishu / Lark (飞书)

Connection: WebSocket (no public IP required)

1. Go to [Feishu Open Platform](https://open.feishu.cn) and create a new app
2. Under **App Features**, enable **Bot**
3. Under **Event Subscriptions**:
   - Select **WebSocket** as the connection mode
   - Add event: `im.message.receive_v1`
4. Under **Permissions**, add:
   - `im:message` — send messages
   - `im:message:receive_v1` — receive messages
5. **Publish** the app (or set to test mode for development)
6. Copy **App ID** and **App Secret** from the app's credentials page

Configure in `~/.cc-connect/config.toml`:

```toml
[[projects.platforms]]
type = "feishu"
[projects.platforms.options]
app_id = "cli_xxxxxxxxxxxx"
app_secret = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
allow_from = "*"
```

Restart cc-connect:

```bash
cc-connect daemon restart
```

You can now message the bot directly in Feishu to interact with Claude Code.

### Telegram

Connection: Long Polling (no public IP required)

1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the prompts to create a bot
3. Copy the **bot token** (format: `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`)

Configure:

```toml
[[projects.platforms]]
type = "telegram"
[projects.platforms.options]
token = "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
allow_from = "*"
```

### Slack

Connection: Socket Mode (no public IP required)

1. Create an app at [api.slack.com/apps](https://api.slack.com/apps)
2. Go to **Settings > Socket Mode** and enable it — copy the **App-Level Token** (`xapp-...`)
3. Under **Event Subscriptions**, subscribe to: `message.channels`, `message.im`
4. Under **OAuth & Permissions**, add scopes: `chat:write`, `channels:history`, `im:history`
5. Install the app to your workspace — copy the **Bot Token** (`xoxb-...`)

Configure:

```toml
[[projects.platforms]]
type = "slack"
[projects.platforms.options]
bot_token = "xoxb-your-bot-token"
app_token = "xapp-your-app-level-token"
allow_from = "*"
```

### Discord

Connection: Gateway WebSocket (no public IP required)

1. Create an app at [discord.com/developers/applications](https://discord.com/developers/applications)
2. Under **Bot**, create a bot and copy the **token**
3. Enable **Message Content Intent** under Privileged Gateway Intents
4. Use **OAuth2 URL Generator** to invite the bot:
   - Scopes: `bot` + `applications.commands` (both required)
   - Bot Permissions: Send Messages, Use Slash Commands
5. Optionally set `guild_id` for instant slash command registration (otherwise takes up to 1 hour)

Configure:

```toml
[[projects.platforms]]
type = "discord"
[projects.platforms.options]
token = "your-discord-bot-token"
allow_from = "*"
# guild_id = ""  # Set for instant slash command registration
```

### DingTalk (钉钉)

Connection: Stream Mode (no public IP required)

1. Create an app at [open-dev.dingtalk.com](https://open-dev.dingtalk.com)
2. Under **App Features > Bot**, enable bot and select **Stream** mode
3. Copy **AppKey** (Client ID) and **AppSecret** (Client Secret)

Configure:

```toml
[[projects.platforms]]
type = "dingtalk"
[projects.platforms.options]
client_id = "your-appkey"
client_secret = "your-appsecret"
allow_from = "*"
```

### WeChat Work (企业微信)

Connection: HTTP Webhook (public IP required)

1. Log in to [WeChat Work Admin](https://work.weixin.qq.com/wework_admin/frame)
2. **App Management** > Create a custom app > note **AgentId** and **Secret**
3. **My Enterprise** > note **Corp ID**
4. **App** > **Receive Messages** > Set API Receive:
   - URL: `http://<your-server-ip>:8081/wecom/callback`
   - Token: any random string
   - EncodingAESKey: click "Random Generate" (43 chars)
   - **Start cc-connect FIRST**, then save to pass URL verification
5. **App** > **Trusted IP** > add your server's public IP

Configure:

```toml
[[projects.platforms]]
type = "wecom"
[projects.platforms.options]
corp_id = "ww1234567890"
corp_secret = "your-app-secret"
agent_id = "1000002"
callback_token = "your-random-token"
callback_aes_key = "your-43-char-encoding-aes-key"
port = "8081"
callback_path = "/wecom/callback"
allow_from = "*"
```

> If using CloudFormation or setup-cloudfront.sh, you need to open port 8081 in the security group for WeChat Work callbacks.

### Personal WeChat (个人微信)

Requires cc-connect beta version (`npm install -g cc-connect@beta`).

Uses the WeChat iLink AI bot interface.

```toml
[[projects.platforms]]
type = "weixin"
[projects.platforms.options]
token = "your-ilink-bot-bearer-token"
base_url = "https://ilinkai.weixin.qq.com"
cdn_base_url = "https://novac2c.cdn.weixin.qq.com/c2c"
long_poll_timeout_ms = 35000
```

### Supported Platforms Summary

| Platform | Connection | Public IP Required |
|----------|------------|-------------------|
| Feishu / Lark | WebSocket | No |
| Telegram | Long Polling | No |
| Slack | Socket Mode | No |
| Discord | Gateway | No |
| DingTalk | Stream | No |
| WeChat Work | HTTP Webhook | Yes |
| Personal WeChat | Long Polling | No |
| LINE | HTTP Webhook | Yes |
| QQ (NapCat) | OneBot WebSocket | No |
| QQ Bot (Official) | WebSocket | No |

## Managing cc-connect

```bash
# Daemon control
cc-connect daemon start|stop|restart|status
cc-connect daemon logs -f

# In-chat commands (send via IM)
/new          # Start new session
/help         # Show available commands
/quiet        # Toggle verbose output
/compact      # Compact conversation context
```

## EC2 Instance Types

All instances use ARM64 (Graviton) for better price-performance:

| Type | vCPU | RAM | Use Case |
|------|------|-----|----------|
| t4g.large | 2 | 8 GB | Light usage, single user |
| t4g.xlarge | 4 | 16 GB | Regular development |
| c6g.xlarge | 4 | 8 GB | CPU-intensive builds |
| m6g.xlarge | 4 | 16 GB | Multi-project / heavy usage |

## IAM Permissions (Bedrock)

Minimum permissions needed on the EC2 instance role:

```json
{
    "Effect": "Allow",
    "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:ListInferenceProfiles"
    ],
    "Resource": "*"
}
```

## License

MIT
