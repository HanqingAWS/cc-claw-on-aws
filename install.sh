#!/bin/bash
set -e

# CC-CLAW Installer
# One-script setup for Claude Code + code-server + cc-connect on any Linux server.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}"
    cat << 'BANNER'
   ____ ____       ____ _        ___        __
  / ___/ ___|     / ___| |      / \ \      / /
 | |  | |   _____| |   | |     / _ \ \ /\ / /
 | |__| |__|_____| |___| |___ / ___ \ V  V /
  \____\____|     \____|_____/_/   \_\_/\_/

  Claude Code on Linux, Access from Web
BANNER
    echo -e "${NC}"
}

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi
}

detect_user() {
    if [ "$(id -u)" -eq 0 ]; then
        if [ -d /home/ubuntu ]; then
            SYS_USER=ubuntu
        elif [ -d /home/ec2-user ]; then
            SYS_USER=ec2-user
        else
            SYS_USER=root
        fi
    else
        SYS_USER=$(whoami)
    fi
    SYS_HOME=$(eval echo "~$SYS_USER")
}

install_dependencies() {
    log_info "Installing system dependencies..."
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y tar gzip git
        command -v curl >/dev/null 2>&1 || sudo dnf install -y curl-minimal
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y tar gzip git curl
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y
        sudo apt-get install -y tar gzip git curl
    else
        log_error "Unsupported package manager."
        exit 1
    fi
}

install_nodejs() {
    if command -v node >/dev/null 2>&1; then
        NODE_CURRENT=$(node -v | sed 's/v//')
        log_info "Node.js $NODE_CURRENT already installed."
        return
    fi
    log_info "Installing Node.js LTS..."
    NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/index.json | python3 -c "import sys,json; print([v['version'][1:] for v in json.load(sys.stdin) if v['lts']][0])")
    ARCH=$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/')
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${ARCH}.tar.xz" | sudo tar -xJ -C /usr/local --strip-components=1
    log_info "Node.js $NODE_VERSION installed."
}

install_claude_code() {
    log_info "Installing Claude Code..."
    if [ "$(id -u)" -eq 0 ]; then
        sudo -u "$SYS_USER" bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'
    else
        curl -fsSL https://claude.ai/install.sh | bash
    fi
}

configure_bedrock() {
    echo ""
    echo -e "${CYAN}=== Claude Code Provider Configuration ===${NC}"
    echo ""
    echo "  1) Amazon Bedrock (IAM role, no API key needed)"
    echo "  2) Anthropic API Key"
    echo ""
    read -rp "Choose provider [1]: " PROVIDER_CHOICE
    PROVIDER_CHOICE=${PROVIDER_CHOICE:-1}

    CLAUDE_DIR="$SYS_HOME/.claude"
    mkdir -p "$CLAUDE_DIR"

    if [ "$PROVIDER_CHOICE" = "1" ]; then
        echo ""
        echo -e "${CYAN}Available models:${NC}"
        echo "  1) global.anthropic.claude-sonnet-4-6        (default, balanced)"
        echo "  2) global.anthropic.claude-opus-4-6-v1       (most capable)"
        echo "  3) us.anthropic.claude-opus-4-7              (latest Opus, US regions only)"
        echo "  4) global.anthropic.claude-haiku-4-5-20251001-v1:0 (fastest)"
        echo "  5) Custom model ID"
        echo ""
        read -rp "Choose model [1]: " MODEL_CHOICE
        MODEL_CHOICE=${MODEL_CHOICE:-1}

        case "$MODEL_CHOICE" in
            1) MODEL="global.anthropic.claude-sonnet-4-6" ;;
            2) MODEL="global.anthropic.claude-opus-4-6-v1" ;;
            3) MODEL="us.anthropic.claude-opus-4-7" ;;
            4) MODEL="global.anthropic.claude-haiku-4-5-20251001-v1:0" ;;
            5) read -rp "Enter model ID: " MODEL ;;
            *) MODEL="global.anthropic.claude-sonnet-4-6" ;;
        esac

        # Detect region
        AWS_REGION_DEFAULT=""
        if command -v curl >/dev/null 2>&1; then
            TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 5" 2>/dev/null || true)
            if [ -n "$TOKEN" ]; then
                AWS_REGION_DEFAULT=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
            fi
        fi
        if [ -z "$AWS_REGION_DEFAULT" ]; then
            AWS_REGION_DEFAULT="us-east-1"
        fi

        # If using us. prefix model, suggest US region
        if [[ "$MODEL" == us.* ]] && [[ "$AWS_REGION_DEFAULT" != us-* ]]; then
            log_warn "Model '$MODEL' requires a US region. Defaulting to us-east-1."
            AWS_REGION_DEFAULT="us-east-1"
        fi

        read -rp "AWS Region [$AWS_REGION_DEFAULT]: " AWS_REGION
        AWS_REGION=${AWS_REGION:-$AWS_REGION_DEFAULT}

        read -rp "Enable 1-hour prompt caching? (y/N): " ENABLE_CACHE
        CACHE_LINE=""
        if [[ "$ENABLE_CACHE" =~ ^[Yy] ]]; then
            CACHE_LINE=',
        "ENABLE_PROMPT_CACHING_1H_BEDROCK": "1"'
        fi

        cat > "$CLAUDE_DIR/settings.json" << SEOF
{
    "env": {
        "CLAUDE_CODE_USE_BEDROCK": "1",
        "ANTHROPIC_MODEL": "$MODEL",
        "AWS_REGION": "$AWS_REGION",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": "global.anthropic.claude-haiku-4-5-20251001-v1:0",
        "ANTHROPIC_DEFAULT_SONNET_MODEL": "global.anthropic.claude-sonnet-4-6",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "global.anthropic.claude-opus-4-6-v1"$CACHE_LINE
    }
}
SEOF
        log_info "Configured Claude Code with Bedrock ($MODEL) in $AWS_REGION."

    else
        read -rp "Enter your Anthropic API Key: " API_KEY
        if [ -z "$API_KEY" ]; then
            log_error "API key cannot be empty."
            exit 1
        fi
        cat > "$CLAUDE_DIR/settings.json" << SEOF
{
    "env": {
        "ANTHROPIC_API_KEY": "$API_KEY"
    }
}
SEOF
        log_info "Configured Claude Code with Anthropic API key."
    fi

    if [ "$(id -u)" -eq 0 ]; then
        chown -R "$SYS_USER:$SYS_USER" "$CLAUDE_DIR"
    fi
}

install_code_server() {
    echo ""
    read -rp "Install code-server (VS Code in browser)? (Y/n): " INSTALL_CS
    if [[ "$INSTALL_CS" =~ ^[Nn] ]]; then
        return
    fi

    log_info "Installing code-server..."
    curl -fsSL https://code-server.dev/install.sh | sh

    read -rsp "Set code-server password: " CS_PASSWORD
    echo ""
    if [ -z "$CS_PASSWORD" ]; then
        log_error "Password cannot be empty."
        exit 1
    fi

    mkdir -p "$SYS_HOME/.config/code-server"
    cat > "$SYS_HOME/.config/code-server/config.yaml" << CSEOF
bind-addr: 0.0.0.0:8080
auth: password
password: $CS_PASSWORD
cert: false
CSEOF

    cat > /etc/systemd/system/code-server.service << SVCEOF
[Unit]
Description=code-server
After=network.target

[Service]
Type=simple
User=$SYS_USER
WorkingDirectory=$SYS_HOME/projects
ExecStart=/usr/bin/code-server --bind-addr 0.0.0.0:8080 $SYS_HOME/projects
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

    if [ "$(id -u)" -eq 0 ]; then
        chown -R "$SYS_USER:$SYS_USER" "$SYS_HOME/.config"
    fi

    mkdir -p "$SYS_HOME/projects"
    if [ "$(id -u)" -eq 0 ]; then
        chown "$SYS_USER:$SYS_USER" "$SYS_HOME/projects"
    fi

    # Set dark theme as default
    CS_SETTINGS_DIR="$SYS_HOME/.local/share/code-server/User"
    mkdir -p "$CS_SETTINGS_DIR"
    cat > "$CS_SETTINGS_DIR/settings.json" << THEOF
{
    "workbench.colorTheme": "Default Dark Modern",
    "editor.fontSize": 14,
    "terminal.integrated.fontSize": 14
}
THEOF
    if [ "$(id -u)" -eq 0 ]; then
        chown -R "$SYS_USER:$SYS_USER" "$SYS_HOME/.local"
    fi

    systemctl daemon-reload
    systemctl enable code-server
    systemctl start code-server
    log_info "code-server started on port 8080."
}

install_cc_connect() {
    echo ""
    read -rp "Install cc-connect (bridge Claude Code to IM platforms)? (Y/n): " INSTALL_CC
    if [[ "$INSTALL_CC" =~ ^[Nn] ]]; then
        return
    fi

    read -rp "Install beta version (includes personal WeChat support)? (y/N): " USE_BETA
    if [[ "$USE_BETA" =~ ^[Yy] ]]; then
        npm install -g cc-connect@beta
    else
        npm install -g cc-connect
    fi

    CC_DIR="$SYS_HOME/.cc-connect"
    mkdir -p "$CC_DIR"

    WORK_DIR="$SYS_HOME/projects"

    echo ""
    echo -e "${CYAN}=== cc-connect Platform Setup ===${NC}"
    echo ""
    echo "  1) Feishu / Lark      (WebSocket, no public IP needed)"
    echo "  2) Telegram            (Long Polling, no public IP needed)"
    echo "  3) Slack               (Socket Mode, no public IP needed)"
    echo "  4) Discord             (Gateway, no public IP needed)"
    echo "  5) DingTalk            (Stream Mode, no public IP needed)"
    echo "  6) WeChat Work         (Webhook, public IP required)"
    echo "  7) Skip (configure later)"
    echo ""
    read -rp "Choose platform [7]: " PLATFORM_CHOICE
    PLATFORM_CHOICE=${PLATFORM_CHOICE:-7}

    PLATFORM_CONFIG=""
    case "$PLATFORM_CHOICE" in
        1)
            read -rp "Feishu App ID: " FEISHU_APP_ID
            read -rp "Feishu App Secret: " FEISHU_APP_SECRET
            PLATFORM_CONFIG=$(cat << PEOF

[[projects.platforms]]
type = "feishu"
[projects.platforms.options]
app_id = "$FEISHU_APP_ID"
app_secret = "$FEISHU_APP_SECRET"
allow_from = "*"
PEOF
)
            ;;
        2)
            read -rp "Telegram Bot Token: " TG_TOKEN
            PLATFORM_CONFIG=$(cat << PEOF

[[projects.platforms]]
type = "telegram"
[projects.platforms.options]
token = "$TG_TOKEN"
allow_from = "*"
PEOF
)
            ;;
        3)
            read -rp "Slack Bot Token (xoxb-...): " SLACK_BOT
            read -rp "Slack App Token (xapp-...): " SLACK_APP
            PLATFORM_CONFIG=$(cat << PEOF

[[projects.platforms]]
type = "slack"
[projects.platforms.options]
bot_token = "$SLACK_BOT"
app_token = "$SLACK_APP"
allow_from = "*"
PEOF
)
            ;;
        4)
            read -rp "Discord Bot Token: " DISCORD_TOKEN
            PLATFORM_CONFIG=$(cat << PEOF

[[projects.platforms]]
type = "discord"
[projects.platforms.options]
token = "$DISCORD_TOKEN"
allow_from = "*"
PEOF
)
            ;;
        5)
            read -rp "DingTalk Client ID (AppKey): " DING_ID
            read -rp "DingTalk Client Secret: " DING_SECRET
            PLATFORM_CONFIG=$(cat << PEOF

[[projects.platforms]]
type = "dingtalk"
[projects.platforms.options]
client_id = "$DING_ID"
client_secret = "$DING_SECRET"
allow_from = "*"
PEOF
)
            ;;
        6)
            read -rp "Corp ID: " WECOM_CORP
            read -rp "App Secret: " WECOM_SECRET
            read -rp "Agent ID: " WECOM_AGENT
            read -rp "Callback Token: " WECOM_TOKEN
            read -rp "Callback AES Key (43 chars): " WECOM_AES
            PLATFORM_CONFIG=$(cat << PEOF

[[projects.platforms]]
type = "wecom"
[projects.platforms.options]
corp_id = "$WECOM_CORP"
corp_secret = "$WECOM_SECRET"
agent_id = "$WECOM_AGENT"
callback_token = "$WECOM_TOKEN"
callback_aes_key = "$WECOM_AES"
port = "8081"
callback_path = "/wecom/callback"
allow_from = "*"
PEOF
)
            ;;
        7)
            log_info "Skipping platform setup. Edit $CC_DIR/config.toml later."
            ;;
    esac

    echo ""
    echo -e "${CYAN}Agent permission mode:${NC}"
    echo "  1) default             (ask before every action)"
    echo "  2) acceptEdits         (auto-approve file edits)"
    echo "  3) bypassPermissions   (auto-approve everything)"
    echo ""
    read -rp "Choose mode [3]: " MODE_CHOICE
    MODE_CHOICE=${MODE_CHOICE:-3}

    case "$MODE_CHOICE" in
        1) AGENT_MODE="default" ;;
        2) AGENT_MODE="acceptEdits" ;;
        3) AGENT_MODE="bypassPermissions" ;;
        *) AGENT_MODE="bypassPermissions" ;;
    esac

    read -rp "Project name [my-project]: " PROJECT_NAME
    PROJECT_NAME=${PROJECT_NAME:-my-project}

    cat > "$CC_DIR/config.toml" << CCEOF
attachment_send = "on"
language = "zh"

[log]
level = "info"

[[projects]]
name = "$PROJECT_NAME"

[projects.agent]
type = "claudecode"
[projects.agent.options]
mode = "$AGENT_MODE"
work_dir = "$WORK_DIR"
allowed_tools = ["Read", "Grep", "Glob", "Bash", "Edit", "Write", "WebFetch", "TodoRead", "TodoWrite"]
$PLATFORM_CONFIG
CCEOF

    if [ "$(id -u)" -eq 0 ]; then
        chown -R "$SYS_USER:$SYS_USER" "$CC_DIR"
    fi

    # Install as daemon
    if [ "$PLATFORM_CHOICE" != "7" ]; then
        log_info "Installing cc-connect daemon..."
        loginctl enable-linger "$SYS_USER" 2>/dev/null || true
        XDG_DIR="/run/user/$(id -u "$SYS_USER")"
        if [ "$(id -u)" -eq 0 ]; then
            su - "$SYS_USER" -c "export XDG_RUNTIME_DIR=$XDG_DIR && cc-connect daemon install --work-dir $CC_DIR" || true
            su - "$SYS_USER" -c "export XDG_RUNTIME_DIR=$XDG_DIR && cc-connect daemon start --work-dir $CC_DIR" || true
        else
            export XDG_RUNTIME_DIR=$XDG_DIR
            cc-connect daemon install --work-dir "$CC_DIR" || true
            cc-connect daemon start --work-dir "$CC_DIR" || true
        fi
        log_info "cc-connect daemon started."
    fi

    log_info "cc-connect installed. Config: $CC_DIR/config.toml"
}

print_summary() {
    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${GREEN}  Installation complete!${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
    if systemctl is-active --quiet code-server 2>/dev/null; then
        PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 5' 2>/dev/null)" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "<your-server-ip>")
        echo -e "  code-server:  ${GREEN}http://$PUBLIC_IP:8080${NC}"
    fi
    echo -e "  Claude Code:  Run ${CYAN}claude${NC} in terminal"
    if [ -f "$SYS_HOME/.cc-connect/config.toml" ]; then
        echo -e "  cc-connect:   Config at ${CYAN}$SYS_HOME/.cc-connect/config.toml${NC}"
    fi
    echo ""
    echo -e "  To set up CloudFront HTTPS access, run:"
    echo -e "    ${CYAN}bash setup-cloudfront.sh${NC}"
    echo ""
}

# === Main ===

print_banner

if [ "$(uname)" != "Linux" ]; then
    log_error "This script only supports Linux."
    exit 1
fi

detect_os
detect_user

log_info "Detected OS: $OS_ID, User: $SYS_USER"

install_dependencies
install_nodejs
install_claude_code
configure_bedrock
install_code_server
install_cc_connect

print_summary
