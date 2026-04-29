#!/usr/bin/env bash
set -euo pipefail

APP_NAME="nako-agent-factory"
INSTALL_DIR="${NAKO_INSTALL_DIR:-/opt/${APP_NAME}}"
SERVER_FILE="${INSTALL_DIR}/nako-server.py"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
PORT="${NAKO_SERVER_PORT:-8088}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
GATEWAY_HEAP_MB="${OPENCLAW_GATEWAY_HEAP_MB:-2048}"
WATCHDOG_INTERVAL="${NAKO_GATEWAY_WATCHDOG_INTERVAL:-10}"
TRUSTED_PROXY_CIDRS="${NAKO_TRUSTED_PROXY_CIDRS:-127.0.0.0/8,::1/128,172.16.0.0/12}"
INSTALL_URL="${NAKO_AGENT_INSTALL_URL:-https://raw.githubusercontent.com/Lovappen/Agents/main/install.sh}"
FACTORY_BASE_URL="${NAKO_FACTORY_BASE_URL:-https://raw.githubusercontent.com/Lovappen/Agents/main/scripts/nako-agent-factory}"
PREINSTALL="${NAKO_PREINSTALL_OPENCLAW:-0}"
BOOTSTRAP_AGENT_ID="${NAKO_BOOTSTRAP_AGENT_ID:-agent-nako-bootstrap}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo bash install.sh" >&2
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_base_packages() {
  local missing=()
  for cmd in bash curl python3; do
    if ! need_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return
  fi

  if need_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl python3 bash
  elif need_cmd dnf; then
    dnf install -y ca-certificates curl python3 bash
  elif need_cmd yum; then
    yum install -y ca-certificates curl python3 bash
  elif need_cmd apk; then
    apk add --no-cache ca-certificates curl python3 bash
  else
    echo "Missing commands: ${missing[*]}; install them first." >&2
    exit 1
  fi
}

install_base_packages

TMP_DIR=""
cleanup() {
  [ -n "${TMP_DIR}" ] && rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"
SERVER_SRC="${SCRIPT_DIR}/nako-server.py"
if [ ! -f "${SERVER_SRC}" ]; then
  TMP_DIR="$(mktemp -d)"
  SERVER_SRC="${TMP_DIR}/nako-server.py"
  echo "Downloading nako-server.py from ${FACTORY_BASE_URL}/nako-server.py"
  curl -fsSL "${FACTORY_BASE_URL}/nako-server.py" -o "${SERVER_SRC}"
fi

mkdir -p "${INSTALL_DIR}" /root/.cc-connect /root/.nako-jobs /tmp/openclaw /var/tmp/openclaw-compile-cache
install -m 0755 "${SERVER_SRC}" "${SERVER_FILE}"

if [ ! -f /root/.cc-connect/config.toml ]; then
  cat > /root/.cc-connect/config.toml <<'EOF'
[log]
level = "info"
EOF
  chmod 0600 /root/.cc-connect/config.toml
fi

if [ "${PREINSTALL}" = "1" ]; then
  echo "Preinstalling OpenClaw and cc-connect with ${INSTALL_URL}"
  curl -fsSL "${INSTALL_URL}" | bash -s -- \
    --agent-id "${BOOTSTRAP_AGENT_ID}" \
    --non-interactive \
    --force \
    --with-cc-connect
fi

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Nako Agent Factory
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment=HOME=/root
Environment=NAKO_SERVER_PORT=${PORT}
Environment=OPENCLAW_GATEWAY_PORT=${GATEWAY_PORT}
Environment=OPENCLAW_GATEWAY_HEAP_MB=${GATEWAY_HEAP_MB}
Environment=NAKO_GATEWAY_WATCHDOG_INTERVAL=${WATCHDOG_INTERVAL}
Environment=NAKO_TRUSTED_PROXY_CIDRS=${TRUSTED_PROXY_CIDRS}
ExecStart=/usr/bin/env python3 ${SERVER_FILE}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${APP_NAME}.service"

echo
echo "Installed ${APP_NAME}"
echo "Service: systemctl status ${APP_NAME}.service"
echo "Logs:    journalctl -u ${APP_NAME}.service -f"
echo "URL:     http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT}/"
echo
echo "Note: first agent creation runs:"
echo "  curl -fsSL ${INSTALL_URL} | bash -s -- --agent-id agent-nako-N --non-interactive --force --with-cc-connect"
