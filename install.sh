#!/usr/bin/env bash

set -u
set -o pipefail

APP_NAME="nft-forward"
SCRIPT_VERSION="v1.3"
SHORTCUT_NAME="nf"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/DarkJimiHole/easynftables/main/install.sh"
SHORTCUT_BIN="/usr/local/bin/${SHORTCUT_NAME}"
SHORTCUT_SBIN="/usr/local/sbin/${SHORTCUT_NAME}"
LEGACY_SHORTCUT_BIN="/usr/local/bin/${APP_NAME}"
LEGACY_SHORTCUT_SBIN="/usr/local/sbin/${APP_NAME}"

APP_DIR="/etc/${APP_NAME}"
RULES_FILE="${APP_DIR}/forwards.db"
CONFIG_FILE="${APP_DIR}/config.env"
BACKUP_DIR="${APP_DIR}/backup"
ORIGINAL_NFT_CONF_BACKUP="${BACKUP_DIR}/nftables.conf.before-${APP_NAME}"
SYSCTL_FILE="/etc/sysctl.d/99-${APP_NAME}.conf"
NFT_CONF="/etc/nftables.conf"

RELAY_LAN_IP=""
NFT_CMD=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="\033[0m"
  C_RED="\033[31m"
  C_GREEN="\033[32m"
  C_YELLOW="\033[33m"
  C_BLUE="\033[34m"
  C_CYAN="\033[36m"
  C_WHITE="\033[37m"
  C_BOLD="\033[1m"
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
  C_WHITE=""
  C_BOLD=""
fi

color() {
  local c="$1"
  shift
  printf "%b%s%b" "$c" "$*" "$C_RESET"
}

print_tagged() {
  local stream="$1"
  local c="$2"
  local tag="$3"
  shift 3

  if [ "$stream" = "stderr" ]; then
    printf "%b[%s]%b %s\n" "$c" "$tag" "$C_RESET" "$*" >&2
  else
    printf "%b[%s]%b %s\n" "$c" "$tag" "$C_RESET" "$*"
  fi
}

echo_info() {
  print_tagged "stdout" "$C_BLUE" "INFO" "$*"
}

echo_ok() {
  print_tagged "stdout" "$C_GREEN" "OK" "$*"
}

echo_warn() {
  print_tagged "stdout" "$C_YELLOW" "WARN" "$*"
}

echo_err() {
  print_tagged "stderr" "$C_RED" "ERROR" "$*"
}

prompt_input() {
  printf "%b[%s]%b %s" "$C_CYAN" "INPUT" "$C_RESET" "$*" >&2
  IFS= read -r REPLY
}

pause_for_menu() {
  echo ""
  prompt_input "按回车返回主菜单..." || true
}

print_section() {
  local title="$1"
  printf "\n%b[%s]%b\n" "$C_GREEN" "$title" "$C_RESET"
}

print_menu_item() {
  local key="$1"
  local label="$2"
  printf "%b%s%b.%b%s%b\n" "$C_CYAN" "$key" "$C_RESET" "$C_WHITE" "$label" "$C_RESET"
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s\n" "$value"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

download_file() {
  local url="$1"
  local output="$2"

  if have_cmd curl; then
    curl -fsSL "$url" -o "$output"
    return $?
  fi

  if have_cmd wget; then
    wget -qO "$output" "$url"
    return $?
  fi

  return 1
}

ensure_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo_err "请使用 root 或 sudo 运行该脚本。"
    exit 1
  fi
}

ensure_storage() {
  mkdir -p "${APP_DIR}" "${BACKUP_DIR}"
  touch "${RULES_FILE}"
  chmod 700 "${APP_DIR}" "${BACKUP_DIR}"
  chmod 600 "${RULES_FILE}"
}

check_debian_like() {
  if [ ! -f /etc/os-release ]; then
    return 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" = "debian" ]; then
    return 0
  fi
  if [[ "${ID_LIKE:-}" == *"debian"* ]]; then
    return 0
  fi
  return 1
}

resolve_nft_cmd() {
  local candidate=""

  if [ -n "${NFT_CMD}" ] && [ -x "${NFT_CMD}" ]; then
    return 0
  fi

  if candidate="$(command -v nft 2>/dev/null)"; then
    NFT_CMD="$candidate"
    return 0
  fi

  for candidate in /usr/sbin/nft /sbin/nft /usr/bin/nft /bin/nft; do
    if [ -x "$candidate" ]; then
      NFT_CMD="$candidate"
      return 0
    fi
  done

  NFT_CMD=""
  return 1
}

normalize_port() {
  local raw="$1"
  local value

  raw="$(trim_value "$raw")"
  [[ "$raw" =~ ^[0-9]{1,5}$ ]] || return 1

  value=$((10#$raw))
  if [ "$value" -lt 1000 ] || [ "$value" -gt 65535 ]; then
    return 1
  fi

  printf "%d\n" "$value"
}

is_valid_port() {
  normalize_port "$1" >/dev/null 2>&1
}

is_valid_ipv4() {
  local ip="$1"
  local part
  local part_num
  local IFS='.'

  ip="$(trim_value "$ip")"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  read -r -a parts <<< "$ip"
  [ "${#parts[@]}" -eq 4 ] || return 1

  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
    part_num=$((10#$part))
    if [ "$part_num" -lt 0 ] || [ "$part_num" -gt 255 ]; then
      return 1
    fi
  done

  [ "$ip" != "0.0.0.0" ] || return 1
  [ "$ip" != "255.255.255.255" ] || return 1
  return 0
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-no}"
  local answer=""

  while true; do
    if ! prompt_input "$prompt"; then
      echo ""
      return 1
    fi
    answer="$(trim_value "$REPLY")"
    answer="${answer,,}"

    if [ -z "$answer" ]; then
      if [ "$default" = "yes" ]; then
        return 0
      fi
      return 1
    fi

    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo_err "请输入 y/yes 或 n/no。" ;;
    esac
  done
}

prompt_port() {
  local prompt="$1"
  local default="${2:-}"
  local input=""
  local normalized=""

  while true; do
    if [ -n "$default" ]; then
      prompt_input "${prompt} [${default}]: " || return 1
      input="$(trim_value "$REPLY")"
      if [ -z "$input" ]; then
        input="$default"
      fi
    else
      prompt_input "${prompt}: " || return 1
      input="$(trim_value "$REPLY")"
    fi

    if normalized="$(normalize_port "$input" 2>/dev/null)"; then
      printf "%s\n" "$normalized"
      return 0
    fi

    echo_err "端口非法：必须是 1000-65535 之间的数字（例如 10086）。"
  done
}

prompt_ipv4() {
  local prompt="$1"
  local default="${2:-}"
  local input=""

  while true; do
    if [ -n "$default" ]; then
      prompt_input "${prompt} [${default}]: " || return 1
      input="$(trim_value "$REPLY")"
      if [ -z "$input" ]; then
        input="$default"
      fi
    else
      prompt_input "${prompt}: " || return 1
      input="$(trim_value "$REPLY")"
    fi

    if is_valid_ipv4 "$input"; then
      printf "%s\n" "$input"
      return 0
    fi

    echo_err "IP 非法：请输入规范 IPv4 地址（示例: 10.100.1.20）。"
  done
}

normalize_rule_note() {
  local note="$1"

  note="${note//$'\r'/ }"
  note="${note//$'\n'/ }"
  note="${note//$'\t'/ }"
  note="${note//|//}"

  while [[ "$note" == *"  "* ]]; do
    note="${note//  / }"
  done

  note="$(trim_value "$note")"
  printf "%s\n" "$note"
}

prompt_rule_note() {
  local prompt="$1"
  local default="${2:-}"
  local input=""
  local normalized=""

  while true; do
    if [ -n "$default" ]; then
      prompt_input "${prompt} [${default}]: " || return 1
      input="$REPLY"
      if [ "$(trim_value "$input")" = "-" ]; then
        printf "\n"
        return 0
      fi
      if [ -z "$(trim_value "$input")" ]; then
        input="$default"
      fi
    else
      prompt_input "${prompt}: " || return 1
      input="$REPLY"
    fi

    normalized="$(normalize_rule_note "$input")"
    if [ "${#normalized}" -le 80 ]; then
      printf "%s\n" "$normalized"
      return 0
    fi

    echo_err "备注过长：请控制在 80 个字符以内。"
  done
}

load_config() {
  RELAY_LAN_IP=""
  if [ -f "${CONFIG_FILE}" ]; then
    RELAY_LAN_IP="$(awk -F'=' '/^RELAY_LAN_IP=/{print $2; exit}' "${CONFIG_FILE}" | tr -d '[:space:]')"
  fi

  if [ -n "$RELAY_LAN_IP" ] && ! is_valid_ipv4 "$RELAY_LAN_IP"; then
    echo_warn "检测到已保存的本机 PO0 内网 IP 非法，已忽略。"
    RELAY_LAN_IP=""
  fi
}

save_config() {
  printf "RELAY_LAN_IP=%s\n" "$RELAY_LAN_IP" > "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
}

ensure_relay_lan_ip() {
  load_config
  if [ -z "$RELAY_LAN_IP" ]; then
    RELAY_LAN_IP="$(prompt_ipv4 "请输入本机 PO0 内网 IP（用于 SNAT，通常就是本机内网/专线 IP）")" || return 1
    save_config
    echo_ok "本机 PO0 内网 IP 已保存: ${RELAY_LAN_IP}"
  fi
}

next_rule_id() {
  if [ ! -s "${RULES_FILE}" ]; then
    echo "1"
    return 0
  fi

  awk -F'|' '
    BEGIN { max = 0 }
    $1 ~ /^[0-9]+$/ { if ($1 > max) max = $1 }
    END { print max + 1 }
  ' "${RULES_FILE}"
}

read_rules() {
  RULE_IDS=()
  RULE_IN_PORTS=()
  RULE_DEST_IPS=()
  RULE_DEST_PORTS=()
  RULE_REMARKS=()

  while IFS='|' read -r id in_port dest_ip dest_port remark; do
    [ -n "$id" ] || continue
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    in_port="$(normalize_port "$in_port" 2>/dev/null || true)"
    dest_port="$(normalize_port "$dest_port" 2>/dev/null || true)"
    remark="$(normalize_rule_note "${remark:-}")"
    [ -n "$in_port" ] || continue
    [ -n "$dest_port" ] || continue
    is_valid_ipv4 "$dest_ip" || continue

    RULE_IDS+=("$id")
    RULE_IN_PORTS+=("$in_port")
    RULE_DEST_IPS+=("$dest_ip")
    RULE_DEST_PORTS+=("$dest_port")
    RULE_REMARKS+=("$remark")
  done < "${RULES_FILE}"
}

port_exists() {
  local target_port="$1"
  local exclude_id="${2:-}"
  local id in_port _dest_ip _dest_port _remark normalized_in

  while IFS='|' read -r id in_port _dest_ip _dest_port _remark; do
    [ -n "$id" ] || continue
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    normalized_in="$(normalize_port "$in_port" 2>/dev/null || true)"
    [ -n "$normalized_in" ] || continue

    if [ "$normalized_in" = "$target_port" ] && [ "$id" != "$exclude_id" ]; then
      return 0
    fi
  done < "${RULES_FILE}"

  return 1
}

build_dest_ip_var_set() {
  local count="${#RULE_IDS[@]}"
  local seen=" "
  local output=""
  local i
  local dest_ip=""
  local var_name=""

  if [ "$count" -eq 0 ]; then
    printf "%s" "$output"
    return 0
  fi

  if [ "$count" -eq 1 ]; then
    printf "\$DEST_IP"
    return 0
  fi

  for i in "${!RULE_IDS[@]}"; do
    dest_ip="${RULE_DEST_IPS[$i]}"
    if [[ "$seen" == *" ${dest_ip} "* ]]; then
      continue
    fi
    seen="${seen}${dest_ip} "
    var_name="\$DEST_IP_$((i + 1))"
    if [ -z "$output" ]; then
      output="$var_name"
    else
      output="${output}, ${var_name}"
    fi
  done

  printf "%s" "$output"
}

render_nftables_conf() {
  local output_file="$1"
  local ip_var_set=""
  local rule_count=0
  local i

  read_rules
  rule_count="${#RULE_IDS[@]}"
  ip_var_set="$(build_dest_ip_var_set)"

  {
    echo "#!/usr/sbin/nft -f"
    echo "# ======================================================="
    echo "# 变量定义区 (由 ${SHORTCUT_NAME} 自动生成)"
    echo "# ======================================================="
    if [ "$rule_count" -eq 1 ]; then
      if [ -n "${RULE_REMARKS[0]}" ]; then
        echo "# 备注: ${RULE_REMARKS[0]}"
      fi
      echo "define DEST_IP       = ${RULE_DEST_IPS[0]}"
      echo "define DEST_PORT_OUT = ${RULE_DEST_PORTS[0]}"
      echo "define RELAY_PORT_IN = ${RULE_IN_PORTS[0]}"
      echo "define RELAY_LAN_IP  = ${RELAY_LAN_IP}"
    elif [ "$rule_count" -gt 1 ]; then
      echo "# --- 公共配置 ---"
      echo "define RELAY_LAN_IP  = ${RELAY_LAN_IP}"
      for i in "${!RULE_IDS[@]}"; do
        echo ""
        echo "# --- 线路 $((i + 1)) 配置 ---"
        if [ -n "${RULE_REMARKS[$i]}" ]; then
          echo "# 备注: ${RULE_REMARKS[$i]}"
        fi
        echo "define PORT_IN_$((i + 1))   = ${RULE_IN_PORTS[$i]}"
        echo "define DEST_IP_$((i + 1))   = ${RULE_DEST_IPS[$i]}"
        echo "define DEST_PORT_$((i + 1)) = ${RULE_DEST_PORTS[$i]}"
      done
    else
      echo "# 当前没有转发规则"
    fi
    echo "# ======================================================="
    echo "# 清空旧规则"
    echo "flush ruleset"
    echo ""
    echo "# --- 核心转发逻辑 (NAT表) ---"
    echo "table ip nat {"
    echo "    chain prerouting {"
    echo "        type nat hook prerouting priority dstnat; policy accept;"
    if [ "$rule_count" -eq 1 ]; then
      if [ -n "${RULE_REMARKS[0]}" ]; then
        echo "        # 备注: ${RULE_REMARKS[0]}"
      fi
      echo "        # 同时转发 TCP 和 UDP"
      echo "        meta l4proto { tcp, udp } th dport \$RELAY_PORT_IN dnat to \$DEST_IP:\$DEST_PORT_OUT"
    else
      for i in "${!RULE_IDS[@]}"; do
        if [ -n "${RULE_REMARKS[$i]}" ]; then
          echo "        # 备注: ${RULE_REMARKS[$i]}"
        fi
        echo "        # [线路 $((i + 1))] 流量进入端口$((i + 1)) -> 转给落地机$((i + 1))"
        echo "        meta l4proto { tcp, udp } th dport \$PORT_IN_$((i + 1)) dnat to \$DEST_IP_$((i + 1)):\$DEST_PORT_$((i + 1))"
      done
    fi
    echo "    }"
    echo ""
    echo "    chain postrouting {"
    echo "        type nat hook postrouting priority srcnat; policy accept;"
    if [ "$rule_count" -eq 1 ]; then
      if [ -n "${RULE_REMARKS[0]}" ]; then
        echo "        # 备注: ${RULE_REMARKS[0]}"
      fi
      echo "        # 仅匹配发往落地机的流量，执行 SNAT"
      echo "        ip daddr \$DEST_IP meta l4proto { tcp, udp } th dport \$DEST_PORT_OUT snat to \$RELAY_LAN_IP"
    else
      for i in "${!RULE_IDS[@]}"; do
        if [ -n "${RULE_REMARKS[$i]}" ]; then
          echo "        # 备注: ${RULE_REMARKS[$i]}"
        fi
        echo "        # [线路 $((i + 1))] 发往落地机$((i + 1))的流量 -> 改源IP为内网IP"
        echo "        ip daddr \$DEST_IP_$((i + 1)) meta l4proto { tcp, udp } th dport \$DEST_PORT_$((i + 1)) snat to \$RELAY_LAN_IP"
      done
    fi
    echo "    }"
    echo "}"
    echo ""
    echo "# --- 性能优化逻辑 (Filter表) ---"
    echo "table ip filter {"
    echo "    chain forward {"
    echo "        type filter hook forward priority 0; policy accept;"
    if [ "$rule_count" -eq 1 ]; then
      echo "        ip daddr \$DEST_IP tcp flags syn tcp option maxseg size set 1452"
    elif [ -n "$ip_var_set" ]; then
      echo "        ip daddr { ${ip_var_set} } tcp flags syn tcp option maxseg size set 1452"
    fi
    echo "    }"
    echo "}"
  } > "${output_file}"
}

backup_original_nft_conf() {
  if [ -f "${NFT_CONF}" ] && [ ! -f "${ORIGINAL_NFT_CONF_BACKUP}" ]; then
    cp -a "${NFT_CONF}" "${ORIGINAL_NFT_CONF_BACKUP}"
  fi
}

install_nftables_pkg_if_needed() {
  if resolve_nft_cmd; then
    echo_info "检测到已安装 nftables: ${NFT_CMD}"
    return 0
  fi

  if ! have_cmd apt-get; then
    echo_err "未安装 nftables，且系统没有 apt-get，无法自动安装。"
    return 1
  fi

  echo_info "当前未安装 nftables，开始安装..."
  echo_info "将使用 Debian 默认路径安装（例如 /usr/sbin/nft 与 /etc/nftables.conf）。"
  apt-get update || {
    echo_err "apt-get update 失败。"
    return 1
  }
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    nftables || {
    echo_err "nftables 安装失败。"
    return 1
  }

  if ! resolve_nft_cmd; then
    echo_err "安装完成后仍无法找到 nftables 命令，请手动检查系统。"
    return 1
  fi

  echo_ok "nftables 安装完成。"
  return 0
}

enable_ip_forward() {
  printf "net.ipv4.ip_forward=1\n" > "${SYSCTL_FILE}"
  chmod 644 "${SYSCTL_FILE}"

  if have_cmd sysctl; then
    if sysctl --system >/dev/null 2>&1; then
      echo_ok "已启用 IPv4 转发 (net.ipv4.ip_forward=1)。"
    else
      echo_warn "sysctl --system 执行失败，请手动检查内核参数。"
    fi
  else
    echo_warn "系统缺少 sysctl，已写入配置文件但未即时生效。"
  fi
}

apply_rules() {
  local tmp_conf=""
  local rollback_conf=""

  load_config
  if [ -s "${RULES_FILE}" ] && [ -z "$RELAY_LAN_IP" ]; then
    echo_err "存在转发规则，但本机 PO0 内网 IP 未设置，无法应用。"
    return 1
  fi

  if ! resolve_nft_cmd; then
    echo_warn "未安装 nftables。"
    if prompt_yes_no "是否现在自动安装 nftables? [Y/n]: " "yes"; then
      install_nftables_pkg_if_needed || return 1
      enable_ip_forward
    else
      echo_warn "已取消自动安装。请先执行菜单 1.安装nftables。"
      return 1
    fi
  fi

  tmp_conf="$(mktemp /tmp/nft-forward.conf.XXXXXX)"
  rollback_conf="$(mktemp /tmp/nft-forward.rollback.XXXXXX)"

  render_nftables_conf "${tmp_conf}"

  if ! "${NFT_CMD}" -c -f "${tmp_conf}" >/dev/null 2>&1; then
    echo_err "规则语法检查失败，未应用。报错如下："
    "${NFT_CMD}" -c -f "${tmp_conf}" 2>&1 | sed "s/^/  /"
    rm -f "${tmp_conf}" "${rollback_conf}"
    return 1
  fi

  if [ -f "${NFT_CONF}" ]; then
    cp -a "${NFT_CONF}" "${rollback_conf}"
  else
    : > "${rollback_conf}"
  fi

  install -m 600 "${tmp_conf}" "${NFT_CONF}"

  if ! "${NFT_CMD}" -f "${NFT_CONF}" >/dev/null 2>&1; then
    echo_err "规则应用失败，正在回滚。"
    if [ -s "${rollback_conf}" ]; then
      install -m 600 "${rollback_conf}" "${NFT_CONF}"
      "${NFT_CMD}" -f "${NFT_CONF}" >/dev/null 2>&1 || true
    fi
    rm -f "${tmp_conf}" "${rollback_conf}"
    return 1
  fi

  if have_cmd systemctl; then
    systemctl enable nftables >/dev/null 2>&1 || true
    systemctl restart nftables >/dev/null 2>&1 || true
  fi

  rm -f "${tmp_conf}" "${rollback_conf}"
  echo_ok "nftables 规则已应用并尝试重启服务。"
  return 0
}

self_install() {
  local self=""
  local tmp_file=""

  self="$(readlink -f "$0" 2>/dev/null || echo "$0")"

  case "$self" in
    "$SHORTCUT_BIN"|"$SHORTCUT_SBIN")
      return 0
      ;;
  esac

  if [ ! -f "$self" ] || [ ! -r "$self" ]; then
    tmp_file="$(mktemp /tmp/easynftables.install.XXXXXX)"
    if ! download_file "$SCRIPT_RAW_URL" "$tmp_file"; then
      rm -f "$tmp_file"
      echo_warn "当前脚本源不可读，且无法从仓库下载 install.sh，已跳过快捷命令安装。"
      return 0
    fi
    self="$tmp_file"
  fi

  install -d -m 0755 "$(dirname "$SHORTCUT_BIN")"
  install -d -m 0755 "$(dirname "$SHORTCUT_SBIN")"
  install -m 0755 "$self" "$SHORTCUT_BIN"
  install -m 0755 "$self" "$SHORTCUT_SBIN"

  rm -f "${LEGACY_SHORTCUT_BIN}" "${LEGACY_SHORTCUT_SBIN}" 2>/dev/null || true
  rm -f "$tmp_file"
}

status_line() {
  local service_state relay_state

  if have_cmd systemctl; then
    if systemctl is-active --quiet nftables; then
      service_state="$(color "$C_GREEN" "running")"
    elif systemctl is-enabled --quiet nftables >/dev/null 2>&1; then
      service_state="$(color "$C_YELLOW" "enabled(not running)")"
    else
      service_state="$(color "$C_YELLOW" "stopped")"
    fi
  else
    service_state="$(color "$C_YELLOW" "unknown")"
  fi

  load_config
  if [ -n "$RELAY_LAN_IP" ]; then
    relay_state="$(color "$C_GREEN" "$RELAY_LAN_IP")"
  else
    relay_state="$(color "$C_YELLOW" "未设置")"
  fi

  echo "$(color "$C_BOLD" "nftables 服务:") ${service_state}"
  echo "$(color "$C_BOLD" "本机 PO0 内网 IP:") ${relay_state}"
}

print_menu() {
  echo ""
  print_menu_item "1" "安装nftables"
  print_menu_item "2" "查看转发"
  print_menu_item "3" "添加转发"
  print_menu_item "4" "修改转发"
  print_menu_item "5" "删除转发"
  print_menu_item "6" "卸载"
  print_menu_item "0" "退出脚本"
}

print_header() {
  local width=58
  local divider left_text right_label right_value padding

  divider="$(printf '%*s' "$width" '' | tr ' ' '-')"
  left_text="easy nftables script ${SCRIPT_VERSION}"
  right_label="Command: "
  right_value="${SHORTCUT_NAME}"
  padding=$(( width - ${#left_text} - ${#right_label} - ${#right_value} ))
  if [ "$padding" -lt 1 ]; then
    padding=1
  fi

  echo ""
  echo "$(color "$C_CYAN" "  ______                 _   _ ______ _______")"
  echo "$(color "$C_CYAN" " |  ____|               | \ | |  ____|__   __|")"
  echo "$(color "$C_CYAN" " | |__   __ _ ___ _   _ |  \| | |__     | |")"
  echo "$(color "$C_CYAN" " |  __| / _\` / __| | | || . \` |  __|    | |")"
  echo "$(color "$C_CYAN" " | |___| (_| \__ \ |_| || |\  | |       | |")"
  echo "$(color "$C_CYAN" " |______\__,_|___/\__, ||_| \_|_|       |_|")"
  echo "$(color "$C_CYAN" "                   __/ |")"
  echo "$(color "$C_CYAN" "                  |___/")"
  echo ""
  echo "$(color "$C_BLUE" "$divider")"
  printf "%b%s%b%*s%b%s%b%b%s%b\n" \
    "$C_BLUE" "$left_text" "$C_RESET" \
    "$padding" "" \
    "$C_BLUE" "$right_label" "$C_RESET" \
    "$C_RED" "$right_value" "$C_RESET"
  echo "$(color "$C_BLUE" "$divider")"
}

install_nftables() {
  print_section "安装/初始化 nftables"

  if ! check_debian_like; then
    echo_warn "当前系统看起来不是 Debian 系，脚本仍可尝试继续。"
    if ! prompt_yes_no "是否继续执行? [y/N]: " "no"; then
      echo_warn "已取消。"
      return 1
    fi
  fi

  ensure_storage
  backup_original_nft_conf

  install_nftables_pkg_if_needed || return 1
  enable_ip_forward

  if have_cmd systemctl; then
    systemctl enable nftables >/dev/null 2>&1 || true
    systemctl restart nftables >/dev/null 2>&1 || true
    echo_ok "nftables 服务已尝试启用并重启。"
  fi

  load_config
  if [ -z "$RELAY_LAN_IP" ]; then
    if prompt_yes_no "尚未设置本机 PO0 内网 IP（用于 SNAT 源地址），是否现在设置? [Y/n]: " "yes"; then
      ensure_relay_lan_ip || return 1
    else
      echo_warn "暂未设置本机 PO0 内网 IP，添加转发时会再次要求输入。"
    fi
  else
    echo_info "当前本机 PO0 内网 IP: ${RELAY_LAN_IP}"
  fi

  self_install
  apply_rules || return 1
  echo_ok "安装/初始化完成。"
  return 0
}

show_forwards() {
  local id in_port dest_ip dest_port remark

  ensure_storage
  load_config

  print_section "转发列表"

  if [ ! -s "${RULES_FILE}" ]; then
    echo_info "暂无转发规则。"
    return 0
  fi

  printf "%-6s %-14s %-18s %-14s %s\n" "ID" "IN_PORT" "DEST_IP" "DEST_PORT" "REMARK"
  printf "%-6s %-14s %-18s %-14s %s\n" "------" "--------------" "------------------" "--------------" "------------------------------"

  while IFS='|' read -r id in_port dest_ip dest_port remark; do
    [ -n "$id" ] || continue
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    in_port="$(normalize_port "$in_port" 2>/dev/null || true)"
    dest_port="$(normalize_port "$dest_port" 2>/dev/null || true)"
    remark="$(normalize_rule_note "${remark:-}")"
    [ -n "$in_port" ] || continue
    [ -n "$dest_port" ] || continue
    is_valid_ipv4 "$dest_ip" || continue
    printf "%-6s %-14s %-18s %-14s %s\n" "$id" "$in_port" "$dest_ip" "$dest_port" "${remark:--}"
  done < <(sort -t'|' -k1,1n "${RULES_FILE}")
}

add_forward() {
  local new_id in_port dest_ip dest_port remark
  local rollback_file

  print_section "添加转发"
  ensure_storage
  ensure_relay_lan_ip || return 1

  while true; do
    in_port="$(prompt_port "请输入中转入口端口 (1000-65535)")" || return 1
    if port_exists "$in_port"; then
      echo_err "入口端口 ${in_port} 已存在，请换一个端口。"
      continue
    fi
    break
  done

  dest_ip="$(prompt_ipv4 "请输入落地机公网 IP")" || return 1
  dest_port="$(prompt_port "请输入落地机服务端口 (1000-65535)")" || return 1
  remark="$(prompt_rule_note "请输入备注（可留空）")" || return 1

  new_id="$(next_rule_id)"
  printf "%s|%s|%s|%s|%s\n" "$new_id" "$in_port" "$dest_ip" "$dest_port" "$remark" >> "${RULES_FILE}"

  if apply_rules; then
    echo_ok "新增成功，规则 ID: ${new_id}"
    return 0
  fi

  rollback_file="$(mktemp /tmp/nft-forward.rules.rollback.XXXXXX)"
  awk -F'|' -v id="$new_id" '$1 != id { print $0 }' "${RULES_FILE}" > "${rollback_file}"
  mv "${rollback_file}" "${RULES_FILE}"
  echo_err "新增失败，已回滚。"
  return 1
}

find_rule_by_id() {
  local target_id="$1"

  awk -F'|' -v id="$target_id" '
    $1 == id {
      print $1 "|" $2 "|" $3 "|" $4 "|" $5
      found = 1
      exit
    }
    END {
      if (!found) exit 1
    }
  ' "${RULES_FILE}"
}

modify_forward() {
  local target_id line
  local cur_id cur_in_port cur_dest_ip cur_dest_port cur_remark
  local new_in_port new_dest_ip new_dest_port new_remark
  local old_rules_backup old_config_backup tmp_rules
  local new_relay_ip

  print_section "修改转发"
  ensure_storage
  load_config
  show_forwards

  if [ ! -s "${RULES_FILE}" ]; then
    return 0
  fi

  prompt_input "请输入要修改的规则 ID: " || return 1
  target_id="$(trim_value "$REPLY")"
  if [[ ! "$target_id" =~ ^[0-9]+$ ]]; then
    echo_err "ID 非法。"
    return 1
  fi

  if ! line="$(find_rule_by_id "$target_id")"; then
    echo_err "未找到 ID=${target_id} 的规则。"
    return 1
  fi

  IFS='|' read -r cur_id cur_in_port cur_dest_ip cur_dest_port cur_remark <<< "$line"
  cur_in_port="$(normalize_port "$cur_in_port" 2>/dev/null || echo "$cur_in_port")"
  cur_dest_port="$(normalize_port "$cur_dest_port" 2>/dev/null || echo "$cur_dest_port")"
  cur_remark="$(normalize_rule_note "${cur_remark:-}")"

  while true; do
    new_in_port="$(prompt_port "新的中转入口端口" "$cur_in_port")" || return 1
    if port_exists "$new_in_port" "$cur_id"; then
      echo_err "入口端口 ${new_in_port} 与其他规则冲突。"
      continue
    fi
    break
  done

  new_dest_ip="$(prompt_ipv4 "新的落地机公网 IP" "$cur_dest_ip")" || return 1
  new_dest_port="$(prompt_port "新的落地机服务端口" "$cur_dest_port")" || return 1
  new_remark="$(prompt_rule_note "新的备注（可留空，输入 - 可清空）" "$cur_remark")" || return 1

  if [ -n "$RELAY_LAN_IP" ]; then
    echo_info "当前本机 PO0 内网 IP: ${RELAY_LAN_IP}"
  else
    echo_warn "当前本机 PO0 内网 IP: 未设置"
  fi

  new_relay_ip="$RELAY_LAN_IP"
  if prompt_yes_no "是否同时修改本机 PO0 内网 IP? [y/N]: " "no"; then
    new_relay_ip="$(prompt_ipv4 "新的本机 PO0 内网 IP" "${RELAY_LAN_IP:-}")" || return 1
  fi

  old_rules_backup="$(mktemp /tmp/nft-forward.rules.backup.XXXXXX)"
  old_config_backup="$(mktemp /tmp/nft-forward.config.backup.XXXXXX)"
  cp -a "${RULES_FILE}" "${old_rules_backup}"
  if [ -f "${CONFIG_FILE}" ]; then
    cp -a "${CONFIG_FILE}" "${old_config_backup}"
  else
    : > "${old_config_backup}"
  fi

  tmp_rules="$(mktemp /tmp/nft-forward.rules.new.XXXXXX)"
  awk -F'|' -v OFS='|' \
    -v id="$cur_id" -v in_port="$new_in_port" -v dest_ip="$new_dest_ip" -v dest_port="$new_dest_port" -v remark="$new_remark" '
      $1 == id { print $1, in_port, dest_ip, dest_port, remark; next }
      { print $0 }
    ' "${RULES_FILE}" > "${tmp_rules}"
  mv "${tmp_rules}" "${RULES_FILE}"

  RELAY_LAN_IP="$new_relay_ip"
  save_config

  if apply_rules; then
    echo_ok "修改成功。"
    rm -f "${old_rules_backup}" "${old_config_backup}"
    return 0
  fi

  cp -a "${old_rules_backup}" "${RULES_FILE}"
  if [ -s "${old_config_backup}" ]; then
    cp -a "${old_config_backup}" "${CONFIG_FILE}"
  else
    rm -f "${CONFIG_FILE}"
  fi
  rm -f "${old_rules_backup}" "${old_config_backup}"
  echo_err "修改失败，已回滚。"
  return 1
}

delete_forward() {
  local target_id
  local old_rules_backup old_config_backup tmp_rules

  print_section "删除转发"
  ensure_storage
  show_forwards
  if [ ! -s "${RULES_FILE}" ]; then
    return 0
  fi

  prompt_input "请输入要删除的规则 ID: " || return 1
  target_id="$(trim_value "$REPLY")"
  if [[ ! "$target_id" =~ ^[0-9]+$ ]]; then
    echo_err "ID 非法。"
    return 1
  fi

  if ! find_rule_by_id "$target_id" >/dev/null; then
    echo_err "未找到 ID=${target_id} 的规则。"
    return 1
  fi

  if ! prompt_yes_no "确认删除 ID=${target_id}? [y/N]: " "no"; then
    echo_warn "已取消删除。"
    return 0
  fi

  old_rules_backup="$(mktemp /tmp/nft-forward.rules.backup.XXXXXX)"
  old_config_backup="$(mktemp /tmp/nft-forward.config.backup.XXXXXX)"
  cp -a "${RULES_FILE}" "${old_rules_backup}"
  if [ -f "${CONFIG_FILE}" ]; then
    cp -a "${CONFIG_FILE}" "${old_config_backup}"
  else
    : > "${old_config_backup}"
  fi

  tmp_rules="$(mktemp /tmp/nft-forward.rules.new.XXXXXX)"
  awk -F'|' -v id="$target_id" '$1 != id { print $0 }' "${RULES_FILE}" > "${tmp_rules}"
  mv "${tmp_rules}" "${RULES_FILE}"

  if apply_rules; then
    echo_ok "删除成功。"
    rm -f "${old_rules_backup}" "${old_config_backup}"
    return 0
  fi

  cp -a "${old_rules_backup}" "${RULES_FILE}"
  if [ -s "${old_config_backup}" ]; then
    cp -a "${old_config_backup}" "${CONFIG_FILE}"
  else
    rm -f "${CONFIG_FILE}"
  fi
  rm -f "${old_rules_backup}" "${old_config_backup}"
  echo_err "删除失败，已回滚。"
  return 1
}

uninstall_all() {
  print_section "卸载"

  if ! prompt_yes_no "该操作将移除转发配置和快捷命令，是否继续? [y/N]: " "no"; then
    echo_warn "已取消卸载。"
    return 0
  fi

  if have_cmd systemctl; then
    systemctl stop nftables >/dev/null 2>&1 || true
    systemctl disable nftables >/dev/null 2>&1 || true
  fi

  if [ -f "${ORIGINAL_NFT_CONF_BACKUP}" ]; then
    install -m 600 "${ORIGINAL_NFT_CONF_BACKUP}" "${NFT_CONF}"
    echo_info "已恢复安装前的 nftables.conf 备份。"
  else
    cat > "${NFT_CONF}" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
EOF
    chmod 600 "${NFT_CONF}"
    echo_info "未找到历史备份，已写入空规则配置。"
  fi

  if resolve_nft_cmd; then
    "${NFT_CMD}" -f "${NFT_CONF}" >/dev/null 2>&1 || true
  fi

  if [ -f "${SYSCTL_FILE}" ]; then
    rm -f "${SYSCTL_FILE}"
    have_cmd sysctl && sysctl --system >/dev/null 2>&1 || true
  fi

  if have_cmd apt-get; then
    if prompt_yes_no "是否同时卸载 nftables 软件包? [Y/n]: " "yes"; then
      apt-get purge -y nftables >/dev/null 2>&1 || true
      apt-get autoremove -y >/dev/null 2>&1 || true
      echo_ok "nftables 软件包已尝试卸载。"
    else
      echo_info "已跳过 nftables 软件包卸载。"
    fi
  fi

  rm -rf "${APP_DIR}"
  rm -f "${SHORTCUT_BIN}" "${SHORTCUT_SBIN}" "${LEGACY_SHORTCUT_BIN}" "${LEGACY_SHORTCUT_SBIN}"
  echo_ok "卸载完成。"
}

show_help() {
  cat <<'EOF'
用法:
  sudo bash install.sh
  sudo bash install.sh --install-self
  sudo nf
EOF
}

main_loop() {
  local choice

  while true; do
    print_header
    status_line
    print_section "主菜单"
    print_menu

    if ! prompt_input "请选择 [0-6]: "; then
      echo ""
      exit 0
    fi
    choice="$(trim_value "$REPLY")"

    case "$choice" in
      1) install_nftables ;;
      2) show_forwards ;;
      3) add_forward ;;
      4) modify_forward ;;
      5) delete_forward ;;
      6) uninstall_all ;;
      0)
        echo_ok "已退出。"
        exit 0
        ;;
      *)
        echo_err "无效选项，请输入 0-6。"
        ;;
    esac

    pause_for_menu
  done
}

main() {
  case "${1:-}" in
    --help|-h)
      show_help
      return 0
      ;;
  esac

  ensure_root
  ensure_storage

  case "${1:-}" in
    --install-self)
      self_install
      ;;
    "")
      self_install
      main_loop
      ;;
    *)
      echo_err "未知参数: $1"
      show_help
      exit 1
      ;;
  esac
}

main "$@"
