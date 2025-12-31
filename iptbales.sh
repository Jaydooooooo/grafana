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
  local prompt="$1" ans
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
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    local id_like="${ID_LIKE:-}" id="${ID:-}"
    if echo "$id $id_like" | grep -qiE 'debian|ubuntu'; then
      echo "debian"; return
    fi
    if echo "$id $id_like" | grep -qiE 'rhel|centos|fedora|rocky|almalinux'; then
      echo "rhel"; return
    fi
  fi
  echo "other"
}

ensure_iptables_debian_persist() {
  # Debian/Ubuntu：强制确保“安装 + 启用 + 可保存/可开机恢复”
  if ! has_cmd apt-get; then
    red "未找到 apt-get，无法按 Debian/Ubuntu 方式安装。"
    exit 1
  fi

  if ! has_cmd iptables; then
    yellow "未检测到 iptables，将安装 iptables..."
  fi

  # 关键：不管 iptables 在不在，都确保 iptables-persistent 在且服务启用
  if ! dpkg -l 2>/dev/null | grep -qE '^ii\s+iptables-persistent\s'; then
    yellow "将安装 iptables-persistent（用于重启后自动恢复规则）"
    if ask_yes_no "是否安装 iptables + iptables-persistent？"; then
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y iptables iptables-persistent
    else
      red "用户取消安装持久化组件，重启后规则将无法保证生效，退出。"
      exit 1
    fi
  fi

  # 确保服务启用
  systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true

  # 如果服务仍不可用，明确报错
  if ! systemctl is-enabled netfilter-persistent >/dev/null 2>&1; then
    red "netfilter-persistent 未启用（iptables-persistent 可能安装异常）。"
    red "请执行：apt-get install -y iptables-persistent && systemctl enable --now netfilter-persistent"
    exit 1
  fi
}

install_iptables_and_persist_other() {
  local fam; fam="$(detect_os_family)"
  if [[ "$fam" == "debian" ]]; then
    ensure_iptables_debian_persist
    return 0
  fi

  # 其它系统：尽量维持你之前逻辑（RHEL 用 iptables-services）
  if [[ "$fam" == "rhel" ]]; then
    if has_cmd dnf; then
      yellow "将安装 iptables-services（用于持久化规则）"
      if ask_yes_no "是否继续安装？"; then
        dnf install -y iptables-services
        systemctl enable --now iptables
      else
        red "用户取消安装，无法继续。"
        exit 1
      fi
      return 0
    fi
    if has_cmd yum; then
      yellow "将安装 iptables-services（用于持久化规则）"
      if ask_yes_no "是否继续安装？"; then
        yum install -y iptables-services
        systemctl enable --now iptables
      else
        red "用户取消安装，无法继续。"
        exit 1
      fi
      return 0
    fi
  fi

  red "无法识别系统或缺少包管理器，请手动安装 iptables 与持久化组件。"
  exit 1
}

valid_ip_or_cidr() {
  local s="$1"
  [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]] || return 1
  local ip="${s%%/*}"
  IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

ensure_chain_and_hook() {
  iptables -nL "$CHAIN" >/dev/null 2>&1 || iptables -N "$CHAIN"

  # hook 放 INPUT 最前，确保优先匹配
  if ! iptables -C INPUT -p tcp -m multiport --dports ${PORTS} -j "$CHAIN" -m comment --comment "$HOOK_COMMENT" >/dev/null 2>&1; then
    iptables -I INPUT 1 -p tcp -m multiport --dports ${PORTS} -j "$CHAIN" -m comment --comment "$HOOK_COMMENT"
  fi

  # 允许本机
  if ! iptables -C "$CHAIN" -i lo -j ACCEPT >/dev/null 2>&1; then
    iptables -I "$CHAIN" 1 -i lo -j ACCEPT
  fi

  # 先移除旧 DROP，最后再加，保证 DROP 永远在链尾
  while iptables -C "$CHAIN" -p tcp -m multiport --dports ${PORTS} -j DROP -m comment --comment "$DROP_COMMENT" >/dev/null 2>&1; do
    iptables -D "$CHAIN" -p tcp -m multiport --dports ${PORTS} -j DROP -m comment --comment "$DROP_COMMENT"
  done
}

add_allow_ip() {
  local ip="$1"
  if iptables -C "$CHAIN" -p tcp -s "$ip" -m multiport --dports ${PORTS} -j ACCEPT -m comment --comment "$ALLOW_COMMENT" >/dev/null 2>&1; then
    yellow "已存在放行规则：$ip"
    return 0
  fi
  iptables -A "$CHAIN" -p tcp -s "$ip" -m multiport --dports ${PORTS} -j ACCEPT -m comment --comment "$ALLOW_COMMENT"
  green "已放行：$ip -> TCP ${PORTS}"
}

finalize_drop_all_others() {
  iptables -C "$CHAIN" -p tcp -m multiport --dports ${PORTS} -j DROP -m comment --comment "$DROP_COMMENT" >/dev/null 2>&1 \
    || iptables -A "$CHAIN" -p tcp -m multiport --dports ${PORTS} -j DROP -m comment --comment "$DROP_COMMENT"
}

save_rules_strict() {
  local fam; fam="$(detect_os_family)"

  if [[ "$fam" == "debian" ]]; then
    # Debian/Ubuntu：强制用 netfilter-persistent 保存，保证重启加载
    if ! has_cmd netfilter-persistent; then
      red "未找到 netfilter-persistent（iptables-persistent 未正确安装），无法保证重启恢复。"
      exit 1
    fi
    netfilter-persistent save
    green "已保存规则（netfilter-persistent save），重启后会自动恢复。"
    return 0
  fi

  # RHEL 兜底
  if [[ "$fam" == "rhel" ]]; then
    if has_cmd service && service iptables status >/dev/null 2>&1; then
      service iptables save
      green "已保存规则（service iptables save）。"
      return 0
    fi
  fi

  # 其它：至少落地 rules.v4（但不保证自动加载）
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
  yellow "已保存到 /etc/iptables/rules.v4（但系统未必会开机自动加载）。"
}

show_result() {
  echo
  green "========== 当前针对 9100/9115 的最终规则 =========="
  iptables -S INPUT | grep -E "$CHAIN|$HOOK_COMMENT" || true
  echo "----------------------------------------------------"
  iptables -S "$CHAIN" || true
  echo "===================================================="
  echo
}

main() {
  require_root

  # 不论是否已安装 iptables，都确保“持久化组件”到位（Debian 系重点）
  if ! has_cmd iptables; then
    yellow "未检测到 iptables 命令。"
  fi
  install_iptables_and_persist_other

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
  save_rules_strict
  show_result
  green "完成 ✅（重启后依旧生效）"
}

main "$@"
