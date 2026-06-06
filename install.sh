#!/usr/bin/env bash

set -u
set -o pipefail

APP_NAME="nft-forward"
SCRIPT_VERSION="v1.4.1"
SHORTCUT_NAME="nf"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/DarkJimiHole/easynftables/main/install.sh"
REPO_RAW_BASE_URL="https://raw.githubusercontent.com/DarkJimiHole/easynftables/main"
SHORTCUT_BIN="/usr/local/bin/${SHORTCUT_NAME}"
SHORTCUT_SBIN="/usr/local/sbin/${SHORTCUT_NAME}"
LEGACY_SHORTCUT_BIN="/usr/local/bin/${APP_NAME}"
LEGACY_SHORTCUT_SBIN="/usr/local/sbin/${APP_NAME}"

APP_DIR="/etc/${APP_NAME}"
RULES_FILE="${APP_DIR}/forwards.db"
CONFIG_FILE="${APP_DIR}/config.env"
REGION_CODES_FILE="${APP_DIR}/region_whitelist.codes"
MANUAL_WHITELIST_FILE="${APP_DIR}/manual_whitelist.list"
SETS_DIR="${APP_DIR}/sets"
MANUAL_WHITELIST_NFT="${SETS_DIR}/manual_whitelist4.nft"
REGION_WHITELIST_NFT="${SETS_DIR}/region_whitelist4.nft"
BACKUP_DIR="${APP_DIR}/backup"
ORIGINAL_NFT_CONF_BACKUP="${BACKUP_DIR}/nftables.conf.before-${APP_NAME}"
SYSCTL_FILE="/etc/sysctl.d/99-${APP_NAME}.conf"
NFT_CONF="/etc/nftables.conf"
LOCK_FILE="/run/${APP_NAME}.lock"

RELAY_LAN_IP=""
WHITELIST_ENABLE=0
REGION_WHITELIST_ENABLE=0
NFT_CMD=""
AUTO_MODE=0
LOCK_HELD=0
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" >/dev/null 2>&1 && pwd -P || pwd)"

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
  prompt_input "按回车继续..." || true
}

print_section() {
  local title="$1"
  printf "\n%b[%s]%b\n" "$C_GREEN" "$title" "$C_RESET"
}

clear_screen() {
  if [ "${NO_CLEAR:-0}" = "1" ] || [ ! -t 1 ]; then
    return 0
  fi
  printf "\033[H\033[2J"
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

normalize_bool() {
  local value="${1:-0}"
  value="$(trim_value "$value")"
  case "$value" in
    1|true|TRUE|yes|YES|on|ON|enabled|ENABLED) echo "1" ;;
    *) echo "0" ;;
  esac
}

is_valid_ipv4_cidr() {
  local raw="$1"
  local ip prefix

  raw="$(trim_value "$raw")"
  if is_valid_ipv4 "$raw"; then
    return 0
  fi

  [[ "$raw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  ip="${raw%/*}"
  prefix="${raw#*/}"
  is_valid_ipv4 "$ip" || return 1
  [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]
}

po0_python() {
  if have_cmd python3; then
    python3 "$@"
  elif have_cmd python; then
    python "$@"
  else
    echo_err "missing python3/python; cannot read region whitelist data."
    return 127
  fi
}

region_tool_file() {
  if [ -f "${APP_DIR}/tools/region_tool.py" ]; then
    printf "%s\n" "${APP_DIR}/tools/region_tool.py"
    return 0
  fi
  if [ -f "${SCRIPT_DIR}/tools/region_tool.py" ]; then
    printf "%s\n" "${SCRIPT_DIR}/tools/region_tool.py"
    return 0
  fi
  return 1
}

region_data_dir() {
  if [ -d "${APP_DIR}/data/regions" ] && [ -f "${APP_DIR}/data/regions.json" ]; then
    printf "%s\n" "${APP_DIR}/data"
    return 0
  fi
  if [ -d "${SCRIPT_DIR}/data/regions" ] && [ -f "${SCRIPT_DIR}/data/regions.json" ]; then
    printf "%s\n" "${SCRIPT_DIR}/data"
    return 0
  fi
  return 1
}

region_tool() {
  local tool data_dir

  if ! tool="$(region_tool_file)"; then
    echo_err "地区白名单资源缺失: missing tools/region_tool.py. 请重新执行安装脚本以安装资源。"
    return 1
  fi
  if ! data_dir="$(region_data_dir)"; then
    echo_err "地区白名单资源缺失: missing data/regions.json or data/regions. 请重新执行安装脚本以安装资源。"
    return 1
  fi

  po0_python "$tool" --regions-json "${data_dir}/regions.json" --data-dir "$data_dir" "$@"
}

region_assets_ready() {
  [ -f "${APP_DIR}/tools/region_tool.py" ] \
    && [ -f "${APP_DIR}/data/regions.json" ] \
    && [ -d "${APP_DIR}/data/regions" ]
}

install_region_assets() {
  if region_assets_ready; then
    return 0
  fi

  if [ -f "${SCRIPT_DIR}/tools/region_tool.py" ]; then
    mkdir -p "${APP_DIR}/tools"
    cp -a "${SCRIPT_DIR}/tools/region_tool.py" "${APP_DIR}/tools/region_tool.py"
    chmod 600 "${APP_DIR}/tools/region_tool.py" 2>/dev/null || true
  fi

  if [ -f "${SCRIPT_DIR}/data/regions.json" ] && [ -d "${SCRIPT_DIR}/data/regions" ]; then
    mkdir -p "${APP_DIR}/data"
    cp -a "${SCRIPT_DIR}/data/regions.json" "${APP_DIR}/data/regions.json"
    rm -rf "${APP_DIR}/data/regions"
    cp -a "${SCRIPT_DIR}/data/regions" "${APP_DIR}/data/regions"
    chmod -R go-rwx "${APP_DIR}/data" 2>/dev/null || true
  fi

  if region_assets_ready; then
    return 0
  fi

  download_region_assets
}

download_region_assets() {
  local tmp_dir file_list rel_path

  if ! have_cmd curl && ! have_cmd wget; then
    echo_err "missing curl/wget; cannot download region whitelist assets."
    return 1
  fi

  if ! have_cmd python3 && ! have_cmd python; then
    echo_err "missing python3/python; cannot parse region whitelist metadata."
    return 1
  fi

  tmp_dir="$(mktemp -d 2>/dev/null || mktemp -d -t "${APP_NAME}.assets.XXXXXX")" || {
    echo_err "failed to create temporary directory for region whitelist assets."
    return 1
  }

  mkdir -p "${tmp_dir}/tools" "${tmp_dir}/data/regions"

  if ! download_file "${REPO_RAW_BASE_URL}/tools/region_tool.py" "${tmp_dir}/tools/region_tool.py"; then
    rm -rf "$tmp_dir"
    echo_err "failed to download tools/region_tool.py from GitHub."
    return 1
  fi

  if ! download_file "${REPO_RAW_BASE_URL}/data/regions.json" "${tmp_dir}/data/regions.json"; then
    rm -rf "$tmp_dir"
    echo_err "failed to download data/regions.json from GitHub."
    return 1
  fi

  file_list="${tmp_dir}/region_files.list"
  if ! po0_python - "${tmp_dir}/data/regions.json" >"$file_list" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    metadata = json.load(fh)

for province in metadata.get("provinces", []):
    if province.get("file"):
        print(province["file"])
    for city in province.get("cities", []):
        if city.get("file"):
            print(city["file"])
PY
  then
    rm -rf "$tmp_dir"
    echo_err "failed to parse data/regions.json."
    return 1
  fi

  while IFS= read -r rel_path; do
    [ -n "$rel_path" ] || continue
    case "$rel_path" in
      regions/*.txt) ;;
      *)
        rm -rf "$tmp_dir"
        echo_err "unsafe region file path in metadata: $rel_path"
        return 1
        ;;
    esac

    if ! download_file "${REPO_RAW_BASE_URL}/data/${rel_path}" "${tmp_dir}/data/${rel_path}"; then
      rm -rf "$tmp_dir"
      echo_err "failed to download data/${rel_path} from GitHub."
      return 1
    fi
  done <"$file_list"

  mkdir -p "${APP_DIR}/tools" "${APP_DIR}/data"
  cp -a "${tmp_dir}/tools/region_tool.py" "${APP_DIR}/tools/region_tool.py"
  cp -a "${tmp_dir}/data/regions.json" "${APP_DIR}/data/regions.json"
  rm -rf "${APP_DIR}/data/regions"
  cp -a "${tmp_dir}/data/regions" "${APP_DIR}/data/regions"
  chmod 600 "${APP_DIR}/tools/region_tool.py" 2>/dev/null || true
  chmod -R go-rwx "${APP_DIR}/data" 2>/dev/null || true
  rm -rf "$tmp_dir"

  echo_ok "地区白名单资源已安装。"
}

detect_ssh_client_ip() {
  if [ -n "${SSH_CONNECTION:-}" ]; then
    printf "%s\n" "$SSH_CONNECTION" | awk '{print $1}'
    return 0
  fi
  if [ -n "${SSH_CLIENT:-}" ]; then
    printf "%s\n" "$SSH_CLIENT" | awk '{print $1}'
    return 0
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
  mkdir -p "${APP_DIR}" "${BACKUP_DIR}" "${SETS_DIR}"
  touch "${RULES_FILE}" "${REGION_CODES_FILE}" "${MANUAL_WHITELIST_FILE}"
  chmod 700 "${APP_DIR}" "${BACKUP_DIR}" "${SETS_DIR}"
  chmod 600 "${RULES_FILE}" "${REGION_CODES_FILE}" "${MANUAL_WHITELIST_FILE}"
}

acquire_lock() {
  if ! have_cmd flock; then
    return 0
  fi

  mkdir -p "$(dirname "${LOCK_FILE}")"
  exec 200>"${LOCK_FILE}"
  if ! flock -w 30 200; then
    echo_err "failed to acquire lock: ${LOCK_FILE}"
    return 1
  fi
  LOCK_HELD=1
}

release_lock() {
  if [ "${LOCK_HELD}" = "1" ] && have_cmd flock; then
    flock -u 200 || true
    LOCK_HELD=0
  fi
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
  WHITELIST_ENABLE=0
  REGION_WHITELIST_ENABLE=0
  if [ -f "${CONFIG_FILE}" ]; then
    RELAY_LAN_IP="$(awk -F'=' '/^RELAY_LAN_IP=/{print $2; exit}' "${CONFIG_FILE}" | tr -d '[:space:]')"
    WHITELIST_ENABLE="$(normalize_bool "$(awk -F'=' '/^WHITELIST_ENABLE=/{print $2; exit}' "${CONFIG_FILE}")")"
    REGION_WHITELIST_ENABLE="$(normalize_bool "$(awk -F'=' '/^REGION_WHITELIST_ENABLE=/{print $2; exit}' "${CONFIG_FILE}")")"
  fi

  if [ -n "$RELAY_LAN_IP" ] && ! is_valid_ipv4 "$RELAY_LAN_IP"; then
    echo_warn "检测到已保存的本机 SNAT IP 非法，已忽略。"
    RELAY_LAN_IP=""
  fi
}

save_config() {
  {
    printf "RELAY_LAN_IP=%s\n" "$RELAY_LAN_IP"
    printf "WHITELIST_ENABLE=%s\n" "${WHITELIST_ENABLE:-0}"
    printf "REGION_WHITELIST_ENABLE=%s\n" "${REGION_WHITELIST_ENABLE:-0}"
  } > "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
}

ensure_relay_lan_ip() {
  load_config
  if [ -z "$RELAY_LAN_IP" ]; then
    RELAY_LAN_IP="$(prompt_ipv4 "请输入本机用于 SNAT 的 IP（通常填写内网/专线 IP；如果没有内网 IP，请填写本机公网 IP）")" || return 1
    save_config
    echo_ok "本机 SNAT IP 已保存: ${RELAY_LAN_IP}"
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

split_user_list() {
  local input="$1"
  input="${input//,/ }"
  input="${input//，/ }"
  input="${input//、/ }"
  printf "%s\n" "$input" | awk '{ for (i = 1; i <= NF; i++) print $i }'
}

file_item_count() {
  local file="$1"
  awk '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 != "" && substr($0, 1, 1) != "#") c++
    }
    END { print c + 0 }
  ' "$file"
}

manual_whitelist_count() {
  file_item_count "${MANUAL_WHITELIST_FILE}"
}

region_whitelist_count() {
  file_item_count "${REGION_CODES_FILE}"
}

whitelist_has_allowed_sources() {
  if [ "$(manual_whitelist_count)" -gt 0 ]; then
    return 0
  fi
  if [ "${REGION_WHITELIST_ENABLE:-0}" = "1" ] && [ "$(region_whitelist_count)" -gt 0 ]; then
    return 0
  fi
  return 1
}

ensure_whitelist_safe() {
  if [ "${WHITELIST_ENABLE:-0}" != "1" ]; then
    return 0
  fi

  if whitelist_has_allowed_sources; then
    return 0
  fi

  echo_err "白名单限制已开启，但手动白名单为空，且没有启用任何地区来源。已拒绝应用规则以避免锁定 VPS。"
  return 1
}

append_unique_line() {
  local file="$1"
  local value="$2"

  touch "$file"
  if grep -Fxq -- "$value" "$file" 2>/dev/null; then
    return 0
  fi
  printf "%s\n" "$value" >> "$file"
}

add_manual_whitelist_entry() {
  local entry="$1"

  entry="$(trim_value "$entry")"
  [ -n "$entry" ] || return 1
  if ! is_valid_ipv4_cidr "$entry"; then
    echo_err "IP/CIDR 非法: ${entry}"
    return 1
  fi

  append_unique_line "${MANUAL_WHITELIST_FILE}" "$entry"
}

ensure_current_ssh_ip_whitelisted() {
  local ssh_ip

  if ! ssh_ip="$(detect_ssh_client_ip)"; then
    echo_warn "未检测到当前 SSH 来源 IP，请确认手动白名单中已有管理 IP。"
    return 0
  fi

  if ! is_valid_ipv4 "$ssh_ip"; then
    echo_warn "检测到的 SSH 来源不是有效 IPv4，已跳过自动加入: ${ssh_ip}"
    return 0
  fi

  add_manual_whitelist_entry "$ssh_ip" || return 1
  echo_ok "已将当前 SSH 来源 IP 加入手动白名单: ${ssh_ip}"
}

collect_manual_whitelist_entries() {
  local raw entry

  while IFS= read -r raw; do
    entry="$(trim_value "$raw")"
    [ -n "$entry" ] || continue
    [[ "$entry" == \#* ]] && continue
    if ! is_valid_ipv4_cidr "$entry"; then
      echo_err "手动白名单包含非法 IP/CIDR: ${entry}"
      return 1
    fi
    printf "%s\n" "$entry"
  done < "${MANUAL_WHITELIST_FILE}"
}

collect_region_whitelist_entries() {
  local codes=()

  [ "${REGION_WHITELIST_ENABLE:-0}" = "1" ] || return 0
  mapfile -t codes < <(awk '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 != "" && substr($0, 1, 1) != "#") print $0
    }
  ' "${REGION_CODES_FILE}")

  [ "${#codes[@]}" -gt 0 ] || return 0
  region_tool collect-cidrs "${codes[@]}"
}

render_nft_set() {
  local set_name="$1"
  shift
  local entries=("$@")
  local i sep

  echo "    set ${set_name} {"
  echo "        type ipv4_addr"
  echo "        flags interval"
  echo "        auto-merge"
  if [ "${#entries[@]}" -gt 0 ]; then
    echo "        elements = {"
    for i in "${!entries[@]}"; do
      sep=","
      if [ "$i" -eq "$((${#entries[@]} - 1))" ]; then
        sep=""
      fi
      echo "            ${entries[$i]}${sep}"
    done
    echo "        }"
  fi
  echo "    }"
}

render_nft_set_file() {
  local set_name="$1"
  local output_file="$2"
  shift 2
  local entries=("$@")

  {
    echo "# Generated by ${SHORTCUT_NAME}; do not edit manually."
    render_nft_set "$set_name" "${entries[@]}"
  } > "$output_file"
  chmod 600 "$output_file" 2>/dev/null || true
}

render_whitelist_set_files() {
  local output_dir="$1"
  local manual_entries=()
  local region_entries=()
  local manual_tmp=""
  local region_tmp=""

  mkdir -p "$output_dir"
  manual_tmp="$(mktemp /tmp/nft-forward.manual-whitelist.XXXXXX)"
  region_tmp="$(mktemp /tmp/nft-forward.region-whitelist.XXXXXX)"

  if ! collect_manual_whitelist_entries > "$manual_tmp"; then
    rm -f "$manual_tmp" "$region_tmp"
    return 1
  fi
  if ! collect_region_whitelist_entries > "$region_tmp"; then
    rm -f "$manual_tmp" "$region_tmp"
    return 1
  fi

  mapfile -t manual_entries < "$manual_tmp"
  mapfile -t region_entries < "$region_tmp"
  rm -f "$manual_tmp" "$region_tmp"

  render_nft_set_file "manual_whitelist4" "${output_dir}/manual_whitelist4.nft" "${manual_entries[@]}"
  render_nft_set_file "region_whitelist4" "${output_dir}/region_whitelist4.nft" "${region_entries[@]}"
}

render_nftables_conf() {
  local output_file="$1"
  local set_include_dir="${2:-$SETS_DIR}"
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
    if [ "${WHITELIST_ENABLE:-0}" = "1" ]; then
      echo "    include \"${set_include_dir}/manual_whitelist4.nft\""
      echo "    include \"${set_include_dir}/region_whitelist4.nft\""
      echo ""
      echo "    chain whitelist_gate {"
      echo "        ip saddr @manual_whitelist4 return"
      if [ "${REGION_WHITELIST_ENABLE:-0}" = "1" ]; then
        echo "        ip saddr @region_whitelist4 return"
      fi
      echo "        reject with icmp type admin-prohibited"
      echo "    }"
      echo ""
      echo "    chain input {"
      echo "        type filter hook input priority 0; policy accept;"
      echo "        iif lo accept"
      echo "        ct state established,related accept"
      echo "        jump whitelist_gate"
      echo "    }"
      echo ""
    fi
    echo "    chain forward {"
    echo "        type filter hook forward priority 0; policy accept;"
    if [ "${WHITELIST_ENABLE:-0}" = "1" ]; then
      echo "        ct state established,related accept"
      echo "        jump whitelist_gate"
    fi
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
    if [ "${AUTO_MODE}" = "1" ]; then
      echo_err "nftables is not installed; automation cannot continue."
      return 1
    fi

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
  local final_conf=""
  local rollback_conf=""
  local tmp_sets_dir=""
  local rollback_sets_dir=""
  local sets_existed=0

  load_config
  ensure_whitelist_safe || return 1

  if [ -s "${RULES_FILE}" ] && [ -z "$RELAY_LAN_IP" ]; then
    echo_err "存在转发规则，但本机 SNAT IP 未设置，无法应用。"
    return 1
  fi

  if ! resolve_nft_cmd; then
    if [ "${AUTO_MODE}" = "1" ]; then
      echo_err "nftables is not installed; automation cannot continue."
      return 1
    fi

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
  final_conf="$(mktemp /tmp/nft-forward.final-conf.XXXXXX)"
  rollback_conf="$(mktemp /tmp/nft-forward.rollback.XXXXXX)"
  tmp_sets_dir="$(mktemp -d /tmp/nft-forward.sets.XXXXXX)"
  rollback_sets_dir="$(mktemp -d /tmp/nft-forward.sets.rollback.XXXXXX)"

  if [ "${WHITELIST_ENABLE:-0}" = "1" ]; then
    if ! render_whitelist_set_files "$tmp_sets_dir"; then
      echo_err "生成白名单 set 文件失败，未应用。"
      rm -f "${tmp_conf}" "${final_conf}" "${rollback_conf}"
      rm -rf "${tmp_sets_dir}" "${rollback_sets_dir}"
      return 1
    fi
  fi

  if ! render_nftables_conf "${tmp_conf}" "$tmp_sets_dir"; then
    echo_err "生成 nftables 规则失败，未应用。"
    rm -f "${tmp_conf}" "${final_conf}" "${rollback_conf}"
    rm -rf "${tmp_sets_dir}" "${rollback_sets_dir}"
    return 1
  fi

  if ! "${NFT_CMD}" -c -f "${tmp_conf}" >/dev/null 2>&1; then
    echo_err "规则语法检查失败，未应用。报错如下："
    "${NFT_CMD}" -c -f "${tmp_conf}" 2>&1 | sed "s/^/  /"
    rm -f "${tmp_conf}" "${final_conf}" "${rollback_conf}"
    rm -rf "${tmp_sets_dir}" "${rollback_sets_dir}"
    return 1
  fi

  if [ -f "${NFT_CONF}" ]; then
    cp -a "${NFT_CONF}" "${rollback_conf}"
  else
    : > "${rollback_conf}"
  fi

  if [ -d "${SETS_DIR}" ]; then
    sets_existed=1
    cp -a "${SETS_DIR}/." "${rollback_sets_dir}/" 2>/dev/null || true
  fi

  if [ "${WHITELIST_ENABLE:-0}" = "1" ]; then
    mkdir -p "${SETS_DIR}"
    install -m 600 "${tmp_sets_dir}/manual_whitelist4.nft" "${MANUAL_WHITELIST_NFT}"
    install -m 600 "${tmp_sets_dir}/region_whitelist4.nft" "${REGION_WHITELIST_NFT}"
    chmod 700 "${SETS_DIR}" 2>/dev/null || true
  fi

  if ! render_nftables_conf "${final_conf}" "${SETS_DIR}"; then
    echo_err "生成最终 nftables 规则失败，正在回滚。"
    if [ "$sets_existed" = "1" ]; then
      rm -rf "${SETS_DIR}"
      mkdir -p "${SETS_DIR}"
      cp -a "${rollback_sets_dir}/." "${SETS_DIR}/" 2>/dev/null || true
      chmod 700 "${SETS_DIR}" 2>/dev/null || true
    else
      rm -rf "${SETS_DIR}"
    fi
    rm -f "${tmp_conf}" "${final_conf}" "${rollback_conf}"
    rm -rf "${tmp_sets_dir}" "${rollback_sets_dir}"
    return 1
  fi

  if ! "${NFT_CMD}" -c -f "${final_conf}" >/dev/null 2>&1; then
    echo_err "最终规则语法检查失败，正在回滚。报错如下："
    "${NFT_CMD}" -c -f "${final_conf}" 2>&1 | sed "s/^/  /"
    if [ "$sets_existed" = "1" ]; then
      rm -rf "${SETS_DIR}"
      mkdir -p "${SETS_DIR}"
      cp -a "${rollback_sets_dir}/." "${SETS_DIR}/" 2>/dev/null || true
      chmod 700 "${SETS_DIR}" 2>/dev/null || true
    else
      rm -rf "${SETS_DIR}"
    fi
    rm -f "${tmp_conf}" "${final_conf}" "${rollback_conf}"
    rm -rf "${tmp_sets_dir}" "${rollback_sets_dir}"
    return 1
  fi

  install -m 600 "${final_conf}" "${NFT_CONF}"

  if ! "${NFT_CMD}" -f "${NFT_CONF}" >/dev/null 2>&1; then
    echo_err "规则应用失败，正在回滚。"
    if [ "$sets_existed" = "1" ]; then
      rm -rf "${SETS_DIR}"
      mkdir -p "${SETS_DIR}"
      cp -a "${rollback_sets_dir}/." "${SETS_DIR}/" 2>/dev/null || true
      chmod 700 "${SETS_DIR}" 2>/dev/null || true
    else
      rm -rf "${SETS_DIR}"
    fi
    if [ -s "${rollback_conf}" ]; then
      install -m 600 "${rollback_conf}" "${NFT_CONF}"
      "${NFT_CMD}" -f "${NFT_CONF}" >/dev/null 2>&1 || true
    fi
    rm -f "${tmp_conf}" "${final_conf}" "${rollback_conf}"
    rm -rf "${tmp_sets_dir}" "${rollback_sets_dir}"
    return 1
  fi

  if have_cmd systemctl; then
    systemctl enable nftables >/dev/null 2>&1 || true
    systemctl restart nftables >/dev/null 2>&1 || true
  fi

  rm -f "${tmp_conf}" "${final_conf}" "${rollback_conf}"
  rm -rf "${tmp_sets_dir}" "${rollback_sets_dir}"
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
  if ! install_region_assets; then
    echo_warn "地区白名单资源未安装成功；普通转发不受影响，但省/市白名单功能暂不可用。"
  fi

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
  echo "$(color "$C_BOLD" "本机 SNAT IP:") ${relay_state}"
  echo "$(color "$C_BOLD" "白名单限制:") $(bool_label "$WHITELIST_ENABLE")"
}

bool_label() {
  if [ "${1:-0}" = "1" ]; then
    color "$C_GREEN" "enabled"
  else
    color "$C_YELLOW" "disabled"
  fi
}

show_whitelist_status() {
  load_config
  printf "%b状态:%b 白名单 %s | 地区来源 %s | 已选地区 %s | 手动 %s\n" \
    "$C_BOLD" "$C_RESET" \
    "$(bool_label "$WHITELIST_ENABLE")" \
    "$(bool_label "$REGION_WHITELIST_ENABLE")" \
    "$(region_whitelist_count)" \
    "$(manual_whitelist_count)"
}

create_whitelist_backup() {
  local backup_dir

  backup_dir="$(mktemp -d /tmp/nft-forward.whitelist.backup.XXXXXX)"
  if [ -f "${CONFIG_FILE}" ]; then
    cp -a "${CONFIG_FILE}" "${backup_dir}/config.env"
  else
    : > "${backup_dir}/config.env.missing"
  fi
  cp -a "${REGION_CODES_FILE}" "${backup_dir}/region_whitelist.codes"
  cp -a "${MANUAL_WHITELIST_FILE}" "${backup_dir}/manual_whitelist.list"
  printf "%s\n" "$backup_dir"
}

restore_whitelist_backup() {
  local backup_dir="$1"

  if [ -f "${backup_dir}/config.env.missing" ]; then
    rm -f "${CONFIG_FILE}"
  else
    cp -a "${backup_dir}/config.env" "${CONFIG_FILE}"
  fi
  cp -a "${backup_dir}/region_whitelist.codes" "${REGION_CODES_FILE}"
  cp -a "${backup_dir}/manual_whitelist.list" "${MANUAL_WHITELIST_FILE}"
}

finish_whitelist_change() {
  local backup_dir="$1"
  local success_message="$2"

  if apply_rules; then
    rm -rf "$backup_dir"
    echo_ok "$success_message"
    return 0
  fi

  restore_whitelist_backup "$backup_dir"
  rm -rf "$backup_dir"
  echo_err "操作失败，已回滚白名单配置。"
  return 1
}

finish_region_whitelist_change() {
  local backup_dir="$1"
  local success_message="$2"

  load_config
  if [ "${WHITELIST_ENABLE:-0}" = "1" ] && [ "${REGION_WHITELIST_ENABLE:-0}" = "1" ]; then
    finish_whitelist_change "$backup_dir" "$success_message"
    return $?
  fi

  rm -rf "$backup_dir"
  if [ "${REGION_WHITELIST_ENABLE:-0}" != "1" ]; then
    echo_ok "${success_message}（地区白名单来源未开启，仅保存配置，暂不生效。）"
  else
    echo_ok "${success_message}（白名单限制未开启，仅保存配置，暂不生效。）"
  fi
  return 0
}

load_region_codes() {
  mapfile -t REGION_CODES < <(awk '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 != "" && substr($0, 1, 1) != "#") print $0
    }
  ' "${REGION_CODES_FILE}")
}

describe_region_code() {
  local code="$1"
  local line

  line="$(region_tool describe-codes "$code" 2>/dev/null | head -n 1 || true)"
  if [ -n "$line" ]; then
    printf "%s\n" "${line#*$'\t'}"
  else
    printf "%s\n" "$code"
  fi
}

show_selected_regions() {
  local i code name

  load_region_codes
  if [ "${#REGION_CODES[@]}" -eq 0 ]; then
    echo_info "暂无已选省/市。"
    return 0
  fi

  for i in "${!REGION_CODES[@]}"; do
    code="${REGION_CODES[$i]}"
    name="$(describe_region_code "$code")"
    printf "%-4s %-8s %s\n" "$((i + 1))." "$code" "$name"
  done
}

show_manual_whitelist() {
  local entries=()
  local i

  mapfile -t entries < <(collect_manual_whitelist_entries 2>/dev/null || true)
  if [ "${#entries[@]}" -eq 0 ]; then
    echo_info "暂无手动白名单。"
    return 0
  fi

  for i in "${!entries[@]}"; do
    printf "%-4s %s\n" "$((i + 1))." "${entries[$i]}"
  done
}

remove_indices_from_file() {
  local file="$1"
  local indices="$2"
  local tmp_file

  tmp_file="$(mktemp /tmp/nft-forward.list.new.XXXXXX)"
  awk -v list="$indices" '
    BEGIN {
      split(list, values, " ")
      for (i in values) {
        if (values[i] ~ /^[0-9]+$/) remove[values[i]] = 1
      }
    }
    !(NR in remove) { print $0 }
  ' "$file" > "$tmp_file"
  mv "$tmp_file" "$file"
}

manage_whitelist_switch() {
  local choice backup_dir

  while true; do
    clear_screen
    print_section "白名单总开关"
    show_whitelist_status
    echo ""
    print_menu_item "1" "开启白名单限制"
    print_menu_item "2" "关闭白名单限制"
    print_menu_item "0" "返回"

    prompt_input "请选择 [0-2]: " || return 1
    choice="$(trim_value "$REPLY")"
    case "$choice" in
      1)
        backup_dir="$(create_whitelist_backup)"
        load_config
        WHITELIST_ENABLE=1
        ensure_current_ssh_ip_whitelisted || {
          restore_whitelist_backup "$backup_dir"
          rm -rf "$backup_dir"
          return 1
        }
        save_config
        finish_whitelist_change "$backup_dir" "白名单限制已开启。"
        pause_for_menu
        return 0
        ;;
      2)
        backup_dir="$(create_whitelist_backup)"
        load_config
        WHITELIST_ENABLE=0
        save_config
        finish_whitelist_change "$backup_dir" "白名单限制已关闭。"
        pause_for_menu
        return 0
        ;;
      0) return 0 ;;
      *) echo_err "无效选项，请输入 0-2。" ;;
    esac
  done
}

toggle_region_whitelist_source() {
  local backup_dir

  backup_dir="$(create_whitelist_backup)"
  load_config
  if [ "$REGION_WHITELIST_ENABLE" = "1" ]; then
    REGION_WHITELIST_ENABLE=0
  else
    REGION_WHITELIST_ENABLE=1
  fi
  save_config
  finish_whitelist_change "$backup_dir" "地区白名单来源状态已更新。"
}

add_region_provinces() {
  local input selector code backup_dir added=0

  print_section "添加省份"
  region_tool show-provinces || return 1
  prompt_input "请输入省份编号/名称，可多选: " || return 1
  input="$REPLY"

  backup_dir="$(create_whitelist_backup)"
  while IFS= read -r selector; do
    [ -n "$selector" ] || continue
    if code="$(region_tool resolve-province "$selector")"; then
      append_unique_line "${REGION_CODES_FILE}" "$code"
      added=$((added + 1))
    else
      restore_whitelist_backup "$backup_dir"
      rm -rf "$backup_dir"
      return 1
    fi
  done < <(split_user_list "$input")

  if [ "$added" -eq 0 ]; then
    restore_whitelist_backup "$backup_dir"
    rm -rf "$backup_dir"
    echo_warn "未添加任何省份。"
    return 0
  fi

  finish_region_whitelist_change "$backup_dir" "省份白名单已更新。"
}

add_region_cities() {
  local province_selector province_code input selector code backup_dir added=0

  print_section "添加城市"
  region_tool show-provinces || return 1
  prompt_input "请先输入省份编号/名称: " || return 1
  province_selector="$(trim_value "$REPLY")"
  [ -n "$province_selector" ] || return 1
  province_code="$(region_tool resolve-province "$province_selector")" || return 1

  region_tool show-cities "$province_code" || return 1
  prompt_input "请输入城市编号/名称，可多选；输入 0 表示全省/全市: " || return 1
  input="$(trim_value "$REPLY")"
  [ -n "$input" ] || return 1

  backup_dir="$(create_whitelist_backup)"
  if [ "$input" = "0" ] || [ "$input" = "全省" ] || [ "$input" = "全市" ]; then
    append_unique_line "${REGION_CODES_FILE}" "$province_code"
    added=1
  else
    while IFS= read -r selector; do
      [ -n "$selector" ] || continue
      if code="$(region_tool resolve-city "$province_code" "$selector")"; then
        append_unique_line "${REGION_CODES_FILE}" "$code"
        added=$((added + 1))
      else
        restore_whitelist_backup "$backup_dir"
        rm -rf "$backup_dir"
        return 1
      fi
    done < <(split_user_list "$input")
  fi

  if [ "$added" -eq 0 ]; then
    restore_whitelist_backup "$backup_dir"
    rm -rf "$backup_dir"
    echo_warn "未添加任何城市。"
    return 0
  fi

  finish_region_whitelist_change "$backup_dir" "城市白名单已更新。"
}

delete_selected_regions() {
  local input index backup_dir

  print_section "删除省/市"
  show_selected_regions
  if [ "$(region_whitelist_count)" -eq 0 ]; then
    return 0
  fi

  prompt_input "请输入要删除的编号，可多选: " || return 1
  input="$(trim_value "$REPLY")"
  [ -n "$input" ] || return 1

  for index in $(split_user_list "$input"); do
    [[ "$index" =~ ^[0-9]+$ ]] || {
      echo_err "编号非法: ${index}"
      return 1
    }
  done

  backup_dir="$(create_whitelist_backup)"
  remove_indices_from_file "${REGION_CODES_FILE}" "$(split_user_list "$input" | tr '\n' ' ')"
  finish_region_whitelist_change "$backup_dir" "地区白名单已删除所选项。"
}

clear_selected_regions() {
  local backup_dir

  if ! prompt_yes_no "确认清空所有地区白名单? [y/N]: " "no"; then
    return 0
  fi

  backup_dir="$(create_whitelist_backup)"
  : > "${REGION_CODES_FILE}"
  finish_region_whitelist_change "$backup_dir" "地区白名单已清空。"
}

manage_region_whitelist() {
  local choice

  while true; do
    clear_screen
    print_section "地区白名单管理"
    show_whitelist_status
    echo ""
    print_menu_item "1" "开启/关闭地区白名单来源"
    print_menu_item "2" "添加省份"
    print_menu_item "3" "添加城市"
    print_menu_item "4" "删除省/市"
    print_menu_item "5" "查看已选省/市"
    print_menu_item "6" "清空地区白名单"
    print_menu_item "0" "返回"

    prompt_input "请选择 [0-6]: " || return 1
    choice="$(trim_value "$REPLY")"
    case "$choice" in
      1) toggle_region_whitelist_source; pause_for_menu ;;
      2) add_region_provinces; pause_for_menu ;;
      3) add_region_cities; pause_for_menu ;;
      4) delete_selected_regions; pause_for_menu ;;
      5) show_selected_regions; pause_for_menu ;;
      6) clear_selected_regions; pause_for_menu ;;
      0) return 0 ;;
      *) echo_err "无效选项，请输入 0-6。" ;;
    esac
  done
}

add_manual_whitelist() {
  local input entry backup_dir added=0

  print_section "添加手动白名单"
  prompt_input "请输入 IP/CIDR，可一次输入多个: " || return 1
  input="$REPLY"

  backup_dir="$(create_whitelist_backup)"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    add_manual_whitelist_entry "$entry" || {
      restore_whitelist_backup "$backup_dir"
      rm -rf "$backup_dir"
      return 1
    }
    added=$((added + 1))
  done < <(split_user_list "$input")

  if [ "$added" -eq 0 ]; then
    restore_whitelist_backup "$backup_dir"
    rm -rf "$backup_dir"
    echo_warn "未添加任何 IP/CIDR。"
    return 0
  fi

  finish_whitelist_change "$backup_dir" "手动白名单已更新。"
}

delete_manual_whitelist() {
  local input index backup_dir ssh_ip="" entries=() selected_entry

  print_section "删除手动白名单"
  mapfile -t entries < <(collect_manual_whitelist_entries 2>/dev/null || true)
  show_manual_whitelist
  if [ "${#entries[@]}" -eq 0 ]; then
    return 0
  fi

  prompt_input "请输入要删除的编号，可多选: " || return 1
  input="$(trim_value "$REPLY")"
  [ -n "$input" ] || return 1

  load_config
  ssh_ip="$(detect_ssh_client_ip 2>/dev/null || true)"
  for index in $(split_user_list "$input"); do
    [[ "$index" =~ ^[0-9]+$ ]] || {
      echo_err "编号非法: ${index}"
      return 1
    }
    if [ "$index" -ge 1 ] && [ "$index" -le "${#entries[@]}" ]; then
      selected_entry="${entries[$((index - 1))]}"
      if [ "$WHITELIST_ENABLE" = "1" ] && [ -n "$ssh_ip" ] && [ "$selected_entry" = "$ssh_ip" ]; then
        prompt_input "正在删除当前 SSH IP (${ssh_ip})，请输入 YES 确认: " || return 1
        if [ "$(trim_value "$REPLY")" != "YES" ]; then
          echo_warn "已取消删除当前 SSH IP。"
          return 0
        fi
      fi
    fi
  done

  backup_dir="$(create_whitelist_backup)"
  remove_indices_from_file "${MANUAL_WHITELIST_FILE}" "$(split_user_list "$input" | tr '\n' ' ')"
  finish_whitelist_change "$backup_dir" "手动白名单已删除所选项。"
}

clear_manual_whitelist() {
  local backup_dir ssh_ip=""

  if ! prompt_yes_no "确认清空所有手动白名单? [y/N]: " "no"; then
    return 0
  fi

  backup_dir="$(create_whitelist_backup)"
  load_config
  : > "${MANUAL_WHITELIST_FILE}"

  if [ "$WHITELIST_ENABLE" = "1" ]; then
    if ssh_ip="$(detect_ssh_client_ip)" && is_valid_ipv4 "$ssh_ip"; then
      add_manual_whitelist_entry "$ssh_ip" || {
        restore_whitelist_backup "$backup_dir"
        rm -rf "$backup_dir"
        return 1
      }
      echo_ok "白名单限制已开启，已保留当前 SSH IP: ${ssh_ip}"
    else
      echo_warn "白名单限制已开启，但未检测到当前 SSH IPv4。"
    fi
  fi

  finish_whitelist_change "$backup_dir" "手动白名单已清空。"
}

manage_manual_whitelist() {
  local choice

  while true; do
    clear_screen
    print_section "手动白名单管理"
    echo "当前数量: $(manual_whitelist_count)"
    echo ""
    print_menu_item "1" "添加 IP/CIDR"
    print_menu_item "2" "删除 IP/CIDR"
    print_menu_item "3" "查看手动白名单"
    print_menu_item "4" "清空手动白名单"
    print_menu_item "0" "返回"

    prompt_input "请选择 [0-4]: " || return 1
    choice="$(trim_value "$REPLY")"
    case "$choice" in
      1) add_manual_whitelist; pause_for_menu ;;
      2) delete_manual_whitelist; pause_for_menu ;;
      3) show_manual_whitelist; pause_for_menu ;;
      4) clear_manual_whitelist; pause_for_menu ;;
      0) return 0 ;;
      *) echo_err "无效选项，请输入 0-4。" ;;
    esac
  done
}

manage_whitelist() {
  local choice

  while true; do
    clear_screen
    print_section "白名单管理"
    show_whitelist_status
    echo ""
    print_menu_item "1" "白名单总开关"
    print_menu_item "2" "地区白名单管理"
    print_menu_item "3" "手动白名单管理"
    print_menu_item "0" "返回主菜单"

    prompt_input "请选择 [0-3]: " || return 1
    choice="$(trim_value "$REPLY")"
    case "$choice" in
      1) manage_whitelist_switch ;;
      2) manage_region_whitelist ;;
      3) manage_manual_whitelist ;;
      0) return 0 ;;
      *) echo_err "无效选项，请输入 0-3。" ;;
    esac
  done
}

print_menu() {
  echo ""
  print_menu_item "1" "安装nftables"
  print_menu_item "2" "查看转发"
  print_menu_item "3" "添加转发"
  print_menu_item "4" "修改转发"
  print_menu_item "5" "删除转发"
  print_menu_item "6" "白名单管理"
  print_menu_item "7" "卸载"
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
    if prompt_yes_no "尚未设置本机 SNAT IP（通常填写内网/专线 IP；如果没有内网 IP，请填写本机公网 IP），是否现在设置? [Y/n]: " "yes"; then
      ensure_relay_lan_ip || return 1
    else
      echo_warn "暂未设置本机 SNAT IP，添加转发时会再次要求输入。"
    fi
  else
    echo_info "当前本机 SNAT IP: ${RELAY_LAN_IP}"
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

rewrite_dest_ip_by_id() {
  local target_id="$1"
  local new_dest_ip="$2"
  local tmp_rules old_rules_backup

  [[ "$target_id" =~ ^[0-9]+$ ]] || {
    echo_err "invalid rule id: ${target_id}"
    return 1
  }
  is_valid_ipv4 "$new_dest_ip" || {
    echo_err "invalid new IPv4: ${new_dest_ip}"
    return 1
  }
  find_rule_by_id "$target_id" >/dev/null || {
    echo_err "rule not found: ${target_id}"
    return 1
  }

  old_rules_backup="$(mktemp /tmp/nft-forward.rules.backup.XXXXXX)"
  tmp_rules="$(mktemp /tmp/nft-forward.rules.new.XXXXXX)"
  cp -a "${RULES_FILE}" "${old_rules_backup}"

  awk -F'|' -v OFS='|' -v id="$target_id" -v dest_ip="$new_dest_ip" '
    $1 == id { $3 = dest_ip }
    { print $0 }
  ' "${RULES_FILE}" > "${tmp_rules}"
  mv "${tmp_rules}" "${RULES_FILE}"

  if apply_rules; then
    rm -f "${old_rules_backup}"
    echo_ok "updated rule dest ip: id=${target_id} new_ip=${new_dest_ip} updated=1"
    return 0
  fi

  cp -a "${old_rules_backup}" "${RULES_FILE}"
  rm -f "${old_rules_backup}"
  echo_err "update failed; rules database rolled back."
  return 1
}

rewrite_dest_ip_by_remark() {
  local target_remark="$1"
  local new_dest_ip="$2"
  local match_mode="${3:-exact}"
  local tmp_rules old_rules_backup count

  target_remark="$(trim_value "$target_remark")"
  [ -n "$target_remark" ] || {
    echo_err "remark must not be empty"
    return 1
  }
  is_valid_ipv4 "$new_dest_ip" || {
    echo_err "invalid new IPv4: ${new_dest_ip}"
    return 1
  }
  case "$match_mode" in
    exact|contains) ;;
    *)
      echo_err "invalid remark match mode: ${match_mode}"
      return 1
      ;;
  esac

  count="$(awk -F'|' -v remark="$target_remark" -v mode="$match_mode" '
    function matches(note) {
      if (mode == "exact") return note == remark
      return index(note, remark) > 0
    }
    matches($5) { c++ }
    END { print c + 0 }
  ' "${RULES_FILE}")"
  [ "$count" -gt 0 ] || {
    echo_err "no rules matched remark: ${target_remark}"
    return 1
  }

  old_rules_backup="$(mktemp /tmp/nft-forward.rules.backup.XXXXXX)"
  tmp_rules="$(mktemp /tmp/nft-forward.rules.new.XXXXXX)"
  cp -a "${RULES_FILE}" "${old_rules_backup}"

  awk -F'|' -v OFS='|' -v remark="$target_remark" -v dest_ip="$new_dest_ip" -v mode="$match_mode" '
    function matches(note) {
      if (mode == "exact") return note == remark
      return index(note, remark) > 0
    }
    matches($5) { $3 = dest_ip }
    { print $0 }
  ' "${RULES_FILE}" > "${tmp_rules}"
  mv "${tmp_rules}" "${RULES_FILE}"

  if apply_rules; then
    rm -f "${old_rules_backup}"
    echo_ok "updated rule dest ip: remark=${target_remark} mode=${match_mode} new_ip=${new_dest_ip} updated=${count}"
    return 0
  fi

  cp -a "${old_rules_backup}" "${RULES_FILE}"
  rm -f "${old_rules_backup}"
  echo_err "update failed; rules database rolled back."
  return 1
}

rewrite_dest_ip_by_current_ip() {
  local old_dest_ip="$1"
  local new_dest_ip="$2"
  local unique="${3:-0}"
  local tmp_rules old_rules_backup count

  is_valid_ipv4 "$old_dest_ip" || {
    echo_err "invalid old IPv4: ${old_dest_ip}"
    return 1
  }
  is_valid_ipv4 "$new_dest_ip" || {
    echo_err "invalid new IPv4: ${new_dest_ip}"
    return 1
  }

  count="$(awk -F'|' -v old_ip="$old_dest_ip" '$3 == old_ip { c++ } END { print c + 0 }' "${RULES_FILE}")"
  [ "$count" -gt 0 ] || {
    echo_err "no rules matched current ip: ${old_dest_ip}"
    return 1
  }
  if [ "$unique" = "1" ] && [ "$count" -ne 1 ]; then
    echo_err "unique mode expected 1 match, got ${count}"
    return 1
  fi

  old_rules_backup="$(mktemp /tmp/nft-forward.rules.backup.XXXXXX)"
  tmp_rules="$(mktemp /tmp/nft-forward.rules.new.XXXXXX)"
  cp -a "${RULES_FILE}" "${old_rules_backup}"

  awk -F'|' -v OFS='|' -v old_ip="$old_dest_ip" -v new_ip="$new_dest_ip" '
    $3 == old_ip { $3 = new_ip }
    { print $0 }
  ' "${RULES_FILE}" > "${tmp_rules}"
  mv "${tmp_rules}" "${RULES_FILE}"

  if apply_rules; then
    rm -f "${old_rules_backup}"
    echo_ok "updated rule dest ip: old_ip=${old_dest_ip} new_ip=${new_dest_ip} updated=${count}"
    return 0
  fi

  cp -a "${old_rules_backup}" "${RULES_FILE}"
  rm -f "${old_rules_backup}"
  echo_err "update failed; rules database rolled back."
  return 1
}

run_automation_update() {
  local command_name="$1"
  shift

  AUTO_MODE=1
  acquire_lock || {
    AUTO_MODE=0
    return 1
  }
  "$command_name" "$@"
  local result=$?
  release_lock
  AUTO_MODE=0
  return "$result"
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
    echo_info "当前本机 SNAT IP: ${RELAY_LAN_IP}"
  else
    echo_warn "当前本机 SNAT IP: 未设置"
  fi

  new_relay_ip="$RELAY_LAN_IP"
  if prompt_yes_no "是否同时修改本机 SNAT IP? [y/N]: " "no"; then
    new_relay_ip="$(prompt_ipv4 "新的本机 SNAT IP（通常填写内网/专线 IP；如果没有内网 IP，请填写本机公网 IP）" "${RELAY_LAN_IP:-}")" || return 1
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
  sudo nf --apply-rules
  sudo nf --show-forwards
  sudo nf --set-dest-ip-by-id <RULE_ID> <NEW_IPV4>
  sudo nf --set-dest-ip-by-remark <REMARK> <NEW_IPV4>
  sudo nf --set-dest-ip-by-remark-contains <TEXT> <NEW_IPV4>
  sudo nf --set-dest-ip-by-current-ip <OLD_IPV4> <NEW_IPV4>
  sudo nf --set-dest-ip-by-current-ip-unique <OLD_IPV4> <NEW_IPV4>
EOF
}

main_loop() {
  local choice

  while true; do
    clear_screen
    print_header
    status_line
    print_section "主菜单"
    print_menu

    if ! prompt_input "请选择 [0-7]: "; then
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
      6) manage_whitelist; continue ;;
      7) uninstall_all ;;
      0)
        echo_ok "已退出。"
        exit 0
        ;;
      *)
        echo_err "无效选项，请输入 0-7。"
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
  if [ "$#" -eq 0 ]; then
    self_install
  fi

  case "${1:-}" in
    --install-self)
      self_install
      ;;
    --apply-rules)
      AUTO_MODE=1
      apply_rules || exit 1
      ;;
    --show-forwards)
      show_forwards
      ;;
    --set-dest-ip-by-id)
      if [ "$#" -ne 3 ]; then
        echo_err "usage: $0 --set-dest-ip-by-id <RULE_ID> <NEW_IPV4>"
        exit 1
      fi
      run_automation_update rewrite_dest_ip_by_id "$2" "$3" || exit 1
      ;;
    --set-dest-ip-by-remark)
      if [ "$#" -ne 3 ]; then
        echo_err "usage: $0 --set-dest-ip-by-remark <REMARK> <NEW_IPV4>"
        exit 1
      fi
      run_automation_update rewrite_dest_ip_by_remark "$2" "$3" "exact" || exit 1
      ;;
    --set-dest-ip-by-remark-contains)
      if [ "$#" -ne 3 ]; then
        echo_err "usage: $0 --set-dest-ip-by-remark-contains <TEXT> <NEW_IPV4>"
        exit 1
      fi
      run_automation_update rewrite_dest_ip_by_remark "$2" "$3" "contains" || exit 1
      ;;
    --set-dest-ip-by-current-ip)
      if [ "$#" -ne 3 ]; then
        echo_err "usage: $0 --set-dest-ip-by-current-ip <OLD_IPV4> <NEW_IPV4>"
        exit 1
      fi
      run_automation_update rewrite_dest_ip_by_current_ip "$2" "$3" "0" || exit 1
      ;;
    --set-dest-ip-by-current-ip-unique)
      if [ "$#" -ne 3 ]; then
        echo_err "usage: $0 --set-dest-ip-by-current-ip-unique <OLD_IPV4> <NEW_IPV4>"
        exit 1
      fi
      run_automation_update rewrite_dest_ip_by_current_ip "$2" "$3" "1" || exit 1
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
