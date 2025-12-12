#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; NC="\033[0m"
log()  { echo -e "${BLUE}[*]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[OK]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; }

on_error() {
  local exit_code=$?
  fail "安装过程中发生错误（exit=$exit_code）。"
  fail "出错位置：第 ${BASH_LINENO[0]} 行；命令：${BASH_COMMAND}"
  echo >&2
  fail "排查建议："
  echo "  ps aux | egrep 'apt|dpkg|unattended|apt.systemd.daily' | egrep -v egrep" >&2
  echo "  tail -n 200 /var/log/apt/term.log" >&2
  echo "  tail -n 200 /var/log/dpkg.log" >&2
  echo "  apt-cache policy grafana grafana-enterprise | sed -n '1,200p'" >&2
  exit $exit_code
}
trap on_error ERR

if [[ "${EUID}" -ne 0 ]]; then
  fail "请用 root 运行："
  echo "  su -" >&2
  echo "  ./install.sh" >&2
  exit 1
fi

ARCH="$(uname -m)"
OS_ID="$(. /etc/os-release && echo "${ID:-unknown}")"
OS_VER="$(. /etc/os-release && echo "${VERSION_ID:-unknown}")"

SETUP_FIREWALL="${SETUP_FIREWALL:-1}"
FIREWALL_FLUSH="${FIREWALL_FLUSH:-0}"
ALLOW_GRAFANA_PUBLIC="${ALLOW_GRAFANA_PUBLIC:-1}"

APT_LOCK_WAIT_SECS="${APT_LOCK_WAIT_SECS:-600}"
APT_LOCK_POLL_SECS="${APT_LOCK_POLL_SECS:-5}"

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

# ---------------- Lock guard ----------------
lock_holders() {
  local pids=()
  for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock; do
    if [[ -e "$f" ]]; then
      while read -r pid; do
        [[ -n "$pid" ]] && pids+=("$pid")
      done < <(fuser "$f" 2>/dev/null || true)
    fi
  done
  printf "%s\n" "${pids[@]}" | awk 'NF{a[$1]=1} END{for (k in a) print k}'
}

print_lock_diag() {
  local pid="$1"
  warn "检测到 apt/dpkg 锁被占用：PID=$pid"
  ps -p "$pid" -o pid,ppid,etime,cmd 2>/dev/null >&2 || true
  warn "常见原因：apt-daily / unattended-upgrades 正在后台更新。"
  warn "你可以暂停："
  echo "  systemctl stop apt-daily.service apt-daily.timer || true" >&2
  echo "  systemctl stop apt-daily-upgrade.service apt-daily-upgrade.timer || true" >&2
  echo "  systemctl stop unattended-upgrades.service || true" >&2
}

wait_for_apt_locks() {
  local waited=0
  while true; do
    local pids
    pids="$(lock_holders || true)"
    if [[ -z "$pids" ]]; then
      ok "未检测到 apt/dpkg 锁占用，继续执行。"
      return 0
    fi

    while read -r pid; do
      [[ -n "$pid" ]] && print_lock_diag "$pid"
    done <<< "$pids"

    if (( waited >= APT_LOCK_WAIT_SECS )); then
      fail "等待 apt/dpkg 锁释放超时（已等 ${waited}s）。"
      return 1
    fi

    warn "自动等待锁释放：${APT_LOCK_POLL_SECS}s 后重试（${waited}/${APT_LOCK_WAIT_SECS}s）..."
    sleep "$APT_LOCK_POLL_SECS"
    waited=$((waited + APT_LOCK_POLL_SECS))
  done
}

# ---------------- APT helpers ----------------
apt_updated=0

apt_prepare() {
  wait_for_apt_locks
  if dpkg --audit >/dev/null 2>&1; then
    warn "检测到 dpkg 状态异常，尝试执行：dpkg --configure -a"
    dpkg --configure -a || true
  fi
  wait_for_apt_locks
  apt-get -y -f install >/dev/null 2>&1 || true
  wait_for_apt_locks
}

apt_update_once() {
  wait_for_apt_locks
  if [[ "$apt_updated" -eq 0 ]]; then
    log "apt-get update（仅执行一次）"
    apt-get update -y
    apt_updated=1
  fi
}

apt_install_if_missing() {
  local pkgs=("$@")
  local to_install=()
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || to_install+=("$p")
  done
  if (( ${#to_install[@]} == 0 )); then
    ok "依赖已满足：${pkgs[*]}"
    return 0
  fi

  apt_prepare
  apt_update_once
  wait_for_apt_locks

  log "安装依赖：${to_install[*]}"
  if ! apt-get install -y --no-install-recommends "${to_install[@]}"; then
    warn "apt-get install 失败，尝试修复后重试一次"
    wait_for_apt_locks
    apt-get -y -f install || true
    wait_for_apt_locks
    dpkg --configure -a || true
    wait_for_apt_locks
    apt-get update -y
    wait_for_apt_locks
    apt-get install -y --no-install-recommends "${to_install[@]}"
  fi
  ok "依赖安装完成：${to_install[*]}"
}

# ---------------- Generic helpers ----------------
github_latest_tag_api() {
  curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true
}
github_latest_tag_fallback() {
  curl -fsSL --connect-timeout 10 --max-time 30 "https://github.com/$1/releases/latest" 2>/dev/null \
    | grep -Eo 'tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | sed 's/tag\///' || true
}
github_latest_tag() {
  local repo="$1"
  local tag=""
  tag="$(github_latest_tag_api "$repo")"
  if [[ -n "$tag" ]]; then printf '%s\n' "$tag"; return 0; fi
  warn "GitHub API 获取 $repo 最新版本失败，尝试 fallback（解析 releases 页面）"
  tag="$(github_latest_tag_fallback "$repo")"
  printf '%s\n' "$tag"
}
download_and_extract_tar_gz() {
  local url="$1"
  mkdir -p "$TMP_BASE"
  log "下载：$url"
  curl -fL --connect-timeout 10 --max-time 180 --retry 3 --retry-delay 2 "$url" -o "$TMP_BASE/pkg.tar.gz"
  tar -xzf "$TMP_BASE/pkg.tar.gz" -C "$TMP_BASE"
  printf '%s\n' "$TMP_BASE"
}
ensure_user() {
  if id "$1" >/dev/null 2>&1; then ok "用户已存在：$1"; return 0; fi
  log "创建系统用户：$1"
  useradd --system --no-create-home --shell /usr/sbin/nologin "$1"
  ok "用户创建完成：$1"
}
systemd_reload_enable_start() {
  local svc="$1"
  systemctl daemon-reload
  systemctl enable --now "$svc"
}
svc_is_active() { systemctl is-active --quiet "$1"; }
port_listening() { ss -ltn 2>/dev/null | grep -Eq ":(\b${1}\b)"; }
http_ok() { curl -fsS --max-time 5 "$1" >/dev/null 2>&1; }
wait_for_port() {
  local port="$1" seconds="${2:-10}" i=0
  while (( i < seconds )); do
    port_listening "$port" && return 0
    sleep 1; ((i++))
  done
  return 1
}

get_public_ip() {
  local ip=""
  ip="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] && { echo "$ip"; return 0; }

  ip="$(curl -fsS --max-time 3 https://ifconfig.me/ip 2>/dev/null || true)"
  [[ -n "$ip" ]] && { echo "$ip"; return 0; }

  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  [[ -n "$ip" ]] && { echo "$ip"; return 0; }

  hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
}

# ---------- Pre-flight ----------
log "系统信息：OS=${OS_ID} ${OS_VER} | ARCH=${ARCH}"
apt_install_if_missing ca-certificates curl wget tar gzip gnupg lsb-release apt-transport-https software-properties-common iproute2 conntrack

if ! command -v systemctl >/dev/null 2>&1; then
  fail "当前环境没有 systemctl（可能是容器/WSL/非 systemd 系统），无法安装 systemd 服务。"
  exit 1
fi

# =========================
# 1) Prometheus
# =========================
install_prometheus() {
  log "开始安装 Prometheus（自动取 GitHub 最新版本）"
  ensure_user "$PROM_USER"
  mkdir -p "$DATA_DIR" "$ETC_DIR/prometheus" "$ETC_DIR/prometheus/rules"
  chown -R "$PROM_USER:$PROM_USER" "$DATA_DIR" "$ETC_DIR/prometheus"

  local tag ver pkg_arch url tmpdir extracted
  tag="$(github_latest_tag "prometheus/prometheus")"; [[ -n "$tag" ]] || { fail "无法获取 Prometheus 最新版本"; exit 1; }
  ver="${tag#v}"

  case "$ARCH" in
    x86_64) pkg_arch="linux-amd64" ;;
    aarch64|arm64) pkg_arch="linux-arm64" ;;
    armv7l) pkg_arch="linux-armv7" ;;
    *) fail "不支持的架构：$ARCH"; exit 1 ;;
  esac

  url="https://github.com/prometheus/prometheus/releases/download/${tag}/prometheus-${ver}.${pkg_arch}.tar.gz"
  tmpdir="$(download_and_extract_tar_gz "$url")"
  extracted="$(find "$tmpdir" -maxdepth 1 -type d -name "prometheus-*" | head -n1)"
  [[ -n "$extracted" ]] || { fail "Prometheus 解压目录未找到（tmpdir=$tmpdir）"; exit 1; }

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
  svc_is_active prometheus.service || { fail "Prometheus 服务未启动"; exit 1; }
  ok "Prometheus 服务已启动"
}

# =========================
# 2) Node Exporter
# =========================
install_node_exporter() {
  log "开始安装 Node Exporter（自动取 GitHub 最新版本）"
  local tag ver pkg_arch url tmpdir extracted
  tag="$(github_latest_tag "prometheus/node_exporter")"; [[ -n "$tag" ]] || { fail "无法获取 Node Exporter 最新版本"; exit 1; }
  ver="${tag#v}"

  case "$ARCH" in
    x86_64) pkg_arch="linux-amd64" ;;
    aarch64|arm64) pkg_arch="linux-arm64" ;;
    armv7l) pkg_arch="linux-armv7" ;;
    *) fail "不支持的架构：$ARCH"; exit 1 ;;
  esac

  url="https://github.com/prometheus/node_exporter/releases/download/${tag}/node_exporter-${ver}.${pkg_arch}.tar.gz"
  tmpdir="$(download_and_extract_tar_gz "$url")"
  extracted="$(find "$tmpdir" -maxdepth 1 -type d -name "node_exporter-*" | head -n1)"
  [[ -n "$extracted" ]] || { fail "Node Exporter 解压目录未找到（tmpdir=$tmpdir）"; exit 1; }

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
  svc_is_active node_exporter.service || { fail "Node Exporter 服务未启动"; exit 1; }
  ok "Node Exporter 服务已启动"
}

# =========================
# 3) Blackbox Exporter
# =========================
install_blackbox_exporter() {
  log "开始安装 Blackbox Exporter（自动取 GitHub 最新版本）"
  local tag ver pkg_arch url tmpdir extracted
  tag="$(github_latest_tag "prometheus/blackbox_exporter")"; [[ -n "$tag" ]] || { fail "无法获取 Blackbox Exporter 最新版本"; exit 1; }
  ver="${tag#v}"

  case "$ARCH" in
    x86_64) pkg_arch="linux-amd64" ;;
    aarch64|arm64) pkg_arch="linux-arm64" ;;
    armv7l) pkg_arch="linux-armv7" ;;
    *) fail "不支持的架构：$ARCH"; exit 1 ;;
  esac

  url="https://github.com/prometheus/blackbox_exporter/releases/download/${tag}/blackbox_exporter-${ver}.${pkg_arch}.tar.gz"
  tmpdir="$(download_and_extract_tar_gz "$url")"
  extracted="$(find "$tmpdir" -maxdepth 1 -type d -name "blackbox_exporter-*" | head -n1)"
  [[ -n "$extracted" ]] || { fail "Blackbox Exporter 解压目录未找到（tmpdir=$tmpdir）"; exit 1; }

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
  svc_is_active blackbox_exporter.service || { fail "Blackbox Exporter 服务未启动"; exit 1; }
  ok "Blackbox Exporter 服务已启动"
}

# =========================
# 4) Grafana
# =========================
install_grafana() {
  log "开始安装 Grafana（官方 APT 仓库）"

  apt_install_if_missing ca-certificates curl gnupg

  install -d -m 0755 /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/grafana.gpg ]]; then
    log "写入 Grafana keyring（dearmor）"
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
    chmod 0644 /etc/apt/keyrings/grafana.gpg
  else
    ok "Grafana keyring 已存在"
  fi

  if [[ ! -f /etc/apt/sources.list.d/grafana.list ]]; then
    log "添加 Grafana apt 源"
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
  else
    ok "Grafana apt 源已存在"
  fi

  wait_for_apt_locks
  log "刷新 apt 索引（包含 Grafana 新源）"
  apt-get update -y
  apt_updated=1

  log "尝试安装 grafana（若找不到则尝试 grafana-enterprise）"
  if ! apt-get install -y grafana; then
    warn "未找到 grafana 包，尝试安装 grafana-enterprise"
    apt-get install -y grafana-enterprise
  fi

  local addr="0.0.0.0"
  if [[ "$ALLOW_GRAFANA_PUBLIC" != "1" ]]; then addr="127.0.0.1"; fi

  if ! grep -q '^\[server\]' /etc/grafana/grafana.ini 2>/dev/null; then
    printf '\n[server]\nhttp_addr = %s\nhttp_port = %s\n' "$addr" "$GRAF_PORT" >> /etc/grafana/grafana.ini
  else
    sed -i -E "s/^[#;]?\s*http_addr\s*=.*/http_addr = ${addr}/" /etc/grafana/grafana.ini || true
    sed -i -E "s/^[#;]?\s*http_port\s*=.*/http_port = ${GRAF_PORT}/" /etc/grafana/grafana.ini || true
  fi

  systemd_reload_enable_start grafana-server.service
  svc_is_active grafana-server.service || { fail "Grafana 服务未启动"; exit 1; }
  ok "Grafana 服务已启动（http_addr=${addr}, port=${GRAF_PORT}）"
}

# =========================
# 5) Firewall
# =========================
apply_firewall_lock() {
  if [[ "$SETUP_FIREWALL" != "1" ]]; then
    warn "已跳过防火墙设置（SETUP_FIREWALL=$SETUP_FIREWALL）"
    return 0
  fi

  log "开始配置 iptables：锁 9090/9100/9115，仅本机可访问；3000 允许外网（默认）"
  apt_install_if_missing iptables iptables-persistent

  local backup="/root/iptables-backup-$(date +%Y%m%d-%H%M%S).rules"
  iptables-save > "$backup"
  ok "已备份当前规则：$backup"

  if [[ "$FIREWALL_FLUSH" == "1" ]]; then
    warn "你启用了 FIREWALL_FLUSH=1：将清空现有 iptables 规则（有 SSH 断连风险）"
    iptables -F
    iptables -X
  fi

  iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i lo -j ACCEPT
  iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I INPUT 2 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -p tcp --dport 22 -j ACCEPT

  for p in "$PROM_PORT" "$NODE_PORT" "$BB_PORT"; do
    iptables -C INPUT -p tcp -s 127.0.0.1 --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s 127.0.0.1 --dport "$p" -j ACCEPT
    iptables -C INPUT -p tcp --dport "$p" -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport "$p" -j DROP
  done

  if [[ "$ALLOW_GRAFANA_PUBLIC" == "1" ]]; then
    while iptables -C INPUT -p tcp --dport "$GRAF_PORT" -j DROP 2>/dev/null; do
      iptables -D INPUT -p tcp --dport "$GRAF_PORT" -j DROP || break
    done
    ok "Grafana 3000：已允许外网访问"
  else
    iptables -C INPUT -p tcp -s 127.0.0.1 --dport "$GRAF_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s 127.0.0.1 --dport "$GRAF_PORT" -j ACCEPT
    iptables -C INPUT -p tcp --dport "$GRAF_PORT" -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport "$GRAF_PORT" -j DROP
    warn "Grafana 3000：仅本机访问（ALLOW_GRAFANA_PUBLIC=0）"
  fi

  iptables-save > /etc/iptables/rules.v4
  ok "iptables 规则已保存到 /etc/iptables/rules.v4（iptables-persistent）"

  echo "===============================" >&2
  echo "🔒 已锁：9090/9100/9115（仅本机）" >&2
  if [[ "$ALLOW_GRAFANA_PUBLIC" == "1" ]]; then
    echo "🌐 已放行：3000（外网可访问 Grafana）" >&2
  else
    echo "🔒 已锁：3000（仅本机）" >&2
  fi
  echo "📝 备份：$backup" >&2
  echo "===============================" >&2
}

# =========================
# Final checks
# =========================
final_checks() {
  log "开始最终检查（服务/端口/HTTP）"
  local all_ok=1

  for svc in prometheus.service node_exporter.service blackbox_exporter.service grafana-server.service; do
    if svc_is_active "$svc"; then ok "服务运行中：$svc"; else fail "服务未运行：$svc"; all_ok=0; fi
  done

  for p in "$PROM_PORT" "$NODE_PORT" "$BB_PORT"; do
    if port_listening "$p"; then ok "端口监听正常：$p"; else fail "端口未监听：$p"; all_ok=0; fi
  done

  if ! port_listening "$GRAF_PORT"; then
    warn "Grafana 端口 ${GRAF_PORT} 暂未监听，等待 15 秒重试..."
    wait_for_port "$GRAF_PORT" 15 || true
  fi
  if port_listening "$GRAF_PORT"; then ok "端口监听正常：${GRAF_PORT}（Grafana）"; else fail "Grafana 端口仍未监听：${GRAF_PORT}"; all_ok=0; fi

  http_ok "http://127.0.0.1:${PROM_PORT}/-/ready" && ok "Prometheus ready ✅" || { fail "Prometheus ready 失败"; all_ok=0; }
  http_ok "http://127.0.0.1:${NODE_PORT}/metrics" && ok "Node Exporter metrics ✅" || { fail "Node Exporter metrics 失败"; all_ok=0; }
  http_ok "http://127.0.0.1:${BB_PORT}/metrics" && ok "Blackbox metrics ✅" || { fail "Blackbox metrics 失败"; all_ok=0; }

  if ! http_ok "http://127.0.0.1:${GRAF_PORT}/api/health"; then
    warn "Grafana health 暂不可用，等待 10 秒重试..."
    sleep 10
  fi
  http_ok "http://127.0.0.1:${GRAF_PORT}/api/health" && ok "Grafana health ✅" || warn "Grafana health 仍不可用（建议看日志：journalctl -u grafana-server -n 200 --no-pager）"

  local host_ip
  host_ip="$(get_public_ip)"

  echo >&2
  echo "==========================================" >&2
  if [[ "$all_ok" -eq 1 ]]; then
    echo -e "${GREEN}🎉 全部安装与检查完成：OK${NC}" >&2
  else
    echo -e "${RED}⚠️ 安装完成但存在检查失败项，请按上面 FAIL 提示排查${NC}" >&2
  fi
  echo "Prometheus(本机): http://127.0.0.1:${PROM_PORT}" >&2
  echo "Grafana(外网):    http://${host_ip}:${GRAF_PORT}" >&2
  echo "==========================================" >&2
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
