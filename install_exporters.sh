#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# install_exporters.sh
# - Install & run node_exporter (9100) and blackbox_exporter (9115)
# - Lock down ports 9100/9115: ONLY allow PANEL_IP, otherwise DROP
# - iptables rules are always inserted to the top
# - If rules already exist: remove duplicates and re-insert at top (re-pin)
# - Do NOT touch other existing rules
# - Persist rules via netfilter-persistent if available
# ============================================================

# ---------------------------
# Config
# ---------------------------
NODE_EXPORTER_VER="${NODE_EXPORTER_VER:-}"         # e.g. "1.10.2" or empty for latest
BLACKBOX_EXPORTER_VER="${BLACKBOX_EXPORTER_VER:-}" # e.g. "0.28.0" or empty for latest
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
TMP_DIR="/tmp/exporters_install_$$"

PORT_NODE="9100"
PORT_BLACKBOX="9115"

# ---------------------------
# Helpers
# ---------------------------
log_ok()   { echo -e "[OK] $*"; }
log_warn() { echo -e "[WARN] $*"; }
log_err()  { echo -e "[ERR] $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log_err "Missing command: $1"; exit 1; }
}

cleanup() {
  rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------
# Detect arch
# ---------------------------
detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) log_err "Unsupported arch: $arch"; exit 1 ;;
  esac
}

# ---------------------------
# Fetch latest release tag from GitHub (no jq required)
# ---------------------------
github_latest_tag() {
  local repo="$1" # "prometheus/node_exporter"
  # GitHub API returns: "tag_name": "vX.Y.Z"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | sed -n 's/.*"tag_name":[[:space:]]*"\(v[^"]*\)".*/\1/p' \
    | head -n1
}

# ---------------------------
# Download + install node_exporter
# ---------------------------
install_node_exporter() {
  local arch tag ver url tarball
  arch="$(detect_arch)"

  if [[ -n "$NODE_EXPORTER_VER" ]]; then
    ver="$NODE_EXPORTER_VER"
    tag="v${ver}"
  else
    tag="$(github_latest_tag "prometheus/node_exporter")"
    ver="${tag#v}"
  fi

  log_ok "Node Exporter 最新版本: ${tag}"

  mkdir -p "$TMP_DIR"
  tarball="${TMP_DIR}/node_exporter.tar.gz"
  url="https://github.com/prometheus/node_exporter/releases/download/${tag}/node_exporter-${ver}.linux-${arch}.tar.gz"

  curl -fsSL "$url" -o "$tarball"
  tar -xzf "$tarball" -C "$TMP_DIR"

  install -m 0755 "${TMP_DIR}/node_exporter-${ver}.linux-${arch}/node_exporter" "${INSTALL_DIR}/node_exporter"

  # systemd unit
  cat > "${SYSTEMD_DIR}/node_exporter.service" <<EOF
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/node_exporter
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now node_exporter.service
  log_ok "node_exporter 安装并启动成功（${PORT_NODE}）"
}

# ---------------------------
# Download + install blackbox_exporter
# ---------------------------
install_blackbox_exporter() {
  local arch tag ver url tarball
  arch="$(detect_arch)"

  if [[ -n "$BLACKBOX_EXPORTER_VER" ]]; then
    ver="$BLACKBOX_EXPORTER_VER"
    tag="v${ver}"
  else
    tag="$(github_latest_tag "prometheus/blackbox_exporter")"
    ver="${tag#v}"
  fi

  log_ok "Blackbox Exporter 最新版本: ${tag}"

  mkdir -p "$TMP_DIR"
  tarball="${TMP_DIR}/blackbox_exporter.tar.gz"
  url="https://github.com/prometheus/blackbox_exporter/releases/download/${tag}/blackbox_exporter-${ver}.linux-${arch}.tar.gz"

  curl -fsSL "$url" -o "$tarball"
  tar -xzf "$tarball" -C "$TMP_DIR"

  install -m 0755 "${TMP_DIR}/blackbox_exporter-${ver}.linux-${arch}/blackbox_exporter" "${INSTALL_DIR}/blackbox_exporter"

  # config (enable tcp_connect)
  mkdir -p /etc/blackbox_exporter
  cat > /etc/blackbox_exporter/blackbox.yml <<'EOF'
modules:
  tcp_connect:
    prober: tcp
    timeout: 5s
EOF

  # systemd unit
  cat > "${SYSTEMD_DIR}/blackbox-exporter.service" <<EOF
[Unit]
Description=Prometheus Blackbox Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/blackbox_exporter --config.file=/etc/blackbox_exporter/blackbox.yml --web.listen-address=:${PORT_BLACKBOX}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now blackbox-exporter.service
  log_ok "blackbox_exporter 安装并启动成功（${PORT_BLACKBOX}，tcp_connect 已开启）"
}

# ---------------------------
# Firewall: iptables rule management
# Requirements:
# - new rules auto pinned to top
# - if exists -> re-pin to top
# - do not modify other existing rules
# - 9100/9115 allowlist-only (others DROP)
# ---------------------------
iptables_delete_all() {
  local chain="$1"; shift
  # Delete all occurrences of the exact rule
  while iptables -C "$chain" "$@" 2>/dev/null; do
    iptables -D "$chain" "$@" 2>/dev/null || break
  done
}

ensure_rule_at_top() {
  local chain="$1"; shift
  iptables_delete_all "$chain" "$@"
  iptables -I "$chain" 1 "$@"
}

ensure_rule_at_pos() {
  local chain="$1"; local pos="$2"; shift 2
  iptables_delete_all "$chain" "$@"
  iptables -I "$chain" "$pos" "$@"
}

setup_firewall_lockdown() {
  local panel_ip="$1"
  local ports=("$PORT_NODE" "$PORT_BLACKBOX")

  if ! command -v iptables >/dev/null 2>&1; then
    log_warn "未检测到 iptables，跳过防火墙规则"
    return 0
  fi

  # Basic safety rules at top (do not change others, only ensure these exist and are pinned)
  # 1) established/related
  ensure_rule_at_top INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  # 2) loopback
  ensure_rule_at_top INPUT -i lo -j ACCEPT

  # Allow PANEL_IP to ports (pin to top). Insert each at top so the last inserted ends up at very top.
  # We'll do 9115 first then 9100 so that 9100 ends up higher (since it is "more important").
  ensure_rule_at_top INPUT -p tcp -s "${panel_ip}/32" --dport "$PORT_BLACKBOX" -j ACCEPT
  log_ok "已置顶允许：${panel_ip} -> ${PORT_BLACKBOX}"

  ensure_rule_at_top INPUT -p tcp -s "${panel_ip}/32" --dport "$PORT_NODE" -j ACCEPT
  log_ok "已置顶允许：${panel_ip} -> ${PORT_NODE}"

  # Now enforce deny-all for those ports (DROP must be AFTER allow rules)
  # We will place DROP right after the top block we just pinned:
  # Current top order is:
  #   1) allow 9100
  #   2) allow 9115
  #   3) lo
  #   4) established
  # So we put DROP at position 5 and 6, which is still near-top but below allows.
  ensure_rule_at_pos INPUT 5 -p tcp --dport "$PORT_NODE" -j DROP
  log_ok "已强化限制：非允许 IP 访问 ${PORT_NODE} -> DROP"

  ensure_rule_at_pos INPUT 6 -p tcp --dport "$PORT_BLACKBOX" -j DROP
  log_ok "已强化限制：非允许 IP 访问 ${PORT_BLACKBOX} -> DROP"

  # Persist rules if netfilter-persistent exists
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
    netfilter-persistent reload >/dev/null 2>&1 || true
    log_ok "已保存并重载 netfilter-persistent"
  else
    log_warn "未检测到 netfilter-persistent（可选安装：iptables-persistent / netfilter-persistent），规则不会自动持久化"
  fi
}

# ---------------------------
# Checks
# ---------------------------
final_checks() {
  # Show listen
  log_ok "最终检查：端口监听"
  ss -lntp | grep -E ":(9100|9115)\b" || true

  # Show top of INPUT rules
  if command -v iptables >/dev/null 2>&1; then
    echo
    echo "==== iptables INPUT 前 20 条（含行号）===="
    iptables -L INPUT -n --line-numbers | sed -n '1,22p'
    echo "========================================="
  fi

  if [[ -f /etc/iptables/rules.v4 ]]; then
    echo
    echo "==== /etc/iptables/rules.v4（节选）===="
    sed -n '1,80p' /etc/iptables/rules.v4 || true
    echo "======================================="
  fi
}

# ---------------------------
# Main
# ---------------------------
main() {
  need_cmd curl
  need_cmd tar
  need_cmd systemctl
  need_cmd ss

  mkdir -p "$TMP_DIR"

  install_node_exporter
  install_blackbox_exporter

  # Ask panel IP
  echo -n "请输入面板服务器 IP（仅允许该 IP 访问 9100/9115）: "
  read -r PANEL_IP

  # Basic IP format check (simple)
  if ! echo "$PANEL_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    log_err "IP 格式看起来不对：$PANEL_IP"
    exit 1
  fi

  setup_firewall_lockdown "$PANEL_IP"
  final_checks

  log_ok "全部成功 ✅"
}

main "$@"
