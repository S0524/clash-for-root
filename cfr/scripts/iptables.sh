#!/system/bin/sh

source /data/adb/cfr/settings.ini

# ANSI 颜色（值含真实 ESC 字符，兼容无 -e 的 echo）
normal="$(printf '\033[0m')"
red="$(printf '\033[1;31m')"
green="$(printf '\033[1;32m')"
yellow="$(printf '\033[1;33m')"
white="$(printf '\033[1;37m')"

runtime_iptables_env="${cfr_run_state}/runtime.iptables.env"
cnip_force_proxy_uid_list="${cfr_run_state}/cnip_force_proxy.uid.list"
cap_cache_file="${cfr_run_state}/iptables.cap.env"
ipset_stamp_dir="${cfr_run_state}/ipset.stamp"

fwmark="16777216/16777216"
table="2024"
pref="100"
tun_bypass_mark="33554432/33554432"
tun_bypass_pref="98"
tun_route_mark="50331648/50331648"
tun_route_table="2025"
tun_route_pref="99"
# QUIC 处理: enable=放行 UDP；disable=REJECT UDP 443/80，强制回退 TCP（需 proxy_udp="true"）
quic=${quic:-"enable"}
performance_mode=${performance_mode:-"false"}
proxy_tcp=${proxy_tcp:-"true"}
proxy_udp=${proxy_udp:-"true"}
dns_hijack_tcp=${dns_hijack_tcp:-"true"}
dns_hijack_udp=${dns_hijack_udp:-"true"}
fake_ip_range=""
fake_ip6_range=""
stack="${stack:-gvisor}"

buildVersion=$(getprop ro.build.version.release)
minBuildVersion="11"
IPV="iptables" # Default
IP6V="ip6tables" # Default
buildVersionMajor=${buildVersion%%.*}
if [ "$buildVersionMajor" -ge "$minBuildVersion" ]; then
  IPV="iptables -w 100"
  IP6V="ip6tables -w 100"
fi

ensure_chain() {
  local table_name="$1"
  local chain_name="$2"
  ${iptables} -t "${table_name}" -N "${chain_name}" >/dev/null 2>&1 || true
  ${iptables} -t "${table_name}" -F "${chain_name}" >/dev/null 2>&1 || true
}

ensure_jump() {
  local table_name="$1"
  local parent_chain="$2"
  local target_chain="$3"
  if ! ${iptables} -t "${table_name}" -C "${parent_chain}" -j "${target_chain}" >/dev/null 2>&1; then
    ${iptables} -t "${table_name}" -I "${parent_chain}" -j "${target_chain}"
  fi
}

del_jump_silent() {
  local table_name="$1"
  local parent_chain="$2"
  local target_chain="$3"
  ${iptables} -t "${table_name}" -D "${parent_chain}" -j "${target_chain}" >/dev/null 2>&1 || true
}

ensure_rule_append() {
  local table_name="$1"
  local chain_name="$2"
  shift 2
  # 自定义链每次启动都会先清空，直接追加即可，避免重复做 -C 检查。
  # 内置链仍需保留检查，避免规则重复累积。
  if is_cfr_custom_chain "${chain_name}"; then
    ${iptables} -t "${table_name}" -A "${chain_name}" "$@" >/dev/null 2>&1 || true
    return 0
  fi
  if ! ${iptables} -t "${table_name}" -C "${chain_name}" "$@" >/dev/null 2>&1; then
    ${iptables} -t "${table_name}" -A "${chain_name}" "$@"
  fi
}

ensure_rule_insert() {
  local table_name="$1"
  local chain_name="$2"
  shift 2
  # 自定义链每次启动都会先清空，直接插入即可，避免重复做 -C 检查。
  if is_cfr_custom_chain "${chain_name}"; then
    ${iptables} -t "${table_name}" -I "${chain_name}" "$@" >/dev/null 2>&1 || true
    return 0
  fi
  if ! ${iptables} -t "${table_name}" -C "${chain_name}" "$@" >/dev/null 2>&1; then
    ${iptables} -t "${table_name}" -I "${chain_name}" "$@"
  fi
}

is_cfr_custom_chain() {
  local chain_name="$1"
  case "${chain_name}" in
    cfr_*|DIVERT|LOCAL_IP_V4|LOCAL_IP_V6|NAT_DNS_HIJACK|NAT_DNS_HIJACK6|NAT_DNS_FORWARD|NAT_DNS_FORWARD6|MIHOMO_DNS_EXTERNAL|MIHOMO_DNS_LOCAL|AP_* )
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

add_core_bypass_rule() {
  local table_name="$1"
  local chain_name="$2"
  local insert_action="$3"

  [ -n "${insert_action}" ] || insert_action="-A"

  if ${iptables} -t "${table_name}" "${insert_action}" "${chain_name}" -m owner --uid-owner "${cfr_user}" --gid-owner "${cfr_group}" -j RETURN >/dev/null 2>&1; then
    return 0
  fi
  if ${iptables} -t "${table_name}" "${insert_action}" "${chain_name}" -m owner --uid-owner "${cfr_user}" -j RETURN >/dev/null 2>&1; then
    return 0
  fi
  if ${iptables} -t "${table_name}" "${insert_action}" "${chain_name}" -m owner --gid-owner "${cfr_group}" -j RETURN >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

del_rule_if_exists() {
  local table_name="$1"
  local chain_name="$2"
  shift 2
  if ${iptables} -t "${table_name}" -C "${chain_name}" "$@" >/dev/null 2>&1; then
    ${iptables} -t "${table_name}" -D "${chain_name}" "$@" >/dev/null 2>&1 || true
  fi
}

del_rule_silent() {
  local table_name="$1"
  local chain_name="$2"
  shift 2
  ${iptables} -t "${table_name}" -D "${chain_name}" "$@" >/dev/null 2>&1 || true
}

cleanup_chain_fast() {
  local table_name="$1"
  local chain_name="$2"
  ${iptables} -t "${table_name}" -F "${chain_name}" >/dev/null 2>&1 || true
  ${iptables} -t "${table_name}" -X "${chain_name}" >/dev/null 2>&1 || true
}

ip_rule_exists() {
  local ip_cmd="$1"
  local fwmark="$2"
  local table_id="$3"
  local pref_id="$4"
  local rule_lines mark_regex

  rule_lines="$(${ip_cmd} rule show pref "${pref_id}" 2>/dev/null)" || return 1
  [ -n "${rule_lines}" ] || return 1
  mark_regex="$(fwmark_match_regex "${fwmark}")"

  printf '%s\n' "${rule_lines}" | busybox grep -Eq "fwmark ${mark_regex}([[:space:]]|\$)" || return 1
  printf '%s\n' "${rule_lines}" | busybox grep -Eq "lookup ${table_id}([[:space:]]|\$)"
}

fwmark_match_regex() {
  local mark="$1"
  local value mask hex_value hex_mask

  value="${mark%%/*}"
  if [ "${value}" != "${mark}" ]; then
    mask="${mark#*/}"
  else
    mask=""
  fi

  case "${value}${mask}" in
    ''|*[!0-9]*)
      printf '%s\n' "${mark}"
      return 0
      ;;
  esac

  hex_value="$(printf '0x%x' "${value}")"
  if [ -n "${mask}" ]; then
    hex_mask="$(printf '0x%x' "${mask}")"
    printf '(%s|%s/%s)\n' "${mark}" "${hex_value}" "${hex_mask}"
  else
    printf '(%s|%s)\n' "${mark}" "${hex_value}"
  fi
}

ensure_ip_rule() {
  local ip_cmd="$1"
  local fwmark="$2"
  local table_id="$3"
  local pref_id="$4"
  if ! ip_rule_exists "${ip_cmd}" "${fwmark}" "${table_id}" "${pref_id}"; then
    ${ip_cmd} rule add fwmark "${fwmark}" table "${table_id}" pref "${pref_id}" >/dev/null 2>&1 || true
  fi
}

del_ip_rule_if_exists() {
  local ip_cmd="$1"
  local fwmark="$2"
  local table_id="$3"
  local pref_id="$4"
  if ip_rule_exists "${ip_cmd}" "${fwmark}" "${table_id}" "${pref_id}"; then
    ${ip_cmd} rule del fwmark "${fwmark}" table "${table_id}" pref "${pref_id}" >/dev/null 2>&1 || true
  fi
}

ip_route_local_default_exists() {
  local ip_cmd="$1"
  local table_id="$2"
  ${ip_cmd} route show table "${table_id}" 2>/dev/null | busybox grep -q "^local default dev lo\b"
}

ensure_ip_route_local_default() {
  local ip_cmd="$1"
  local table_id="$2"
  if ! ip_route_local_default_exists "${ip_cmd}" "${table_id}"; then
    ${ip_cmd} route add local default dev lo table "${table_id}"
  fi
}

del_ip_route_local_default_if_exists() {
  local ip_cmd="$1"
  local table_id="$2"
  if ip_route_local_default_exists "${ip_cmd}" "${table_id}"; then
    ${ip_cmd} route del local default dev lo table "${table_id}" >/dev/null 2>&1 || true
  fi
}

runtime_save() {
  mkdir -p "${cfr_run}" >/dev/null 2>&1 || true
  {
    printf 'network_mode="%s"\n' "${network_mode}"
    printf 'bin_name="%s"\n' "${bin_name}"
    printf 'ipv6="%s"\n' "${ipv6}"
    printf 'dns_hijack_mode="%s"\n' "${dns_hijack_mode}"
    printf 'performance_mode="%s"\n' "${performance_mode}"
    printf 'quic="%s"\n' "${quic}"
    printf 'proxy_tcp="%s"\n' "${proxy_tcp}"
    printf 'proxy_udp="%s"\n' "${proxy_udp}"
    printf 'dns_hijack_tcp="%s"\n' "${dns_hijack_tcp}"
    printf 'dns_hijack_udp="%s"\n' "${dns_hijack_udp}"
    printf 'fwmark="%s"\n' "${fwmark}"
    printf 'table="%s"\n' "${table}"
    printf 'pref="%s"\n' "${pref}"
    printf 'tproxy_port="%s"\n' "${tproxy_port}"
    printf 'redir_port="%s"\n' "${redir_port}"
    printf 'tun_device="%s"\n' "${tun_device}"
    printf 'mihomo_dns_port="%s"\n' "${mihomo_dns_port}"
    printf 'fake_ip_range="%s"\n' "${fake_ip_range}"
    printf 'fake_ip6_range="%s"\n' "${fake_ip6_range}"
    printf 'bypass_cn_ip="%s"\n' "${bypass_cn_ip}"
    printf 'bypass_cn_ip_v4="%s"\n' "${bypass_cn_ip_v4}"
    printf 'bypass_cn_ip_v6="%s"\n' "${bypass_cn_ip_v6}"
    printf 'cfr_user="%s"\n' "${cfr_user}"
    printf 'cfr_group="%s"\n' "${cfr_group}"
  } >"${runtime_iptables_env}" 2>/dev/null
}

runtime_load() {
  [ -f "${runtime_iptables_env}" ] || return 1
  . "${runtime_iptables_env}"
  return 0
}

runtime_clear() {
  rm -f "${runtime_iptables_env}" >/dev/null 2>&1 || true
}

runtime_env_value() {
  local key="$1"
  [ -f "${runtime_iptables_env}" ] || return 1
  busybox awk -F'"' -v key="${key}" '$0 ~ ("^" key "=") { print $2; exit }' "${runtime_iptables_env}"
}

cleanup_mode_for_apply() {
  local old_mode old_bin old_ipv6 old_dns old_tproxy old_redir old_tun

  [ -f "${runtime_iptables_env}" ] || {
    printf 'all\n'
    return 0
  }

  old_mode="$(runtime_env_value "network_mode")"
  old_bin="$(runtime_env_value "bin_name")"
  old_ipv6="$(runtime_env_value "ipv6")"
  old_dns="$(runtime_env_value "dns_hijack_mode")"
  old_tproxy="$(runtime_env_value "tproxy_port")"
  old_redir="$(runtime_env_value "redir_port")"
  old_tun="$(runtime_env_value "tun_device")"

  [ -n "${old_mode}" ] || {
    printf 'all\n'
    return 0
  }

  if [ "${old_mode}" != "${network_mode}" ] ||
     [ "${old_bin}" != "${bin_name}" ] ||
     [ "${old_ipv6}" != "${ipv6}" ] ||
     [ "${old_dns}" != "${dns_hijack_mode}" ] ||
     [ "${old_tproxy}" != "${tproxy_port}" ] ||
     [ "${old_redir}" != "${redir_port}" ] ||
     [ "${old_tun}" != "${tun_device}" ]; then
    printf 'all\n'
    return 0
  fi

  printf '%s\n' "${old_mode}"
}

current_boot_id() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    cat /proc/sys/kernel/random/boot_id 2>/dev/null
    return 0
  fi

  busybox stat -c '%Y' /proc/1 2>/dev/null
}

load_capability_cache() {
  local current_boot

  [ -f "${cap_cache_file}" ] || return 1
  current_boot="$(current_boot_id)"
  [ -n "${current_boot}" ] || return 1

  . "${cap_cache_file}" 2>/dev/null || return 1

  [ "${cap_cache_boot_id}" = "${current_boot}" ] || return 1
  [ -n "${cap_tproxy4}" ] || return 1
  [ -n "${cap_tproxy6}" ] || return 1
  [ -n "${cap_socket_match}" ] || return 1
  [ -n "${cap_socket_transparent}" ] || return 1
  [ -n "${cap_conntrack_match}" ] || return 1
  [ -n "${cap_connmark_match}" ] || return 1
  [ -n "${cap_connmark_target}" ] || return 1
  [ -n "${cap_ipset}" ] || return 1
  [ -n "${cap_ip6_nat}" ] || return 1

  return 0
}

save_capability_cache() {
  local current_boot

  current_boot="$(current_boot_id)"
  [ -n "${current_boot}" ] || return 1
  mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true

  {
    printf 'cap_cache_boot_id="%s"\n' "${current_boot}"
    printf 'cap_tproxy4="%s"\n' "${cap_tproxy4}"
    printf 'cap_tproxy6="%s"\n' "${cap_tproxy6}"
    printf 'cap_socket_match="%s"\n' "${cap_socket_match}"
    printf 'cap_socket_transparent="%s"\n' "${cap_socket_transparent}"
    printf 'cap_conntrack_match="%s"\n' "${cap_conntrack_match}"
    printf 'cap_connmark_match="%s"\n' "${cap_connmark_match}"
    printf 'cap_connmark_target="%s"\n' "${cap_connmark_target}"
    printf 'cap_ipset="%s"\n' "${cap_ipset}"
    printf 'cap_ip6_nat="%s"\n' "${cap_ip6_nat}"
  } > "${cap_cache_file}" 2>/dev/null
}

cap_has_target() {
  local family="$1"
  local target="$2"
  local f
  if [ "${family}" = "6" ]; then
    f="/proc/net/ip6_tables_targets"
  else
    f="/proc/net/ip_tables_targets"
  fi
  [ -r "${f}" ] || return 1
  busybox grep -qw "${target}" "${f}"
}

cap_has_match() {
  local family="$1"
  local match="$2"
  local f
  if [ "${family}" = "6" ]; then
    f="/proc/net/ip6_tables_matches"
  else
    f="/proc/net/ip_tables_matches"
  fi
  [ -r "${f}" ] || return 1
  busybox grep -qw "${match}" "${f}"
}

probe_capabilities() {
  if load_capability_cache; then
    return 0
  fi

  cap_tproxy4="false"
  cap_tproxy6="false"
  cap_socket_match="false"
  cap_socket_transparent="false"
  cap_conntrack_match="false"
  cap_connmark_match="false"
  cap_connmark_target="false"
  cap_ipset="false"
  cap_ip6_nat="false"

  cap_has_target 4 TPROXY && cap_tproxy4="true"
  cap_has_target 6 TPROXY && cap_tproxy6="true"

  # socket 匹配（检测是否支持 -m socket --transparent）
  (cap_has_match 4 socket || cap_has_match 6 socket) && cap_socket_match="true"
  if [ "${cap_socket_match}" = "true" ]; then
    local _socket_probe_chain="cfr_SOCKET_PROBE"
    ${IPV} -t mangle -N "${_socket_probe_chain}" >/dev/null 2>&1 || true
    ${IPV} -t mangle -F "${_socket_probe_chain}" >/dev/null 2>&1 || true
    if ${IPV} -t mangle -A "${_socket_probe_chain}" -p tcp -m socket --transparent -j RETURN >/dev/null 2>&1; then
      cap_socket_transparent="true"
    fi
    ${IPV} -t mangle -F "${_socket_probe_chain}" >/dev/null 2>&1 || true
    ${IPV} -t mangle -X "${_socket_probe_chain}" >/dev/null 2>&1 || true
  fi
  (cap_has_match 4 conntrack || cap_has_match 6 conntrack) && cap_conntrack_match="true"
  (cap_has_match 4 connmark || cap_has_match 6 connmark) && cap_connmark_match="true"
  (cap_has_target 4 CONNMARK || cap_has_target 6 CONNMARK) && cap_connmark_target="true"

  command -v ipset >/dev/null 2>&1 && cap_ipset="true"
  ip6_nat_supported && cap_ip6_nat="true"
  save_capability_cache || true
}

# 同样的日志在一次启动周期内只记一次（标记文件由 service.sh 启动时清空）
log_once() {
  local key="$1"
  shift
  local stamp="${cfr_run_state}/logged_${key}"
  [ -f "${stamp}" ] && return 0
  : > "${stamp}" 2>/dev/null
  log "$@"
}

# 一行概括运行参数，只附加与默认值不同的开关
log_context() {
  local extra=""
  [ "${proxy_tcp}" != "true" ] && extra="${extra} TCP=${proxy_tcp}"
  [ "${proxy_udp}" != "true" ] && extra="${extra} UDP=${proxy_udp}"
  [ "${quic}" != "enable" ] && extra="${extra} QUIC=${quic}"
  [ "${performance_mode}" = "true" ] && extra="${extra} 性能=开"
  [ "${bypass_cn_ip}" = "true" ] && extra="${extra} 大陆IP=开"
  [ "${mac_filter}" = "true" ] && extra="${extra} MAC=开"
  log_once ctx Info "运行: ${network_mode} | IPv6=${ipv6} | DNS=${dns_hijack_mode}${extra}"
}

apply_capability_downgrades() {
  probe_capabilities

  local _old_mode="${network_mode}"
  local _old_dns="${dns_hijack_mode}"
  local _old_cn="${bypass_cn_ip}"

  if [[ "${network_mode}" == @(tproxy|enhance) ]] && [ "${cap_tproxy4}" != "true" ]; then
    log Warning "降级: 内核不支持 TPROXY，网络模式 ${network_mode} -> redirect"
    network_mode="redirect"
  fi

  if [ "${dns_hijack_mode}" = "tproxy" ] && [ "${cap_tproxy4}" != "true" ]; then
    log Warning "降级: 内核不支持 TPROXY，DNS劫持模式 tproxy -> redirect"
    dns_hijack_mode="redirect"
  fi

  if [ "${bypass_cn_ip}" = "true" ] && [ "${cap_ipset}" != "true" ]; then
    log Warning "降级: ipset 不可用，大陆IP分流 true -> false"
    bypass_cn_ip="false"
    bypass_cn_ip_v4="false"
    bypass_cn_ip_v6="false"
  fi

  [ "${_old_mode}" != "${network_mode}" ] && log Info "最终网络模式=${network_mode}"
  [ "${_old_dns}" != "${dns_hijack_mode}" ] && log Info "最终 DNS劫持模式=${dns_hijack_mode}"
  [ "${_old_cn}" != "${bypass_cn_ip}" ] && log Info "最终大陆IP分流=${bypass_cn_ip}"
}

setup_nat_dns_chain() {
  local chain_name="$1"
  local dns_port="$2"
  local family="$3"
  local label="$4"

  ensure_chain nat "${chain_name}"
  if ! add_core_bypass_rule nat "${chain_name}" -I; then
    [ "${iptables}" = "$IPV" ] && log Warning "${label}内核进程旁路失败，owner 匹配不可用，可能导致 DNS 回环。"
  fi
  if [ "${family}" = "4" ] && [ "${ignore_ap_list}" != "" ]; then
    for ignore in "${ignore_ap_list[@]}" ; do
      ensure_rule_append nat "${chain_name}" -i "${ignore}" -j RETURN
    done
  fi
  if dns_tcp_enabled; then
    ensure_rule_append nat "${chain_name}" -p tcp --dport 53 -j REDIRECT --to-ports "${dns_port}"
  fi
  if dns_udp_enabled; then
    ensure_rule_append nat "${chain_name}" -p udp --dport 53 -j REDIRECT --to-ports "${dns_port}"
  fi
  ensure_jump nat PREROUTING "${chain_name}"
  ensure_jump nat OUTPUT "${chain_name}"
}

setup_nat_dns_hijack() {
  setup_nat_dns_chain "$1" "$2" "$3" "DNS "
}

dns_mode_is_redirect() {
  [ "${dns_hijack_mode}" = "redirect" ]
}

dns_mode_is_disable() {
  [ "${dns_hijack_mode}" = "disable" ]
}

dns_tcp_enabled() {
  [ "${dns_hijack_tcp}" = "true" ]
}

dns_udp_enabled() {
  [ "${dns_hijack_udp}" = "true" ]
}

uid_list_has_entries() {
  [ -s "${uid_list}" ]
}

cnip_force_proxy_uid_list_has_entries() {
  [ -s "${cnip_force_proxy_uid_list}" ]
}

# 返回当前地址族对应的 CNIP ipset 名；未启用或未就绪时失败
cnip_force_proxy_set_name() {
  [ "${bypass_cn_ip}" = "true" ] || return 1
  cnip_force_proxy_uid_list_has_entries || return 1
  command -v ipset >/dev/null 2>&1 || return 1
  if [ "${iptables}" = "$IPV" ]; then
    [ "${bypass_cn_ip_v4}" = "true" ] || return 1
    printf 'cnip\n'
  else
    [ "${bypass_cn_ip_v6}" = "true" ] || return 1
    printf 'cnip6\n'
  fi
}

trim_value() {
  printf '%s' "$1" | busybox sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

prepare_cnip_force_proxy_uids() {
  : > "${cnip_force_proxy_uid_list}"
  [ "${bypass_cn_ip}" = "true" ] || return 0
  [ ${#cnip_force_proxy_apps[@]} -gt 0 ] || return 0

  local packages_file
  packages_file="${system_packages_file:-/data/system/packages.list}"

  for entry in "${cnip_force_proxy_apps[@]}"; do
    entry="$(trim_value "${entry}")"
    [ -n "${entry}" ] || continue

    local prefix="0"
    local package="${entry}"
    local normalized_entry=""

    case "${entry}" in
      *:*)
        prefix="${entry%%:*}"
        package="${entry#*:}"
        ;;
    esac

    prefix="$(trim_value "${prefix}")"
    package="$(trim_value "${package}")"

    case "${prefix}" in
      ''|*[!0-9]*)
        log Warning "CNIP 例外应用 \"${entry}\" 用户前缀无效，已回退为 0"
        prefix="0"
        ;;
    esac

    if [ -z "${package}" ]; then
      log Warning "CNIP 例外应用 \"${entry}\" 包名无效，已跳过"
      continue
    fi

    normalized_entry="${prefix}:${package}"
    if [ "${entry}" = "${package}" ] && [ "${prefix}" = "0" ]; then
      log Info "CNIP 例外应用 \"${entry}\" 未填写用户前缀，已按 \"${normalized_entry}\" 处理"
    fi

    local base_uid
    base_uid=$(busybox awk -v pkg="${package}" '$1 == pkg {print $2; exit}' "${packages_file}" 2>/dev/null)

    case "${base_uid}" in
      ''|*[!0-9]*)
        log Warning "CNIP 例外应用 \"${normalized_entry}\" 未找到 UID，已跳过"
        continue
        ;;
    esac

    echo $((base_uid + prefix * 100000)) >> "${cnip_force_proxy_uid_list}"
  done

  if [ -s "${cnip_force_proxy_uid_list}" ]; then
    local temp_uid_list="${cfr_run_state}/cnip_force_proxy.temp.list"
    busybox sort -un "${cnip_force_proxy_uid_list}" > "${temp_uid_list}"
    mv "${temp_uid_list}" "${cnip_force_proxy_uid_list}"
    log Info "CNIP 例外应用 UID 已加载: $(busybox tr '\n' ' ' < "${cnip_force_proxy_uid_list}" | sed 's/[[:space:]]*$//')"
  fi
}

dns_target_port() {
  local port="${mihomo_dns_port}"
  [ -n "${port}" ] || port="1053"
  printf '%s\n' "${port}"
}

dns_should_use_mihomo_forward() {
  [ "${mihomo_dns_forward}" = "enable" ] || return 1
  [ "${bin_name}" = "mihomo" ] || return 1
  dns_mode_is_redirect && return 1
  dns_mode_is_disable && return 1
  return 0
}

setup_nat_dns_forward() {
  setup_nat_dns_chain "$1" "$2" "$3" "DNS 转发"
}

ensure_dns_nat_hijack() {
  dns_mode_is_redirect || dns_should_use_mihomo_forward || return 0
  if [ "${iptables}" = "$IP6V" ] && ! ip6_nat_supported; then
    [ "${ipv6}" = "true" ] && log Warning "ip6tables NAT 不可用，跳过 IPv6 DNS 重定向。"
    return 0
  fi

  local chain_name="NAT_DNS_HIJACK"
  local family="4"
  if [ "${iptables}" = "$IP6V" ]; then
    chain_name="NAT_DNS_HIJACK6"
    family="6"
  fi

  if dns_mode_is_redirect; then
    setup_nat_dns_hijack "${chain_name}" "$(dns_target_port)" "${family}"
  else
    if [ "${iptables}" = "$IPV" ]; then
      chain_name="NAT_DNS_FORWARD"
    else
      chain_name="NAT_DNS_FORWARD6"
    fi
    setup_nat_dns_forward "${chain_name}" "$(dns_target_port)" "${family}"
  fi
}

append_dns_return_rules() {
  local chain_name="$1"
  if [ "${network_mode}" != "enhance" ] && dns_tcp_enabled; then
    ensure_rule_append mangle "${chain_name}" -p tcp --dport 53 -j RETURN
  fi
  if dns_udp_enabled; then
    ensure_rule_append mangle "${chain_name}" -p udp --dport 53 -j RETURN
  fi
}

append_dns_tproxy_rules() {
  local chain_name="$1"
  if [ "${network_mode}" != "enhance" ] && dns_tcp_enabled && [ "${proxy_tcp}" = "true" ]; then
    append_tproxy_dispatch_rule "${chain_name}" -p tcp --dport 53
  fi
  if dns_udp_enabled && [ "${proxy_udp}" = "true" ]; then
    append_tproxy_dispatch_rule "${chain_name}" -p udp --dport 53
  fi
}

append_dns_mark_rules() {
  local chain_name="$1"
  if [ "${network_mode}" != "enhance" ] && dns_tcp_enabled && [ "${proxy_tcp}" = "true" ]; then
    ensure_rule_append mangle "${chain_name}" -p tcp --dport 53 -j MARK --set-xmark "${fwmark}"
  fi
  if dns_udp_enabled && [ "${proxy_udp}" = "true" ]; then
    ensure_rule_append mangle "${chain_name}" -p udp --dport 53 -j MARK --set-xmark "${fwmark}"
  fi
}

append_redirect_dispatch_rule() {
  local chain_name="$1"
  shift

  if performance_connmark_enabled; then
    ensure_rule_append nat "${chain_name}" "$@" -m conntrack --ctstate NEW,RELATED -j CONNMARK --set-xmark "${fwmark}"
    ensure_rule_append nat "${chain_name}" "$@" -m conntrack --ctstate NEW,RELATED -m connmark --mark "${fwmark}" -j REDIRECT --to-ports "${redir_port}"
    return 0
  fi

  ensure_rule_append nat "${chain_name}" "$@" -j REDIRECT --to-ports "${redir_port}"
}

apply_redirect_connmark_restore_rules() {
  local chain_name="$1"

  performance_connmark_enabled || return 0
  [ "${proxy_tcp}" = "true" ] || return 0
  ensure_rule_append nat "${chain_name}" -p tcp -m connmark --mark "${fwmark}" -j REDIRECT --to-ports "${redir_port}"
}

apply_redirect_performance_rules() {
  [ "${performance_mode}" = "true" ] || return 0
  [ "${iptables}" = "$IPV" ] || return 0

  if redirect_performance_chain_enabled; then
    case "${network_mode}" in
      enhance)
        log Info "性能模式：Enhance 下已启用 REDIRECT 子链快速路径。"
        ;;
      mixed)
        log Info "性能模式：Enhance 下已启用 REDIRECT 子链快速路径。"
        ;;
      *)
        log Info "性能模式：已启用 REDIRECT 子链快速路径。"
        ;;
    esac
  else
    log Warning "性能模式已开启，但 REDIRECT 模式未检测到可用的 conntrack / connmark 支持，跳过额外优化。"
  fi
}

apply_mangle_dns_rules() {
  local chain_name="$1"
  local rule_mode="$2"

  if dns_mode_is_redirect || dns_mode_is_disable || dns_should_use_mihomo_forward; then
    append_dns_return_rules "${chain_name}"
    return 0
  fi

  case "${rule_mode}" in
    tproxy)
      append_dns_tproxy_rules "${chain_name}"
      ;;
    mark)
      append_dns_mark_rules "${chain_name}"
      ;;
  esac
}

ensure_local_ip_chain() {
  local table_name="$1"
  if [ "${iptables}" = "$IPV" ]; then
    ensure_chain "${table_name}" LOCAL_IP_V4
  else
    ensure_chain "${table_name}" LOCAL_IP_V6
  fi
}

append_common_bypass_rules() {
  local table_name="$1"
  local chain_name="$2"

  ensure_local_ip_chain "${table_name}"

  if [ "${iptables}" = "$IPV" ]; then
    for subnet in "${intranet[@]}" ; do
      ensure_rule_append "${table_name}" "${chain_name}" -d ${subnet} -j RETURN
    done
    if [ "${bypass_cn_ip}" = "true" ] && [ "${bypass_cn_ip_v4}" = "true" ] && command -v ipset >/dev/null 2>&1; then
      ensure_rule_append "${table_name}" "${chain_name}" -m set --match-set cnip dst -j RETURN
    fi
    ensure_rule_append "${table_name}" "${chain_name}" -j LOCAL_IP_V4
  else
    for subnet6 in "${intranet6[@]}" ; do
      ensure_rule_append "${table_name}" "${chain_name}" -d ${subnet6} -j RETURN
    done
    if [ "${bypass_cn_ip}" = "true" ] && [ "${bypass_cn_ip_v6}" = "true" ] && command -v ipset >/dev/null 2>&1; then
      ensure_rule_append "${table_name}" "${chain_name}" -m set --match-set cnip6 dst -j RETURN
    fi
    ensure_rule_append "${table_name}" "${chain_name}" -j LOCAL_IP_V6
  fi
}

append_cnip_force_proxy_local_rules() {
  local table_name="$1"
  local chain_name="$2"
  local action="$3"
  local set_name

  set_name="$(cnip_force_proxy_set_name)" || return 0

  while read -r appid; do
    [ -n "${appid}" ] || continue
    case "${action}" in
      redirect)
        [ "${proxy_tcp}" = "true" ] || continue
        append_redirect_dispatch_rule "${chain_name}" -p tcp -m owner --uid-owner "${appid}" -m set --match-set "${set_name}" dst
        ;;
      mark)
        if [ "${network_mode}" != "enhance" ] && [ "${proxy_tcp}" = "true" ]; then
          ensure_rule_append "${table_name}" "${chain_name}" -p tcp -m owner --uid-owner "${appid}" -m set --match-set "${set_name}" dst -j MARK --set-xmark "${fwmark}"
          ensure_rule_append "${table_name}" "${chain_name}" -p tcp -m owner --uid-owner "${appid}" -m set --match-set "${set_name}" dst -j RETURN
        fi
        if [ "${proxy_udp}" = "true" ]; then
          ensure_rule_append "${table_name}" "${chain_name}" -p udp -m owner --uid-owner "${appid}" -m set --match-set "${set_name}" dst -j MARK --set-xmark "${fwmark}"
          ensure_rule_append "${table_name}" "${chain_name}" -p udp -m owner --uid-owner "${appid}" -m set --match-set "${set_name}" dst -j RETURN
        fi
        ;;
    esac
  done < "${cnip_force_proxy_uid_list}"
}

append_cnip_force_proxy_tun_rules() {
  local chain_name="$1"
  local set_name

  set_name="$(cnip_force_proxy_set_name)" || return 0

  while read -r appid; do
    [ -n "${appid}" ] || continue
    if [ "${proxy_tcp}" = "true" ]; then
      ensure_rule_append mangle "${chain_name}" -p tcp -m owner --uid-owner "${appid}" -m set --match-set "${set_name}" dst -j MARK --set-xmark "${tun_route_mark}"
      ensure_rule_append mangle "${chain_name}" -p tcp -m owner --uid-owner "${appid}" -m set --match-set "${set_name}" dst -j RETURN
    fi
    if [ "${proxy_udp}" = "true" ]; then
      ensure_rule_append mangle "${chain_name}" -p udp -m owner --uid-owner "${appid}" -m set --match-set "${set_name}" dst -j MARK --set-xmark "${tun_route_mark}"
      ensure_rule_append mangle "${chain_name}" -p udp -m owner --uid-owner "${appid}" -m set --match-set "${set_name}" dst -j RETURN
    fi
  done < "${cnip_force_proxy_uid_list}"
}

append_local_protocol_rule() {
  local table_name="$1"
  local chain_name="$2"
  local proto="$3"
  local action="$4"
  local owner_kind="$5"
  local owner_value="$6"

  if [ "${proto}" = "tcp" ]; then
    [ "${proxy_tcp}" = "true" ] || return 0
  else
    [ "${proxy_udp}" = "true" ] || return 0
  fi

  set -- -p "${proto}"
  if [ -n "${owner_kind}" ] && [ -n "${owner_value}" ]; then
    set -- "$@" -m owner "--${owner_kind}" "${owner_value}"
  fi

  case "${action}" in
    redirect)
      [ "${proto}" = "tcp" ] || return 0
      append_redirect_dispatch_rule "${chain_name}" "$@"
      ;;
    mark)
      if [ "${proto}" = "tcp" ] && [ "${network_mode}" = "enhance" ]; then
        return 0
      fi
      ensure_rule_append "${table_name}" "${chain_name}" "$@" -j MARK --set-xmark "${fwmark}"
      ;;
  esac
}

apply_local_proxy_rules() {
  local table_name="$1"
  local chain_name="$2"
  local action="$3"

  case "${proxy_mode}" in
    core)
      append_local_protocol_rule "${table_name}" "${chain_name}" tcp "${action}"
      append_local_protocol_rule "${table_name}" "${chain_name}" udp "${action}"
      [ "${iptables}" = "$IPV" ] && [ "${network_mode}" != "enhance" ] && log Info "核心模式：所有应用透明代理。"
      ;;
    blacklist|black)
      if uid_list_has_entries; then
        while read -r appid; do
          ensure_rule_append "${table_name}" "${chain_name}" -m owner --uid-owner "${appid}" -j RETURN
        done < "${uid_list}"
      fi
      if [ "${gid_list}" != "" ] ; then
        for gid in "${gid_list[@]}" ; do
          ensure_rule_append "${table_name}" "${chain_name}" -m owner --gid-owner ${gid} -j RETURN
        done
      fi
      append_local_protocol_rule "${table_name}" "${chain_name}" tcp "${action}"
      append_local_protocol_rule "${table_name}" "${chain_name}" udp "${action}"
      if [ "${iptables}" = "$IPV" ] && [ "${network_mode}" != "enhance" ]; then
        if uid_list_has_entries || [ "${gid_list}" != "" ]; then
          log Info "黑名单模式: ${packages_list[*]} 不走代理，其余应用走代理。"
        else
          log Info "黑名单为空，所有应用走代理。"
        fi
      fi
      ;;
    whitelist|white)
      if uid_list_has_entries; then
        while read -r appid; do
          append_local_protocol_rule "${table_name}" "${chain_name}" tcp "${action}" "uid-owner" "${appid}"
          append_local_protocol_rule "${table_name}" "${chain_name}" udp "${action}" "uid-owner" "${appid}"
        done < "${uid_list}"
        append_local_protocol_rule "${table_name}" "${chain_name}" tcp "${action}" "uid-owner" "0"
        append_local_protocol_rule "${table_name}" "${chain_name}" udp "${action}" "uid-owner" "0"
        append_local_protocol_rule "${table_name}" "${chain_name}" tcp "${action}" "uid-owner" "1051"
        append_local_protocol_rule "${table_name}" "${chain_name}" udp "${action}" "uid-owner" "1051"
        append_local_protocol_rule "${table_name}" "${chain_name}" tcp "${action}" "uid-owner" "1052"
        append_local_protocol_rule "${table_name}" "${chain_name}" udp "${action}" "uid-owner" "1052"
      else
        append_local_protocol_rule "${table_name}" "${chain_name}" tcp "${action}"
        append_local_protocol_rule "${table_name}" "${chain_name}" udp "${action}"
      fi
      if [ "${gid_list}" != "" ] ; then
        for gid in "${gid_list[@]}" ; do
          append_local_protocol_rule "${table_name}" "${chain_name}" tcp "${action}" "gid-owner" "${gid}"
          append_local_protocol_rule "${table_name}" "${chain_name}" udp "${action}" "gid-owner" "${gid}"
        done
      fi
      [ "${iptables}" = "$IPV" ] && [ "${network_mode}" != "enhance" ] && {
        if uid_list_has_entries || [ "${gid_list}" != "" ]; then
          log Info "白名单模式: ${packages_list[*]} 走代理，其余应用不走代理。"
        else
          log Warning "白名单为空，已退化为所有应用均走代理。"
        fi
      }
      ;;
    *)
      log Warning "代理模式: ${proxy_mode} 配置错误。"
      append_local_protocol_rule "${table_name}" "${chain_name}" tcp "${action}"
      append_local_protocol_rule "${table_name}" "${chain_name}" udp "${action}"
      [ "${iptables}" = "$IPV" ] && [ "${network_mode}" != "enhance" ] && log Info "所有应用透明代理。"
      ;;
  esac
}

loopback_addr() {
  if [ "${iptables}" = "$IPV" ]; then
    printf '127.0.0.1\n'
  else
    printf '::1\n'
  fi
}

tun_bypass_pre_chain() {
  if [ "${iptables}" = "$IPV" ]; then
    printf 'cfr_TUN_BYPASS_PRE\n'
  else
    printf 'cfr_TUN_BYPASS6_PRE\n'
  fi
}

tun_bypass_out_chain() {
  if [ "${iptables}" = "$IPV" ]; then
    printf 'cfr_TUN_BYPASS_OUT\n'
  else
    printf 'cfr_TUN_BYPASS6_OUT\n'
  fi
}

tun_bypass_family_label() {
  if [ "${iptables}" = "$IPV" ]; then
    printf 'IPv4\n'
  else
    printf 'IPv6\n'
  fi
}

current_cnip_set_name() {
  if [ "${iptables}" = "$IPV" ]; then
    [ "${bypass_cn_ip_v4}" = "true" ] && printf 'cnip\n'
  else
    [ "${bypass_cn_ip_v6}" = "true" ] && printf 'cnip6\n'
  fi
}

append_mark_and_return_rule() {
  local table_name="$1"
  local chain_name="$2"
  local mark_value="$3"
  shift 3

  ensure_rule_append "${table_name}" "${chain_name}" "$@" -j MARK --set-xmark "${mark_value}"
  ensure_rule_append "${table_name}" "${chain_name}" "$@" -j RETURN
}

append_tun_dns_rules() {
  local chain_name="$1"
  dns_mode_is_disable && return 0

  if dns_tcp_enabled; then
    append_mark_and_return_rule mangle "${chain_name}" "${tun_route_mark}" -p tcp --dport 53
  fi
  if dns_udp_enabled; then
    append_mark_and_return_rule mangle "${chain_name}" "${tun_route_mark}" -p udp --dport 53
  fi
}

append_tun_fake_ip_route_rules() {
  local chain_name="$1"
  local fake_range=""

  if [ "${iptables}" = "$IPV" ]; then
    fake_range="${fake_ip_range}"
  else
    fake_range="${fake_ip6_range}"
  fi

  [ -n "${fake_range}" ] || return 0

  ensure_rule_append mangle "${chain_name}" -d "${fake_range}" -j MARK --set-xmark "${tun_route_mark}"
  ensure_rule_append mangle "${chain_name}" -d "${fake_range}" -j RETURN
}

append_tun_bypass_destination_rules() {
  local chain_name="$1"
  local set_name=""

  append_tun_fake_ip_route_rules "${chain_name}"

  if [ "${iptables}" = "$IPV" ]; then
    for subnet in "${intranet[@]}" ; do
      ensure_rule_append mangle "${chain_name}" -d ${subnet} -j RETURN
    done
  else
    for subnet6 in "${intranet6[@]}" ; do
      ensure_rule_append mangle "${chain_name}" -d ${subnet6} -j RETURN
    done
  fi

  if [ "${bypass_cn_ip}" = "true" ] && command -v ipset >/dev/null 2>&1; then
    set_name="$(current_cnip_set_name)"
    [ -n "${set_name}" ] && ensure_rule_append mangle "${chain_name}" -m set --match-set "${set_name}" dst -j MARK --set-xmark "${tun_bypass_mark}"
  fi

  ensure_rule_append mangle "${chain_name}" -m mark --mark "${tun_bypass_mark}" -j RETURN
  ensure_rule_append mangle "${chain_name}" -j MARK --set-xmark "${tun_route_mark}"
}

append_tun_proxy_mode_rules() {
  local chain_name="$1"

  case "${proxy_mode}" in
    blacklist|black)
      if uid_list_has_entries; then
        while read -r appid; do
          ensure_rule_append mangle "${chain_name}" -m owner --uid-owner "${appid}" -j RETURN
        done < "${uid_list}"
      fi
      if [ "${gid_list}" != "" ]; then
        for gid in "${gid_list[@]}"; do
          ensure_rule_append mangle "${chain_name}" -m owner --gid-owner ${gid} -j RETURN
        done
      fi
      ;;
    whitelist|white)
      if uid_list_has_entries; then
        while read -r appid; do
          ensure_rule_append mangle "${chain_name}" -m owner --uid-owner "${appid}" -j MARK --set-xmark "${tun_route_mark}"
        done < "${uid_list}"
      fi
      if [ "${gid_list}" != "" ]; then
        for gid in "${gid_list[@]}"; do
          ensure_rule_append mangle "${chain_name}" -m owner --gid-owner ${gid} -j MARK --set-xmark "${tun_route_mark}"
        done
      fi
      if uid_list_has_entries || [ "${gid_list}" != "" ]; then
        ensure_rule_append mangle "${chain_name}" -j RETURN
      fi
      ;;
  esac
}

append_tun_core_bypass_rules() {
  local chain_name="$1"

  if ! add_core_bypass_rule mangle "${chain_name}" -A; then
    ensure_rule_append mangle "${chain_name}" -m mark --mark "${tun_bypass_mark}" -j RETURN
    [ "${iptables}" = "$IPV" ] && log Warning "TUN 内核进程旁路失败，owner 匹配不可用，已降级为 mark 旁路。"
  fi
}

apply_tun_route_rules() {
  if [ "${iptables}" = "$IPV" ]; then
    ensure_ip_rule ip "${tun_bypass_mark}" "main" "${tun_bypass_pref}"
    ensure_ip_rule ip "${tun_route_mark}" "${tun_route_table}" "${tun_route_pref}"
    ip route replace default dev "${tun_device}" table "${tun_route_table}" >/dev/null 2>&1 || return 1
  else
    ensure_ip_rule "ip -6" "${tun_bypass_mark}" "main" "${tun_bypass_pref}"
    ensure_ip_rule "ip -6" "${tun_route_mark}" "${tun_route_table}" "${tun_route_pref}"
    ip -6 route replace default dev "${tun_device}" table "${tun_route_table}" >/dev/null 2>&1 || return 1
  fi

}

cleanup_tun_route_rules() {
  if [ "${iptables}" = "$IPV" ]; then
    del_ip_rule_if_exists ip "${tun_bypass_mark}" "main" "${tun_bypass_pref}"
    del_ip_rule_if_exists ip "${tun_route_mark}" "${tun_route_table}" "${tun_route_pref}"
    ip route flush table "${tun_route_table}" >/dev/null 2>&1 || true
  else
    del_ip_rule_if_exists "ip -6" "${tun_bypass_mark}" "main" "${tun_bypass_pref}"
    del_ip_rule_if_exists "ip -6" "${tun_route_mark}" "${tun_route_table}" "${tun_route_pref}"
    ip -6 route flush table "${tun_route_table}" >/dev/null 2>&1 || true
  fi
}

apply_loopback_reject_rule() {
  local port="$1"
  ensure_rule_append filter OUTPUT -d "$(loopback_addr)" -p tcp -m owner --uid-owner "${cfr_user}" --gid-owner "${cfr_group}" -m tcp --dport "${port}" -j REJECT
}

cleanup_loopback_reject_rule() {
  local port="$1"
  del_rule_silent filter OUTPUT -d "$(loopback_addr)" -p tcp -m owner --uid-owner "${cfr_user}" --gid-owner "${cfr_group}" -m tcp --dport "${port}" -j REJECT
  if [ "${iptables}" = "$IPV" ]; then
    del_rule_silent filter OUTPUT -d "$(loopback_addr)" -p tcp -m owner --uid-owner 0:3005 -m tcp --dport "${port}" -j REJECT
    del_rule_silent filter OUTPUT -d "$(loopback_addr)" -p tcp -m owner --uid-owner 0 --gid-owner 3005 -m tcp --dport "${port}" -j REJECT
  else
    del_rule_silent filter OUTPUT -d "$(loopback_addr)" -p tcp -m owner --uid-owner 0:3005 -m tcp --dport "${port}" -j REJECT
    del_rule_silent filter OUTPUT -d "$(loopback_addr)" -p tcp -m owner --uid-owner 0 --gid-owner 3005 -m tcp --dport "${port}" -j REJECT
  fi
}

apply_quic_block_rules() {
  [ "${quic}" = "disable" ] || return 0
  # tproxy/enhance 模式下 UDP 已被代理，仅在 proxy_udp=true 时需要阻断；
  # redirect/mixed 模式不代理 UDP，QUIC 会绕过代理直连，因此无论 proxy_udp 如何都应阻断。
  if [ "${network_mode}" != "redirect" ] && [ "${network_mode}" != "mixed" ] && [ "${proxy_udp}" != "true" ]; then
    return 0
  fi
  ensure_rule_append filter OUTPUT -p udp --dport 443 -j REJECT
  ensure_rule_append filter OUTPUT -p udp --dport 80 -j REJECT
  [ "${iptables}" = "$IPV" ] && log Warning "已禁用 QUIC"
}

cleanup_quic_block_rules() {
  del_rule_silent filter OUTPUT -p udp -m multiport --dport 443,80 -j REJECT
  del_rule_silent filter OUTPUT -p udp --dport 443 -j REJECT
  del_rule_silent filter OUTPUT -p udp --dport 80 -j REJECT
}

apply_dot_block_rules() {
  [ "${block_dot:-true}" = "true" ] || return 0
  dns_mode_is_disable && return 0

  ensure_chain filter cfr_DOT_BLOCK
  add_core_bypass_rule filter cfr_DOT_BLOCK -I >/dev/null 2>&1 || true
  ensure_rule_append filter cfr_DOT_BLOCK -o lo -j RETURN
  ensure_rule_append filter cfr_DOT_BLOCK -p tcp --dport 853 -j REJECT --reject-with tcp-reset
  ensure_jump filter OUTPUT cfr_DOT_BLOCK
  [ "${iptables}" = "$IPV" ] && log_once dot_block Info "已阻断 Android Private DNS (TCP 853)，防止绕过代理 DNS"
}

cleanup_dot_block_rules() {
  del_jump_silent filter OUTPUT cfr_DOT_BLOCK
  cleanup_chain_fast filter cfr_DOT_BLOCK
}

collect_protected_local_ports() {
  local scope="${1:-out}"
  local ports="" p=""
  if [ -f "${mihomo_config}" ]; then
    ports="$(busybox awk -v scope="${scope}" -v protect_ctrl="${protect_controller_port:-false}" '
      !/^[[:space:]]*#/ {
        is_ctrl = ($0 ~ /^external-controller:[[:space:]]*/)
        is_proxy = ($0 ~ /^(port|socks-port|mixed-port):[[:space:]]*/)
        if ((is_ctrl && (scope == "in" || protect_ctrl == "true")) || is_proxy) {
          val = $0
          sub(/^[^:]+:[[:space:]]*/, "", val)
          sub(/[[:space:]]*(#.*)?$/, "", val)
          gsub(/["\x27]/, "", val)
          if (val ~ /:/) {
            sub(/^.*:/, "", val)
          }
          if (val ~ /^[0-9]+$/ && val + 0 > 0) print val
        }
      }
    ' "${mihomo_config}" 2>/dev/null)"
  fi
  case "${network_mode}" in
    tproxy|enhance)
      [ -n "${tproxy_port}" ] && ports="${ports} ${tproxy_port}"
      ;;
  esac
  for p in ${ports}; do
    printf '%s\n' "${p}"
  done | busybox sort -un
}

apply_local_port_protect_rules() {
  [ "${stealth_mode:-true}" = "true" ] || return 0
  local in_ports out_ports port
  in_ports="$(collect_protected_local_ports in)"
  out_ports="$(collect_protected_local_ports out)"

  # 非回环入站一律拒绝扫描管理端口与本地代理端口（允许局域网控制时除外）
  if [ "${allow_lan_controller:-false}" != "true" ] && [ -n "${in_ports}" ]; then
    ensure_chain filter cfr_PORT_IN
    ensure_rule_append filter cfr_PORT_IN -i lo -j RETURN
    for port in ${in_ports}; do
      ensure_rule_append filter cfr_PORT_IN -p tcp --dport "${port}" -j REJECT --reject-with tcp-reset
    done
    ensure_jump filter INPUT cfr_PORT_IN
  fi

  # 本机回环只允许 root(0) 与内核用户连接受保护端口，阻止普通 App 本地端口指纹探测
  if [ -n "${out_ports}" ]; then
    ensure_chain filter cfr_PORT_OUT
    local loop_dst
    if [ "${iptables}" = "$IPV" ]; then
      loop_dst="127.0.0.0/8"
    else
      loop_dst="::1/128"
    fi
    ensure_rule_append filter cfr_PORT_OUT -m owner --uid-owner 0 -j RETURN
    add_core_bypass_rule filter cfr_PORT_OUT -A >/dev/null 2>&1 || true
    for port in ${out_ports}; do
      ensure_rule_append filter cfr_PORT_OUT -d "${loop_dst}" -p tcp --dport "${port}" -j REJECT --reject-with tcp-reset
    done
    ensure_jump filter OUTPUT cfr_PORT_OUT
  fi
  [ "${iptables}" = "$IPV" ] && log_once port_protect Info "已启用本地控制/代理端口隐匿保护"
}

cleanup_local_port_protect_rules() {
  del_jump_silent filter INPUT cfr_PORT_IN
  del_jump_silent filter OUTPUT cfr_PORT_OUT
  cleanup_chain_fast filter cfr_PORT_IN
  cleanup_chain_fast filter cfr_PORT_OUT
}

apply_killswitch_family() {
  ensure_chain filter cfr_KILLSWITCH
  ensure_rule_append filter cfr_KILLSWITCH -o lo -j ACCEPT
  ensure_rule_append filter cfr_KILLSWITCH -m owner --uid-owner 0 -j ACCEPT
  add_core_bypass_rule filter cfr_KILLSWITCH -A >/dev/null 2>&1 || true

  if [ "${iptables}" = "$IPV" ]; then
    for subnet in "${intranet[@]}"; do
      ensure_rule_append filter cfr_KILLSWITCH -d "${subnet}" -j ACCEPT
    done
  else
    for subnet6 in "${intranet6[@]}"; do
      ensure_rule_append filter cfr_KILLSWITCH -d "${subnet6}" -j ACCEPT
    done
  fi

  ensure_rule_append filter cfr_KILLSWITCH -p tcp -j REJECT --reject-with tcp-reset
  ensure_rule_append filter cfr_KILLSWITCH -j REJECT
  ensure_jump filter OUTPUT cfr_KILLSWITCH
}

cleanup_killswitch_family() {
  del_jump_silent filter OUTPUT cfr_KILLSWITCH
  cleanup_chain_fast filter cfr_KILLSWITCH
}

enable_killswitch() {
  [ "${kill_switch:-true}" = "true" ] || return 0
  probe_user_group >/dev/null 2>&1 || true
  local current_iptables
  for current_iptables in "$IPV" "$IP6V"; do
    iptables="${current_iptables}"
    apply_killswitch_family >/dev/null 2>&1 || true
  done
  iptables="$IPV"
  log_once killswitch_on Info "Kill-Switch 临时防漏阻断已开启"
}

disable_killswitch() {
  local current_iptables
  for current_iptables in "$IPV" "$IP6V"; do
    iptables="${current_iptables}"
    cleanup_killswitch_family >/dev/null 2>&1 || true
  done
  iptables="$IPV"
}

cleanup_dns_nat_hijack_chains() {
  if [ "${iptables}" = "$IPV" ]; then
    del_jump_silent nat PREROUTING NAT_DNS_HIJACK
    del_jump_silent nat OUTPUT NAT_DNS_HIJACK
    cleanup_chain_fast nat NAT_DNS_HIJACK
    del_jump_silent nat PREROUTING NAT_DNS_FORWARD
    del_jump_silent nat OUTPUT NAT_DNS_FORWARD
    cleanup_chain_fast nat NAT_DNS_FORWARD
  else
    del_jump_silent nat PREROUTING NAT_DNS_HIJACK6
    del_jump_silent nat OUTPUT NAT_DNS_HIJACK6
    cleanup_chain_fast nat NAT_DNS_HIJACK6
    del_jump_silent nat PREROUTING NAT_DNS_FORWARD6
    del_jump_silent nat OUTPUT NAT_DNS_FORWARD6
    cleanup_chain_fast nat NAT_DNS_FORWARD6
  fi
}

cleanup_legacy_mihomo_dns_chains() {
  [ "${iptables}" = "$IPV" ] || return 0
  del_jump_silent nat PREROUTING MIHOMO_DNS_EXTERNAL
  del_jump_silent nat OUTPUT MIHOMO_DNS_LOCAL
  cleanup_chain_fast nat MIHOMO_DNS_EXTERNAL
  cleanup_chain_fast nat MIHOMO_DNS_LOCAL
}

setup_fake_ip_icmp_rules() {
  [ "${bin_name}" = "mihomo" ] || return 0
  if [ "${iptables}" = "$IPV" ]; then
    [ -n "${fake_ip_range}" ] || return 0
    ensure_rule_insert nat OUTPUT -d "${fake_ip_range}" -p icmp -j DNAT --to-destination 127.0.0.1
    ensure_rule_insert nat PREROUTING -d "${fake_ip_range}" -p icmp -j DNAT --to-destination 127.0.0.1
  else
    [ -n "${fake_ip6_range}" ] || return 0
    ip6_nat_supported || return 0
    ensure_rule_insert nat OUTPUT -d "${fake_ip6_range}" -p ipv6-icmp -j DNAT --to-destination ::1
    ensure_rule_insert nat PREROUTING -d "${fake_ip6_range}" -p ipv6-icmp -j DNAT --to-destination ::1
  fi
}

cleanup_fake_ip_icmp_rules() {
  if [ "${iptables}" = "$IPV" ]; then
    [ -n "${fake_ip_range}" ] || return 0
    del_rule_silent nat OUTPUT -p icmp -d "${fake_ip_range}" -j DNAT --to-destination 127.0.0.1
    del_rule_silent nat PREROUTING -p icmp -d "${fake_ip_range}" -j DNAT --to-destination 127.0.0.1
    del_rule_silent nat OUTPUT -d "${fake_ip_range}" -p icmp -j DNAT --to-destination 127.0.0.1
    del_rule_silent nat PREROUTING -d "${fake_ip_range}" -p icmp -j DNAT --to-destination 127.0.0.1
  else
    [ -n "${fake_ip6_range}" ] || return 0
    ip6_nat_supported || return 0
    del_rule_silent nat OUTPUT -d "${fake_ip6_range}" -p ipv6-icmp -j DNAT --to-destination ::1
    del_rule_silent nat PREROUTING -d "${fake_ip6_range}" -p ipv6-icmp -j DNAT --to-destination ::1
  fi
}

setup_tproxy_policy_routing() {
  if [ "${iptables}" = "$IPV" ]; then
    ensure_ip_rule ip "${fwmark}" "${table}" "${pref}"
    ensure_ip_route_local_default ip "${table}"
  else
    ensure_ip_rule "ip -6" "${fwmark}" "${table}" "${pref}"
    ensure_ip_route_local_default "ip -6" "${table}"
  fi
}

cleanup_tproxy_policy_routing() {
  if [ "${iptables}" = "$IPV" ]; then
    del_ip_rule_if_exists ip "${fwmark}" "${table}" "${pref}"
    del_ip_route_local_default_if_exists ip "${table}"
    ip route flush table "${table}" >/dev/null 2>&1 || true
    ip rule del pref "${pref}" >/dev/null 2>&1 || true
  else
    del_ip_rule_if_exists "ip -6" "${fwmark}" "${table}" "${pref}"
    del_ip_route_local_default_if_exists "ip -6" "${table}"
    ip -6 route flush table "${table}" >/dev/null 2>&1 || true
    ip -6 rule del pref "${pref}" >/dev/null 2>&1 || true
  fi
}

apply_tproxy_ipv6_fakeip_rules() {
  local chain_name="$1"
  local action="$2"

  [ "${iptables}" = "$IP6V" ] || return 0
  [ -n "${fake_ip6_range}" ] || return 0
  [ "${bin_name}" = "mihomo" ] || return 0

  case "${action}" in
    tproxy)
      if [ "${network_mode}" != "enhance" ] && [ "${proxy_tcp}" = "true" ]; then
        ensure_rule_append mangle "${chain_name}" -p tcp -d "${fake_ip6_range}" -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
      fi
      if [ "${proxy_udp}" = "true" ]; then
        ensure_rule_append mangle "${chain_name}" -p udp -d "${fake_ip6_range}" -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
      fi
      ;;
    mark)
      if [ "${network_mode}" != "enhance" ] && [ "${proxy_tcp}" = "true" ]; then
        ensure_rule_append mangle "${chain_name}" -p tcp -d "${fake_ip6_range}" -j MARK --set-xmark "${fwmark}"
      fi
      if [ "${proxy_udp}" = "true" ]; then
        ensure_rule_append mangle "${chain_name}" -p udp -d "${fake_ip6_range}" -j MARK --set-xmark "${fwmark}"
      fi
      ;;
  esac
}

performance_conntrack_enabled() {
  [ "${performance_mode}" = "true" ] || return 1
  [ "${cap_conntrack_match}" = "true" ] || return 1
  return 0
}

performance_connmark_enabled() {
  [ "${performance_mode}" = "true" ] || return 1
  [ "${cap_conntrack_match}" = "true" ] || return 1
  [ "${cap_connmark_match}" = "true" ] || return 1
  [ "${cap_connmark_target}" = "true" ] || return 1
  return 0
}

redirect_performance_chain_enabled() {
  performance_connmark_enabled
}

tproxy_performance_chain_enabled() {
  performance_connmark_enabled || return 1
  if [ "${network_mode}" != "enhance" ] && [ "${cap_socket_transparent}" != "true" ]; then
    return 1
  fi
  if [ "${network_mode}" = "enhance" ] && [ "${proxy_udp}" != "true" ]; then
    return 1
  fi
  return 0
}

apply_tproxy_reply_bypass_rules() {
  local chain_name="$1"
  performance_conntrack_enabled || return 0
  ensure_rule_append mangle "${chain_name}" -m conntrack --ctdir REPLY -j RETURN
}

apply_redirect_reply_bypass_rules() {
  local chain_name="$1"
  performance_conntrack_enabled || return 0
  ensure_rule_append nat "${chain_name}" -m conntrack --ctdir REPLY -j RETURN
}

append_tproxy_dispatch_rule() {
  local chain_name="$1"
  shift

  ensure_rule_append mangle "${chain_name}" "$@" -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
}

apply_tproxy_performance_rules() {
  [ "${performance_mode}" = "true" ] || return 0

  if [ "${iptables}" = "$IPV" ]; then
    if tproxy_performance_chain_enabled; then
      if [ "${network_mode}" = "enhance" ]; then
        log Info "性能模式：Enhance 下 TCP 使用 REDIRECT 子链，UDP 使用 TPROXY 子链。"
      else
        log Info "性能模式：TPROXY 已启用性能优化规则。"
      fi
    elif [ "${network_mode}" = "enhance" ] && [ "${proxy_udp}" != "true" ]; then
      log Info "性能模式：Enhance 当前未启用 UDP 代理，已跳过 TPROXY 子链优化。"
    elif [ "${network_mode}" != "enhance" ] && [ "${cap_socket_match}" = "true" ] && [ "${cap_socket_transparent}" != "true" ]; then
      log Warning "性能模式已开启，但内核不支持 socket --transparent，TPROXY 回退为普通规则。"
    elif performance_conntrack_enabled; then
      log Warning "性能模式已开启，但内核缺少 connmark 支持，TPROXY 回退为普通规则。"
    else
      log Warning "性能模式已开启，但未检测到可用的 conntrack / connmark 支持，TPROXY 回退为普通规则。"
    fi
  fi
}

append_tproxy_perf_connmark_rules() {
  local chain_name="$1"

  if [ "${network_mode}" != "enhance" ] && [ "${proxy_tcp}" = "true" ]; then
    ensure_rule_append mangle "${chain_name}" -p tcp -m conntrack --ctstate NEW,RELATED -j CONNMARK --set-xmark "${fwmark}"
  fi
  if [ "${proxy_udp}" = "true" ]; then
    ensure_rule_append mangle "${chain_name}" -p udp -m conntrack --ctstate NEW,RELATED -j CONNMARK --set-xmark "${fwmark}"
  fi
}

tproxy_perf_pre_ip_chain() {
  printf 'cfr_TP_PRE_IP\n'
}

tproxy_perf_pre_if_chain() {
  printf 'cfr_TP_PRE_IF\n'
}

tproxy_perf_out_ip_chain() {
  printf 'cfr_TP_OUT_IP\n'
}

tproxy_perf_out_app_chain() {
  printf 'cfr_TP_OUT_APP\n'
}

redirect_perf_pre_ip_chain() {
  printf 'cfr_RD_PRE_IP\n'
}

redirect_perf_pre_if_chain() {
  printf 'cfr_RD_PRE_IF\n'
}

redirect_perf_out_ip_chain() {
  printf 'cfr_RD_OUT_IP\n'
}

redirect_perf_out_app_chain() {
  printf 'cfr_RD_OUT_APP\n'
}

add_perf_chain_jumps() {
  local table_name="$1"
  local parent_chain="$2"
  shift 2
  local target
  for target in "$@"; do
    if [ "${proxy_tcp}" = "true" ]; then
      if [ "${table_name}" != "mangle" ] || [ "${network_mode}" != "enhance" ]; then
        ensure_rule_append "${table_name}" "${parent_chain}" -p tcp --syn -j "${target}"
      fi
    fi
    if [ "${table_name}" = "mangle" ] && [ "${proxy_udp}" = "true" ]; then
      ensure_rule_append "${table_name}" "${parent_chain}" -p udp -m conntrack --ctstate NEW,RELATED -j "${target}"
    fi
  done
}

setup_perf_dest_chain() {
  local table_name="$1"
  local chain_name="$2"
  ensure_chain "${table_name}" "${chain_name}"

  # 避免本地/内网 DNS 在性能模式下被提前旁路。
  append_perf_bypass_target() {
    local _table_name="$1"
    local _chain_name="$2"
    shift 2
    ensure_rule_append "${_table_name}" "${_chain_name}" "$@" -p udp ! --dport 53 -j ACCEPT
    ensure_rule_append "${_table_name}" "${_chain_name}" "$@" ! -p udp -j ACCEPT
  }

  if [ "${iptables}" = "$IPV" ]; then
    for subnet in "${intranet[@]}" ; do
      append_perf_bypass_target "${table_name}" "${chain_name}" -d ${subnet}
    done
    if [ "${bypass_cn_ip}" = "true" ] && [ "${bypass_cn_ip_v4}" = "true" ] && command -v ipset >/dev/null 2>&1; then
      append_perf_bypass_target "${table_name}" "${chain_name}" -m set --match-set cnip dst
    fi
  else
    for subnet6 in "${intranet6[@]}" ; do
      append_perf_bypass_target "${table_name}" "${chain_name}" -d ${subnet6}
    done
    if [ "${bypass_cn_ip}" = "true" ] && [ "${bypass_cn_ip_v6}" = "true" ] && command -v ipset >/dev/null 2>&1; then
      append_perf_bypass_target "${table_name}" "${chain_name}" -m set --match-set cnip6 dst
    fi
  fi

  append_perf_bypass_target "${table_name}" "${chain_name}" -m addrtype --dst-type LOCAL
  # addrtype 在部分设备不可用时的回退：显式回环地址兜底
  if [ "${iptables}" = "$IPV" ]; then
    append_perf_bypass_target "${table_name}" "${chain_name}" -d 127.0.0.0/8
  else
    append_perf_bypass_target "${table_name}" "${chain_name}" -d ::1/128
  fi
}

setup_perf_pre_if_chain() {
  local table_name="$1"
  local chain_name="$2"
  ensure_chain "${table_name}" "${chain_name}"

  if [ "${ignore_ap_list}" != "" ]; then
    for ignore in "${ignore_ap_list[@]}"; do
      ensure_rule_append "${table_name}" "${chain_name}" -i "${ignore}" -j ACCEPT
    done
  fi

  ensure_rule_append "${table_name}" "${chain_name}" -i lo -j RETURN

  if [ "${ap_list}" = "" ]; then
    ensure_rule_append "${table_name}" "${chain_name}" -j ACCEPT
    return 0
  fi

  for ap in "${ap_list[@]}"; do
    if [ "${mac_filter}" = "true" ]; then
      if [ "${mac_mode}" = "whitelist" ]; then
        for mac_item in "${macs_list[@]}"; do
          local mac
          mac="$(echo "${mac_item}" | busybox tr '[:upper:]' '[:lower:]' | busybox tr -d '[:space:]')"
          echo "${mac}" | busybox grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || continue
          ensure_rule_append "${table_name}" "${chain_name}" -i "${ap}" -m mac --mac-source "${mac}" -j RETURN
        done
        ensure_rule_append "${table_name}" "${chain_name}" -i "${ap}" -j ACCEPT
      else
        for mac_item in "${macs_list[@]}"; do
          local mac
          mac="$(echo "${mac_item}" | busybox tr '[:upper:]' '[:lower:]' | busybox tr -d '[:space:]')"
          echo "${mac}" | busybox grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || continue
          ensure_rule_append "${table_name}" "${chain_name}" -i "${ap}" -m mac --mac-source "${mac}" -j ACCEPT
        done
        ensure_rule_append "${table_name}" "${chain_name}" -i "${ap}" -j RETURN
      fi
    else
      ensure_rule_append "${table_name}" "${chain_name}" -i "${ap}" -j RETURN
    fi
  done

  ensure_rule_append "${table_name}" "${chain_name}" -j ACCEPT
}

setup_perf_out_app_chain() {
  local table_name="$1"
  local chain_name="$2"
  ensure_chain "${table_name}" "${chain_name}"

  case "${proxy_mode}" in
    blacklist|black)
      if uid_list_has_entries; then
        while read -r appid; do
          ensure_rule_append "${table_name}" "${chain_name}" -m owner --uid-owner "${appid}" -j ACCEPT
        done < "${uid_list}"
      fi
      if [ "${gid_list}" != "" ]; then
        for gid in "${gid_list[@]}" ; do
          ensure_rule_append "${table_name}" "${chain_name}" -m owner --gid-owner ${gid} -j ACCEPT
        done
      fi
      ;;
    whitelist|white)
      local _has_whitelist="false"
      if uid_list_has_entries; then
        while read -r appid; do
          ensure_rule_append "${table_name}" "${chain_name}" -m owner --uid-owner "${appid}" -j RETURN
        done < "${uid_list}"
        ensure_rule_append "${table_name}" "${chain_name}" -m owner --uid-owner 0 -j RETURN
        ensure_rule_append "${table_name}" "${chain_name}" -m owner --uid-owner 1051 -j RETURN
        ensure_rule_append "${table_name}" "${chain_name}" -m owner --uid-owner 1052 -j RETURN
        _has_whitelist="true"
      fi
      if [ "${gid_list}" != "" ]; then
        for gid in "${gid_list[@]}" ; do
          ensure_rule_append "${table_name}" "${chain_name}" -m owner --gid-owner ${gid} -j RETURN
        done
        _has_whitelist="true"
      fi
      if [ "${_has_whitelist}" = "true" ]; then
        ensure_rule_append "${table_name}" "${chain_name}" -j ACCEPT
      fi
      ;;
  esac
}

setup_redirect_perf_external_chain() {
  local ip_chain
  local if_chain

  ip_chain="$(redirect_perf_pre_ip_chain)"
  if_chain="$(redirect_perf_pre_if_chain)"

  setup_external_chain_common nat cfr_EXTERNAL
  apply_redirect_reply_bypass_rules cfr_EXTERNAL
  ensure_dns_nat_hijack
  setup_perf_dest_chain nat "${ip_chain}"
  setup_perf_pre_if_chain nat "${if_chain}"

  add_perf_chain_jumps nat cfr_EXTERNAL "${ip_chain}" "${if_chain}"

  if [ "${proxy_tcp}" = "true" ]; then
    apply_redirect_connmark_restore_rules cfr_EXTERNAL
    ensure_rule_append nat cfr_EXTERNAL -p tcp -m conntrack --ctstate NEW,RELATED -j CONNMARK --set-xmark "${fwmark}"
    ensure_rule_append nat cfr_EXTERNAL -p tcp -m connmark --mark "${fwmark}" -j REDIRECT --to-ports "${redir_port}"
  fi

  finish_external_chain nat cfr_EXTERNAL
}

setup_redirect_perf_local_chain() {
  local ip_chain
  local app_chain

  ip_chain="$(redirect_perf_out_ip_chain)"
  app_chain="$(redirect_perf_out_app_chain)"

  setup_local_chain_common nat cfr_LOCAL
  apply_redirect_reply_bypass_rules cfr_LOCAL
  append_cnip_force_proxy_local_rules nat cfr_LOCAL redirect
  setup_perf_dest_chain nat "${ip_chain}"
  setup_perf_out_app_chain nat "${app_chain}"

  add_perf_chain_jumps nat cfr_LOCAL "${app_chain}" "${ip_chain}"

  if [ "${proxy_tcp}" = "true" ]; then
    apply_redirect_connmark_restore_rules cfr_LOCAL
    ensure_rule_append nat cfr_LOCAL -p tcp -m conntrack --ctstate NEW,RELATED -j CONNMARK --set-xmark "${fwmark}"
    ensure_rule_append nat cfr_LOCAL -p tcp -m connmark --mark "${fwmark}" -j REDIRECT --to-ports "${redir_port}"
  fi

  finish_local_chain nat cfr_LOCAL
}

cleanup_perf_chains() {
  local table_name="$1"
  shift
  local chain_name
  for chain_name in "$@"; do
    cleanup_chain_fast "${table_name}" "${chain_name}"
  done
}

setup_tproxy_perf_external_chain() {
  local ip_chain
  local if_chain

  ip_chain="$(tproxy_perf_pre_ip_chain)"
  if_chain="$(tproxy_perf_pre_if_chain)"

  setup_external_chain_common mangle cfr_EXTERNAL
  setup_perf_dest_chain mangle "${ip_chain}"
  setup_perf_pre_if_chain mangle "${if_chain}"

  apply_tproxy_reply_bypass_rules cfr_EXTERNAL
  apply_mangle_dns_rules cfr_EXTERNAL tproxy
  apply_tproxy_ipv6_fakeip_rules cfr_EXTERNAL tproxy

  add_perf_chain_jumps mangle cfr_EXTERNAL "${ip_chain}" "${if_chain}"

  append_tproxy_perf_connmark_rules cfr_EXTERNAL
  if [ "${network_mode}" != "enhance" ] && [ "${proxy_tcp}" = "true" ]; then
    ensure_rule_append mangle cfr_EXTERNAL -p tcp -m connmark --mark "${fwmark}" -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
  fi
  if [ "${proxy_udp}" = "true" ]; then
    ensure_rule_append mangle cfr_EXTERNAL -p udp -m connmark --mark "${fwmark}" -j TPROXY --on-port "${tproxy_port}" --tproxy-mark "${fwmark}"
  fi

  finish_external_chain mangle cfr_EXTERNAL
}

setup_tproxy_perf_local_chain() {
  local ip_chain
  local app_chain

  ip_chain="$(tproxy_perf_out_ip_chain)"
  app_chain="$(tproxy_perf_out_app_chain)"

  setup_local_chain_common mangle cfr_LOCAL
  setup_perf_dest_chain mangle "${ip_chain}"
  setup_perf_out_app_chain mangle "${app_chain}"

  apply_tproxy_reply_bypass_rules cfr_LOCAL
  [ "${proxy_mode}" = "core" ] && apply_tproxy_ipv6_fakeip_rules cfr_LOCAL mark
  append_cnip_force_proxy_local_rules mangle cfr_LOCAL mark

  add_perf_chain_jumps mangle cfr_LOCAL "${ip_chain}" "${app_chain}"
  apply_mangle_dns_rules cfr_LOCAL mark

  append_tproxy_perf_connmark_rules cfr_LOCAL
  if [ "${network_mode}" != "enhance" ] && [ "${proxy_tcp}" = "true" ]; then
    ensure_rule_append mangle cfr_LOCAL -p tcp -m connmark --mark "${fwmark}" -j MARK --set-xmark "${fwmark}"
  fi
  if [ "${proxy_udp}" = "true" ]; then
    ensure_rule_append mangle cfr_LOCAL -p udp -m connmark --mark "${fwmark}" -j MARK --set-xmark "${fwmark}"
  fi

  finish_local_chain mangle cfr_LOCAL
}

setup_tproxy_external_chain() {
  apply_tproxy_performance_rules
  if tproxy_performance_chain_enabled; then
    setup_tproxy_perf_external_chain
    return 0
  fi

  setup_external_chain_common mangle cfr_EXTERNAL
  apply_tproxy_reply_bypass_rules cfr_EXTERNAL
  apply_mangle_dns_rules cfr_EXTERNAL tproxy
  apply_tproxy_ipv6_fakeip_rules cfr_EXTERNAL tproxy
  append_common_bypass_rules mangle cfr_EXTERNAL
  apply_ignored_external_interfaces mangle cfr_EXTERNAL
  apply_external_loopback_rule mangle cfr_EXTERNAL tproxy
  apply_external_ap_rules mangle cfr_EXTERNAL tproxy
  finish_external_chain mangle cfr_EXTERNAL
}

setup_tproxy_local_chain() {
  if tproxy_performance_chain_enabled; then
    setup_tproxy_perf_local_chain
    return 0
  fi

  setup_local_chain_common mangle cfr_LOCAL
  apply_tproxy_reply_bypass_rules cfr_LOCAL
  apply_mangle_dns_rules cfr_LOCAL mark
  [ "${proxy_mode}" = "core" ] && apply_tproxy_ipv6_fakeip_rules cfr_LOCAL mark
  append_cnip_force_proxy_local_rules mangle cfr_LOCAL mark
  append_common_bypass_rules mangle cfr_LOCAL
  apply_local_proxy_rules mangle cfr_LOCAL mark
  finish_local_chain mangle cfr_LOCAL
}

setup_tproxy_divert_chain() {
  if [ "${network_mode}" = "enhance" ] || [ "${cap_socket_match}" != "true" ] || [ "${cap_socket_transparent}" != "true" ]; then
    cleanup_tproxy_divert_chain
    return 0
  fi

  ensure_chain mangle DIVERT
  ensure_rule_append mangle DIVERT -j MARK --set-xmark "${fwmark}"
  ensure_rule_append mangle DIVERT -j ACCEPT
  ensure_rule_insert mangle PREROUTING -p tcp -m socket --transparent -j DIVERT
}

cleanup_tproxy_divert_chain() {
  del_rule_silent mangle PREROUTING -p tcp -m socket --transparent -j DIVERT
  del_rule_silent mangle PREROUTING -p tcp -m socket -j DIVERT
  cleanup_chain_fast mangle DIVERT
}

setup_external_chain_common() {
  local table_name="$1"
  local chain_name="$2"
  ensure_chain "${table_name}" "${chain_name}"
}

finish_external_chain() {
  local table_name="$1"
  local chain_name="$2"
  local parent_chain="${3:-PREROUTING}"
  ensure_jump "${table_name}" "${parent_chain}" "${chain_name}"
}

cleanup_external_chain_common() {
  local table_name="$1"
  local chain_name="$2"
  local parent_chain="${3:-PREROUTING}"
  del_jump_silent "${table_name}" "${parent_chain}" "${chain_name}"
  cleanup_chain_fast "${table_name}" "${chain_name}"
}

setup_local_chain_common() {
  local table_name="$1"
  local chain_name="$2"
  ensure_chain "${table_name}" "${chain_name}"

  if ! add_core_bypass_rule "${table_name}" "${chain_name}" -I; then
    ensure_rule_insert "${table_name}" "${chain_name}" -m mark --mark "${fwmark}" -j RETURN
    [ "${iptables}" = "$IPV" ] && log Warning "owner 匹配不可用，内核进程旁路已降级为 mark 规则。"
  fi
}

finish_local_chain() {
  local table_name="$1"
  local chain_name="$2"
  local parent_chain="${3:-OUTPUT}"
  ensure_jump "${table_name}" "${parent_chain}" "${chain_name}"
}

cleanup_local_chain_common() {
  local table_name="$1"
  local chain_name="$2"
  local parent_chain="${3:-OUTPUT}"

  del_jump_silent "${table_name}" "${parent_chain}" "${chain_name}"
  cleanup_chain_fast "${table_name}" "${chain_name}"

  if [ "${table_name}" = "nat" ] || [ "${table_name}" = "mangle" ]; then
    if [ "${iptables}" = "$IPV" ]; then
      cleanup_chain_fast "${table_name}" LOCAL_IP_V4
    else
      cleanup_chain_fast "${table_name}" LOCAL_IP_V6
    fi
  fi
}

setup_redirect_local_chain() {
  if redirect_performance_chain_enabled; then
    setup_redirect_perf_local_chain
    return 0
  fi

  setup_local_chain_common nat cfr_LOCAL
  apply_redirect_reply_bypass_rules cfr_LOCAL
  append_cnip_force_proxy_local_rules nat cfr_LOCAL redirect
  append_common_bypass_rules nat cfr_LOCAL
  apply_redirect_connmark_restore_rules cfr_LOCAL
  apply_local_proxy_rules nat cfr_LOCAL redirect
  finish_local_chain nat cfr_LOCAL
}

setup_redirect_external_chain() {
  apply_redirect_performance_rules
  if redirect_performance_chain_enabled; then
    setup_redirect_perf_external_chain
    return 0
  fi

  setup_external_chain_common nat cfr_EXTERNAL
  apply_redirect_reply_bypass_rules cfr_EXTERNAL
  ensure_dns_nat_hijack
  append_common_bypass_rules nat cfr_EXTERNAL
  apply_ignored_external_interfaces nat cfr_EXTERNAL
  apply_redirect_connmark_restore_rules cfr_EXTERNAL
  apply_external_loopback_rule nat cfr_EXTERNAL redirect
  apply_external_ap_rules nat cfr_EXTERNAL redirect
  finish_external_chain nat cfr_EXTERNAL
}

append_external_protocol_rule() {
  local table_name="$1"
  local chain_name="$2"
  local action="$3"
  local proto="$4"
  local iface="$5"
  local mac="$6"

  case "${action}" in
    redirect)
      [ "${proto}" = "tcp" ] || return 0
      [ "${proxy_tcp}" = "true" ] || return 0
      set -- -p tcp -i "${iface}"
      [ -n "${mac}" ] && set -- "$@" -m mac --mac-source "${mac}"
      append_redirect_dispatch_rule "${chain_name}" "$@"
      ;;
    tproxy)
      if [ "${proto}" = "tcp" ]; then
        [ "${proxy_tcp}" = "true" ] || return 0
        [ "${network_mode}" != "enhance" ] || return 0
      else
        [ "${proxy_udp}" = "true" ] || return 0
      fi
      set -- -p "${proto}" -i "${iface}"
      [ -n "${mac}" ] && set -- "$@" -m mac --mac-source "${mac}"
      append_tproxy_dispatch_rule "${chain_name}" "$@"
      ;;
  esac
}

apply_ignored_external_interfaces() {
  local table_name="$1"
  local chain_name="$2"

  if [ "${ignore_ap_list}" != "" ]; then
    for ignore in "${ignore_ap_list[@]}"; do
      ensure_rule_append "${table_name}" "${chain_name}" -i "${ignore}" -j RETURN
    done
    [ "${iptables}" = "$IPV" ] && [ "${network_mode}" != "enhance" ] && log Info "${ignore_ap_list[*]} 入站接口已忽略透明代理。"
  fi
}

apply_external_loopback_rule() {
  local table_name="$1"
  local chain_name="$2"
  local action="$3"

  case "${action}" in
    redirect)
      append_external_protocol_rule "${table_name}" "${chain_name}" "${action}" tcp lo
      ;;
    tproxy)
      append_external_protocol_rule "${table_name}" "${chain_name}" "${action}" tcp lo
      append_external_protocol_rule "${table_name}" "${chain_name}" "${action}" udp lo
      ;;
  esac
}

apply_external_ap_rules() {
  local table_name="$1"
  local chain_name="$2"
  local action="$3"

  [ "${ap_list}" != "" ] || return 0

  for ap in "${ap_list[@]}"; do
    if [ "${mac_filter}" = "true" ]; then
      if [ "${mac_mode}" = "whitelist" ]; then
        local _mac_added="false"
        for mac_item in "${macs_list[@]}"; do
          local mac
          mac="$(echo "${mac_item}" | busybox tr '[:upper:]' '[:lower:]' | busybox tr -d '[:space:]')"
          echo "${mac}" | busybox grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || continue
          append_external_protocol_rule "${table_name}" "${chain_name}" "${action}" tcp "${ap}" "${mac}"
          append_external_protocol_rule "${table_name}" "${chain_name}" "${action}" udp "${ap}" "${mac}"
          _mac_added="true"
        done
        if [ "${_mac_added}" != "true" ]; then
          [ "${iptables}" = "$IPV" ] && [ "${network_mode}" != "enhance" ] && log Warning "热点接口 ${ap}：MAC 白名单已启用但列表为空/无有效项，将不代理该接口的客户端流量"
        fi
      else
        for mac_item in "${macs_list[@]}"; do
          local mac
          mac="$(echo "${mac_item}" | busybox tr '[:upper:]' '[:lower:]' | busybox tr -d '[:space:]')"
          echo "${mac}" | busybox grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || continue
          if [ "${action}" = "redirect" ]; then
            ensure_rule_append "${table_name}" "${chain_name}" -i "${ap}" -m mac --mac-source "${mac}" -j RETURN
          else
            [ "${network_mode}" != "enhance" ] && [ "${proxy_tcp}" = "true" ] && ensure_rule_append "${table_name}" "${chain_name}" -p tcp -i "${ap}" -m mac --mac-source "${mac}" -j RETURN
            [ "${proxy_udp}" = "true" ] && ensure_rule_append "${table_name}" "${chain_name}" -p udp -i "${ap}" -m mac --mac-source "${mac}" -j RETURN
          fi
        done
        append_external_protocol_rule "${table_name}" "${chain_name}" "${action}" tcp "${ap}"
        append_external_protocol_rule "${table_name}" "${chain_name}" "${action}" udp "${ap}"
      fi
    else
      append_external_protocol_rule "${table_name}" "${chain_name}" "${action}" tcp "${ap}"
      append_external_protocol_rule "${table_name}" "${chain_name}" "${action}" udp "${ap}"
    fi
  done

  [ "${iptables}" = "$IPV" ] && [ "${network_mode}" != "enhance" ] && {
    if [ "${mac_filter}" = "true" ]; then
      if [ "${mac_mode}" = "whitelist" ]; then
        log Info "${ap_list[*]} 热点 MAC 白名单透明代理已启用。"
      else
        log Info "${ap_list[*]} 热点 MAC 黑名单透明代理已启用。"
      fi
    else
      log Info "${ap_list[*]} 透明代理。"
    fi
  }
}

case "${bin_name}" in
  "mihomo")
    fake_ip_range=$(busybox awk '!/^ *#/ && /fake-ip-range:/ { print $2; found=1; exit } END { if (!found) print "198.18.0.1/16" }' "${mihomo_config}" 2>/dev/null)
    fake_ip6_range=$(busybox awk '!/^ *#/ && /fake-ip-range6:/ { print $2; found=1; exit } END { if (!found) print "fc00::/18" }' "${mihomo_config}" 2>/dev/null)
    mihomo_dns_port=$(sed -n '/^dns:/,/^[^ ]/p' "${mihomo_config}" | grep -E '^[^#]*listen:.*:[0-9]+' | grep -Eo '[0-9]+' | tail -n 1)
    mihomo_dns_port=${mihomo_dns_port:-1053}
    if [[ "${network_mode}" == @(mixed|tun) ]]; then
      tun_device=$(busybox awk '
        /^tun:[[:space:]]*(#.*)?$/ { in_tun=1; next }
        in_tun && /^[^[:space:]#-]/ { in_tun=0 }
        in_tun && /^[[:space:]]+device:[[:space:]]*/ {
          sub(/^[[:space:]]+device:[[:space:]]*/, "", $0)
          sub(/[[:space:]]*(#.*)?$/, "", $0)
          gsub(/["\x27]/, "", $0)
          print $0
          found=1
          exit
        }
        END { if (!found) print "'"${tun_device_name:-tun0}"'" }
      ' "${mihomo_config}" 2>/dev/null)
      stack=$(busybox awk '
        /^tun:[[:space:]]*(#.*)?$/ { in_tun=1; next }
        in_tun && /^[^[:space:]#-]/ { in_tun=0 }
        in_tun && /^[[:space:]]+stack:[[:space:]]*/ {
          sub(/^[[:space:]]+stack:[[:space:]]*/, "", $0)
          sub(/[[:space:]]*(#.*)?$/, "", $0)
          gsub(/["\x27]/, "", $0)
          print $0
          found=1
          exit
        }
        END { if (!found) print "'"${stack}"'" }
      ' "${mihomo_config}" 2>/dev/null)
    fi
    ;;
  *)
    log Error "未知内核: ${bin_name}"
    exit 1
    ;;
esac

log_tun_context() {
  if [[ "${network_mode}" == @(mixed|tun) ]]; then
    log_once tun Info "TUN: ${tun_device} | 协议栈: ${stack}"
  fi
}

bin_alive() {
  local PID
  PID=$(<"${cfr_pid}" 2>/dev/null)
  if ! kill -0 "$PID" >/dev/null; then
    log Error "$(<"${cfr_log_dir}/${bin_name}.log")"
    log Error "${bin_name} 服务未运行。"
    log Error "请检查 ${bin_name}.log 获取更多信息。"
    log Error "正在清理僵尸进程 $PID"
    for bin in "${bin_list[@]}"; do
      killall -15 "${bin}" >/dev/null 2>&1 || busybox pkill -15 "${bin}" >/dev/null 2>&1
    done
    cleanup_iptables
    [ -f "${cfr_pid}" ] && rm -f "${cfr_pid}"
    return 1
  else
    return 0
  fi
}

probe_user_group() {
  if PID=$(busybox pidof ${bin_name}) ; then
    cfr_user=$(stat -c %U /proc/$PID)
    cfr_group=$(stat -c %G /proc/$PID)
    return 0
  else
    IFS=':' read -r cfr_user cfr_group <<< "${cfr_user_group}"
    return 1
  fi
}

set_ipv6_conf_all() {
  local key="$1"
  local value="$2"
  local path

  for path in /proc/sys/net/ipv6/conf/*/"${key}"; do
    [ -e "${path}" ] || continue
    echo "${value}" > "${path}" 2>/dev/null || true
  done
}

restore_ipv6_ra_conf() {
  set_ipv6_conf_all disable_ipv6 0
  set_ipv6_conf_all autoconf 1
  set_ipv6_conf_all accept_ra 2
  set_ipv6_conf_all accept_ra_defrtr 1
  set_ipv6_conf_all accept_ra_pinfo 1
}

disable_ipv6() {
  sysctl -w net.ipv4.ip_forward=1
  sysctl -w net.ipv6.conf.all.forwarding=0

  set_ipv6_conf_all accept_ra 0
  set_ipv6_conf_all disable_ipv6 1

  # 添加不可达规则，阻断 IPv6 流量继续转发。
  ip -6 rule show pref "${pref}" 2>/dev/null | busybox grep -q "unreachable" || ip -6 rule add unreachable pref "${pref}"
} >/dev/null 2>&1

ipv6_enable() {
  sysctl -w net.ipv4.ip_forward=1
  sysctl -w net.ipv6.conf.all.forwarding=1

  restore_ipv6_ra_conf

  # 移除不可达规则，恢复 IPv6 路由。
  ip -6 rule show pref "${pref}" 2>/dev/null | busybox grep -q "unreachable" && ip -6 rule del unreachable pref "${pref}" >/dev/null 2>&1 || true

  # 这里不全局阻断 IPv6 DNS，避免影响 TUN 模式下的 DNS 转发。
  del_rule_silent filter OUTPUT -p udp --destination-port 53 -j DROP 2>/dev/null || true
} >/dev/null 2>&1

collect_dynamic_ipv4_bypass_subnets() {
  ip -4 addr show up 2>/dev/null | busybox awk -v tun="${tun_device}" '
    /^[0-9]+: / {
      iface=$2
      sub(/:.*/, "", iface)
      sub(/@.*/, "", iface)
    }
    /inet / {
      addr=""
      for (i = 1; i <= NF; i++) {
        if ($i == "inet") {
          addr=$(i + 1)
          break
        }
      }
      if (addr == "" || iface == tun || iface == "lo") {
        next
      }
      sub(/\/.*/, "", addr)
      if (addr != "" && addr !~ /^127\./) {
        print addr "/32"
      }
    }
  '
}

collect_dynamic_ipv6_bypass_subnets() {
  ip -6 addr show up 2>/dev/null | busybox awk -v tun="${tun_device}" '
    /^[0-9]+: / {
      iface=$2
      sub(/:.*/, "", iface)
      sub(/@.*/, "", iface)
    }
    /inet6 / {
      if ($0 !~ /scope global/) {
        next
      }
      addr=""
      for (i = 1; i <= NF; i++) {
        if ($i == "inet6") {
          addr=$(i + 1)
          break
        }
      }
      if (addr == "" || iface == tun || iface == "lo") {
        next
      }
      if (addr ~ /^fe80/ || addr ~ /^::1/) {
        next
      }
      if ($0 ~ / tentative/ || $0 ~ / dadfailed/) {
        next
      }
      sub(/\/.*/, "", addr)
      if (addr != "") {
        print addr "/128"
      }
    }
  '
}

intranet=(
  0.0.0.0/8
  10.0.0.0/8
  100.64.0.0/10
  127.0.0.0/8
  169.254.0.0/16
  172.16.0.0/12
  192.0.0.0/24
  192.0.2.0/24
  192.88.99.0/24
  192.168.0.0/16
  198.51.100.0/24
  203.0.113.0/24
  224.0.0.0/4
  240.0.0.0/4
  255.0.0.0/4
  255.255.255.0/24
  255.255.255.255/32
)
# 同时补充设备当前已有的非 TUN IPv4 地址段，避免本机地址被误导流。
intranet+=($(collect_dynamic_ipv4_bypass_subnets))

intranet6=(
  ::/128
  ::1/128
  ::ffff:0:0/96
  100::/64
  64:ff9b::/96
  2001::/32
  2001:10::/28
  2001:20::/28
  2001:db8::/32
  2002::/16
  fe80::/10
  ff00::/8
)
intranet6+=($(collect_dynamic_ipv6_bypass_subnets))

# 检测内核是否支持 ip6tables nat 表。
ip6_nat_supported() {
  ${IP6V} -t nat -L >/dev/null 2>&1
}

ipset_stamp_file() {
  local set_name="$1"
  printf '%s/%s.stamp\n' "${ipset_stamp_dir}" "${set_name}"
}

ipset_source_stamp() {
  local source_file="$1"
  busybox stat -c '%s:%Y' "${source_file}" 2>/dev/null
}

ipset_has_entries() {
  local set_name="$1"
  local entries

  entries="$(ipset list -terse "${set_name}" 2>/dev/null | busybox awk '/^Number of entries:/ {print $4; exit}')"
  case "${entries}" in
    ''|*[!0-9]*)
      ;;
    *)
      [ "${entries}" -gt 0 ]
      return $?
      ;;
  esac

  entries="$(ipset list "${set_name}" 2>/dev/null | busybox awk '/^Number of entries:/ {print $4; exit}')"
  case "${entries}" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      [ "${entries}" -gt 0 ]
      ;;
  esac
}

ipset_should_reload() {
  local set_name="$1"
  local source_file="$2"
  local stamp_file current_stamp old_stamp

  [ -f "${source_file}" ] || return 1

  current_stamp="$(ipset_source_stamp "${source_file}")"
  [ -n "${current_stamp}" ] || return 0

  stamp_file="$(ipset_stamp_file "${set_name}")"
  old_stamp="$(cat "${stamp_file}" 2>/dev/null)"
  [ "${current_stamp}" != "${old_stamp}" ] && return 0

  ipset_has_entries "${set_name}" || return 0
  return 1
}

ipset_write_stamp() {
  local set_name="$1"
  local source_file="$2"
  local stamp_file current_stamp

  current_stamp="$(ipset_source_stamp "${source_file}")"
  [ -n "${current_stamp}" ] || return 1
  mkdir -p "${ipset_stamp_dir}" >/dev/null 2>&1 || true
  stamp_file="$(ipset_stamp_file "${set_name}")"
  printf '%s\n' "${current_stamp}" > "${stamp_file}" 2>/dev/null
}

# 中国大陆 IP 集的载入与清理。
setup_cn_ipset() {
  [ "${bypass_cn_ip}" = "true" ] || return 0
  if ! command -v ipset >/dev/null 2>&1; then
    log Warning "ipset 不可用，跳过大陆IP分流"
    return 1
  fi
  if [ "${bypass_cn_ip_v4}" = "true" ] && [ -f "${cn_ip_file}" ] && ipset_should_reload cnip "${cn_ip_file}"; then
    if {
      echo "create cnip hash:net family inet hashsize 8192 maxelem 65536 -exist"
      echo "flush cnip"
      busybox awk '!/^[[:space:]]*#/ && NF > 0 {printf "add cnip %s\n", $0}' "${cn_ip_file}"
    } | ipset restore -exist 2>/dev/null; then
      ipset_write_stamp cnip "${cn_ip_file}" || true
      log Info "已加载中国大陆 IPv4 段到 ipset: cnip"
    else
      log Warning "加载 cnip 失败"
    fi
  fi
  if [ "${ipv6}" = "true" ] && [ "${bypass_cn_ip_v6}" = "true" ] && [ -f "${cn_ipv6_file}" ] && ipset_should_reload cnip6 "${cn_ipv6_file}"; then
    if {
      echo "create cnip6 hash:net family inet6 hashsize 8192 maxelem 65536 -exist"
      echo "flush cnip6"
      busybox awk '!/^[[:space:]]*#/ && NF > 0 {printf "add cnip6 %s\n", $0}' "${cn_ipv6_file}"
    } | ipset restore -exist 2>/dev/null; then
      ipset_write_stamp cnip6 "${cn_ipv6_file}" || true
      log Info "已加载中国大陆 IPv6 段到 ipset: cnip6"
    else
      log Warning "加载 cnip6 失败"
    fi
  fi
}

cleanup_cn_ipset() {
  local cleanup_mode="${1:-keep}"

  command -v ipset >/dev/null 2>&1 || return 0
  case "${cleanup_mode}" in
    flush)
      ipset flush cnip 2>/dev/null || true
      ipset flush cnip6 2>/dev/null || true
      ;;
    destroy)
      ipset destroy cnip 2>/dev/null || true
      ipset destroy cnip6 2>/dev/null || true
      ;;
    *)
      ;;
  esac
}
probe_tun_device() {
  ip link show "${tun_device}" >/dev/null 2>&1 && return 0
  busybox ifconfig "${tun_device}" >/dev/null 2>&1 && return 0
  busybox ifconfig 2>/dev/null | busybox awk -F: -v dev="${tun_device}" '$1==dev {found=1} END{exit !found}'
}

wait_tun_device() {
  local timeout="${1:-12}"
  local interval="${2:-1}"
  local elapsed=0
  while [ "${elapsed}" -lt "${timeout}" ]; do
    probe_tun_device && return 0
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done
  return 1
}

forward() {
  local action=$1

  # 如需 NAT 出口，可在此补充 MASQUERADE。

  if [ "${action}" = "-D" ]; then
    del_rule_if_exists filter FORWARD -i "${tun_device}" -j ACCEPT
    del_rule_if_exists filter FORWARD -o "${tun_device}" -j ACCEPT
  else
    ensure_rule_insert filter FORWARD -i "${tun_device}" -j ACCEPT
    ensure_rule_insert filter FORWARD -o "${tun_device}" -j ACCEPT
  fi

  sysctl -w net.ipv4.ip_forward=1
  sysctl -w net.ipv4.conf.default.rp_filter=2
  sysctl -w net.ipv4.conf.all.rp_filter=2

} >/dev/null 2>&1

start_tun_bypass() {
  local pre_chain out_chain family_label
  pre_chain="$(tun_bypass_pre_chain)"
  out_chain="$(tun_bypass_out_chain)"
  family_label="$(tun_bypass_family_label)"

  ensure_chain mangle "${pre_chain}"
  ensure_chain mangle "${out_chain}"

  ensure_rule_append mangle "${pre_chain}" -i "${tun_device}" -j RETURN
  append_tun_dns_rules "${pre_chain}"
  append_tun_bypass_destination_rules "${pre_chain}"

  append_tun_core_bypass_rules "${out_chain}"
  append_tun_dns_rules "${out_chain}"
  append_cnip_force_proxy_tun_rules "${out_chain}"
  append_tun_proxy_mode_rules "${out_chain}"
  append_tun_bypass_destination_rules "${out_chain}"

  ensure_jump mangle PREROUTING "${pre_chain}" || {
    stop_tun_bypass >/dev/null 2>&1
    return 1
  }
  ensure_jump mangle OUTPUT "${out_chain}" || {
    stop_tun_bypass >/dev/null 2>&1
    return 1
  }
  apply_tun_route_rules || {
    stop_tun_bypass >/dev/null 2>&1
    return 1
  }
}

stop_tun_bypass() {
  local pre_chain out_chain
  pre_chain="$(tun_bypass_pre_chain)"
  out_chain="$(tun_bypass_out_chain)"

  cleanup_tun_route_rules
  del_jump_silent mangle PREROUTING "${pre_chain}"
  del_jump_silent mangle OUTPUT "${out_chain}"
  cleanup_chain_fast mangle "${pre_chain}"
  cleanup_chain_fast mangle "${out_chain}"
}

start_redirect() {
  if [ "${iptables}" = "$IP6V" ] && ! ip6_nat_supported; then
    [ "${ipv6}" = "true" ] && log Warning "ip6tables NAT 不可用，跳过 IPv6 重定向规则"
    return 0
  fi

  setup_redirect_external_chain
  setup_redirect_local_chain

  apply_quic_block_rules
  apply_dot_block_rules
  apply_local_port_protect_rules

  apply_loopback_reject_rule "${redir_port}"
}

stop_redirect() {
  cleanup_loopback_reject_rule "${redir_port}"

  cleanup_external_chain_common nat cfr_EXTERNAL
  cleanup_local_chain_common nat cfr_LOCAL
  cleanup_perf_chains nat \
    "$(redirect_perf_pre_ip_chain)" \
    "$(redirect_perf_pre_if_chain)" \
    "$(redirect_perf_out_ip_chain)" \
    "$(redirect_perf_out_app_chain)"
  cleanup_quic_block_rules
  cleanup_dns_nat_hijack_chains
}

start_tproxy() {
  if [ "${iptables}" = "$IP6V" ] && [ "${cap_tproxy6}" != "true" ]; then
    [ "${ipv6}" = "true" ] && log Warning "未检测到 IPv6 TPROXY 支持，跳过 ip6tables TProxy 规则"
    return 1
  fi

  setup_tproxy_policy_routing
  setup_tproxy_external_chain
  setup_tproxy_local_chain
  setup_tproxy_divert_chain

  apply_quic_block_rules
  apply_dot_block_rules
  apply_local_port_protect_rules

  if [ ${network_mode} != "enhance" ]; then
    # 阻止本地直接访问 TPROXY 端口，避免流量回环。
    apply_loopback_reject_rule "${tproxy_port}"
  fi

  ensure_dns_nat_hijack
  setup_fake_ip_icmp_rules
}

stop_tproxy() {
  cleanup_tproxy_policy_routing

  cleanup_external_chain_common mangle cfr_EXTERNAL
  cleanup_local_chain_common mangle cfr_LOCAL
  cleanup_perf_chains mangle \
    "$(tproxy_perf_pre_ip_chain)" \
    "$(tproxy_perf_pre_if_chain)" \
    "$(tproxy_perf_out_ip_chain)" \
    "$(tproxy_perf_out_app_chain)"

  cleanup_tproxy_divert_chain

  cleanup_quic_block_rules

  cleanup_loopback_reject_rule "${tproxy_port}"

  if [ "${iptables}" = "$IPV" ]; then
    cleanup_legacy_mihomo_dns_chains
  fi
  cleanup_fake_ip_icmp_rules
  cleanup_dns_nat_hijack_chains
}

cleanup_iptables_family() {
  local cleanup_mode="${1:-all}"

  case "${cleanup_mode}" in
    redirect)
      stop_redirect
      ;;
    tproxy)
      stop_tproxy
      ;;
    enhance)
      stop_redirect
      stop_tproxy
      ;;
    mixed)
      stop_redirect
      forward -D
      ;;
    tun)
      stop_tun_bypass
      forward -D
      ;;
    all|*)
      stop_redirect
      stop_tproxy
      stop_tun_bypass
      forward -D
      ;;
  esac

  cleanup_dot_block_rules
  cleanup_local_port_protect_rules

  if [ "${iptables}" = "$IP6V" ]; then
    del_rule_if_exists filter OUTPUT -p udp --destination-port 53 -j DROP
  fi
}

cleanup_iptables_for_mode() {
  local cleanup_mode="${1:-all}"
  local current_iptables

  for current_iptables in "$IPV" "$IP6V"; do
    iptables="${current_iptables}"
    cleanup_iptables_family "${cleanup_mode}" > /dev/null 2>&1
  done
}

cleanup_iptables() {
  cleanup_iptables_for_mode all
}

setup_cn_ipset_if_needed() {
  if [ "${bypass_cn_ip}" = "true" ]; then
    setup_cn_ipset || log Warning "大陆IP分流初始化失败，已跳过"
  fi
}

cleanup_cn_ipset_if_needed() {
  local cleanup_mode="${1:-keep}"

  if [ "${bypass_cn_ip}" = "true" ] || [ "${cleanup_mode}" != "keep" ]; then
    cleanup_cn_ipset "${cleanup_mode}"
  fi
}

wait_tun_ready() {
  wait_tun_device 12 1 || log Warning "未在 12 秒内检测到 TUN 设备: (${tun_device})，继续下发规则"
}

prepare_rule_apply() {
  local cleanup_mode

  probe_user_group || {
    log Error "无法获取内核进程用户组，请确认 ${bin_name} 已启动。"
  }
  prepare_cnip_force_proxy_uids
  log_iptables_results
  cleanup_mode="$(cleanup_mode_for_apply)"
  cleanup_iptables_for_mode "${cleanup_mode}"
}

apply_redirect_family() {
  if start_redirect; then
    log Info "${iptables} 透明代理规则创建完成。"
  else
    log Error "${iptables} 透明代理规则创建失败。"
    stop_redirect > /dev/null 2>&1
  fi
}

apply_tproxy_family() {
  if start_tproxy; then
    log Info "${iptables} 透明代理规则创建完成。"
  else
    log Error "${iptables} 透明代理规则创建失败。"
    stop_tproxy > /dev/null 2>&1
  fi
}

apply_mixed_family() {
  forward -I || forward -D > /dev/null 2>&1
  apply_redirect_family
}

apply_enhance_family() {
  if start_redirect && start_tproxy; then
    log Info "${iptables} 透明代理规则创建完成。"
  else
    log Error "${iptables} 透明代理规则创建失败。"
    stop_redirect > /dev/null 2>&1
    stop_tproxy > /dev/null 2>&1
  fi
}

apply_tun_family() {
  if [ "${performance_mode}" = "true" ] && [ "${iptables}" = "$IPV" ]; then
    log Info "TUN 模式下忽略性能模式"
  fi

  if ! forward -I; then
    log Error "$(tun_bypass_family_label) TUN 规则创建失败。"
    forward -D > /dev/null 2>&1
    return 1
  fi

  apply_dot_block_rules
  apply_local_port_protect_rules

  if [ "${bypass_cn_ip}" != "true" ]; then
    stop_tun_bypass > /dev/null 2>&1
    log_once tun_done Info "$(tun_bypass_family_label) TUN 规则创建完成"
    return 0
  fi

  if start_tun_bypass; then
    log_once tun_done Info "$(tun_bypass_family_label) TUN 规则创建完成"
  else
    log Error "$(tun_bypass_family_label) TUN 规则创建失败。"
    stop_tun_bypass > /dev/null 2>&1
    forward -D > /dev/null 2>&1
    return 1
  fi
}

# IPv6 可用则对同一族应用规则，否则系统级禁用 IPv6
apply_ipv6_or_disable() {
  local apply_fn="$1"
  if [ "${ipv6}" = "true" ]; then
    ipv6_enable
    iptables="$IP6V"
    "${apply_fn}"
  else
    disable_ipv6
    log_once ipv6 Info "已禁用 IPv6"
  fi
}

log_iptables_results() {
  [ "${network_mode}" = "tun" ] && return 0
  log Info "代理模式: ${proxy_mode}"
  log_context
}

runtime_loaded="false"
if [ "$1" = "disable" ]; then
  if runtime_load >/dev/null 2>&1; then
    runtime_loaded="true"
  fi
fi

case "$1" in
  killswitch)
    enable_killswitch
    exit 0
    ;;
  unkillswitch)
    disable_killswitch
    exit 0
    ;;
esac

if [[ "${network_mode}" == @(redirect|mixed|tproxy|enhance) ]]; then
  case "$1" in
    enable|renew)
      apply_capability_downgrades
      log_tun_context
      prepare_rule_apply
      setup_cn_ipset_if_needed

      [ $1 = "renew" ] && log Warning "正在清理 iptables 透明代理规则。"

      case "${network_mode}" in
        tproxy)
          log Info "TPROXY: 正在创建透明代理规则。"

          iptables="$IPV"
          apply_tproxy_family
          apply_ipv6_or_disable apply_tproxy_family
        ;;
        redirect)
          log Info "Redirect: 正在创建透明代理规则。"

          iptables="$IPV"
          apply_redirect_family
          apply_ipv6_or_disable apply_redirect_family
        ;;
        mixed)
          log Info "Mixed: 正在创建透明代理规则。"

          iptables="$IPV"
          wait_tun_ready
          apply_mixed_family
          apply_ipv6_or_disable apply_mixed_family
        ;;
        enhance)
          log Info "Enhance: 正在创建透明代理规则。"

          iptables="$IPV"
          apply_enhance_family
          apply_ipv6_or_disable apply_enhance_family
        ;;
        *)
          log Error "网络模式: ${network_mode}，未知模式"
          exit 1
        ;;
      esac
      disable_killswitch
      runtime_save
      bin_alive && log_once connected Info "${bin_name} 已连接"
      ;;
    disable)
      cleanup_mode="all"
      [ "${runtime_loaded}" = "true" ] && cleanup_mode="${network_mode:-all}"
      [ "$3" = "keep_ks" ] || ipv6_enable
      probe_user_group || log Error "无法获取内核进程用户组，请确认 ${bin_name} 已启动。"
      log Warning "正在清理 iptables 透明代理规则。"

      cleanup_iptables_for_mode "${cleanup_mode}"
      [ "$3" = "keep_ks" ] || disable_killswitch

      cleanup_cn_ipset_if_needed "${2:-keep}"

      runtime_clear

      log Info "iptables 透明代理规则清理完成。"
      ;;
    *)
      echo "${red}$0 $1 未知命令${normal}"
      echo "${yellow}用法:${normal} ${green}$0${normal} {${yellow}enable|disable|renew|killswitch|unkillswitch${normal}}"
      ;;
  esac
else
  case "$1" in
    enable|renew)
      apply_capability_downgrades
      log_tun_context

      prepare_rule_apply
      setup_cn_ipset_if_needed
      wait_tun_ready
      [ $1 = "renew" ] && log_once tun_clean Info "正在清理 TUN 规则"
      iptables="$IPV"

      apply_tun_family
      apply_ipv6_or_disable apply_tun_family

      disable_killswitch
      runtime_save
      [ $1 = "renew" ] && log_once tun_renew Info "iptables TUN 规则已重建"
      bin_alive && log_once connected Info "${bin_name} 已连接"
      ;;
    disable)
      cleanup_mode="all"
      [ "${runtime_loaded}" = "true" ] && cleanup_mode="${network_mode:-all}"
      [ "$3" = "keep_ks" ] || ipv6_enable
      probe_user_group || log Error "无法获取内核进程用户组，请确认 ${bin_name} 已启动。"
      log_once tun_clean Info "正在清理 TUN 规则"

      cleanup_iptables_for_mode "${cleanup_mode}"
      [ "$3" = "keep_ks" ] || disable_killswitch
      cleanup_cn_ipset_if_needed "${2:-keep}"

      runtime_clear

      log Info "TUN 规则清理完成。"
      ;;
    *)
      echo "${red}$0: '$1' 未知命令${normal}"
      echo "${yellow}用法:${normal} ${green}$0${normal} {${yellow}enable|disable|renew|killswitch|unkillswitch${normal}}"
      ;;
  esac
fi