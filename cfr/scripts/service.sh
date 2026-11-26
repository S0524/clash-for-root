#!/system/bin/sh

# $0 不含 / 时（如 sh service.sh）${0%/*} 会原样返回，需兜底
case "$0" in
  */*) scripts_dir="${0%/*}" ;;
  *) scripts_dir="/data/adb/cfr/scripts" ;;
esac
source /data/adb/cfr/settings.ini

file_settings="/data/adb/cfr/settings.ini"
PROPFILE="/data/adb/modules/cfr/module.prop"

# ANSI 颜色（值含真实 ESC 字符，兼容无 -e 的 echo）
normal="$(printf '\033[0m')"
red="$(printf '\033[1;31m')"
green="$(printf '\033[1;32m')"
yellow="$(printf '\033[1;33m')"

sed_file_if_changed() {
  local file="$1"
  shift

  local temp_file="${cfr_run_state}/.${file##*/}.$$.tmp"
  mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true
  sed "$@" "${file}" > "${temp_file}" || {
    rm -f "${temp_file}" >/dev/null 2>&1 || true
    return 1
  }

  if busybox cmp -s "${temp_file}" "${file}"; then
    rm -f "${temp_file}" >/dev/null 2>&1 || true
    return 0
  fi

  mv "${temp_file}" "${file}"
}

find_packages_uid() {
  log Info "代理模式: ${proxy_mode}"

  if [ "${proxy_mode}" = "core" ]; then
    log Info "核心模式已启用，跳过 package 和 gid 处理"
    > "${uid_list}"
    return 0
  fi

  log Info "开始处理 UID/GID 列表"

  > "${uid_list}"

  local packages_file request_file map_file
  packages_file="${system_packages_file:-/data/system/packages.list}"
  request_file="${cfr_run_state}/package.uid.request"
  map_file="${cfr_run_state}/package.uid.map"

  mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true
  : > "${request_file}"
  for entry in "${packages_list[@]}"; do
    local prefix="0"
    local package="${entry}"

    case "${entry}" in
      *:*)
        prefix="${entry%%:*}"
        package="${entry#*:}"
        ;;
    esac

    case "${prefix}" in
      ''|*[!0-9]*)
        log Warning "用户 \"${prefix}\" 应用: \"${package}\" -> 用户前缀无效，已回退为 0"
        prefix="0"
        ;;
    esac

    if [ -z "${package}" ] || [ "${package}" = "${entry}" ] && [ "${entry}" = "${prefix}" ]; then
      log Warning "用户 \"${prefix}\" 应用: \"${entry}\" -> 包名无效"
      continue
    fi

    printf '%s %s %s\n' "${prefix}" "${package}" "${entry}" >> "${request_file}"
  done

  if [ -s "${request_file}" ] && [ -f "${packages_file}" ]; then
    busybox awk '
      NR == FNR { wanted[$2] = 1; next }
      ($1 in wanted) { print $1 " " $2 }
    ' "${request_file}" "${packages_file}" > "${map_file}"

    while IFS=' ' read -r prefix package entry; do
      [ -n "${package}" ] || continue

      local base_uid
      base_uid=$(busybox awk -v pkg="${package}" '$1 == pkg {print $2; exit}' "${map_file}" 2>/dev/null)

      case "${base_uid}" in
        ''|*[!0-9]*)
          log Warning "用户 \"${prefix}\" 应用: \"${package}\" -> 未找到"
          continue
          ;;
      esac

      local multiuser_uid=$((base_uid + prefix * 100000))
      echo "${multiuser_uid}" >> "${uid_list}"
    done < "${request_file}"
  elif [ -s "${request_file}" ]; then
    log Warning "packages.list 不存在: ${packages_file}"
  fi

  rm -f "${request_file}" "${map_file}" >/dev/null 2>&1 || true

  if [ ${#gid_list[@]} -gt 0 ]; then
    printf "%s\n" "${gid_list[@]}" >> "${uid_list}"
  fi

  if [ -s "${uid_list}" ]; then
    local uid_count
    uid_count=$(busybox wc -l < "${uid_list}")
    log Info "UID/GID 列表处理完成: ${uid_count} 条"
    local temp_uid_list="${cfr_run_state}/temp_uid.list"
    busybox sort -un "${uid_list}" > "${temp_uid_list}"
    mv "${temp_uid_list}" "${uid_list}"
  fi
}

log_service_results() {
    log Info "更新TUN模式UID列表: 模式=$2"
}

cfr_check_logs() {
  # 启动前清空所有日志
  find "${cfr_log_dir}" -maxdepth 1 -type f -name "*.log" -exec rm -f {} +
  # crond spool 在 run/state 下，清掉旧的 root 任务文件
  rm -f "${cfr_run_state}/root" 2>/dev/null
  find "${cfr_run_state}" -maxdepth 1 -type f \( -name "*.list" -a ! -name "appuid.list" \) -exec rm -f {} +
  # 清掉 iptables.sh 的“只记一次”标记，下次启动重新输出
  find "${cfr_run_state}" -maxdepth 1 -type f -name "logged_*" -exec rm -f {} +
  log Info "已清空日志文件"
}

cfr_bin_alive() {
  local PID
  PID=$(<"${cfr_pid}" 2>/dev/null)
  if [ -n "${PID}" ] && kill -0 "$PID" >/dev/null 2>&1; then
    return 0
  fi
  # pid 文件可能尚未写入或内容失效，按进程名兜底
  busybox pidof "${bin_name}" >/dev/null 2>&1
}

# 启动彻底失败：清理残留、撤规则、标记模块状态
kernel_start_give_up() {
  for bin in "${bin_list[@]}"; do
    killall -15 "${bin}" >/dev/null 2>&1 || busybox pkill -15 "${bin}" >/dev/null 2>&1
  done
  "${scripts_dir}/iptables.sh" disable >/dev/null 2>&1
  rm -f "${cfr_pid}" 2>/dev/null
  set_description error "内核启动失败"
  exit 1
}

cfr_run_crontab() {
  busybox pkill -f "crond -c ${cfr_run_state}" >/dev/null 2>&1
  busybox crontab -c "${cfr_run_state}" -r
  echo "# root 的定时任务" > "${cfr_run_state}/root"

  if [ "${run_crontab}" = "true" ]; then
    local cron_desc=""
    [ "${update_subscription}" = "true" ] && cron_desc="${cron_desc:+${cron_desc} / }订阅"
    [ "${update_geo}" = "true" ] && cron_desc="${cron_desc:+${cron_desc} / }GeoX"
    [ "${bypass_cn_ip}" = "true" ] && cron_desc="${cron_desc:+${cron_desc} / }CNIP"
    [ "${update_components:-false}" = "true" ] && cron_desc="${cron_desc:+${cron_desc} / }组件"
    if [ -n "${cron_desc}" ]; then
      echo "${interva_update} ${scripts_dir}/tool.sh geosub" >> "${cfr_run_state}/root"
      log Info "定时任务 (${interva_update}): 更新 ${cron_desc}"
    fi
    cat "${cfr_dir}/crontab.cfg" >> "${cfr_run_state}/root"
    chmod 0644 "${cfr_run_state}/root"
    nohup busybox crond -c "${cfr_run_state}" >/dev/null 2>&1 &
  else
    log Info "crond 已禁用"
  fi
}

cfr_permission_stamp_path() {
  printf '%s/permission.%s.stamp\n' "${cfr_run_state}" "${bin_name}"
}

cfr_permission_stamp_value() {
  local bin_stat core_dir_stat curl_stat

  bin_stat="$(busybox stat -c '%u:%g:%a:%s:%Y' "${bin_path}" 2>/dev/null)"
  core_dir_stat="$(busybox stat -c '%u:%g:%a:%Y' "${cfr_dir}/${bin_name}" 2>/dev/null)"
  curl_stat="$(busybox stat -c '%u:%g:%a:%s:%Y' "${cfr_dir}/bin/curl" 2>/dev/null)"

  printf '%s|%s|%s|%s|%s\n' "${cfr_user_group}" "${bin_path}" "${bin_stat}" "${core_dir_stat}" "${curl_stat}"
}

cfr_permission_stamp_valid() {
  local stamp_file current_stamp old_stamp

  stamp_file="$(cfr_permission_stamp_path)"
  [ -f "${stamp_file}" ] || return 1

  current_stamp="$(cfr_permission_stamp_value)"
  old_stamp="$(cat "${stamp_file}" 2>/dev/null)"
  [ -n "${current_stamp}" ] && [ "${current_stamp}" = "${old_stamp}" ]
}

cfr_permission_stamp_save() {
  mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true
  cfr_permission_stamp_value > "$(cfr_permission_stamp_path)" 2>/dev/null
}

cfr_ownership() {
  chown -R "${cfr_user_group}" "${cfr_dir}"
  find "${cfr_dir}/${bin_name}" -type d -exec chmod 0700 {} + 2>/dev/null || true
  find "${cfr_dir}/${bin_name}" -type f -exec chmod 0600 {} + 2>/dev/null || true
  chmod 0700 "${cfr_dir}" "${cfr_dir}/bin" "${cfr_dir}/scripts" "${cfr_run}" "${cfr_run_state}" "${cfr_log_dir}" 2>/dev/null || true
  chmod 0600 "${cfr_dir}/settings.ini" "${cfr_dir}/package.list.cfg" "${cfr_dir}/gid.list.cfg" "${cfr_dir}/ap.list.cfg" "${cfr_dir}/crontab.cfg" 2>/dev/null || true

  chown "${cfr_user_group}" "${bin_path}"
  chmod 0700 "${bin_path}"

  chmod 0700 "${cfr_dir}/bin/curl" 2>/dev/null || true
}

cfr_permission() {
  if [[ "${cfr_user_group}" == @(root:net_admin|0:3005) && -f "${bin_path}" ]]; then
    if ! cfr_permission_stamp_valid; then
      cfr_ownership
      cfr_permission_stamp_save || true
    fi
    log Info "内核: ${bin_name}"
  else
    if  [[ "${cfr_user_group}" != @(root:net_admin|0:3005) ]]; then
      log Error "不支持的用户组: ${cfr_user_group}"
      sed -i "s/cfr_user_group=.*/cfr_user_group=\"root:net_admin\"/g" "${file_settings}"
      exit 1
    fi
    log Error "未检测到内核: ${bin_name}"
    log Error "请下载 ${bin_name} 内核并放入 bin/ 目录"
    set_description error "内核不存在"
    exit 1
  fi
}

cfr_check_bin() {
  if [ ! -x "${bin_path}" ]; then
    log Error "内核不可执行: ${bin_name}"
    set_description error "内核不可执行"
    exit 1
  fi

  local version_output version_short
  version_output=$("${bin_path}" -v 2>/dev/null) || {
    log Error "${bin_name} 版本信息获取失败"
    set_description error "内核损坏"
    exit 1
  }

  version_short=$(printf '%s\n' "${version_output}" | busybox grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
  [ -n "${version_short}" ] || version_short=$(printf '%s\n' "${version_output}" | head -n 1)
  log Info "内核版本: ${version_short}"
}

tun_requires_manual_routing() {
  [[ "${network_mode}" == @(mixed|tun) ]] && [ "${bypass_cn_ip}" = "true" ]
}

# 仅在显式开启 tun_force_gvisor="true" 时强切 gvisor，默认保留 mixed/system 减少协议栈指纹差异
tun_should_force_gvisor() {
  tun_requires_manual_routing && [ "${tun_force_gvisor:-false}" = "true" ]
}
tun_should_manage_core_config() { tun_requires_manual_routing; }

tun_auto_flag_value() {
  if tun_requires_manual_routing; then
    printf 'false\n'
  else
    printf 'true\n'
  fi
}

tun_effective_stack() {
  if tun_should_force_gvisor; then
    printf 'gvisor\n'
  elif [ -n "${stack}" ]; then
    printf '%s\n' "${stack}"
  else
    printf 'mixed\n'
  fi
}

# 规则补全：
#   - 缺少 GEOSITE,CN → 插到 GEOIP,CN（没有则 MATCH）之前，策略沿用 GEOIP,CN
#   - GEOSITE,CN 已在但排在 GEOIP,CN 之后 → 前移
# 改动前备份，改完用内核 -t 校验，失败回滚
rules_scan() {
  busybox awk '
    BEGIN { indent = -1 }
    /^rules:[[:space:]]*(#.*)?$/ { in_rules = 1; next }
    in_rules && /^[^[:space:]#-]/ { in_rules = 0 }
    in_rules && /^[[:space:]]*#/ { next }
    in_rules && /^[[:space:]]*-[[:space:]]/ {
      n++
      l = tolower($0)
      if (indent < 0) { match($0, /^[[:space:]]*/); indent = RLENGTH }
      if (!site && l ~ /^[[:space:]]*-[[:space:]]*geosite[[:space:]]*,[[:space:]]*cn([[:space:]]*,|[[:space:]]*$)/) site = n
      if (!geo && l ~ /^[[:space:]]*-[[:space:]]*geoip[[:space:]]*,[[:space:]]*cn([[:space:]]*,|[[:space:]]*$)/) geo = n
      if (!mrule && l ~ /^[[:space:]]*-[[:space:]]*match[[:space:]]*,/) mrule = n
      next
    }
    END { printf "%d %d %d %d %d\n", site, geo, mrule, (indent < 0 ? 2 : indent), n }
  ' "$1" 2>/dev/null
}

prepare_rules() {
  local cfg="$1"
  local tmp bak pad target site_line flow
  local site_pos geo_pos match_pos indent
  local site_pat geo_pat anchor_pat

  tmp="${cfr_run_state}/.${cfg##*/}.rules.$$.tmp"
  bak="${cfr_run_state}/.${cfg##*/}.rules.$$.bak"
  busybox mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true

  # 没有 geosite 数据时，GEOSITE 规则会让内核启动失败，直接跳过
  if [ ! -s "${cfr_dir}/${bin_name}/geosite.dat" ]; then
    log Warning "未找到 ${bin_name}/geosite.dat，跳过 GEOSITE 规则补全"
    return 0
  fi

  # 行内写法（rules: [...]）无法安全改写
  flow=$(busybox awk '/^rules:/ { l = $0; sub(/^rules:[[:space:]]*/, "", l); if (l == "" || l ~ /^\[[[:space:]]*\][[:space:]]*(#.*)?$/ || l ~ /^#/) next; print "flow"; exit }' "${cfg}" 2>/dev/null)
  if [ -n "${flow}" ]; then
    log Warning "rules 为行内写法（rules: [...]），跳过 GEOSITE 规则补全"
    return 0
  fi

  site_pat='^[[:space:]]*-[[:space:]]*geosite[[:space:]]*,[[:space:]]*cn([[:space:]]*,|[[:space:]]*$)'
  geo_pat='^[[:space:]]*-[[:space:]]*geoip[[:space:]]*,[[:space:]]*cn([[:space:]]*,|[[:space:]]*$)'

  cp -f "${cfg}" "${bak}"

  set -- $(rules_scan "${cfg}")
  site_pos="${1:-0}"
  geo_pos="${2:-0}"
  match_pos="${3:-0}"
  indent="${4:-2}"

  pad=$(busybox awk -v n="${indent}" 'BEGIN { s = ""; for (i = 0; i < n; i++) s = s " "; printf "%s", s }')

  # GEOSITE,CN 的策略沿用 GEOIP,CN 那行，取不到就用 DIRECT
  target=$(busybox awk '
    BEGIN { FS = "," }
    {
      l = tolower($0)
      if (l ~ /^[[:space:]]*-[[:space:]]*geoip[[:space:]]*,[[:space:]]*cn[[:space:]]*,/) {
        t = $3
        sub(/[[:space:]]*#.*/, "", t)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
        if (t != "") { print t; exit }
      }
    }
  ' "${cfg}" 2>/dev/null)
  [ -z "${target}" ] && target="DIRECT"

  # 国内域名直连
  if [ "${site_pos}" -gt 0 ]; then
    if [ "${geo_pos}" -gt 0 ] && [ "${site_pos}" -gt "${geo_pos}" ]; then
      site_line=$(busybox grep -m1 -iE '^[[:space:]]*-[[:space:]]*GEOSITE[[:space:]]*,[[:space:]]*CN([[:space:]]*,|[[:space:]]*$)' "${cfg}" 2>/dev/null)
      if [ -z "${site_line}" ]; then
        log Warning "读取 GEOSITE,CN 行失败，跳过前移"
      elif busybox awk -v geo="${geo_pat}" -v site="${site_pat}" -v line="${site_line}" '
        BEGIN { done = 0 }
        {
          l = tolower($0)
          if (!done && l ~ geo) { print line; print; done = 1; next }
          if (l ~ site) next
          print
        }
        END { if (!done) print line }
      ' "${cfg}" > "${tmp}" 2>/dev/null && [ -s "${tmp}" ]; then
        mv -f "${tmp}" "${cfg}"
          log Info "已将 GEOSITE,CN 前移到 GEOIP,CN 之前"
      else
        rm -f "${tmp}" 2>/dev/null
        cp -f "${bak}" "${cfg}"
        log Warning "移动 GEOSITE,CN 失败，已回滚"
        return 1
      fi
    fi
  else
    # 锚点：GEOIP,CN → MATCH → rules 块末尾
    if [ "${geo_pos}" -gt 0 ] || [ "${match_pos}" -gt 0 ]; then
      if [ "${geo_pos}" -gt 0 ]; then
        anchor_pat="${geo_pat}"
      else
        anchor_pat='^[[:space:]]*-[[:space:]]*match[[:space:]]*,'
      fi
      if busybox awk -v pat="${anchor_pat}" -v target="${target}" '
        BEGIN { done = 0 }
        {
          if (!done) {
            l = tolower($0)
            if (l ~ pat) {
              match($0, /^[[:space:]]*/)
              printf "%s- GEOSITE,CN,%s\n", substr($0, 1, RLENGTH), target
              done = 1
            }
          }
          print
        }
      ' "${cfg}" > "${tmp}" 2>/dev/null && [ -s "${tmp}" ]; then
        mv -f "${tmp}" "${cfg}"
          log Info "已补全国内域名直连: GEOSITE,CN,${target}"
      else
        rm -f "${tmp}" 2>/dev/null
        cp -f "${bak}" "${cfg}"
        log Warning "插入 GEOSITE,CN 失败，已回滚"
        return 1
      fi
    else
      if busybox awk -v rule="${pad}- GEOSITE,CN,${target}" '
        BEGIN { in_rules = 0; done = 0 }
        {
          if (!done && in_rules && $0 ~ /^[^[:space:]#-]/) { print rule; in_rules = 0; done = 1 }
          print
          if ($0 ~ /^rules:[[:space:]]*(#.*)?$/) in_rules = 1
        }
        END { if (!done) { if (!in_rules) print "rules:"; print rule } }
      ' "${cfg}" > "${tmp}" 2>/dev/null && [ -s "${tmp}" ]; then
        mv -f "${tmp}" "${cfg}"
          log Info "已追加国内域名直连: GEOSITE,CN,${target}"
      else
        rm -f "${tmp}" 2>/dev/null
        cp -f "${bak}" "${cfg}"
        log Warning "追加 GEOSITE,CN 失败，已回滚"
        return 1
      fi
    fi
  fi

  rm -f "${bak}" "${tmp}" 2>/dev/null
  return 0
}

yaml_get_top_key() {
  local cfg="$1" key="$2"
  busybox awk -v k="${key}" '
    !/^[[:space:]]*#/ && $0 ~ ("^" k ":[[:space:]]*") {
      v = $0
      sub("^" k ":[[:space:]]*", "", v)
      sub(/[[:space:]]*(#.*)?$/, "", v)
      gsub(/["\x27]/, "", v)
      print v
      exit
    }
  ' "${cfg}" 2>/dev/null
}

yaml_set_top_key() {
  local cfg="$1" key="$2" val="$3"
  local tmp="${cfr_run_state}/.${cfg##*/}.yaml.$$.tmp"
  mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true
  if busybox awk -v k="${key}" -v v="${val}" '
    BEGIN { done = 0 }
    !done && $0 ~ ("^" k ":[[:space:]]*") {
      print k ": " v
      done = 1
      next
    }
    { print }
    END { if (!done) print k ": " v }
  ' "${cfg}" > "${tmp}" 2>/dev/null && [ -s "${tmp}" ]; then
    if ! busybox cmp -s "${tmp}" "${cfg}"; then
      mv -f "${tmp}" "${cfg}"
    else
      rm -f "${tmp}" 2>/dev/null
    fi
  else
    rm -f "${tmp}" 2>/dev/null
    return 1
  fi
}

yaml_set_section_key() {
  local cfg="$1" section="$2" subkey="$3" val="$4"
  local tmp="${cfr_run_state}/.${cfg##*/}.sec.$$.tmp"
  mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true
  if busybox awk -v sec="${section}" -v sk="${subkey}" -v v="${val}" '
    BEGIN { in_sec = 0; found_sec = 0; replaced = 0; indent = "  " }
    $0 ~ ("^" sec ":[[:space:]]*(#.*)?$") {
      in_sec = 1
      found_sec = 1
      print
      next
    }
    in_sec && /^[^[:space:]#-]/ {
      if (!replaced) {
        print indent sk ": " v
        replaced = 1
      }
      in_sec = 0
    }
    in_sec && !replaced && $0 ~ ("^[[:space:]]+" sk ":[[:space:]]*") {
      match($0, /^[[:space:]]+/)
      indent = substr($0, 1, RLENGTH)
      print indent sk ": " v
      replaced = 1
      next
    }
    in_sec && /^[[:space:]]+[a-zA-Z0-9_-]+:/ {
      match($0, /^[[:space:]]+/)
      indent = substr($0, 1, RLENGTH)
    }
    { print }
    END {
      if (in_sec && !replaced) {
        print indent sk ": " v
      } else if (!found_sec) {
        print sec ":"
        print "  " sk ": " v
      }
    }
  ' "${cfg}" > "${tmp}" 2>/dev/null && [ -s "${tmp}" ]; then
    if ! busybox cmp -s "${tmp}" "${cfg}"; then
      mv -f "${tmp}" "${cfg}"
    else
      rm -f "${tmp}" 2>/dev/null
    fi
  else
    rm -f "${tmp}" 2>/dev/null
    return 1
  fi
}

yaml_ensure_tun_dns_hijack() {
  local cfg="$1"
  local tmp="${cfr_run_state}/.${cfg##*/}.hijack.$$.tmp"
  local has_hijack
  has_hijack=$(busybox awk '
    /^tun:[[:space:]]*(#.*)?$/ { in_sec=1; next }
    in_sec && /^[^[:space:]#-]/ { in_sec=0 }
    in_sec && /^[[:space:]]+dns-hijack:/ { print "1"; exit }
  ' "${cfg}" 2>/dev/null)
  [ -n "${has_hijack}" ] && return 0

  if busybox awk '
    { print }
    /^tun:[[:space:]]*(#.*)?$/ {
      print "  dns-hijack:"
      print "    - any:53"
      print "    - tcp://any:53"
    }
  ' "${cfg}" > "${tmp}" 2>/dev/null && [ -s "${tmp}" ]; then
    mv -f "${tmp}" "${cfg}"
  else
    rm -f "${tmp}" 2>/dev/null
  fi
}

ensure_controller_secret() {
  local secret_file="${cfr_run_state}/controller.secret"
  local current_secret
  current_secret="$(yaml_get_top_key "${mihomo_config}" "secret")"
  if [ -n "${current_secret}" ]; then
    return 0
  fi

  local gen_secret=""
  if [ -s "${secret_file}" ]; then
    gen_secret="$(busybox tr -d '[:space:]' < "${secret_file}" 2>/dev/null)"
  fi
  if [ -z "${gen_secret}" ]; then
    if [ -r /proc/sys/kernel/random/uuid ]; then
      gen_secret="$(busybox tr -d '-\n' < /proc/sys/kernel/random/uuid 2>/dev/null | busybox cut -c1-24)"
    fi
    if [ -z "${gen_secret}" ] && [ -r /dev/urandom ]; then
      gen_secret="$(busybox tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | busybox head -c 24)"
    fi
    [ -n "${gen_secret}" ] || gen_secret="cfr$(date +%s)$$"
    mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true
    printf '%s\n' "${gen_secret}" > "${secret_file}"
    chmod 0600 "${secret_file}" 2>/dev/null || true
  fi

  yaml_set_top_key "${mihomo_config}" "secret" "\"${gen_secret}\""
  log Info "已为控制接口强制配置随机访问密钥 (secret)"
}

sync_provider_subscription_url() {
  local cfg="$1"
  local sub_url="${subscription_url_mihomo[0]}"
  [ -n "${sub_url}" ] || return 0
  case "${sub_url}" in
    *你的订阅链接*) return 0 ;;
  esac

  local tmp="${cfr_run_state}/.${cfg##*/}.prov.$$.tmp"
  mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true

  if CFR_PROVIDER_URL="${sub_url}" busybox awk '
    BEGIN { in_prov = 0; in_airport = 0; updated = 0 }
    /^proxy-providers:[[:space:]]*(#.*)?$/ { in_prov = 1; print; next }
    in_prov && /^[^[:space:]#-]/ { in_prov = 0; in_airport = 0 }
    in_prov && /^  airport:[[:space:]]*(#.*)?$/ { in_airport = 1; print; next }
    in_airport && /^  [^[:space:]#-]/ { in_airport = 0 }
    in_airport && !updated && /^[[:space:]]+url:[[:space:]]*/ {
      match($0, /^[[:space:]]+/)
      indent = substr($0, 1, RLENGTH)
      u = ENVIRON["CFR_PROVIDER_URL"]
      gsub(/"/, "\\\"", u)
      print indent "url: \"" u "\""
      updated = 1
      next
    }
    { print }
  ' "${cfg}" > "${tmp}" 2>/dev/null && [ -s "${tmp}" ]; then
    if ! busybox cmp -s "${tmp}" "${cfg}"; then
      mv -f "${tmp}" "${cfg}"
      log Info "已将 settings.ini 订阅链接同步至 proxy-providers.airport"
    else
      rm -f "${tmp}" 2>/dev/null
    fi
  else
    rm -f "${tmp}" 2>/dev/null
  fi

  # 首次安装尚无节点缓存时，确保 providers 目录就绪并短暂等待外网路由就绪再让内核拉取节点
  if busybox grep -q '^proxy-providers:' "${cfg}" 2>/dev/null && [ ! -s "${cfr_dir}/${bin_name}/providers/airport.yaml" ]; then
    mkdir -p "${cfr_dir}/${bin_name}/providers" >/dev/null 2>&1 || true
    chown "${cfr_user_group}" "${cfr_dir}/${bin_name}/providers" >/dev/null 2>&1 || true
    chmod 0700 "${cfr_dir}/${bin_name}/providers" >/dev/null 2>&1 || true
    local net_wait=0
    while [ ${net_wait} -lt 15 ]; do
      ip route get 223.5.5.5 >/dev/null 2>&1 && break
      sleep 1
      net_wait=$((net_wait + 1))
    done
  fi
}

prepare_mihomo() {
  # 配置缺失时先尝试用订阅补回，仍缺失才报错
  if [ ! -f "${mihomo_config}" ] && [ "${update_subscription}" = "true" ] && [ -n "${subscription_url_mihomo[0]}" ]; then
    log Warning "未找到 config.yaml，尝试从订阅获取"
    # 配置缺失兜底：限时 10 秒
    SUBS_TIMEOUT=10 "${scripts_dir}/tool.sh" subs >/dev/null 2>&1 || true
  fi

  if [ ! -f "${mihomo_config}" ]; then
    log Error "未找到 config.yaml"
    set_description error "配置文件不存在"
    exit 1
  fi

  log Info "配置文件: config.yaml"

  local cfg_backup="${cfr_run_state}/.${mihomo_config##*/}.prep.$$.bak"
  mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true
  cp -f "${mihomo_config}" "${cfg_backup}" 2>/dev/null || true

  local cur_ctrl
  cur_ctrl="$(yaml_get_top_key "${mihomo_config}" "external-controller")"
  if [ -z "${cur_ctrl}" ]; then
    yaml_set_top_key "${mihomo_config}" "external-controller" "127.0.0.1:23450"
  elif [ "${stealth_mode:-true}" = "true" ] && [ "${allow_lan_controller:-false}" != "true" ]; then
    case "${cur_ctrl}" in
      0.0.0.0:*)
        yaml_set_top_key "${mihomo_config}" "external-controller" "127.0.0.1:${cur_ctrl#0.0.0.0:}"
        log Info "隐匿模式：已将 external-controller 监听地址收紧为 127.0.0.1"
        ;;
    esac
  fi

  if [ "${stealth_mode:-true}" = "true" ]; then
    ensure_controller_secret
  fi

  if [ -z "$(yaml_get_top_key "${mihomo_config}" "external-ui")" ]; then
    yaml_set_top_key "${mihomo_config}" "external-ui" "./dashboard"
  fi
  if [ -z "$(yaml_get_top_key "${mihomo_config}" "external-ui-url")" ]; then
    yaml_set_top_key "${mihomo_config}" "external-ui-url" "\"https://github.com/Zephyruso/zashboard/releases/latest/download/dist-firasans-only.zip\""
  fi

  yaml_set_top_key "${mihomo_config}" "tproxy-port" "${tproxy_port}"
  yaml_set_top_key "${mihomo_config}" "redir-port" "${redir_port}"

  local target_tun_dev="${tun_device_name:-tun0}"

  if [[ "${network_mode}" == @(mixed|tun) ]]; then
    # 当 TUN + CNIP 由 iptables.sh 接管策略路由时，这里只同步 tun 开关，不再让 Mihomo 自动写路由。
    local mihomo_tun_auto_route
    local mihomo_tun_strict_route
    local mihomo_tun_auto_redirect
    local mihomo_tun_auto_detect_interface
    local mihomo_tun_stack
    mihomo_tun_auto_route="$(tun_auto_flag_value)"
    mihomo_tun_strict_route="$(tun_auto_flag_value)"
    mihomo_tun_auto_redirect="$(tun_auto_flag_value)"
    mihomo_tun_auto_detect_interface="$(tun_auto_flag_value)"
    mihomo_tun_stack="$(tun_effective_stack)"
    stack="${mihomo_tun_stack}"
    if tun_should_force_gvisor; then
      log Info "检测到 TUN + 大陆IP分流，已将 mihomo 协议栈调整为 gvisor。"
    fi
    mihomo_tun_status=$(busybox awk '!/^ *#/ && /^tun:/ { found=1; exit } END{ if (found) print "1" }' "${mihomo_config}" 2>/dev/null)
    if [ -z "${mihomo_tun_status}" ]; then
      printf '%s\n' '' 'tun:' \
        '  enable: true' \
        '  mtu: 9000' \
        "  device: ${target_tun_dev}" \
        "  stack: ${mihomo_tun_stack}" \
        '  dns-hijack:' \
        '    - any:53' \
        '    - tcp://any:53' \
        "  auto-route: ${mihomo_tun_auto_route}" \
        "  strict-route: ${mihomo_tun_strict_route}" \
        "  auto-redirect: ${mihomo_tun_auto_redirect}" \
        "  auto-detect-interface: ${mihomo_tun_auto_detect_interface}" \
        '  include-android-user: [0, 10]' \
        '  exclude-uid: []' \
        '  include-uid: []' >> "${mihomo_config}"
    else
      log Info "已存在 [tun] 配置"
      yaml_ensure_tun_dns_hijack "${mihomo_config}"
      if [ "${stealth_mode:-true}" = "true" ]; then
        local cur_tun_dev
        cur_tun_dev=$(busybox awk '/^tun:/{f=1;next} f && /^[^[:space:]#-]/{f=0} f && /^[[:space:]]+device:/{print $2;exit}' "${mihomo_config}" 2>/dev/null)
        if [ -z "${cur_tun_dev}" ] || [ "${cur_tun_dev}" = "meta" ]; then
          yaml_set_section_key "${mihomo_config}" "tun" "device" "${target_tun_dev}"
        fi
      fi
    fi

    yaml_set_section_key "${mihomo_config}" "tun" "enable" "true"
    if tun_should_manage_core_config; then
      yaml_set_section_key "${mihomo_config}" "tun" "stack" "${mihomo_tun_stack}"
      yaml_set_section_key "${mihomo_config}" "tun" "auto-route" "${mihomo_tun_auto_route}"
      yaml_set_section_key "${mihomo_config}" "tun" "strict-route" "${mihomo_tun_strict_route}"
      yaml_set_section_key "${mihomo_config}" "tun" "auto-redirect" "${mihomo_tun_auto_redirect}"
      yaml_set_section_key "${mihomo_config}" "tun" "auto-detect-interface" "${mihomo_tun_auto_detect_interface}"
      yaml_set_top_key "${mihomo_config}" "routing-mark" "33554432"
    else
      yaml_set_section_key "${mihomo_config}" "tun" "auto-route" "true"
      yaml_set_section_key "${mihomo_config}" "tun" "auto-detect-interface" "true"
      log Info "TUN 未启用大陆 IP 分流，保留 Mihomo 现有 TUN 路由与协议栈配置。"
    fi

    if [ "${proxy_mode}" = "core" ]; then
      yaml_set_section_key "${mihomo_config}" "tun" "exclude-uid" "[]"
      yaml_set_section_key "${mihomo_config}" "tun" "include-uid" "[]"
      log_service_results "mihomo" "core" ""
    else
      if [ -f "${uid_list}" ]; then
          list_uid=$(busybox tr '\n' ',' < "${uid_list}" | sed 's/,$//')
      else
          list_uid=""
      fi

      if [[ "${proxy_mode}" = "whitelist" || "${proxy_mode}" = "white" ]]; then
        mode="include"
      elif [[ "${proxy_mode}" = "blacklist" || "${proxy_mode}" = "black" ]]; then
        mode="exclude"
      fi

      yaml_set_section_key "${mihomo_config}" "tun" "exclude-uid" "[]"
      yaml_set_section_key "${mihomo_config}" "tun" "include-uid" "[]"

      if [ -n "${list_uid}" ]; then
        yaml_set_section_key "${mihomo_config}" "tun" "${mode}-uid" "[${list_uid}]"
      fi
      log_service_results "mihomo" "$mode" "$list_uid"
    fi

  else
    yaml_set_section_key "${mihomo_config}" "tun" "enable" "false"
  fi

  mihomo_enhanced_mode=$(busybox awk '/^dns:/{f=1;next} f && /^[^[:space:]#-]/{f=0} f && /^[[:space:]]+enhanced-mode:/ { print $2; exit }' "${mihomo_config}" 2>/dev/null)
  if [ -z "${mihomo_enhanced_mode}" ]; then
    yaml_set_section_key "${mihomo_config}" "dns" "enhanced-mode" "fake-ip"
    mihomo_enhanced_mode="fake-ip"
  fi

  if [[ "${network_mode}" == @(mixed|tproxy|redirect|enhance) ]]; then
    if [[ "${proxy_mode}" != "core" ]] && [[ -n "${packages_list[*]}" || -n "${ignore_ap_list[*]}" || -n "${gid_list[*]}" ]] && [ "${mihomo_enhanced_mode}" = "fake-ip" ]; then
      log Warning "${proxy_mode} 仅在 mihomo 的 enhanced-mode: redir-host 下生效"
      log Warning "已将 fake-ip 替换为 redir-host"
      yaml_set_section_key "${mihomo_config}" "dns" "enhanced-mode" "redir-host"
      yaml_set_section_key "${mihomo_config}" "sniffer" "enable" "true"
    fi
  fi

  sync_provider_subscription_url "${mihomo_config}"
  prepare_rules "${mihomo_config}"

  if ! "${bin_path}" -d "${cfr_dir}/${bin_name}" -t -f "${mihomo_config}" >/dev/null 2>&1; then
    log Warning "改写后配置未通过内核校验，已回滚到改写前版本"
    [ -s "${cfg_backup}" ] && mv -f "${cfg_backup}" "${mihomo_config}" 2>/dev/null || true
  else
    rm -f "${cfg_backup}" 2>/dev/null || true
  fi
  chmod 0600 "${mihomo_config}" 2>/dev/null || true
}

cfr_run_bin() {
  log Info "启动服务: ${bin_name}"
  ulimit -SHn 1000000

  case "${bin_name}" in
    mihomo)
      if [ "${auto_modify_config}" = "true" ]; then
        prepare_mihomo
      fi
      nohup busybox setuidgid "${cfr_user_group}" "${bin_path}" -d "${cfr_dir}/${bin_name}" -f "${mihomo_config}" > "${bin_log}" 2>&1 &
      PID=$!
      echo -n $PID > "${cfr_pid}"
      ;;
    *)
      log Error "未知内核: ${bin_name}"
      exit 1
      ;;
  esac
}

cfr_cgroup() {
  set_cgroup_config() {
    local cgroup_attr="$1"
    local cgroup_value="$2"

    if [ "${cgroup_value}" = "true" ]; then
      if ${scripts_dir}/tool.sh "${cgroup_attr}"; then
        true
      else
        log Warning "无法为 ${bin_name} 启用 ${cgroup_attr}"
        log Warning "已关闭 cgroups ${cgroup_attr}"
        sed -i -E "/cgroup_${cgroup_attr}/ s/(true)/false/" "${file_settings}"
      fi
    fi
  }
  set_cgroup_config "memcg" "${cgroup_memcg}"
  set_cgroup_config "cpuset" "${cgroup_cpuset}"
  set_cgroup_config "blkio" "${cgroup_blkio}"
}

cfr_bin_status() {
  local PID
  PID=$(busybox pidof "${bin_name}")

  if [ -z "$PID" ]; then
    log Error "${bin_name} 未在运行"
    return 1
  fi

  stack=$(busybox awk '!/^ *#/ && /stack: / { print $2;found=1; exit}' "${mihomo_config}")
  log Info "${bin_name} 服务正在运行"

  log Info "代理模式: ${proxy_mode} + 网络模式: ${network_mode} + $(if [[ "${network_mode}" == @(mixed|tun) ]]; then echo "协议栈: ${stack}"; fi)"

  rss=$(grep VmRSS /proc/$PID/status | busybox awk '{ print $2 }')
  [ "${rss}" -ge 1024 ] && bin_rss="$(expr ${rss} / 1024) MB" || bin_rss="${rss} KB"
  swap=$(grep VmSwap /proc/$PID/status | busybox awk '{ print $2 }')
  [ "${swap}" -ge 1024 ] && bin_swap="$(expr ${swap} / 1024) MB" || bin_swap="${swap} KB"

  user_group=$(stat -c %U:%G /proc/$PID)

  log Info "${bin_name} (PID: $PID) 用户组: ${user_group}, 内存: ${bin_rss}, 交换: ${bin_swap}"

  cpu=$(ps -p $PID -o %cpu | busybox awk 'NR==2{print $1}' 2>/dev/null)

  cpus_allowed=$(grep Cpus_allowed_list /proc/$PID/status | busybox awk '{ print $2" "$3 }')
  core=$(busybox awk '{print $39}' /proc/$PID/stat 2>/dev/null)

  log Info "${bin_name} CPU: ${cpu:-无法获取}%, 允许核心: ${cpus_allowed:-无法获取}"

  temperature_celsius=$(($(cat /sys/class/power_supply/battery/temp) / 10))
  log Info "电池温度: ${temperature_celsius}°C"

  running_time=$(busybox ps -o comm,etime | grep ${bin_name} | busybox awk '{print $2}')
  log Info "${bin_name} 运行时间: ${running_time:-无法获取}"

  (
    localIP=($(ip -4 a | awk '/inet / && !/127.0.0.1/ { split($2, a, "/"); print a[1] }'))
    log Info "本地 IP: ${localIP[*]}"
    localDNS=($(dumpsys connectivity | awk -F'[ ,]' '/DnsAddresses:/ { for (i=1; i<=NF; i++) if ($i ~ /^\/.*$/) { dns=substr($i, 2); if (dns ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print dns } }'))
    log Info "本地 DNS: ${localDNS[*]}"
  ) &


  if [ -n "$PID" ]; then
    get_dns_mode
    set_description running
    echo -n "$PID" > "${cfr_pid}"
  fi
}

set_description() {
  local status="$1"
  local error_msg="$2"
  local desc=""
  local ipv6_info=""
  local wifi_match_str=""
  local ssid_mode_str=""
  local ssid_count=0
  local bssid_count=0

  if [ "${ipv6}" = "true" ]; then
    ipv6_info="已启用"
  else
    ipv6_info="已禁用"
  fi

  if [ "$status" = "running" ] && [ "${enable_network_service_control}" = "true" ] && [ "${use_ssid_matching}" = "true" ]; then
    if [ "${use_wifi_list_mode}" = "blacklist" ]; then
      ssid_mode_str="黑名单"
    elif [ "${use_wifi_list_mode}" = "whitelist" ]; then
      ssid_mode_str="白名单"
    else
      ssid_mode_str="未知模式"
    fi
    ssid_count=0
    for ssid_item in "${wifi_ssids_list[@]}"; do
      [ -n "$ssid_item" ] && ssid_count=$((ssid_count + 1))
    done

    bssid_count=0
    for bssid_item in "${wifi_bssids_list[@]}"; do
      [ -n "$bssid_item" ] && bssid_count=$((bssid_count + 1))
    done

    wifi_match_str=" | WiFi匹配（${ssid_mode_str}）SSID:${ssid_count} BSSID:${bssid_count}"
  fi

  case "$status" in
    running)
      desc="✅ cfr 运行中 | 内核: ${bin_name} | 代理模式: ${proxy_mode} | 网络: ${network_mode} | IPv6状态: ${ipv6_info} | DNS模式: ${dns_mode}${wifi_match_str}"
      ;;
    stopped)
      desc="❌ cfr 已停止 | 代理已禁用"
      ;;
    idle)
      desc="✨ cfr 模块已加载，等待服务启动"
      ;;
    error)
      local current_time
      current_time=$(date "+%Y-%m-%d %H:%M:%S")
      [ -z "${error_msg}" ] && error_msg="配置错误"
      desc="⚠️ cfr ${error_msg} | 时间: ${current_time} | 内核: ${bin_name} | 详情见 log/${bin_name}.log"
      ;;
    *)
      desc="💤 cfr 状态未知"
      ;;
  esac
  local escaped_desc
  escaped_desc=$(echo "${desc}" | sed -e 's/[&|#]/\\&/g')
  sed -Ei "s#^description=.*#description=${escaped_desc}#g" "$PROPFILE"
}
get_dns_mode() {
  dns_mode="未知"
  if [ "${bin_name}" = "mihomo" ]; then
    if grep -q "enhanced-mode: redir-host" "${mihomo_config}" 2>/dev/null; then
      dns_mode="redir-host"
    elif grep -q "enhanced-mode: fake-ip" "${mihomo_config}" 2>/dev/null; then
      dns_mode="fake-ip"
    fi
  fi
  export dns_mode
}

start_cfr() {
  cfr_check_logs
  find_packages_uid
  get_dns_mode
  set_description running

  cfr_version=$(busybox awk '!/^ *#/ && /version=/ { print $0 }' "/data/adb/modules/cfr/module.prop" 2>/dev/null)
  startup_datetime="$(date)"
  startup_abi="$(getprop ro.product.cpu.abi)"
  if [ "${stealth_mode:-true}" = "true" ]; then
    log Info "时间: ${startup_datetime}"
    log Info "模块: ${cfr_version} (${startup_abi})"
  else
    startup_timezone="$(getprop persist.sys.timezone)"
    startup_network="$(getprop gsm.sim.operator.alpha) $(getprop gsm.network.type)"
    log Info "时区: ${startup_timezone} | 时间: ${startup_datetime}"
    log Info "网络: ${startup_network}"
    log Info "模块: ${cfr_version} (${startup_abi})"
  fi

  # 已在运行则重启并重建规则
  PIDS=("${bin_list[@]}")
  PID=""
  i=0

  while [ -z "$PID" ] && [ "$i" -lt "${#PIDS[@]}" ]; do
    PID=$(busybox pidof "${PIDS[$i]}")
    i=$((i+1))
  done

  if [ -n "$PID" ]; then
    stop_cfr
    start_cfr && "${scripts_dir}/iptables.sh" renew
    exit 0
  fi

  case "${bin_name}" in
    mihomo)
      log Info "启动服务"
      ;;
    *)
      log Error "内核名未定义或未知: ${bin_name}"
      exit 1
      ;;
  esac

  busybox_code=$(busybox | busybox grep -oE '[0-9.]*' | head -n 1)
  if [ -n "${busybox_code}" ] && [ "$(echo "${busybox_code}" | busybox awk -F. '{printf "%03d%03d%03d\n", $1, $2, $3}')" -lt "$(echo "1.36.1" | busybox awk -F. '{printf "%03d%03d%03d\n", $1, $2, $3}')" ]; then
    log Warning "busybox v${busybox_code} 过低，请更新到 v1.36.1+"
  else
    log Info "busybox: v${busybox_code}"
  fi

  cfr_permission
  cfr_check_bin

  [ "${run_crontab}" = "true" ] && cfr_run_crontab || log Info "定时任务已禁用"

  if [ -z "${proxy_mode}" ]; then
    M1=$(busybox awk '!/^ *#/ && /mode:/{print $0}' "${pkg_config}")
    [ -z $M1 ] && printf "\nmode:white" >> "${pkg_config}"
  fi

  # 先启用 Kill-Switch 再清理旧代理规则，防止启动/订阅更新窗口期普通 App 裸连泄漏
  if [ "${kill_switch:-true}" = "true" ]; then
    "${scripts_dir}/iptables.sh" killswitch >/dev/null 2>&1 || true
    "${scripts_dir}/iptables.sh" disable keep keep_ks >/dev/null 2>&1 || true
  else
    "${scripts_dir}/iptables.sh" disable >/dev/null 2>&1 || true
  fi

  upsubs_pending="false"
  if [ "${update_subscription}" = "true" ]; then
    if [ "${upsubs_after_start:-true}" = "true" ] && [ -s "${mihomo_config}" ]; then
      # 已有可用配置时先拉起内核与透明代理，再经由代理更新订阅，避免直连暴露订阅特征
      upsubs_pending="true"
    else
      log Info "启动前更新订阅"
      SUBS_TIMEOUT=10 "${scripts_dir}/tool.sh" subs >/dev/null 2>&1 || true
    fi
  fi

  # 启动内核；若因配置问题启动失败，重下订阅后重试一次
  local retried="false" start_ok i kernel_tail
  while true; do
    cfr_run_bin
    cfr_cgroup

    # 连续 3 秒确认进程存活即视为启动成功
    start_ok="true"
    i=0
    while [ "$i" -lt 3 ]; do
      sleep 1
      if ! cfr_bin_alive; then
        start_ok="false"
        break
      fi
      i=$((i + 1))
    done
    [ "${start_ok}" = "true" ] && break

    kernel_tail=$(busybox tail -n 5 "${cfr_log_dir}/${bin_name}.log" 2>/dev/null)
    log Error "${bin_name} 启动失败"
    [ -n "${kernel_tail}" ] && log Error "内核输出: ${kernel_tail}"

    if [ "${retried}" = "false" ] && [ "${update_subscription}" = "true" ] && [ -n "${subscription_url_mihomo[0]}" ]; then
      retried="true"
      log Warning "可能是 config.yaml 有问题，重新下载订阅后重试"
      busybox pkill -15 "${bin_name}" >/dev/null 2>&1
      rm -f "${cfr_pid}" 2>/dev/null
      if [ "${kill_switch:-true}" = "true" ]; then
        "${scripts_dir}/iptables.sh" killswitch >/dev/null 2>&1 || true
        "${scripts_dir}/iptables.sh" disable keep keep_ks >/dev/null 2>&1 || true
      else
        "${scripts_dir}/iptables.sh" disable >/dev/null 2>&1 || true
      fi
      # 启动失败重下：限时 10 秒
      if ! SUBS_TIMEOUT=10 "${scripts_dir}/tool.sh" subs >/dev/null 2>&1; then
        log Warning "订阅重新下载失败: $(busybox tail -n 1 "${cfr_log_dir}/tool.log" 2>/dev/null)"
        log Warning "继续使用现有配置重试"
      else
        upsubs_pending="false"
      fi
      continue
    fi

    log Error "无法自动恢复，请检查 ${bin_name}.log"
    kernel_start_give_up
  done

  export upsubs_pending
  true
}

stop_cfr() {
  stop_cron
  for bin in "${bin_list[@]}"; do
    if busybox pgrep "${bin}" >/dev/null; then
      if busybox pkill -15 "${bin}" >/dev/null; then
        :
      else
        killall -15 "${bin}" >/dev/null 2>&1 || kill -15 "$(busybox pidof "${bin}")" >/dev/null 2>&1
      fi
    fi
  done

  count=0
  while [ $count -lt 3 ]; do
    if ! busybox pidof "${bin_name}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    count=$((count + 1))
  done

  if ! busybox pidof "${bin_name}" >/dev/null; then
    if [ -f "${cfr_pid}" ]; then
      rm -f "${cfr_pid}"
    fi
    log Warning "${bin_name} 已关闭，服务已停止。"
    log Warning "${bin_name} 已断开连接。"
  else
    log Warning "${bin_name} 未完全停止，可能正在关闭或关闭失败。"
    force_stop
  fi

  set_description stopped
}

stop_cron() {
  local cronkill
  cronkill=$(busybox pgrep -f "crond -c ${cfr_run_state}")
  for cron in ${cronkill}; do
    kill -15 "${cron}" >/dev/null 2>&1
  done
}

force_stop() {
  log Warning "尝试强制关闭"
  local PID
  PID=$(cat "${cfr_pid}" 2>/dev/null)

  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill -9 "$PID" >/dev/null 2>&1
  else
    for bin in "${bin_list[@]}"; do
      busybox pkill -9 "${bin}" >/dev/null 2>&1
    done
  fi

  if ! busybox pgrep -f "${bin_name}" >/dev/null 2>&1; then
    log Warning "完成，现在可以安心休息了"
    rm -f "${cfr_pid}"
  fi
}

if ! command -v busybox >/dev/null 2>&1; then
  log Error "$(which busybox) 命令未找到"
  exit 1
fi

case "$1" in
  prepare)
    # 订阅更新后补全缺失字段
    if [ "${auto_modify_config}" = "true" ] && [ -f "${mihomo_config}" ]; then
      prepare_mihomo
    fi
    ;;
  start)
    stop_cfr >/dev/null 2>&1
    if start_cfr; then
      "${scripts_dir}/iptables.sh" renew >/dev/null 2>&1 || true
      $scripts_dir/tool.sh webroot >/dev/null 2>&1
      if [ "${upsubs_pending}" = "true" ]; then
        (SUBS_TIMEOUT=15 "${scripts_dir}/tool.sh" subs >/dev/null 2>&1 || true) &
      fi
    fi
    ;;
  stop)
    # 必须先撤掉 iptables 规则，否则流量会被重定向到已关闭的端口导致断网
    "${scripts_dir}/iptables.sh" disable >/dev/null 2>&1 || true
    stop_cfr
    ;;
  restart)
    if [ "${kill_switch:-true}" = "true" ]; then
      "${scripts_dir}/iptables.sh" killswitch >/dev/null 2>&1 || true
      "${scripts_dir}/iptables.sh" disable keep keep_ks && stop_cfr
    else
      "${scripts_dir}/iptables.sh" disable && stop_cfr
    fi
    if start_cfr; then
      "${scripts_dir}/iptables.sh" renew
      $scripts_dir/tool.sh webroot >/dev/null 2>&1
      if [ "${upsubs_pending}" = "true" ]; then
        (SUBS_TIMEOUT=15 "${scripts_dir}/tool.sh" subs >/dev/null 2>&1 || true) &
      fi
    fi
    ;;
  refresh_uids)
    [ "${proxy_mode}" = "core" ] && exit 0
    find_packages_uid
    if cfr_bin_alive; then
      if [[ "${network_mode}" == @(mixed|tun) ]]; then
        [ "${auto_modify_config}" = "true" ] && [ -f "${mihomo_config}" ] && prepare_mihomo >/dev/null 2>&1 || true
        "${scripts_dir}/tool.sh" reload >/dev/null 2>&1 || true
      fi
      if [[ "${network_mode}" != "tun" ]] || [ "${bypass_cn_ip}" = "true" ]; then
        "${scripts_dir}/iptables.sh" renew >/dev/null 2>&1 || true
      fi
    fi
    ;;
  status)
    if busybox pidof "${bin_name}" >/dev/null; then
      echo "${yellow}$("${bin_path}" -v)${normal}"
      cfr_bin_status
    else
      log Warning "${bin_name} 已关闭，服务已停止"
    fi
    ;;
  cron)
    run_crontab="true"
    stop_cron
    cfr_run_crontab
    ;;
  kcron)
    stop_cron
    ;;
  *)
    echo "${red}$0 '$1' 未找到${normal}" >&2
    echo "${yellow}用法${normal}: ${green}$0${normal} {${yellow}start|stop|restart|status|cron|kcron${normal}}" >&2
    ;;
esac