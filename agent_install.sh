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
            --master) MASTER_ADDR="$2"; shift 2 ;;
            --secret) SECRET_TOKEN="$2"; shift 2 ;;
            --name) SERVICE_NAME="$2"; shift 2 ;;
            --ip) CUSTOM_IP="$2"; shift 2 ;;
            --uninstall) UNINSTALL_MODE=true; shift ;;
            --beta) BETA_MODE=true; shift ;;
            --smart) SMART_MODE=true; shift ;;
            *) shift ;;
        esac
    done

    if [ "$UNINSTALL_MODE" = true ]; then return; fi

    if [ -z "$MASTER_ADDR" ] || [ -z "$SECRET_TOKEN" ]; then
        error "Usage: ... | bash -s -- --master URL --secret TOKEN"
    fi
}

# =========================
# 系统检测（关键）
# =========================
detect_system() {
    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64) ARCH_SUFFIX="amd64" ;;
        aarch64|arm64) ARCH_SUFFIX="arm64" ;;
        *) error "Unsupported architecture: $ARCH" ;;
    esac

    if [ -f /etc/alpine-release ]; then
        OS_FAMILY="alpine"
        info "Detected Alpine Linux (OpenRC)"
    else
        OS_FAMILY="systemd"
        info "Detected systemd-based Linux"
    fi

    ASSET_NAME="${BINARY_NAME}_linux_${ARCH_SUFFIX}"
}

# =========================
# 下载程序
# =========================
download_binary() {
    step "Downloading binary..."

    URL="https://github.com/$REPO/releases/latest/download/$ASSET_NAME"

    curl -L -o "/tmp/$BINARY_NAME" "$URL" --progress-bar

    if [ ! -s "/tmp/$BINARY_NAME" ]; then
        error "Download failed"
    fi

    chmod +x "/tmp/$BINARY_NAME"
    mv "/tmp/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME"

    # Alpine musl 提示
    if [ "$OS_FAMILY" = "alpine" ]; then
        if ! ldd "$INSTALL_DIR/$BINARY_NAME" 2>&1 | grep -q musl; then
            warn "Binary may not support musl (Alpine)"
            warn "Try: apk add gcompat"
        fi
    fi
}

# =========================
# systemd 服务
# =========================
configure_systemd() {
    step "Configuring systemd..."

    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Prism Agent
After=network.target

[Service]
ExecStart=$INSTALL_DIR/$BINARY_NAME --master "$MASTER_ADDR" --secret "$SECRET_TOKEN"
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
}

# =========================
# OpenRC 服务（Alpine）
# =========================
configure_openrc() {
    step "Configuring OpenRC..."

    SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"

    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="$SERVICE_NAME"
command="$INSTALL_DIR/$BINARY_NAME"
command_args="--master '$MASTER_ADDR' --secret '$SECRET_TOKEN'"
command_background=true
pidfile="/run/${SERVICE_NAME}.pid"

depend() {
    need net
}
EOF

    chmod +x "$SERVICE_FILE"
    rc-update add "$SERVICE_NAME" default
}

configure_service() {
    if [ "$OS_FAMILY" = "alpine" ]; then
        configure_openrc
    else
        configure_systemd
    fi
}

# =========================
# 启动服务
# =========================
start_service() {
    step "Starting service..."

    if [ "$OS_FAMILY" = "alpine" ]; then
        rc-service "$SERVICE_NAME" restart
    else
        systemctl restart "$SERVICE_NAME"
    fi

    sleep 2
}

# =========================
# 卸载
# =========================
uninstall_agent() {
    step "Uninstalling..."

    if [ -f /etc/alpine-release ]; then
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

    info "Uninstalled."
    exit 0
}

# =========================
# 结果展示
# =========================
show_result() {
    echo ""
    echo -e "${GREEN}==== Install Complete ==== ${NC}"

    if [ "$OS_FAMILY" = "alpine" ]; then
        rc-service "$SERVICE_NAME" status || true
    else
        systemctl status "$SERVICE_NAME" --no-pager || true
    fi

    echo ""
    echo "Uninstall:"
    echo "curl -sL $SCRIPT_URL | bash -s -- --uninstall"
}

# =========================
# 主流程
# =========================
main() {
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
