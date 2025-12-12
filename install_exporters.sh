#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请切换到 root 用户后再运行脚本（不要用 sudo 执行本脚本）"
    exit 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)
      err "$(uname -m) 架构不支持"
      exit 1
      ;;
  esac
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_pkgs_if_needed() {
  # 确保基础工具存在
  local pkgs=()
  need_cmd curl || pkgs+=("curl")
  need_cmd wget || pkgs+=("wget")
  need_cmd tar  || pkgs+=("tar")
  need_cmd ss   || pkgs+=("iproute2")

  if ((${#pkgs[@]} > 0)); then
    warn "安装依赖: ${pkgs[*]}"
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
  fi
}

ensure_firewall_tools() {
  # 判断 iptables / netfilter-persistent 是否存在，不存在则安装
  local pkgs=()

  need_cmd iptables || pkgs+=("iptables")
  # Debian/Ubuntu 持久化通常由 iptables-persistent + netfilter-persistent 提供
  if ! need_cmd netfilter-persistent; then
    pkgs+=("iptables-persistent" "netfilter-persistent")
  fi

  if ((${#pkgs[@]} > 0)); then
    warn "检测到缺少防火墙组件，准备安装: ${pkgs[*]}"
    # 避免 iptables-persistent 安装时交互
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
  fi
}

github_latest_tag() {
  # $1: owner/repo
  local project="$1"
  curl -fsSL "https://api.github.com/repos/${project}/releases/latest" \
    | awk -F'"' '/"tag_name"\s*:\s*"/ {print $4; exit}'
}

ensure_user() {
  # $1: username
  local u="$1"
  if id "$u" >/dev/null 2>&1; then
    return 0
  fi
  useradd -rs /bin/false "$u"
}

port_in_use() {
  # $1: port
  local p="$1"
  ss -tuln | grep -q ":${p}\b"
}

install_node_exporter() {
  local project="prometheus/node_exporter"
  local tag version url tmpdir

  tag="$(github_latest_tag "${project}")"
  version="${tag#v}"
  url="https://github.com/prometheus/node_exporter/releases/download/${tag}/node_exporter-${version}.linux-${ARCH}.tar.gz"

  log "Node Exporter 最新版本: ${tag}"

  ensure_user "node_exporter"

  tmpdir="$(mktemp -d)"
  wget -qO "${tmpdir}/node_exporter.tar.gz" "${url}"
  tar -xzf "${tmpdir}/node_exporter.tar.gz" -C "${tmpdir}"

  # 覆盖安装
  install -m 0755 "${tmpdir}/node_exporter-"*/node_exporter /usr/local/bin/node_exporter

  rm -rf "${tmpdir}"

  cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now node_exporter.service
  log "node_exporter 已启动并设置开机自启（端口 9100）"
}

install_blackbox_exporter() {
  local project="prometheus/blackbox_exporter"
  local tag version url tmpdir

  tag="$(github_latest_tag "${project}")"
  version="${tag#v}"
  url="https://github.com/prometheus/blackbox_exporter/releases/download/${tag}/blackbox_exporter-${version}.linux-${ARCH}.tar.gz"

  log "Blackbox Exporter 最新版本: ${tag}"

  # 端口占用检测（如果已经是 blackbox_exporter 占用也没关系，这里只做提醒）
  if port_in_use 9115; then
    warn "检测到 9115 端口已被占用（如果是已有 blackbox_exporter 在跑，可忽略）"
  fi

  tmpdir="$(mktemp -d)"
  wget -qO "${tmpdir}/blackbox_exporter.tar.gz" "${url}"
  tar -xzf "${tmpdir}/blackbox_exporter.tar.gz" -C "${tmpdir}"

  mkdir -p /etc/blackbox_exporter
  install -m 0755 "${tmpdir}/blackbox_exporter-"*/blackbox_exporter /usr/local/bin/blackbox_exporter

  rm -rf "${tmpdir}"

  # 写入 blackbox.yml（含 tcp_connect）
  cat > /etc/blackbox_exporter/blackbox.yml <<'EOF'
modules:
  icmp:
    prober: icmp

  http:
    prober: http

  tcp_connect:
    prober: tcp
    timeout: 5s

  dns:
    prober: dns
    dns:
      preferred_ip_protocol: "ip4"
      query_name: "www.apple.com"
      query_type: "A"
EOF

  cat > /etc/systemd/system/blackbox-exporter.service <<'EOF'
[Unit]
Description=Prometheus Blackbox Exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/blackbox_exporter --config.file="/etc/blackbox_exporter/blackbox.yml" --web.listen-address=":9115"
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now blackbox-exporter.service
  log "blackbox_exporter 已启动并设置开机自启（端口 9115，已开启 tcp_connect 模块）"
}

prompt_panel_ip() {
  local ip=""
  while true; do
    read -r -p "请输入面板服务器 IP（将仅允许该 IP 访问 9100/9115）: " ip
    ip="${ip// /}"
    if [[ -z "${ip}" ]]; then
      warn "IP 不能为空"
      continue
    fi
    # 简单校验 IPv4
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      PANEL_IP="${ip}"
      break
    else
      warn "IP 格式看起来不对，请重新输入（例如 1.2.3.4）"
    fi
  done
}

apply_firewall_rules() {
  # 仅放行面板机访问 9100/9115（INPUT 链）
  # 为避免重复插入，用 -C 检查，不存在再插入
  local ip="${PANEL_IP}"

  for port in 9100 9115; do
    if iptables -C INPUT -p tcp -s "${ip}" --dport "${port}" -j ACCEPT >/dev/null 2>&1; then
      log "iptables 规则已存在：允许 ${ip} -> ${port}"
    else
      iptables -I INPUT -p tcp -s "${ip}" --dport "${port}" -j ACCEPT
      log "已添加 iptables 规则：允许 ${ip} -> ${port}"
    fi
  done

  netfilter-persistent save >/dev/null 2>&1 || true
  netfilter-persistent reload >/dev/null 2>&1 || true

  log "已保存并重载 netfilter-persistent"
  echo
  echo "当前 rules.v4："
  cat /etc/iptables/rules.v4 || true
}

check_services() {
  local ok_all=1

  echo
  echo "========== 安装结果检查 =========="

  # node_exporter
  if command -v node_exporter >/dev/null 2>&1; then
    log "node_exporter 二进制存在：/usr/local/bin/node_exporter"
  else
    err "node_exporter 二进制不存在"
    ok_all=0
  fi

  if systemctl is-active --quiet node_exporter.service; then
    log "node_exporter 服务运行中"
  else
    err "node_exporter 服务未运行"
    ok_all=0
  fi

  if ss -tuln | grep -q ":9100\b"; then
    log "node_exporter 端口 9100 正在监听"
  else
    err "未检测到 9100 监听"
    ok_all=0
  fi

  # blackbox_exporter
  if command -v blackbox_exporter >/dev/null 2>&1; then
    log "blackbox_exporter 二进制存在：/usr/local/bin/blackbox_exporter"
  else
    err "blackbox_exporter 二进制不存在"
    ok_all=0
  fi

  if systemctl is-active --quiet blackbox-exporter.service; then
    log "blackbox-exporter 服务运行中"
  else
    err "blackbox-exporter 服务未运行"
    ok_all=0
  fi

  if ss -tuln | grep -q ":9115\b"; then
    log "blackbox-exporter 端口 9115 正在监听"
  else
    err "未检测到 9115 监听"
    ok_all=0
  fi

  # tcp “ping” 模块检查（tcp_connect）
  if [[ -f /etc/blackbox_exporter/blackbox.yml ]] && grep -q "tcp_connect" /etc/blackbox_exporter/blackbox.yml; then
    log "tcp 探测模块已开启（blackbox.yml 中存在 tcp_connect）"
  else
    err "未检测到 tcp_connect 模块配置"
    ok_all=0
  fi

  echo "================================="

  if [[ "${ok_all}" -eq 1 ]]; then
    echo -e "${GREEN}全部检查通过 ✅${NC}"
  else
    echo -e "${RED}存在失败项 ❌（请根据上面提示排查）${NC}"
    exit 1
  fi
}

main() {
  require_root
  detect_arch
  install_pkgs_if_needed
  ensure_firewall_tools

  install_node_exporter
  install_blackbox_exporter

  prompt_panel_ip
  apply_firewall_rules

  check_services
}

main "$@"
