#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# JJ Monitoring Stack Installer
# Prometheus + Node Exporter + Blackbox Exporter + Grafana + (Optional) iptables lock
# Debian/Ubuntu (apt)
# =========================

export DEBIAN_FRONTEND=noninteractive

# ---------- Pretty output ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; NC="\033[0m"
log()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

on_error() {
  local exit_code=$?
  fail "安装过程中发生错误（exit=$exit_code）。"
  fail "出错位置：第 ${BASH_LINENO[0]} 行；命令：${BASH_COMMAND}"
  fail "你可以把上面三行复制给我，我帮你定位原因。"
  exit $exit_code
}
trap on_error ERR

# ---------- Must be root ----------
if [[ "${EUID}" -ne 0 ]]; then
  fail "请用 root 运行："
  echo "  su -"
  echo "  ./grafana_install.sh"
  exit 1
fi

# ---------- Config ----------
ARCH="$(uname -m)"
OS_ID="$(. /etc/os-release && echo "${ID:-unknown}")"
OS_VER="$(. /etc/os-release && echo "${VERSION_ID:-unknown}")"

SETUP_FIREWALL="${SETUP_FIREWALL:-1}"     # 1=apply iptables rules, 0=skip
FIREWALL_FLUSH="${FIREWALL_FLUSH:-0}"     # 1=flush old rules (DANGEROUS), 0=do not flush
PROM_USER="prometheus"
INSTALL_DIR="/usr/local/bin"
ETC_DIR="/etc"
DATA_DIR="/var/lib/prometheus"

PROM_PORT=9090
NODE_PORT=9100
BB_PORT=9115
GRAF_PORT=3000

TMP_BASE="/tmp/monitoring-stack.$$"
cleanup() { rm -rf "$TMP_BASE" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# ---------- Helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

apt_install_if_missing() {
  local pkgs=("$@")
  local to_install=()
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || to_install+=("$p")
  done
  if (( ${#to_install[@]} > 0 )); then
    log "安装依赖：${to_install[*]}"
    apt-get update -y
    apt-get install -y --no-install-recommends "${to_install[@]}"
    ok "依赖安装完成：${to_install[*]}"
  else
    ok "依赖已满足：${pkgs[*]}"
  fi
}

curl_get() {
  # $1=url
  curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 "$1"
}

github_latest_tag_api() {
  # $1 = owner/repo
  # may fail due to rate limit; return empty if failed
  curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name":' \
    | sed -E 's/.*"([^"]+)".*/\1/' || true
}

github_latest_tag_fallback() {
  # Fallback: parse releases "latest" redirect page
  # $1 = owner/repo
  # Extract vX.Y.Z from HTML
  curl -fsSL --connect-timeout 10 --max-time 30 "https://github.com/$1/releases/latest" 2>/dev/null \
    | grep -Eo 'tag/v[0-9]+\.[0-9]+\.[0-9]+' \
    | head -n1 \
    | sed 's/tag\///' || true
}

github_latest_tag() {
  local repo="$1"
  local tag=""
  tag="$(github_latest_tag_api "$repo")"
  if [[ -n "$tag" ]]; then
    echo "$tag"
    return 0
  fi
  warn "GitHub API 获取 $repo 最新版本失败，尝试 fallback（解析 releases 页面）"
  tag="$(github_latest_tag_fallback "$repo")"
  echo "$tag"
}

download_and_extract_tar_gz() {
  # $1=url
  local url="$1"
  mkdir -p "$TMP_BASE"
  log "下载：$url"
  curl -fL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 "$url" -o "$TMP_BASE/pkg.tar.gz"
  tar -xzf "$TMP_BASE/pkg.tar.gz" -C "$TMP_BASE"
  echo "$TMP_BASE"
}

ensure_user() {
  if id "$1" >/dev/null 2>&1; then
    ok "用户已存在：$1"
  else
    log "创建系统用户：$1"
    useradd --system --no-create-home --shell /usr/sbin/nologin "$1"
    ok "用户创建完成：$1"
  fi
}

systemd_reload_enable_start() {
  local svc="$1"
  systemctl daemon-reload
  systemctl enable --now "$svc"
}

svc_is_active() {
  local svc="$1"
  systemctl is-active --quiet "$svc"
}

port_listening() {
  local port="$1"
  ss -ltn 2>/dev/null | grep -q ":${port} "
}

http_ok() {
  local url="$1"
  curl -fsS --max-time 5 "$url" >/dev/null 2>&1
}

show_journal_hint() {
  local svc="$1"
  echo "  journalctl -u $svc --no-pager -n 200"
}

# ---------- Pre-flight ----------
log "系统信息：OS=${OS_ID} ${OS_VER} | ARCH=${ARCH}"

# iproute2 provides ss; conntrack improves iptables match reliability; systemd required for systemctl
apt_install_if_missing ca-certificates curl wget tar gzip gnupg lsb-release apt-transport-https software-properties-common iproute2 conntrack

# =========================
# 1) Install Prometheus
# =========================
install_prometheus() {
  log "开始安装 Prometheus（自动取 GitHub 最新版本）"

  ensure_user "$PROM_USER"
  mkdir -p "$DATA_DIR" "$ETC_DIR/prometheus" "$ETC_DIR/prometheus/rules"
  chown -R "$PROM_USER:$PROM_USER" "$DATA_DIR" "$ETC_DIR/prometheus"

  local tag
  tag="$(github_latest_tag "prometheus/prometheus")"
  if [[ -z "$tag" ]]; then
    fail "无法获取 Prometheus 最新版本（GitHub API / fallback 都失败）。"
    exit 1
  fi
  local ver="${tag#v}"

  local pkg_arch=""
  case "$ARCH" in
    x86_64) pkg_arch="linux-amd64" ;;
    aarch64|arm64) pkg_arch="linux-arm64" ;;
    armv7l) pkg_arch="linux-armv7" ;;
    *) fail "不支持的架构：$ARCH"; exit 1 ;;
  esac

  local url="https://github.com/prometheus/prometheus/releases/download/${tag}/prometheus-${ver}.${pkg_arch}.tar.gz"
  local tmpdir
  tmpdir="$(download_and_extract_tar_gz "$url")"

  local extracted
  extracted="$(find "$tmpdir" -maxdepth 1 -type d -name "prometheus-*" | head -n1)"
  if [[ -z "$extracted" ]]; then
    fail "Prometheus 解压目录未找到"
    exit 1
  fi

  install -m 0755 "$extracted/prometheus" "$INSTALL_DIR/prometheus"
  install -m 0755 "$extracted/promtool"   "$INSTALL_DIR/promtool"
  cp -r "$extracted/consoles" "$ETC_DIR/prometheus/" || true
  cp -r "$extracted/console_libraries" "$ETC_DIR/prometheus/" || true

  cat > "$ETC_DIR/prometheus/prometheus.yml" <<'YAML'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["127.0.0.1:9090"]

  - job_name: "node_exporter"
    static_configs:
      - targets: ["127.0.0.1:9100"]

  - job_name: "blackbox"
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - https://www.google.com
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115
YAML

  chown -R "$PROM_USER:$PROM_USER" "$ETC_DIR/prometheus"

  cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=${PROM_USER}
Group=${PROM_USER}
Type=simple
ExecStart=${INSTALL_DIR}/prometheus \\
  --config.file=${ETC_DIR}/prometheus/prometheus.yml \\
  --storage.tsdb.path=${DATA_DIR} \\
  --web.listen-address=127.0.0.1:${PROM_PORT} \\
  --web.console.templates=${ETC_DIR}/prometheus/consoles \\
  --web.console.libraries=${ETC_DIR}/prometheus/console_libraries
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemd_reload_enable_start prometheus.service

  if svc_is_active prometheus.service; then
    ok "Prometheus 服务已启动"
  else
    fail "Prometheus 服务未启动，请查看："
    show_journal_hint prometheus
    exit 1
  fi
}

# =========================
# 2) Install Node Exporter
# =========================
install_node_exporter() {
  log "开始安装 Node Exporter（自动取 GitHub 最新版本）"

  local tag
  tag="$(github_latest_tag "prometheus/node_exporter")"
  if [[ -z "$tag" ]]; then
    fail "无法获取 Node Exporter 最新版本（GitHub API / fallback 都失败）。"
    exit 1
  fi
  local ver="${tag#v}"

  local pkg_arch=""
  case "$ARCH" in
    x86_64) pkg_arch="linux-amd64" ;;
    aarch64|arm64) pkg_arch="linux-arm64" ;;
    armv7l) pkg_arch="linux-armv7" ;;
    *) fail "不支持的架构：$ARCH"; exit 1 ;;
  esac

  local url="https://github.com/prometheus/node_exporter/releases/download/${tag}/node_exporter-${ver}.${pkg_arch}.tar.gz"
  local tmpdir
  tmpdir="$(download_and_extract_tar_gz "$url")"

  local extracted
  extracted="$(find "$tmpdir" -maxdepth 1 -type d -name "node_exporter-*" | head -n1)"
  if [[ -z "$extracted" ]]; then
    fail "Node Exporter 解压目录未找到"
    exit 1
  fi

  install -m 0755 "$extracted/node_exporter" "$INSTALL_DIR/node_exporter"

  cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=nobody
Group=nogroup
Type=simple
ExecStart=${INSTALL_DIR}/node_exporter --web.listen-address=127.0.0.1:${NODE_PORT}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemd_reload_enable_start node_exporter.service

  if svc_is_active node_exporter.service; then
    ok "Node Exporter 服务已启动"
  else
    fail "Node Exporter 服务未启动，请查看："
    show_journal_hint node_exporter
    exit 1
  fi
}

# =========================
# 3) Install Blackbox Exporter
# =========================
install_blackbox_exporter() {
  log "开始安装 Blackbox Exporter（自动取 GitHub 最新版本）"

  local tag
  tag="$(github_latest_tag "prometheus/blackbox_exporter")"
  if [[ -z "$tag" ]]; then
    fail "无法获取 Blackbox Exporter 最新版本（GitHub API / fallback 都失败）。"
    exit 1
  fi
  local ver="${tag#v}"

  local pkg_arch=""
  case "$ARCH" in
    x86_64) pkg_arch="linux-amd64" ;;
    aarch64|arm64) pkg_arch="linux-arm64" ;;
    armv7l) pkg_arch="linux-armv7" ;;
    *) fail "不支持的架构：$ARCH"; exit 1 ;;
  esac

  local url="https://github.com/prometheus/blackbox_exporter/releases/download/${tag}/blackbox_exporter-${ver}.${pkg_arch}.tar.gz"
  local tmpdir
  tmpdir="$(download_and_extract_tar_gz "$url")"

  local extracted
  extracted="$(find "$tmpdir" -maxdepth 1 -type d -name "blackbox_exporter-*" | head -n1)"
  if [[ -z "$extracted" ]]; then
    fail "Blackbox Exporter 解压目录未找到"
    exit 1
  fi

  install -m 0755 "$extracted/blackbox_exporter" "$INSTALL_DIR/blackbox_exporter"
  mkdir -p "$ETC_DIR/blackbox_exporter"

  cat > "$ETC_DIR/blackbox_exporter/blackbox.yml" <<'YAML'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      method: GET
      preferred_ip_protocol: "ip4"
  tcp_connect:
    prober: tcp
    timeout: 5s
YAML

  cat > /etc/systemd/system/blackbox_exporter.service <<EOF
[Unit]
Description=Prometheus Blackbox Exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/blackbox_exporter \\
  --config.file=${ETC_DIR}/blackbox_exporter/blackbox.yml \\
  --web.listen-address=127.0.0.1:${BB_PORT}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemd_reload_enable_start blackbox_exporter.service

  if svc_is_active blackbox_exporter.service; then
    ok "Blackbox Exporter 服务已启动"
  else
    fail "Blackbox Exporter 服务未启动，请查看："
    show_journal_hint blackbox_exporter
    exit 1
  fi
}

# =========================
# 4) Install Grafana (apt repo)
# =========================
install_grafana() {
  log "开始安装 Grafana（官方 APT 仓库）"

  mkdir -p /usr/share/keyrings

  if [[ ! -f /usr/share/keyrings/grafana.key ]]; then
    log "写入 Grafana keyring"
    wget -q -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key
  else
    ok "Grafana keyring 已存在"
  fi

  if [[ ! -f /etc/apt/sources.list.d/grafana.list ]]; then
    log "添加 Grafana apt 源"
    echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
  else
    ok "Grafana apt 源已存在"
  fi

  apt-get update -y
  apt-get install -y grafana

  systemd_reload_enable_start grafana-server.service

  if svc_is_active grafana-server.service; then
    ok "Grafana 服务已启动"
  else
    fail "Grafana 服务未启动，请查看："
    show_journal_hint grafana-server
    exit 1
  fi
}

# =========================
# 5) Optional firewall lock (iptables)
# =========================
apply_firewall_lock() {
  if [[ "$SETUP_FIREWALL" != "1" ]]; then
    warn "已跳过防火墙设置（SETUP_FIREWALL=$SETUP_FIREWALL）"
    return 0
  fi

  log "开始配置 iptables：锁定 Prometheus/Grafana/Exporter 端口只允许 127.0.0.1"
  warn "提示：默认不会清空旧规则（更安全）。如需清空旧规则请加：FIREWALL_FLUSH=1"

  apt_install_if_missing iptables iptables-persistent conntrack

  local backup="/root/iptables-backup-$(date +%Y%m%d-%H%M%S).rules"
  iptables-save > "$backup"
  ok "已备份当前规则：$backup"

  if [[ "$FIREWALL_FLUSH" == "1" ]]; then
    warn "你启用了 FIREWALL_FLUSH=1：将清空现有 iptables 规则（有 SSH 断连风险）"
    iptables -F
    iptables -X
  fi

  # 基础放行（若已存在，重复加不会报错但会多条；你也可以按需自己精简）
  iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i lo -j ACCEPT
  iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I INPUT 2 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -p tcp --dport 22 -j ACCEPT

  # 锁端口：先允许本机，再 DROP 外部（用 -I 提升优先级）
  iptables -C INPUT -p tcp -s 127.0.0.1 --dport "${PROM_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s 127.0.0.1 --dport "${PROM_PORT}" -j ACCEPT
  iptables -C INPUT -p tcp --dport "${PROM_PORT}" -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport "${PROM_PORT}" -j DROP

  iptables -C INPUT -p tcp -s 127.0.0.1 --dport "${GRAF_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s 127.0.0.1 --dport "${GRAF_PORT}" -j ACCEPT
  iptables -C INPUT -p tcp --dport "${GRAF_PORT}" -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport "${GRAF_PORT}" -j DROP

  iptables -C INPUT -p tcp -s 127.0.0.1 --dport "${NODE_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s 127.0.0.1 --dport "${NODE_PORT}" -j ACCEPT
  iptables -C INPUT -p tcp --dport "${NODE_PORT}" -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport "${NODE_PORT}" -j DROP

  iptables -C INPUT -p tcp -s 127.0.0.1 --dport "${BB_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s 127.0.0.1 --dport "${BB_PORT}" -j ACCEPT
  iptables -C INPUT -p tcp --dport "${BB_PORT}" -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport "${BB_PORT}" -j DROP

  # 持久化
  iptables-save > /etc/iptables/rules.v4
  ok "iptables 规则已保存到 /etc/iptables/rules.v4（iptables-persistent）"

  echo "==============================="
  echo "🔥 已锁定 Prometheus / Grafana / node_exporter / blackbox_exporter"
  echo "🔥 只有本机 (127.0.0.1) 可访问"
  echo "📝 备份保存于：$backup"
  echo "==============================="
}

# =========================
# Final checks
# =========================
final_checks() {
  log "开始最终检查（服务/端口/HTTP）"

  local all_ok=1

  for svc in prometheus.service node_exporter.service blackbox_exporter.service grafana-server.service; do
    if svc_is_active "$svc"; then
      ok "服务运行中：$svc"
    else
      fail "服务未运行：$svc"
      show_journal_hint "${svc%.service}"
      all_ok=0
    fi
  done

  for p in "$PROM_PORT" "$NODE_PORT" "$BB_PORT" "$GRAF_PORT"; do
    if port_listening "$p"; then
      ok "端口监听正常：$p（本机）"
    else
      fail "端口未监听：$p（可能服务未起来或监听地址不同）"
      all_ok=0
    fi
  done

  if http_ok "http://127.0.0.1:${PROM_PORT}/-/ready"; then ok "Prometheus ready ✅"; else fail "Prometheus ready 失败"; all_ok=0; fi
  if http_ok "http://127.0.0.1:${NODE_PORT}/metrics"; then ok "Node Exporter metrics ✅"; else fail "Node Exporter metrics 失败"; all_ok=0; fi
  if http_ok "http://127.0.0.1:${BB_PORT}/metrics"; then ok "Blackbox metrics ✅"; else fail "Blackbox metrics 失败"; all_ok=0; fi
  if http_ok "http://127.0.0.1:${GRAF_PORT}/api/health"; then ok "Grafana health ✅"; else warn "Grafana health 检查失败（可能刚启动还没就绪，等 10 秒再试）"; fi

  echo
  echo "=========================================="
  if [[ "$all_ok" -eq 1 ]]; then
    echo -e "${GREEN}🎉 全部安装与检查完成：OK${NC}"
  else
    echo -e "${RED}⚠️ 安装完成但存在检查失败项，请按上面 FAIL 提示排查${NC}"
  fi

  echo "Prometheus:  http://127.0.0.1:${PROM_PORT}"
  echo "Grafana:     http://127.0.0.1:${GRAF_PORT}"
  echo "NodeExp:     http://127.0.0.1:${NODE_PORT}/metrics"
  echo "Blackbox:    http://127.0.0.1:${BB_PORT}/metrics"
  if [[ "$SETUP_FIREWALL" == "1" ]]; then
    echo "防火墙：已锁端口（外网无法访问 3000/9090/9100/9115，如需外网访问请跳过防火墙或自行放行/反代）"
  fi
  echo "=========================================="
}

main() {
  log "===== 开始安装监控栈 ====="
  install_prometheus
  install_node_exporter
  install_blackbox_exporter
  install_grafana
  apply_firewall_lock
  final_checks
}

main "$@"
