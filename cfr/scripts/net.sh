#!/system/bin/sh

if [ -f "/data/adb/modules/cfr/disable" ]; then
  exit 0
fi

events="$1"

export PATH="/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH:/system/bin:/data/data/com.termux/files/usr/bin"

BASE_DIR="/data/adb/cfr"
case "$0" in
  */*)
    SCRIPTS_DIR="${0%/*}"
    ;;
  *)
    SCRIPTS_DIR="${BASE_DIR}/scripts"
    ;;
esac
LOG_DIR="${BASE_DIR}/log"
STATE_DIR="${BASE_DIR}/run/state"
cfr_PID_FILE="${BASE_DIR}/run/cfr.pid"

DEBUG_LOG_FILE="${LOG_DIR}/debug.log"
CTRL_STATE_FILE="${STATE_DIR}/last_check_time"
CTRL_WIFI_STATE_FILE="${STATE_DIR}/last_wifi_state"
CTRL_STABILITY_WINDOW=3

buildVersion=$(getprop ro.build.version.release)
minBuildVersion="11"
IPV="iptables"
IP6V="ip6tables"
buildVersionMajor=${buildVersion%%.*}
if [ "${buildVersionMajor}" -ge "${minBuildVersion}" ]; then
  IPV="iptables -w 100"
  IP6V="ip6tables -w 100"
fi

iptables="${IPV}"
ip6tables="${IP6V}"

ensure_dirs() {
  mkdir -p "${LOG_DIR}" "${STATE_DIR}" >/dev/null 2>&1 || true
}

net_log_info() {
  local previous_cfr_log="${cfr_log}"
  cfr_log="${DEBUG_LOG_FILE}"
  log Info "$*" >/dev/null
  cfr_log="${previous_cfr_log}"
}

net_log_warn() {
  local previous_cfr_log="${cfr_log}"
  cfr_log="${DEBUG_LOG_FILE}"
  log Warn "$*" >/dev/null
  cfr_log="${previous_cfr_log}"
}

net_log_debug() {
  local previous_cfr_log="${cfr_log}"
  cfr_log="${DEBUG_LOG_FILE}"
  log Debug "$*" >/dev/null
  cfr_log="${previous_cfr_log}"
}

# 与 inotify.sh 共用同一个调试日志；文件在 service.sh 启动时删除，这里只确保存在
reset_event_logs() {
  ensure_dirs
  : >> "${DEBUG_LOG_FILE}" 2>/dev/null || true
}

control_log_msg() {
  [ "${inotify_log_enabled}" = "true" ] || return 0
  local previous_cfr_log="${cfr_log}"
  cfr_log="${DEBUG_LOG_FILE}"
  log Info "$*" >/dev/null
  cfr_log="${previous_cfr_log}"
}

ensure_chain_and_flush() {
  local ipt_cmd="$1"
  local table_name="$2"
  local chain_name="$3"
  ${ipt_cmd} -t "${table_name}" -N "${chain_name}" >/dev/null 2>&1 || true
  ${ipt_cmd} -t "${table_name}" -F "${chain_name}" >/dev/null 2>&1 || true
}

append_rule_fast() {
  local ipt_cmd="$1"
  local table_name="$2"
  local chain_name="$3"
  shift 3
  ${ipt_cmd} -t "${table_name}" -A "${chain_name}" "$@" >/dev/null 2>&1
}

mode_needs_local_ip_mangle() {
  case "${network_mode}" in
    tproxy|enhance)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

mode_needs_local_ip_nat() {
  case "${network_mode}" in
    redirect|mixed|enhance)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

append_local_ip_ruleset() {
  local ipt_cmd="$1"
  local table_name="$2"
  local chain_name="$3"
  local local_ip="$4"

  append_rule_fast "${ipt_cmd}" "${table_name}" "${chain_name}" -d "${local_ip}" -p udp ! --dport 53 -j ACCEPT
  local rv1=$?
  append_rule_fast "${ipt_cmd}" "${table_name}" "${chain_name}" -d "${local_ip}" ! -p udp -j ACCEPT
  local rv2=$?

  if [ "${rv1}" = "0" ] || [ "${rv2}" = "0" ]; then
    return 0
  fi
  return 1
}

get_active_tun_device() {
  local dev=""
  if [ -f "${mihomo_config}" ]; then
    dev=$(busybox awk '
      /^tun:[[:space:]]*(#.*)?$/ { in_tun=1; next }
      in_tun && /^[^[:space:]#-]/ { in_tun=0 }
      in_tun && /^[[:space:]]+device:[[:space:]]*/ {
        sub(/^[[:space:]]+device:[[:space:]]*/, "", $0)
        sub(/[[:space:]]*(#.*)?$/, "", $0)
        gsub(/["\x27]/, "", $0)
        print $0
        exit
      }
    ' "${mihomo_config}" 2>/dev/null)
  fi
  [ -n "${dev}" ] || dev="${tun_device_name:-tun0}"
  printf '%s\n' "${dev}"
}

collect_local_ipv4_list() {
  local tun_dev
  tun_dev="$(get_active_tun_device)"
  ip -o -4 addr show up 2>/dev/null \
    | busybox awk -v tun="${tun_dev}" '
      $2 != "lo" && $2 != tun && $4 !~ /^127\./ {
        ip = $4
        sub(/\/.*/, "", ip)
        if (ip != "") print ip "/32"
      }
    ' \
    | busybox sort -u
}

collect_local_ipv6_list() {
  local tun_dev
  tun_dev="$(get_active_tun_device)"
  ip -o -6 addr show up scope global 2>/dev/null \
    | busybox awk -v tun="${tun_dev}" '
      $2 != "lo" && $2 != tun && $0 !~ / tentative| dadfailed/ && $4 !~ /^(fd00|fe80|::1)/ {
        ip = $4
        sub(/\/.*/, "", ip)
        if (ip != "") print ip "/128"
      }
    ' \
    | busybox sort -u
}

enforce_ipv6_state_on_change() {
  [ "${ipv6}" = "false" ] || return 0
  local path
  sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1 || true
  for path in /proc/sys/net/ipv6/conf/*/accept_ra; do
    [ -e "${path}" ] && echo 0 > "${path}" 2>/dev/null || true
  done
  for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [ -e "${path}" ] && echo 1 > "${path}" 2>/dev/null || true
  done
  ip -6 rule show pref 100 2>/dev/null | busybox grep -q "unreachable" || ip -6 rule add unreachable pref 100 >/dev/null 2>&1 || true
  net_log_debug "网络切换后已重新加固 IPv6 禁用策略"
}

ensure_policy_routes_on_change() {
  case "${network_mode}" in
    tproxy|enhance)
      ip rule show pref 100 2>/dev/null | busybox grep -q "lookup 2024" || ip rule add fwmark 16777216/16777216 table 2024 pref 100 >/dev/null 2>&1 || true
      ip route show table 2024 2>/dev/null | busybox grep -q "^local default dev lo" || ip route add local default dev lo table 2024 >/dev/null 2>&1 || true
      if [ "${ipv6}" = "true" ]; then
        ip -6 rule show pref 100 2>/dev/null | busybox grep -q "lookup 2024" || ip -6 rule add fwmark 16777216/16777216 table 2024 pref 100 >/dev/null 2>&1 || true
        ip -6 route show table 2024 2>/dev/null | busybox grep -q "^local default dev lo" || ip -6 route add local default dev lo table 2024 >/dev/null 2>&1 || true
      fi
      ;;
    tun)
      if [ "${bypass_cn_ip}" = "true" ]; then
        local tun_dev
        tun_dev="$(get_active_tun_device)"
        ip rule show pref 98 2>/dev/null | busybox grep -q "lookup main" || ip rule add fwmark 33554432/33554432 table main pref 98 >/dev/null 2>&1 || true
        ip rule show pref 99 2>/dev/null | busybox grep -q "lookup 2025" || ip rule add fwmark 50331648/50331648 table 2025 pref 99 >/dev/null 2>&1 || true
        ip route show table 2025 2>/dev/null | busybox grep -q "dev ${tun_dev}" || ip route replace default dev "${tun_dev}" table 2025 >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

update_local_ip_rules() {
  local v4_ok=0
  local v4_fail=0
  local v6_ok=0
  local v6_fail=0
  local need_mangle="false"
  local need_nat="false"
  local need_nat6="false"
  local local_ipv4=""
  local local_ipv6=""
  local ok=""

  if mode_needs_local_ip_mangle; then
    need_mangle="true"
  fi
  if mode_needs_local_ip_nat; then
    need_nat="true"
    if [ "${ipv6}" = "true" ] && ${ip6tables} -t nat -L >/dev/null 2>&1; then
      need_nat6="true"
    fi
  fi

  if [ "${need_mangle}" != "true" ] && [ "${need_nat}" != "true" ]; then
    net_log_debug "当前模式无需更新本地 IP 防回环规则"
    return 0
  fi

  if [ "${need_mangle}" = "true" ]; then
    net_log_debug "开始更新本地 IPv4 防回环规则"
    ensure_chain_and_flush "${iptables}" mangle LOCAL_IP_V4
  fi
  if [ "${need_nat}" = "true" ]; then
    ensure_chain_and_flush "${iptables}" nat LOCAL_IP_V4
  fi

  for local_ipv4 in $(collect_local_ipv4_list); do
    ok="true"

    if [ "${need_mangle}" = "true" ]; then
      append_local_ip_ruleset "${iptables}" mangle LOCAL_IP_V4 "${local_ipv4}" || ok="false"
    fi
    if [ "${need_nat}" = "true" ]; then
      append_local_ip_ruleset "${iptables}" nat LOCAL_IP_V4 "${local_ipv4}" || ok="false"
    fi

    if [ "${ok}" = "true" ]; then
      v4_ok=$((v4_ok + 1))
      net_log_debug "本地 IPv4 ${local_ipv4} 防回环规则已更新"
    else
      v4_fail=$((v4_fail + 1))
      net_log_warn "本地 IPv4 ${local_ipv4} 防回环规则更新失败"
    fi
  done

  if [ $((v4_ok + v4_fail)) -eq 0 ]; then
    net_log_debug "未检测到需要写入的本地 IPv4 地址"
  fi

  if [ "${ipv6}" = "true" ]; then
    if [ "${need_mangle}" = "true" ]; then
      net_log_debug "开始更新本地 IPv6 防回环规则"
      ensure_chain_and_flush "${ip6tables}" mangle LOCAL_IP_V6
    fi
    if [ "${need_nat6}" = "true" ]; then
      ensure_chain_and_flush "${ip6tables}" nat LOCAL_IP_V6
    fi

    for local_ipv6 in $(collect_local_ipv6_list); do
      ok="true"

      if [ "${need_mangle}" = "true" ]; then
        append_local_ip_ruleset "${ip6tables}" mangle LOCAL_IP_V6 "${local_ipv6}" || ok="false"
      fi
      if [ "${need_nat6}" = "true" ]; then
        append_local_ip_ruleset "${ip6tables}" nat LOCAL_IP_V6 "${local_ipv6}" || ok="false"
      fi

      if [ "${ok}" = "true" ]; then
        v6_ok=$((v6_ok + 1))
        net_log_debug "本地 IPv6 ${local_ipv6} 防回环规则已更新"
      else
        v6_fail=$((v6_fail + 1))
        net_log_warn "本地 IPv6 ${local_ipv6} 防回环规则更新失败"
      fi
    done

    if [ $((v6_ok + v6_fail)) -eq 0 ]; then
      net_log_debug "未检测到需要写入的本地 IPv6 地址"
    fi
  fi

  net_log_info "防回环规则更新完成: IPv4 成功=${v4_ok} 失败=${v4_fail}, IPv6 成功=${v6_ok} 失败=${v6_fail}"
}

check_stability_window() {
  local current
  local last=0

  current=$(date +%s)
  [ -f "${CTRL_STATE_FILE}" ] && last=$(cat "${CTRL_STATE_FILE}" 2>/dev/null || echo 0)

  if [ $((current - last)) -lt ${CTRL_STABILITY_WINDOW} ]; then
    control_log_msg "跳过：处于稳定窗口冷却期（$((current - last))秒）"
    return 1
  fi

  echo "${current}" > "${CTRL_STATE_FILE}"
  return 0
}

is_service_running() {
  [ -f "${cfr_PID_FILE}" ] && kill -0 "$(cat "${cfr_PID_FILE}" 2>/dev/null)" 2>/dev/null
}

start_service_if_needed() {
  if is_service_running; then
    control_log_msg "[跳过] 服务已在运行"
    return 0
  fi

  "${SCRIPTS_DIR}/service.sh" start
  "${SCRIPTS_DIR}/iptables.sh" enable
  control_log_msg "[启动] 服务已启动"
}

stop_service_if_needed() {
  if ! is_service_running; then
    control_log_msg "[跳过] 服务已停止"
    return 0
  fi

  "${SCRIPTS_DIR}/iptables.sh" disable
  "${SCRIPTS_DIR}/service.sh" stop
  control_log_msg "[停止] 服务已停止"
}

mask_bssid() {
  local b="$1"
  case "${b}" in
    ??:??:??:??:??:??)
      printf '%s:**:**:%s\n' "${b%??:??:??:??}" "${b#??:??:??:??:}"
      ;;
    *)
      printf '%s\n' "${b}"
      ;;
  esac
}

save_wifi_state() {
  local ssid="$1"
  local bssid="$2"
  local ip="$3"
  local masked_bssid
  masked_bssid="$(mask_bssid "${bssid}")"

  cat > "${CTRL_WIFI_STATE_FILE}" <<-EOF
ssid:${ssid}
bssid:${masked_bssid}
ip:${ip}
EOF
}

apply_network_control_policy() {
  [ "${enable_network_service_control}" = "true" ] || return 0

  if [ ! -f "${SCRIPTS_DIR}/utils.sh" ]; then
    control_log_msg "警告：未找到 utils.sh，跳过网络策略控制"
    return 0
  fi

  . "${SCRIPTS_DIR}/utils.sh"
  check_stability_window || return 0

  local wifi_status
  local ssid
  local bssid
  local wifi_ip=""
  local i

  wifi_status=$(is_wifi_connected)
  ssid=$(get_current_ssid)
  bssid=$(get_current_bssid)

  control_log_msg "网络状态检查"

  if [ "${wifi_status}" = "wifi" ]; then
    for i in 1 2 3; do
      wifi_ip=$(get_wifi_ip)
      [ -n "${wifi_ip}" ] && break
      sleep 1
    done

    if [ -z "${wifi_ip}" ]; then
      control_log_msg "WiFi 连接中，等待 IP 地址"
      return 0
    fi

    control_log_msg "WiFi 已连接 (IP: ${wifi_ip}, BSSID: $(mask_bssid "${bssid}"))"
    save_wifi_state "${ssid}" "${bssid}" "${wifi_ip}"
  else
    control_log_msg "WiFi: 已断开"
  fi

  if should_enable_service "${wifi_status}" "${ssid}" "${bssid}"; then
    control_log_msg "策略：启用服务"
    start_service_if_needed
  else
    control_log_msg "策略：禁用服务"
    stop_service_if_needed
  fi

  control_log_msg "完成"
}

if [ "${events}" = "w" ]; then
  reset_event_logs
  if [ ! -f "${BASE_DIR}/settings.ini" ]; then
    printf '%s [Warn]: 未找到 settings.ini，跳过本次处理\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "${DEBUG_LOG_FILE}" 2>/dev/null || true
    exit 0
  fi

  . "${BASE_DIR}/settings.ini"
  # 读取实际生效的运行模式（防止内核不支持 TPROXY 降级为 redirect 后 net.sh 仍按 settings.ini 操作 mangle）
  [ -f "${STATE_DIR}/runtime.iptables.env" ] && . "${STATE_DIR}/runtime.iptables.env" 2>/dev/null || true
  if [ -f "${cfr_PID_FILE}" ]; then
    enforce_ipv6_state_on_change
    ensure_policy_routes_on_change
    update_local_ip_rules
  else
    net_log_info "未检测到运行中的内核进程，跳过防回环规则更新"
  fi
  apply_network_control_policy
fi
