#!/bin/bash

set -e

REPO="zexinhwang/Liquid-Glass-Prism-dns"
BINARY_NAME="prism-agent"
INSTALL_DIR="/usr/local/bin"
SERVICE_NAME="prism-agent"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/main/agent_install.sh"
CUSTOM_IP=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run as root (sudo)"
    fi
}

parse_args() {
    MASTER_ADDR=""
    SECRET_TOKEN=""
    UNINSTALL_MODE=false
    BETA_MODE=false
    SMART_MODE=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --master)
                if [ -n "$2" ] && [ "${2:0:2}" != "--" ]; then
                    MASTER_ADDR="$2"
                    shift 2
                else
                    error "--master requires a value"
                fi
                ;;
            --secret)
                if [ -n "$2" ] && [ "${2:0:2}" != "--" ]; then
                    SECRET_TOKEN="$2"
                    shift 2
                else
                    error "--secret requires a value"
                fi
                ;;
            --name)
                if [ -n "$2" ] && [ "${2:0:2}" != "--" ]; then
                    SERVICE_NAME="$2"
                    shift 2
                else
                    shift 1
                fi
                ;;
            --ip)
                if [ -n "$2" ] && [ "${2:0:2}" != "--" ]; then
                    CUSTOM_IP="$2"
                    shift 2
                else
                    shift 1
                fi
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                shift
                ;;
            --beta)
                BETA_MODE=true
                shift
                ;;
            --smart)
                SMART_MODE=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if [ "$UNINSTALL_MODE" = true ]; then
        return
    fi

    if [ -z "$MASTER_ADDR" ] || [ -z "$SECRET_TOKEN" ]; then
        echo -e "${YELLOW}Missing parameters!${NC}"
        echo -e "Usage: ... | bash -s -- --master URL --secret TOKEN [--beta] [--smart]"
        exit 1
    fi
}

uninstall_agent() {
    step "Uninstalling Prism Agent ($SERVICE_NAME)..."

    if [ "$OS_FAMILY" = "alpine" ]; then
        rc-service "$SERVICE_NAME" stop 2>/dev/null || true
        rc-update del "$SERVICE_NAME" default 2>/dev/null || true
        rm -f "/etc/init.d/${SERVICE_NAME}"
    else
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
    fi

    rm -f "$INSTALL_DIR/$BINARY_NAME"

    info "Uninstallation completed."
    exit 0
}

detect_system() {
    ARCH=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')

    # 检测 Alpine
    if [ -f /etc/alpine-release ]; then
        OS_FAMILY="alpine"
        info "Detected Alpine Linux (OpenRC)"
    else
        OS_FAMILY="systemd"
    fi

    case "$ARCH" in
        x86_64) ARCH_SUFFIX="amd64" ;;
        aarch64|arm64) ARCH_SUFFIX="arm64" ;;
        *) error "Unsupported architecture: $ARCH" ;;
    esac

    ASSET_NAME="${BINARY_NAME}_${OS}_${ARCH_SUFFIX}"
    info "Detected: ${OS} / ${ARCH_SUFFIX}"
}

download_binary() {
    step "Fetching version info..."

    API_URL="https://api.github.com/repos/$REPO/releases"
    
    if [ "$BETA_MODE" = true ]; then
        info "Mode: ${YELLOW}Beta Channel (Pre-release)${NC}"
    else
        info "Mode: ${GREEN}Stable Channel (Official)${NC}"
    fi
    
    RESP=$(curl -s --connect-timeout 10 "$API_URL")

    if [ "$BETA_MODE" = true ]; then
        # Beta: find the beta release with largest timestamp (format: beta-YYYYMMDDHHMMSS)
        DOWNLOAD_URL=$(echo "$RESP" | awk -v asset="$ASSET_NAME" '
            BEGIN { latest_ts = ""; latest_url = "" }
            /"tag_name":/ { 
                tag = $0
                gsub(/.*"tag_name": *"|".*/, "", tag)
                current_tag = tag
            }
            /"browser_download_url":/ && index($0, asset) {
                url = $0
                gsub(/.*"browser_download_url": *"|".*/, "", url)
                if (index(current_tag, "beta-") == 1) {
                    ts = current_tag
                    gsub(/^beta-/, "", ts)
                    if (ts > latest_ts) {
                        latest_ts = ts
                        latest_url = url
                    }
                }
            }
            END { print latest_url }
        ')
        VERSION=$(echo "$DOWNLOAD_URL" | grep -oE 'beta-[0-9]+' | head -1)
    else
        # Stable: find first non-prerelease with agent asset
        DOWNLOAD_URL=$(echo "$RESP" | grep -E '"tag_name"|"prerelease"|"browser_download_url".*prism-agent' | \
            awk -v asset="$ASSET_NAME" '
                /"tag_name":/ { tag=$0; gsub(/.*"tag_name": *"|".*/, "", tag) }
                /"prerelease":/ { prerelease=$0; gsub(/.*"prerelease": *|,.*/, "", prerelease) }
                /"browser_download_url":/ && index($0, asset) { 
                    url=$0; gsub(/.*"browser_download_url": *"|".*/, "", url)
                    if (prerelease == "false") { print url; exit }
                }
            ')
        VERSION=$(echo "$DOWNLOAD_URL" | grep -oE 'v[0-9]+\.[0-9]+[^/]*' | head -1)
    fi

    if [ -z "$DOWNLOAD_URL" ]; then
        warn "Smart search failed, trying fallback..."
        DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$ASSET_NAME"
    fi

    if [ -n "$VERSION" ]; then
        info "Found agent version: ${CYAN}${VERSION}${NC}"
    fi

    info "Download URL: $DOWNLOAD_URL"
    curl -L -o "/tmp/$BINARY_NAME" "$DOWNLOAD_URL" --progress-bar

    if [ ! -f "/tmp/$BINARY_NAME" ] || [ ! -s "/tmp/$BINARY_NAME" ]; then
        error "Download failed. Please check network or GitHub access."
    fi

    chmod +x "/tmp/$BINARY_NAME"
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        info "Stopping old service..."
        systemctl stop "$SERVICE_NAME"
    fi

    mv "/tmp/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME"
}

configure_service() {
    if [ "$OS_FAMILY" = "alpine" ]; then
        configure_openrc
    else
        configure_systemd
    fi
}

configure_openrc() {
    step "Configuring OpenRC service..."

    SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"

    EXEC_ARGS="--master \"$MASTER_ADDR\" --secret \"$SECRET_TOKEN\""

    if [ "$SMART_MODE" = true ]; then
        EXEC_ARGS="$EXEC_ARGS --smart"
    fi

    if [ -n "$CUSTOM_IP" ]; then
        EXEC_ARGS="$EXEC_ARGS --ip \"$CUSTOM_IP\""
    fi

    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="$SERVICE_NAME"
description="Liquid Glass Prism Agent"

command="$INSTALL_DIR/$BINARY_NAME"
command_args='$EXEC_ARGS'
command_background=true
pidfile="/run/${SERVICE_NAME}.pid"

depend() {
    need net
}
EOF

    chmod +x "$SERVICE_FILE"

    rc-update add "$SERVICE_NAME" default
}

configure_systemd() {
    step "Configuring systemd service..."
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    EXEC_ARGS="--master \"$MASTER_ADDR\" --secret \"$SECRET_TOKEN\""
    
    if [ "$SMART_MODE" = true ]; then
        EXEC_ARGS="$EXEC_ARGS --smart"
    fi

    if [ -n "$CUSTOM_IP" ]; then
        EXEC_ARGS="$EXEC_ARGS --ip \"$CUSTOM_IP\""
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Liquid Glass Prism Agent ($SERVICE_NAME)
After=network.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5s
ExecStart=$INSTALL_DIR/$BINARY_NAME $EXEC_ARGS
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

start_service() {
    step "Starting service..."

    if [ "$OS_FAMILY" = "alpine" ]; then
        rc-service "$SERVICE_NAME" restart
    else
        systemctl restart "$SERVICE_NAME"
    fi

    sleep 3
}

show_result() {
    echo ""

    if [ "$OS_FAMILY" = "alpine" ]; then
        LOGS=$(rc-service "$SERVICE_NAME" status 2>/dev/null || true)
    else
        LOGS=$(journalctl -u "$SERVICE_NAME" -n 50 --no-pager 2>/dev/null || true)
    fi

    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   Liquid Glass Prism Agent Installed!        ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo ""

    if [ "$BETA_MODE" = true ]; then
        echo -e "  Version: ${YELLOW}Beta (Pre-release)${NC}"
    else
        echo -e "  Version: ${GREEN}Stable${NC}"
    fi

    if [ "$SMART_MODE" = true ]; then
        echo -e "  Feature: ${CYAN}Smart Mode Enabled${NC}"
    fi

    # 模式识别
    if echo "$LOGS" | grep -q "DNS Mode Started"; then
        echo -e "  Mode:    ${CYAN}DNS Client${NC} (127.0.0.1)"
    elif echo "$LOGS" | grep -q "Proxy Mode Started"; then
        echo -e "  Mode:    ${CYAN}Proxy Agent${NC} (80/443)"
    else
        echo -e "  Status:  ${YELLOW}Starting / Syncing...${NC}"
    fi

    echo ""

    # 服务状态
    if [ "$OS_FAMILY" = "alpine" ]; then
        rc-service "$SERVICE_NAME" status || true
    else
        systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1 && \
            echo -e "  Service: ${GREEN}Running${NC}" || \
            echo -e "  Service: ${RED}Not Running${NC}"
    fi

    echo ""
    echo -e "  Logs:"
    if [ "$OS_FAMILY" = "alpine" ]; then
        echo "  (Use: rc-service $SERVICE_NAME status)"
    else
        echo "  journalctl -u $SERVICE_NAME -f"
    fi

    echo ""
    echo -e "  Uninstall:"
    echo -e "  ${GREEN}curl -sL $SCRIPT_URL | bash -s -- --uninstall${NC}"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
}

show_banner() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       Liquid Glass Prism Agent Installer         ║${NC}"
    echo -e "${BLUE}║       github.com/mslxi/Liquid-Glass-Prism-dns    ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

main() {
    show_banner
    check_root
    parse_args "$@"
    
    if [ "$UNINSTALL_MODE" = true ]; then
        uninstall_agent
    fi

    detect_system
    download_binary
    configure_service
    start_service
    show_result
}

main "$@"
