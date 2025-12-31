#!/usr/bin/env bash
set -euo pipefail

PORTS="9100,9115"
CHAIN="EXPORTER_WHITELIST"
HOOK_COMMENT="exporter_whitelist_hook"
ALLOW_COMMENT="exporter_whitelist_allow"
DROP_COMMENT="exporter_whitelist_drop"

green(){ echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
red(){ echo -e "\033[31m$*\033[0m"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    red "请用 root 运行此脚本。"
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

ask_yes_no() {
  local prompt="$1"
  local ans
  while true; do
    read -r -p "$prompt [y/n]: " ans
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "请输入 y 或 n。" ;;
    esac
  done
}

detect_os_family() {
  # 输出：debian / rhel / other
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    local id_like="${ID_LIKE:-}"
    local id="${ID:-}"
    if echo "$id $id_like" | grep -qiE 'debian|ubuntu'; then
      echo "debian"; return
    fi
    if echo "$id $id_like" | grep -qiE 'rhel|centos|fedora|rocky|almalinux'; then
      echo "rhel"; return
    fi
  fi
  echo "other"
}

install_iptables_and_persist() {
  local fam; fam="$(detect_os_family)"

  yellow "检测到系统可能未安装 iptables，准备安装…"
  if [[ "$fam" == "debian" ]]; then
    if ! has_cmd apt-get; then
      red "系统不是标准 Debian/Ubuntu（未找到 apt-get），请手动安装 iptables。"
      exit 1
    fi
    yellow "将安装：iptables + iptables-persistent（用于持久化规则）"
    if ask_yes_no "是否继续安装？"; then
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y iptables iptables-persistent
      green "安装完成。"
    else
      red "用户取消安装，无法继续。"
      exit 1
    fi
  elif [[ "$fam" == "rhel" ]]; then
    if has_cmd dnf; then
      yellow "将安装：iptables-services（用于持久化规则）"
      if ask_yes_no "是否继续安装？"; then
        dnf install -y iptables-services
        systemctl enable --now iptables
        green "安装并启用 iptables-services 完成。"
      else
        red "用户取消安装，无法继续。"
        exit 1
      fi
    elif has_cmd yum; then
      yellow "将安装：iptables-services（用于持久化规则）"
      if ask_yes_no "是否继续安装？"; then
        yum install -y iptables-services
        systemctl enable --now iptables
        green "安装并启用 iptables-services 完成。"
      else
        red "用户取消安装，无法继续。"
        exit 1
      fi
    else
      red "系统不是标准 RHEL 系（未找到 yum/dnf），请手动安装 iptables。"
      exit 1
    fi
  else
    red "无法识别发行版类型，请手动安装 iptables 并确保能持久化规则。"
    exit 1
  fi
}

valid_ip_or_cidr() {
  # 支持：a.b.c.d 或 a.b.c.d/0-32
  local s="$1"
  # 基本格式
  if [[ ! "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; then
    return 1
  fi
  # 检查每段 <= 255
  local ip="${s%%/*}"
  IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    if (( o < 0 || o > 255 )); then
      return 1
    fi
  done
  return 0
}

ensure_chain_and_hook() {
  # 创建自定义链
  if ! iptables -nL "$CHAIN" >/dev/null 2>&1; then
    iptables -N "$CHAIN"
  fi

  # 确保 INPUT 链中有 hook（放在最前面，优先匹配）
  # hook规则：凡是访问 9100/9115 的 TCP 流量，都跳转到自定义链处理
  if ! iptables -C INPUT -p tcp -m multiport --dports ${PORTS} -j "$CHAIN" -m comment --comment "$HOOK_COMMENT" >/dev/null 2>&1; then
    iptables -I INPUT 1 -p tcp -m multiport --dports ${PORTS} -j "$CHAIN" -m comment --comment "$HOOK_COMMENT"
  fi

  # 自定义链里：先允许 lo（本机访问永远放行）
  if ! iptables -C "$CHAIN" -i lo -j ACCEPT >/dev/null 2>&1; then
    iptables -I "$CHAIN" 1 -i lo -j ACCEPT
  fi

  # 删除旧的“最终 DROP”（避免重复 & 确保 DROP 在最后）
  while iptables -C "$CHAIN" -p tcp -m multiport --dports ${PORTS} -j DROP -m comment --comment "$DROP_COMMENT" >/dev/null 2>&1; do
    iptables -D "$CHAIN" -p tcp -m multiport --dports ${PORTS} -j DROP -m comment --comment "$DROP_COMMENT"
  done
}

add_allow_ip() {
  local ip="$1"
  # 允许规则放在 DROP 之前；为避免重复，先检查 -C
  if iptables -C "$CHAIN" -p tcp -s "$ip" -m multiport --dports ${PORTS} -j ACCEPT -m comment --comment "$ALLOW_COMMENT" >/dev/null 2>&1; then
    yellow "已存在放行规则：$ip"
    return 0
  fi
  # 插入到链尾部（DROP 还没加回去，或稍后加回去）
  iptables -A "$CHAIN" -p tcp -s "$ip" -m multiport --dports ${PORTS} -j ACCEPT -m comment --comment "$ALLOW_COMMENT"
  green "已放行：$ip -> TCP ${PORTS}"
}

finalize_drop_all_others() {
  # 在链尾追加最终 DROP（确保其它全部拒绝）
  if ! iptables -C "$CHAIN" -p tcp -m multiport --dports ${PORTS} -j DROP -m comment --comment "$DROP_COMMENT" >/dev/null 2>&1; then
    iptables -A "$CHAIN" -p tcp -m multiport --dports ${PORTS} -j DROP -m comment --comment "$DROP_COMMENT"
  fi
}

save_rules() {
  local fam; fam="$(detect_os_family)"

  if [[ "$fam" == "debian" ]]; then
    if has_cmd netfilter-persistent; then
      netfilter-persistent save
      green "已保存规则（netfilter-persistent save）。"
      return 0
    fi
    # 兜底：iptables-save -> rules.v4
    if has_cmd iptables-save; then
      mkdir -p /etc/iptables
      iptables-save > /etc/iptables/rules.v4
      green "已保存规则到 /etc/iptables/rules.v4（兜底保存）。"
      return 0
    fi
  elif [[ "$fam" == "rhel" ]]; then
    if has_cmd service && service iptables status >/dev/null 2>&1; then
      service iptables save
      green "已保存规则（service iptables save）。"
      return 0
    fi
    if has_cmd iptables-save; then
      iptables-save > /etc/sysconfig/iptables
      green "已保存规则到 /etc/sysconfig/iptables（兜底保存）。"
      return 0
    fi
  fi

  yellow "未检测到可用的持久化保存命令。你可以手动保存：iptables-save > /etc/iptables/rules.v4"
}

show_result() {
  echo
  green "========== 当前针对 9100/9115 的最终规则 =========="
  iptables -S INPUT | grep -E "$CHAIN|$HOOK_COMMENT" || true
  echo "----------------------------------------------------"
  iptables -S "$CHAIN" || true
  echo "===================================================="
  echo
  yellow "说明："
  echo "1) 只有你添加的 IP/CIDR 能访问 TCP 9100/9115"
  echo "2) 其他所有来源访问 9100/9115 都会被 DROP"
  echo "3) 不影响其它端口（SSH 等不会被改动）"
}

main() {
  require_root

  if ! has_cmd iptables; then
    yellow "未检测到 iptables 命令。"
    install_iptables_and_persist
  fi

  # 再次确认
  if ! has_cmd iptables; then
    red "iptables 仍不可用，退出。"
    exit 1
  fi

  ensure_chain_and_hook

  echo
  green "将为端口 9100 和 9115 设置白名单访问（其他全部拒绝）。"
  echo "请输入要放行的 IP（支持 CIDR，例如 1.2.3.4 或 1.2.3.0/24）。"
  echo

  while true; do
    local ip
    read -r -p "请输入允许访问 9100/9115 的 IP/CIDR: " ip
    ip="${ip//[[:space:]]/}"

    if [[ -z "$ip" ]]; then
      yellow "输入为空，请重新输入。"
      continue
    fi

    if ! valid_ip_or_cidr "$ip"; then
      red "IP/CIDR 格式不合法：$ip"
      continue
    fi

    add_allow_ip "$ip"

    if ! ask_yes_no "是否继续添加 IP？"; then
      break
    fi
  done

  finalize_drop_all_others
  save_rules
  show_result

  green "完成 ✅"
}

main "$@"
