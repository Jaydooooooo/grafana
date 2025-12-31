#!/usr/bin/env bash
# 功能：
# - 交互式添加允许访问 9100/9115 的 IP/CIDR（可多次添加直到用户选择否）
# - 只允许白名单访问这两个端口，其它来源一律 DROP
# - 若 IP 已被允许：不重复新增规则，但会“置顶”该允许规则（仅次于 lo），避免被其它规则干扰
# - 自动创建并挂载自定义链（INPUT 置顶跳转到该链）
# - 若缺少 iptables：询问后安装；并安装/启用持久化组件，确保重启后规则仍生效
# - Debian/Ubuntu：iptables-persistent + netfilter-persistent
# - RHEL/CentOS/Rocky/Alma：iptables-services

set -euo pipefail

PORTS="9100,9115"
CHAIN="EXPORTER_WHITELIST"

HOOK_COMMENT="exporter_whitelist_hook"
ALLOW_COMMENT="exporter_whitelist_allow"
DROP_COMMENT="exporter_whitelist_drop"

green(){ echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
red(){ echo -e "\033[31m$*\033[0m"; }

has_cmd(){ command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    red "请用 root 运行此脚本。"
    exit 1
  fi
}

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
  # 输出：debian / rhel / other
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
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

valid_ip_or_cidr() {
  # 支持：a.b.c.d 或 a.b.c.d/0-32
  local s="$1"
  [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]] || return 1
  local ip="${s%%/*}"
  IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

install_debian_iptables_persist_strict() {
  if ! has_cmd apt-get; then
    red "未找到 apt-get，无法按 Debian/Ubuntu 方式安装。"
    exit 1
  fi

  yellow "需要安装/确保：iptables + iptables-persistent（重启自动恢复规则）"
  if ask_yes_no "是否继续安装/配置？"; then
    apt-get update -y
    # iptables-persistent 会提示保存规则，这里用非交互
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables iptables-persistent
    # 确保服务启用
    systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true

    if ! systemctl is-enabled netfilter-persistent >/dev/null 2>&1; then
      red "netfilter-persistent 未启用，无法保证重启恢复。"
      red "请手动执行：systemctl enable --now netfilter-persistent"
      exit 1
    fi
  else
    red "用户取消安装/配置持久化组件。重启后规则无法保证生效，退出。"
    exit 1
  fi
}

install_rhel_iptables_services_strict() {
  yellow "需要安装/确保：iptables-services（重启自动恢复规则）"
  if ask_yes_no "是否继续安装/配置？"; then
    if has_cmd dnf; then
      dnf install -y iptables-services
    elif has_cmd yum; then
      yum install -y iptables-services
    else
      red "未找到 yum/dnf，无法自动安装 iptables-services。"
      exit 1
    fi
    systemctl enable --now iptables >/dev/null 2>&1 || true
  else
    red "用户取消安装/配置持久化组件。重启后规则无法保证生效，退出。"
    exit 1
  fi
}

ensure_iptables_and_persistence() {
  local fam; fam="$(detect_os_family)"

  if ! has_cmd iptables; then
    yellow "未检测到 iptables 命令。"
    if [[ "$fam" == "debian" ]]; then
      install_debian_iptables_persist_strict
    elif [[ "$fam" == "rhel" ]]; then
      install_rhel_iptables_services_strict
    else
      red "无法识别系统类型，且缺少 iptables。请手动安装 iptables 与持久化组件。"
      exit 1
    fi
  else
    # iptables 在，但仍要确保“持久化组件”存在且启用（关键：你重启失效就是这里没做到）
    if [[ "$fam" == "debian" ]]; then
      if ! has_cmd netfilter-persistent; then
        yellow "检测到 iptables 已存在，但缺少 netfilter-persistent（iptables-persistent）。"
        install_debian_iptables_persist_strict
      else
        systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true
      fi
    elif [[ "$fam" == "rhel" ]]; then
      # RHEL：确保 iptables 服务存在（iptables-services）
      if ! systemctl list-unit-files 2>/dev/null | grep -qE '^iptables\.service'; then
        yellow "检测到 iptables 已存在，但缺少 iptables-services（iptables.service）。"
        install_rhel_iptables_services_strict
      else
        systemctl enable --now iptables >/dev/null 2>&1 || true
      fi
    else
      yellow "系统类型无法识别：将仅写入 /etc/iptables/rules.v4（不保证开机自动加载）。"
    fi
  fi
}

ensure_chain_and_hook() {
  # 创建链
  iptables -nL "$CHAIN" >/dev/null 2>&1 || iptables -N "$CHAIN"

  # INPUT 链置顶挂钩：访问 9100/9115 先跳到自定义链
  if ! iptables -C INPUT -p tcp -m multiport --dports ${PORTS} -j "$CHAIN" -m comment --comment "$HOOK_COMMENT" >/dev/null 2>&1; then
    iptables -I INPUT 1 -p tcp -m multiport --dports ${PORTS} -j "$CHAIN" -m comment --comment "$HOOK_COMMENT"
  else
    # 如果 hook 不在最前（可能被别的规则挤下去），把它移动到最前
    # 简化做法：删掉再插到第1条
    iptables -D INPUT -p tcp -m multiport --dports ${PORTS} -j "$CHAIN" -m comment --comment "$HOOK_COMMENT" || true
    iptables -I INPUT 1 -p tcp -m multiport --dports ${PORTS} -j "$CHAIN" -m comment --comment "$HOOK_COMMENT"
  fi
}

ensure_lo_first() {
  # 确保 lo 放行在 CHAIN 的第一条（并去重）
  while iptables -C "$CHAIN" -i lo -j ACCEPT >/dev/null 2>&1; do
    iptables -D "$CHAIN" -i lo -j ACCEPT || break
  done
  iptables -I "$CHAIN" 1 -i lo -j ACCEPT
}

ensure_allow_rule_top() {
  # 将指定 IP 的允许规则置顶（仅次于 lo），并保证不重复
  local ip="$1"
  local rule=(-p tcp -s "$ip" -m multiport --dports ${PORTS} -j ACCEPT -m comment --comment "$ALLOW_COMMENT")

  # 删除所有同款规则（防重复 & 调整位置）
  while iptables -C "$CHAIN" "${rule[@]}" >/dev/null 2>&1; do
    iptables -D "$CHAIN" "${rule[@]}" || break
  done

  # 插入到第2条：第1条给 lo
  iptables -I "$CHAIN" 2 "${rule[@]}"
  green "已置顶放行：$ip -> TCP ${PORTS}"
}

ip_already_allowed() {
  local ip="$1"
  local rule=(-p tcp -s "$ip" -m multiport --dports ${PORTS} -j ACCEPT -m comment --comment "$ALLOW_COMMENT")
  iptables -C "$CHAIN" "${rule[@]}" >/dev/null 2>&1
}

add_allow_ip() {
  local ip="$1"

  ensure_lo_first

  if ip_already_allowed "$ip"; then
    yellow "该 IP 已允许通过：$ip（不重复新增，将把规则置顶）"
  fi

  ensure_allow_rule_top "$ip"
}

finalize_drop_all_others() {
  # DROP 必须在最后，且只保留一个
  while iptables -C "$CHAIN" -p tcp -m multiport --dports ${PORTS} -j DROP -m comment --comment "$DROP_COMMENT" >/dev/null 2>&1; do
    iptables -D "$CHAIN" -p tcp -m multiport --dports ${PORTS} -j DROP -m comment --comment "$DROP_COMMENT"
  done
  iptables -A "$CHAIN" -p tcp -m multiport --dports ${PORTS} -j DROP -m comment --comment "$DROP_COMMENT"
}

save_rules_strict() {
  local fam; fam="$(detect_os_family)"

  if [[ "$fam" == "debian" ]]; then
    if ! has_cmd netfilter-persistent; then
      red "未找到 netfilter-persistent（iptables-persistent 未正确安装），无法保证重启恢复。"
      exit 1
    fi
    netfilter-persistent save
    green "已保存规则（netfilter-persistent save），重启后会自动恢复。"
    return 0
  fi

  if [[ "$fam" == "rhel" ]]; then
    # 优先使用 iptables-services 的保存
    if has_cmd service && service iptables status >/dev/null 2>&1; then
      service iptables save
      green "已保存规则（service iptables save），重启后会自动恢复。"
      return 0
    fi
    # 兜底
    if has_cmd iptables-save; then
      iptables-save > /etc/sysconfig/iptables
      green "已保存规则到 /etc/sysconfig/iptables（兜底）。"
      return 0
    fi
  fi

  # 其它系统：落地文件但不保证开机加载
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
  yellow "已保存到 /etc/iptables/rules.v4（但系统未必会开机自动加载）。"
}

show_result() {
  echo
  green "========== 当前针对 9100/9115 的最终规则（顺序很重要）=========="
  echo "INPUT (前几条)："
  iptables -S INPUT | sed -n '1,30p'
  echo "--------------------------------------------------------------"
  echo "$CHAIN："
  iptables -S "$CHAIN"
  echo "=============================================================="
  echo
  yellow "说明："
  echo "1) INPUT 链第1条：访问 9100/9115 会跳转到 $CHAIN"
  echo "2) $CHAIN 第1条：lo 放行"
  echo "3) $CHAIN 第2条起：你添加的白名单（最新添加永远更靠前）"
  echo "4) $CHAIN 最后一条：DROP（拒绝其他所有来源访问 9100/9115）"
  echo
}

main() {
  require_root

  ensure_iptables_and_persistence
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
