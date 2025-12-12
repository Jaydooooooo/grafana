#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
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
      err "不支持的架构: $(uname -m)"
      exit 1
      ;;
  esac
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y "$@" >/dev/null
}

ensure_base_tools() {
  local pkgs=()
  need_cmd curl || pkgs+=("curl")
  need_cmd wget || pkgs+=("wget")
  need_cmd tar  || pkgs+=("tar")
  need_cmd ss   || pkgs+=("iproute2")

  if ((${#pkgs[@]})); then
    warn "安装基础依赖: ${pkgs[*]}"
    apt_install "${pkgs[@]}"
  fi
}

ensure_firewall_tools() {
  local pkgs=()
  need_cmd iptables || pkgs+=("iptables")
  need_cmd netfilter-persistent || pkgs+=("iptables-persistent" "netfilter-persistent")

  if ((${#pkgs[@]})); then
    warn "安装防火墙依赖: ${pkgs[*]}"
    apt_install "${pkgs[@]}"
  fi
}

github_latest_tag() {
  # 先拿到完整返回，再解析 tag；拿不到则输出 message，方便排障
  local repo="$1"
  local resp tag msg

  resp="$(curl -sS -L \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: install_exporters" \
    "https://api.github.com/repos/${repo}/releases/latest" || true)"

  tag="$(printf '%s' "${resp}" | awk -F'"' '/"tag_name"[[:space:]]*:[[:space:]]*"/ {print $4; exit}')"

  if [[ -z "${tag}" ]]; then
    msg="$(printf '%s' "${resp}" | awk -F'"' '/"message"[[:space:]]*:[[:space:]]*"/ {print $4; exit}')"
    err "无法获取 ${repo} 最新版本 tag_name"
    [[ -n "${msg}" ]] && err "GitHub 返回: ${msg}"
    return 1
  fi

  echo "${tag}"
}

ensure_user() {
  local u="$1"
  id "$u" >/dev/null 2>&1 || useradd -rs /bin/false "$u"
}

port_listening() {
  local port="$1"
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
}

service_active() {
  local svc="$1"
  systemctl is-active --quiet "${svc}"
}

download_and_install_binary() {
  local url="$1" prefix="$2" bin="$3" dst="$4"
  local tmp
  tmp="$(mktemp -d)"
  wget -qO "${tmp}/pkg.tgz" "${url}"
  tar -xzf "${tmp}/pkg.tgz" -C "${tmp}"
  install -m 0755 "${tmp}/${prefix}/${bin}" "${dst}"
  rm -rf "${tmp}"
}

install_node_exporter() {
  local tag version url prefix
  tag="$(github_latest_tag "prometheus/node_exporter")" || { err "获取 node_exporter tag 失败"; exit 1; }
  version="${tag#v}"
  url="https://github.com/prometheus/node_exporter/releases/download/${tag}/node_exporter-${version}.linux-${ARCH}.tar.gz"
  prefix="node_exporter-${version}.linux-${ARCH}"

  ok "Node Exporter 最新版本: ${tag}"

  ensure_user "node_exporter"
  download_and_install_binary "${url}" "${prefix}" "node_exporter" "/usr/local/bin/node_exporter"

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
  systemctl enable --now node_exporter.service >/dev/null
  ok "node_exporter 已安装并启动（监听 9100）"
}

install_blackbox_exporter() {
  local tag version url prefix
  tag="$(github_latest_tag "prometheus/blackbox_exporter")" || { err "获取 blackbox_exporter tag 失败"; exit 1; }
  version="${tag#v}"
  url="https://github.com/prometheus/blackbox_exporter/releases/download/${tag}/blackbox_exporter-${version}.linux-${ARCH}.tar.gz"
  prefix="blackbox_exporter-${version}.linux-${ARCH}"

  ok "Blackbox Exporter 最新版本: ${tag}"

  if port_listening 9115 && ! service_active blackbox-exporter.service; then
    err "端口 9115 已被占用，且 blackbox-exporter.service 未运行。请先释放端口再执行。"
    exit 1
  fi

  download_and_install_binary "${url}" "${prefix}" "blackbox_exporter" "/usr/local/bin/blackbox_exporter"

  mkdir -p /etc/blackbox_exporter
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
  systemctl enable --now blackbox-exporter.service >/dev/null
  systemctl restart blackbox-exporter.service >/dev/null
  ok "blackbox_exporter 已安装并启动（监听 9115，已开启 tcp_connect）"
}

prompt_panel_ip() {
  local ip=""
  while true; do
    read -r -p "请输入面板服务器 IP（仅允许该 IP 访问 9100/9115）: " ip
    ip="${ip// /}"
    [[ -n "${ip}" ]] || { warn "IP 不能为空"; continue; }
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { warn "IP 格式不正确，请输入类似 1.2.3.4"; continue; }
    PANEL_IP="${ip}"
    break
  done
}

iptables_allow_panel() {
  local ip="${PANEL_IP}"
  for port in 9100 9115; do
    if iptables -C INPUT -p tcp -s "${ip}" --dport "${port}" -j ACCEPT >/dev/null 2>&1; then
      ok "iptables 已存在规则：允许 ${ip} -> ${port}"
    else
      iptables -I INPUT -p tcp -s "${ip}" --dport "${port}" -j ACCEPT
      ok "iptables 已添加规则：允许 ${ip} -> ${port}"
    fi
  done

  netfilter-persistent save >/dev/null 2>&1 || true
  netfilter-persistent reload >/dev/null 2>&1 || true

  ok "已保存并重载 netfilter-persistent"
  echo
  echo "==== /etc/iptables/rules.v4 ===="
  cat /etc/iptables/rules.v4 || true
  echo "==============================="
}

check_all() {
  local fail=0
  echo
  echo "========== 最终检查 =========="

  [[ -x /usr/local/bin/node_exporter ]] && ok "node_exporter 二进制 OK" || { err "node_exporter 二进制缺失"; fail=1; }
  service_active node_exporter.service && ok "node_exporter 服务运行 OK" || { err "node_exporter 服务未运行"; fail=1; }
  port_listening 9100 && ok "9100 监听 OK" || { err "9100 未监听"; fail=1; }

  [[ -x /usr/local/bin/blackbox_exporter ]] && ok "blackbox_exporter 二进制 OK" || { err "blackbox_exporter 二进制缺失"; fail=1; }
  service_active blackbox-exporter.service && ok "blackbox-exporter 服务运行 OK" || { err "blackbox-exporter 服务未运行"; fail=1; }
  port_listening 9115 && ok "9115 监听 OK" || { err "9115 未监听"; fail=1; }

  [[ -f /etc/blackbox_exporter/blackbox.yml ]] && grep -q "^  tcp_connect:" /etc/blackbox_exporter/blackbox.yml \
    && ok "tcp_connect（tcping）模块已开启 OK" || { err "tcp_connect 模块未开启"; fail=1; }

  echo "=============================="

  if [[ "${fail}" -eq 0 ]]; then
    ok "全部成功 ✅"
  else
    err "存在失败项 ❌（请按上面提示排查）"
    exit 1
  fi
}

main() {
  require_root
  detect_arch
  ensure_base_tools
  ensure_firewall_tools

  install_node_exporter
  install_blackbox_exporter

  prompt_panel_ip
  iptables_allow_panel

  check_all
}

main "$@"
