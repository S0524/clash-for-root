#!/system/bin/sh

# $0 不含 / 时（如 sh tool.sh）${0%/*} 会原样返回，需兜底
case "$0" in
  */*) scripts_dir="${0%/*}" ;;
  *) scripts_dir="/data/adb/cfr/scripts" ;;
esac

user_agent="Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
source /data/adb/cfr/settings.ini

case ":${PATH}:" in
  *":${bin_dir}:"*) ;;
  *) export PATH="${bin_dir}:${PATH}" ;;
esac

TOOL_LOG="${cfr_log_dir}/tool.log"
busybox mkdir -p "$(dirname "$TOOL_LOG")"
cfr_log="$TOOL_LOG"

# ===== 下载 / 更新限时（秒）· 全模块限时只在这里改，别处都引用这些变量 =====
# 组件 = geox / mihomo 内核 / metacubexd 面板 / curl / 国内 IP 列表
DL_MAX_TIME=60        # 组件下载总超时，同时是 upfile() 第 4 参数的默认值
DL_CONN_TIMEOUT=15    # 组件下载建连超时（总超时比它短时自动跟着缩短）
API_CONN_TIMEOUT=15   # GitHub 版本号查询建连超时
API_MAX_TIME=60       # GitHub 版本号查询总超时
SUBS_MAX_TIME=60      # 手动执行 tool.sh subs 的总超时；启动流程用 SUBS_TIMEOUT= 临时覆盖
RELOAD_CONN_TIMEOUT=5 # 调内核 API 热重载配置：建连超时
RELOAD_MAX_TIME=15    # 调内核 API 热重载配置：总超时

resolve_curl_tls_args() {
  CURL_TLS_ARGS=""
  WGET_TLS_ARGS=""
  if [ "${tls_verify:-true}" = "false" ]; then
    CURL_TLS_ARGS="--insecure"
    WGET_TLS_ARGS="--no-check-certificate"
    return 0
  fi

  local ca_file="" ca_dir=""
  for ca_file in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem /data/adb/cfr/ca-bundle.crt; do
    if [ -s "${ca_file}" ]; then
      CURL_TLS_ARGS="--cacert ${ca_file}"
      return 0
    fi
  done

  # Android /apex/com.android.conscrypt/cacerts 的 .0 文件直接走 --capath 在 static-curl 下可能触发 exit 60，
  # 合并提取 PEM 块为单文件 ca-bundle.crt 以确保各类 TLS 后端校验兼容
  local bundle="${cfr_run_state}/ca-bundle.crt"
  if [ ! -s "${bundle}" ]; then
    mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true
    local tmp_bundle="${bundle}.$$.tmp"
    {
      for ca_dir in /apex/com.android.conscrypt/cacerts /system/etc/security/cacerts /etc/ssl/certs; do
        [ -d "${ca_dir}" ] || continue
        busybox awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' "${ca_dir}"/* 2>/dev/null || true
      done
    } > "${tmp_bundle}"
    if [ -s "${tmp_bundle}" ]; then
      mv -f "${tmp_bundle}" "${bundle}"
      chmod 0600 "${bundle}" 2>/dev/null || true
    else
      rm -f "${tmp_bundle}" 2>/dev/null || true
    fi
  fi

  if [ -s "${bundle}" ]; then
    CURL_TLS_ARGS="--cacert ${bundle}"
    return 0
  fi

  for ca_dir in /apex/com.android.conscrypt/cacerts /system/etc/security/cacerts /etc/ssl/certs; do
    if [ -d "${ca_dir}" ] && [ -n "$(ls -A "${ca_dir}" 2>/dev/null)" ]; then
      CURL_TLS_ARGS="--capath ${ca_dir}"
      return 0
    fi
  done

  # 未找到任何系统 CA 目录时回退警告，避免完全无法联网更新
  log Warning "未检测到系统 CA 证书目录，TLS 校验回退为跳过"
  CURL_TLS_ARGS="--insecure"
  WGET_TLS_ARGS="--no-check-certificate"
}

setup_github_api() {
  resolve_curl_tls_args
  rev1="busybox wget ${WGET_TLS_ARGS} -qO- -T ${API_CONN_TIMEOUT}"
  if which curl >/dev/null; then
    rev1="curl ${CURL_TLS_ARGS} -sL --connect-timeout ${API_CONN_TIMEOUT} --max-time ${API_MAX_TIME}"
  fi
}

resolve_github_latest_tag() {
  local repo="$1"
  local effective_url="" tag=""

  setup_github_api
  if command -v curl >/dev/null 2>&1; then
    effective_url=$(curl ${CURL_TLS_ARGS} -sIL -o /dev/null -w '%{url_effective}' --connect-timeout "${API_CONN_TIMEOUT}" --max-time "${API_MAX_TIME}" --user-agent "${user_agent}" "https://github.com/${repo}/releases/latest" 2>/dev/null)
  else
    effective_url=$(busybox wget ${WGET_TLS_ARGS} -S --spider -T "${API_CONN_TIMEOUT}" "https://github.com/${repo}/releases/latest" 2>&1 | busybox awk '/^[[:space:]]*[Ll]ocation:/ { loc=$2 } END { gsub(/\r/, "", loc); print loc }')
  fi

  case "${effective_url}" in
    */releases/tag/*)
      tag="${effective_url##*/releases/tag/}"
      tag="${tag%%\?*}"
      ;;
  esac

  if [ -z "${tag}" ]; then
    tag=$($rev1 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | busybox awk -F'"' '/"tag_name"[[:space:]]*:/ { print $4; exit }')
  fi

  printf '%s\n' "${tag}"
}

mask_url() {
  local u="$1"
  echo "$u" | sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*://)?([^/]+).*$#\1\2/***#'
}

upfile() {
  local file="$1"
  local update_url="$2"
  local custom_ua="$3" # 接收自定义 User-Agent
  local max_time="${4:-${DL_MAX_TIME}}" # 第 4 参数：总超时（秒），不传用 DL_MAX_TIME
  local conn_timeout="${DL_CONN_TIMEOUT}"
  # 总超时比连接超时还短时，连接超时也要跟着缩短，否则限时形同虚设
  [ "${max_time}" -lt "${conn_timeout}" ] && conn_timeout="${max_time}"
  local current_ua

  if [ -n "${custom_ua}" ]; then
    current_ua="${custom_ua}"
  else
    current_ua="${user_agent}"
  fi

  resolve_curl_tls_args

  local file_bak="${file}.bak"
  [ -f "${file}" ] && mv "${file}" "${file_bak}"

  log_url="${update_url}"
  if [ "${LOG_MASK_URL}" = "mask" ]; then
    log_url="$(mask_url "${update_url}")"
  fi
  log Info "开始下载: ${log_url}"

  if which curl >/dev/null; then
    http_code=$(curl -L -s ${CURL_TLS_ARGS} --http1.1 --compressed --connect-timeout "${conn_timeout}" --max-time "${max_time}" --user-agent "${current_ua}" -o "${file}" -w "%{http_code}" "${update_url}")
    curl_exit_code=$?

    if [ ${curl_exit_code} -ne 0 ]; then
      log Error "使用 curl 下载失败 (退出码: ${curl_exit_code})"
      [ -f "${file_bak}" ] && mv "${file_bak}" "${file}"
      return 1
    fi

    if [ "${http_code}" -ne 200 ]; then
      log Error "下载失败: 服务器返回 HTTP 状态码 ${http_code}"
      [ -f "${file_bak}" ] && mv "${file_bak}" "${file}"
      return 1
    fi
  else
    # wget 没有总超时参数，-T 只限制单次读阻塞，这里沿用建连限时
    if ! busybox wget ${WGET_TLS_ARGS} -q -T ${DL_CONN_TIMEOUT} -U "${current_ua}" -O "${file}" "${update_url}"; then
      log Error "使用 wget 下载失败"
      [ -f "${file_bak}" ] && mv "${file_bak}" "${file}"
      return 1
    fi
  fi

  if [ ! -s "${file}" ]; then
    log Error "下载失败: 文件为空"
    [ -f "${file_bak}" ] && mv "${file_bak}" "${file}"
    return 1
  fi

  log Info "下载成功"
  rm -f "${file_bak}" 2>/dev/null
  return 0
}

is_cfr_running() {
  [ -f "${cfr_pid}" ] && kill -0 "$(<"${cfr_pid}" 2>/dev/null)" 2>/dev/null
}

reload_cnip_set() {
  local set_name="$1"
  local family="$2"
  local source_file="$3"
  local entries=0

  if [ ! -s "${source_file}" ]; then
    log Error "${set_name} 重写入失败: 文件不存在或为空"
    return 1
  fi

  if ! command -v ipset >/dev/null 2>&1; then
    log Warning "ipset 不可用，跳过 ${set_name} 重写入"
    return 1
  fi

  entries="$(busybox awk '!/^[[:space:]]*#/ && NF > 0 {count++} END {print count + 0}' "${source_file}" 2>/dev/null)"
  log Info "正在重写入 ${set_name}，条目=${entries}"

  if {
    echo "create ${set_name} hash:net family ${family} hashsize 8192 maxelem 65536 -exist"
    echo "flush ${set_name}"
    busybox awk -v set="${set_name}" '!/^[[:space:]]*#/ && NF > 0 {printf "add %s %s\n", set, $0}' "${source_file}"
  } | ipset restore -exist 2>/dev/null; then
    log Info "${set_name} 重写入完成"
    return 0
  fi

  log Error "${set_name} 重写入失败"
  return 1
}

reload_cnip_sets_after_update() {
  local updated_v4="$1"
  local updated_v6="$2"
  local ok="true"

  [ "${bypass_cn_ip}" = "true" ] || return 0
  is_cfr_running || return 0

  if [ "${updated_v4}" = "true" ] || [ "${updated_v6}" = "true" ]; then
    log Info "服务运行中且已启用 CNIP，正在重写入 ipset"
  fi

  if [ "${updated_v4}" = "true" ]; then
    reload_cnip_set cnip inet "${cn_ip_file}" || ok="false"
  fi

  if [ "${updated_v6}" = "true" ]; then
    reload_cnip_set cnip6 inet6 "${cn_ipv6_file}" || ok="false"
  fi

  [ "${ok}" = "true" ]
}

upcnip() {
  local attempted=0
  local success=0
  local updated_v4="false"
  local updated_v6="false"

  # IPv4
  if [ "${bypass_cn_ip}" = "true" ] && [ "${bypass_cn_ip_v4}" = "true" ]; then
    if [ -z "${cn_ip_url}" ] || [ -z "${cn_ip_file}" ]; then
      log Warning "cn_ip_url 或 cn_ip_file 未配置，跳过 IPv4"
    else
      attempted=$((attempted + 1))
      busybox mkdir -p "$(dirname "${cn_ip_file}")" >/dev/null 2>&1 || true
      log Info "下载 CN IPv4 列表 → ${cn_ip_file}"
      if upfile "${cn_ip_file}" "${cn_ip_url}"; then
        log Info "CN IPv4 列表更新完成"
        success=$((success + 1))
        updated_v4="true"
      else
        log Error "CN IPv4 列表更新失败"
      fi
    fi
  fi

  # IPv6
  if [ "${bypass_cn_ip}" = "true" ] && [ "${ipv6}" = "true" ] && [ "${bypass_cn_ip_v6}" = "true" ]; then
    if [ -z "${cn_ipv6_url}" ] || [ -z "${cn_ipv6_file}" ]; then
      log Warning "cn_ipv6_url 或 cn_ipv6_file 未配置，跳过 IPv6"
    else
      attempted=$((attempted + 1))
      busybox mkdir -p "$(dirname "${cn_ipv6_file}")" >/dev/null 2>&1 || true
      log Info "下载 CN IPv6 列表 → ${cn_ipv6_file}"
      if upfile "${cn_ipv6_file}" "${cn_ipv6_url}"; then
        log Info "CN IPv6 列表更新完成"
        success=$((success + 1))
        updated_v6="true"
      else
        log Error "CN IPv6 列表更新失败"
      fi
    fi
  fi

  if [ "${attempted}" -eq 0 ]; then
    log Info "未启用 CNIP 更新项，已跳过"
    return 0
  fi

  if [ "${success}" -ne "${attempted}" ]; then
    log Error "CNIP 列表更新异常（成功 ${success}/${attempted}）"
    return 1
  fi

  if ! reload_cnip_sets_after_update "${updated_v4}" "${updated_v6}"; then
    log Error "CNIP ipset 重写入失败"
    return 1
  fi

  log Info "CNIP 列表更新完成（成功 ${success}/${attempted}）"
  return 0
}

restart_cfr() {
  local core_to_restart=${1:-$bin_name}
  if [ -z "$core_to_restart" ]; then
    log Error "未指定需要重启的内核"
    return 1
  fi

  "${scripts_dir}/service.sh" restart "$core_to_restart"

  local pid
  pid=$(busybox pidof "$core_to_restart")

  if [ -n "$pid" ]; then
    log Info "$core_to_restart 重启完成 [$(date +"%F %R")]"
  else
    log Error "重启 ${core_to_restart} 失败"
    "${scripts_dir}/iptables.sh" disable >/dev/null 2>&1
  fi
}

reload() {
  local ip_port secret endpoint curl_command
  # 0.0.0.0 是监听地址，请求本地 API 需用 127.0.0.1
  ip_port=$(busybox awk '!/^ *#/ && /^external-controller:/ {print $2; exit}' "${mihomo_config}" | sed "s/[\"']//g; s/0\.0\.0\.0/127.0.0.1/")
  secret=$(busybox awk '!/^ *#/ && /^secret:/ {print $2; exit}' "${mihomo_config}" | sed "s/[\"']//g")

  curl_command="curl"
  if ! command -v curl >/dev/null; then
    if [ ! -e "${bin_dir}/curl" ]; then
      upcurl || return 1
    fi
    curl_command="${bin_dir}/curl"
  fi


  endpoint="http://${ip_port}/configs?force=true"

  local resp
  if resp=$(${curl_command} --connect-timeout ${RELOAD_CONN_TIMEOUT} --max-time ${RELOAD_MAX_TIME} -sS -X PUT \
      -H "Authorization: Bearer ${secret}" "${endpoint}" \
      -d '{"path": "", "payload": ""}' 2>&1); then
    log Info "${bin_name} 配置重载成功"
    return 0
  else
    log Error "${bin_name} 配置重载失败 ! ${resp}"
    return 1
  fi
}

upcurl() {
  setup_github_api

  local arch
  case $(uname -m) in
    "aarch64") arch="aarch64" ;;
    "armv7l"|"armv8l") arch="armv7" ;;
    "i686") arch="i686" ;;
    "x86_64") arch="amd64" ;;
    *) log Warning "不支持的架构: $(uname -m)" >&2; return 1 ;;
  esac

  mkdir -p "${bin_dir}/backup"
  [ -f "${bin_dir}/curl" ] && cp "${bin_dir}/curl" "${bin_dir}/backup/curl.bak" >/dev/null 2>&1

  local latest_version
  latest_version="$(resolve_github_latest_tag "stunnel/static-curl")"
  if [ -z "${latest_version}" ]; then
    log Error "获取 static-curl 最新版本失败"
    return 1
  fi

  local curl_tag_file="${cfr_run_state}/curl.tag"
  local cur_curl_tag="" cur_curl_ver=""
  if [ -x "${bin_dir}/curl" ] && [ "${FORCE_UPDATE:-false}" != "true" ]; then
    [ -s "${curl_tag_file}" ] && cur_curl_tag="$(busybox tr -d '[:space:]' < "${curl_tag_file}" 2>/dev/null)"
    cur_curl_ver="$("${bin_dir}/curl" -V 2>/dev/null | busybox awk 'NR==1{print $2}')"
    if [ "${cur_curl_tag}" = "${latest_version}" ] || { [ -z "${cur_curl_tag}" ] && [ "${cur_curl_ver}" = "${latest_version%%-*}" ]; }; then
      log Info "curl 已是最新版本 (${latest_version})，跳过更新"
      return 0
    fi
  fi

  local download_link="https://github.com/stunnel/static-curl/releases/download/${latest_version}/curl-linux-${arch}-glibc-${latest_version}.tar.xz"
  local temp_archive="${cfr_dir}/curl.tar.xz"
  local temp_extract_dir="${cfr_dir}/curl_temp"

  if ! upfile "${temp_archive}" "${download_link}"; then
    log Error "下载 curl 失败"
    return 1
  fi

  rm -rf "${temp_extract_dir}"
  mkdir -p "${temp_extract_dir}"

  if ! busybox tar -xJf "${temp_archive}" -C "${temp_extract_dir}" >&2; then
    log Error "解压 ${temp_archive} 失败" >&2
    cp "${bin_dir}/backup/curl.bak" "${bin_dir}/curl" >/dev/null 2>&1 && log Info "已恢复 curl"
    rm -f "${temp_archive}"
    rm -rf "${temp_extract_dir}"
    return 1
  fi

  local curl_binary
  curl_binary=$(find "${temp_extract_dir}" -type f -name "curl")
  if [ -n "${curl_binary}" ]; then
    mv "${curl_binary}" "${bin_dir}/curl"
    log Info "curl 更新完成"
  else
    log Error "在解压的存档中未找到 curl 二进制文件"
    rm -f "${temp_archive}"
    rm -rf "${temp_extract_dir}"
    return 1
  fi

  chown "${cfr_user_group}" "${cfr_dir}/bin/curl"
  chmod 0700 "${bin_dir}/curl"
  mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true
  printf '%s\n' "${latest_version}" > "${cfr_run_state}/curl.tag" 2>/dev/null || true

  rm -f "${temp_archive}"
  rm -rf "${temp_extract_dir}"
  rm -f "${bin_dir}/backup/curl.bak" 2>/dev/null
}

calc_sha256() {
  local f="$1"
  local sum=""
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum "${f}" 2>/dev/null | busybox awk '{print $1}')
  elif busybox sha256sum --help >/dev/null 2>&1; then
    sum=$(busybox sha256sum "${f}" 2>/dev/null | busybox awk '{print $1}')
  fi
  printf '%s\n' "${sum}" | busybox tr '[:upper:]' '[:lower:]'
}

has_sha256_tool() {
  command -v sha256sum >/dev/null 2>&1 || busybox sha256sum --help >/dev/null 2>&1
}

update_geox_file() {
  local target_file="$1"
  local url="$2"
  local skip_existing="${3:-false}"
  local name="${target_file##*/}"
  local sha_tmp="${target_file}.sha256sum.tmp"
  local data_tmp="${target_file}.tmp"

  if [ "${skip_existing}" = "true" ] && [ -s "${target_file}" ]; then
    log Info "${name} 已存在，跳过"
    return 0
  fi

  if ! has_sha256_tool; then
    log Warning "系统缺少 sha256sum，跳过 ${name} 完整性校验"
    if upfile "${target_file}" "${url}"; then
      chown "${cfr_user_group}" "${target_file}" 2>/dev/null || true
      chmod 0600 "${target_file}" 2>/dev/null || true
      return 0
    fi
    return 1
  fi

  rm -f "${sha_tmp}" "${data_tmp}" 2>/dev/null
  if ! upfile "${sha_tmp}" "${url}.sha256sum" "" 15; then
    rm -f "${sha_tmp}" 2>/dev/null
    log Error "${name}.sha256sum 下载失败，放弃更新以保护现有文件"
    return 1
  fi

  local expected actual
  expected=$(busybox awk '{print $1; exit}' "${sha_tmp}" 2>/dev/null | busybox tr '[:upper:]' '[:lower:]')
  rm -f "${sha_tmp}" 2>/dev/null
  if ! printf '%s' "${expected}" | busybox grep -Eq '^[0-9a-f]{64}$'; then
    log Error "${name}.sha256sum 格式无效，放弃更新"
    return 1
  fi

  if [ -s "${target_file}" ]; then
    actual="$(calc_sha256 "${target_file}")"
    if [ "${actual}" = "${expected}" ]; then
      log Info "${name} 已是最新 (SHA256 一致)，跳过下载"
      return 0
    fi
  fi

  if ! upfile "${data_tmp}" "${url}"; then
    rm -f "${data_tmp}" 2>/dev/null
    log Error "${name} 下载失败"
    return 1
  fi

  actual="$(calc_sha256 "${data_tmp}")"
  if [ "${actual}" != "${expected}" ]; then
    rm -f "${data_tmp}" 2>/dev/null
    log Error "${name} SHA256 校验失败 (预期 ${expected}，实际 ${actual})，已丢弃"
    return 1
  fi

  mv -f "${data_tmp}" "${target_file}"
  chown "${cfr_user_group}" "${target_file}" 2>/dev/null || true
  chmod 0600 "${target_file}" 2>/dev/null || true
  GEOX_UPDATED="true"
  log Info "${name} 更新并校验成功 (SHA256: ${actual})"
  return 0
}

# $1=true 时忽略 update_geo 开关；$2=true 时只补缺失文件，已存在的跳过
upgeox() {
  local fill_missing="${1:-false}"
  local skip_existing="${2:-false}"
  local ok="true"
  geoip_file="${cfr_dir}/mihomo/geoip.dat"
  geoip_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
  geosite_file="${cfr_dir}/mihomo/geosite.dat"
  geosite_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"

  if [ "${update_geo}" = "true" ] || [ "${fill_missing}" = "true" ]; then
    log Info "更新 GeoX"

    if ! update_geox_file "${geoip_file}" "${geoip_url}" "${skip_existing}"; then
      log Error "geoip.dat 更新失败"
      ok="false"
    fi

    if ! update_geox_file "${geosite_file}" "${geosite_url}" "${skip_existing}"; then
      log Error "geosite.dat 更新失败"
      ok="false"
    fi

    find "${cfr_dir}/${bin_name}" -maxdepth 1 -type f \( -name "*.dat.bak" -o -name "*.dat.tmp" -o -name "*.sha256sum.tmp" \) -delete 2>/dev/null

    [ "${ok}" = "true" ] && return 0
    return 1
  else
    return 1
  fi
}

upgeox_all() {
  local original_bin_name=$bin_name
  local rc
  bin_name="mihomo"
  upgeox true
  rc=$?
  bin_name=$original_bin_name
  return ${rc}
}

# 只补齐缺失的 GeoX 文件（安装脚本用）
upgeox_fill() {
  local original_bin_name=$bin_name
  local rc
  bin_name="mihomo"
  upgeox true true
  rc=$?
  bin_name=$original_bin_name
  return ${rc}
}

upsubs() {
  if [ "${update_subscription}" != "true" ]; then
    log Info "订阅自动更新已禁用: update_subscription=\"${update_subscription}\""
    return 0
  fi

  local url="${subscription_url_mihomo[0]}"
  if [ -z "${url}" ] || [ "${url}" = "https://你的订阅链接" ]; then
    log Info "${bin_name} 订阅链接未配置，跳过更新"
    return 0
  fi

  log Info "${bin_name} 开始更新订阅 → $(date)"

  local prev_bak="${mihomo_config}.prev"
  rm -f "${prev_bak}" 2>/dev/null
  [ -s "${mihomo_config}" ] && cp -f "${mihomo_config}" "${prev_bak}" 2>/dev/null

  # 订阅总超时：启动流程会传 SUBS_TIMEOUT=10/5/30 覆盖（见 service.sh），手动执行为 SUBS_MAX_TIME
  local subs_timeout="${SUBS_TIMEOUT:-${SUBS_MAX_TIME}}"
  if LOG_MASK_URL=mask upfile "${mihomo_config}" "${url}" "ClashMeta" "${subs_timeout}"; then
    # 校验 1: 必须含 Clash 关键字段, 且不能是 HTML 错误页
    if ! grep -qE '^[[:space:]]*(proxies|proxy-providers|proxy-groups|rules|mixed-port|port):' "${mihomo_config}" 2>/dev/null \
       || grep -qiE '<html|<!doctype' "${mihomo_config}" 2>/dev/null; then
      log Error "订阅内容无效，已回滚"
      if [ -s "${prev_bak}" ]; then
        mv -f "${prev_bak}" "${mihomo_config}"
        log Info "已恢复上一份可用配置"
      else
        log Error "无可用备份，请手动检查 config.yaml"
      fi
      return 1
    fi

    rm -f "${prev_bak}" 2>/dev/null
    log Info "订阅更新成功"

    # 订阅常缺模块必需字段，覆盖后会导致 API 与面板失效，先补全
    "${scripts_dir}/service.sh" prepare >/dev/null 2>&1
    webroot >/dev/null 2>&1

    if [ -s "${cfr_pid}" ] && kill -0 "$(<"${cfr_pid}" 2>/dev/null)" 2>/dev/null; then
      # 优先通过 API 平滑重载，避免重启内核造成的短暂断流
      if ! reload >/dev/null 2>&1; then
        log Warning "API 重载失败，改用重启服务"
        "${scripts_dir}/service.sh" restart 2>/dev/null
      fi
    fi
    log Info "${bin_name} 订阅更新完成 → $(date)"
    return 0
  else
    log Error "订阅更新失败"
    if [ -s "${prev_bak}" ] && [ ! -s "${mihomo_config}" ]; then
      mv -f "${prev_bak}" "${mihomo_config}"
      log Info "已恢复上一份可用配置"
    else
      rm -f "${prev_bak}" 2>/dev/null
    fi
    return 1
  fi
}

upkernel() {
  setup_github_api

  local core_to_update="$1"
  if [ -z "$core_to_update" ]; then
    log Error "未指定要更新的内核名称"
    return 1
  fi

  [ "${core_to_update}" = "mihomo" ] || {
    log Error "未知的内核: ${core_to_update}"
    return 1
  }

  mkdir -p "${bin_dir}/backup"
  if [ -f "${bin_dir}/mihomo" ]; then
    cp "${bin_dir}/mihomo" "${bin_dir}/backup/mihomo.bak" >/dev/null 2>&1
  fi
  case $(uname -m) in
    "aarch64") arch="arm64-v8"; platform="android" ;;
    "armv7l"|"armv8l") arch="armv7"; platform="linux" ;;
    "i686") arch="386"; platform="linux" ;;
    "x86_64") arch="amd64"; platform="linux" ;;
    *) log Warning "不支持的架构: $(uname -m)" >&2; return 1 ;;
  esac

  local file_kernel="${core_to_update}-${arch}"

  local download_link="https://github.com/MetaCubeX/mihomo/releases"

  if [ "${mihomo_stable}" = "enable" ]; then
    latest_version="$(resolve_github_latest_tag "MetaCubeX/mihomo")"
    tag="$latest_version"
  else
    tag="Prerelease-Alpha"
    latest_version=$($rev1 "${download_link}/expanded_assets/${tag}" | busybox grep -oE "alpha-[0-9a-z]+" | head -1)
  fi

  if [ -z "$latest_version" ]; then
    log Error "获取 mihomo 最新稳定版/预发行版失败"
    return 1
  fi

  if [ -x "${bin_dir}/${core_to_update}" ] && [ "${FORCE_UPDATE:-false}" != "true" ]; then
    local cur_kernel_ver=""
    if [ "${mihomo_stable}" = "enable" ]; then
      cur_kernel_ver="$("${bin_dir}/${core_to_update}" -v 2>/dev/null | busybox grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
    else
      cur_kernel_ver="$("${bin_dir}/${core_to_update}" -v 2>/dev/null | busybox grep -oE 'alpha-[0-9a-z]+' | head -n 1)"
    fi
    if [ -n "${cur_kernel_ver}" ] && [ "${cur_kernel_ver}" = "${latest_version}" ]; then
      log Info "${core_to_update} 已是最新版本 (${latest_version})，跳过更新"
      return 0
    fi
  fi

  filename="mihomo-${platform}-${arch}-${latest_version}"
  if upfile "${cfr_dir}/${file_kernel}.gz" "${download_link}/download/${tag}/${filename}.gz" && xkernel "$core_to_update" "" "" "" "$file_kernel"; then
    KERNEL_RESTARTED="true"
  fi
}

upkernels() {
  for core in "$@"; do
    upkernel "$core"
  done
}

xkernel() {
  local core_to_process="$1"
  local platform="$2"
  local arch="$3"
  local latest_version="$4"
  local file_kernel="$5"

  local original_bin_name=$bin_name
  local target_bin_name="$core_to_process"

  bin_name=$core_to_process

  gunzip_command="gunzip"
  if ! command -v gunzip >/dev/null; then
    gunzip_command="busybox gunzip"
  fi

  if ${gunzip_command} -f "${cfr_dir}/${file_kernel}.gz" >&2 && mv "${cfr_dir}/${file_kernel}" "${bin_dir}/${target_bin_name}"; then
    log Info "${target_bin_name} 已成功更新 (来自: ${core_to_process})"
  else
    log Error "解压或移动 ${target_bin_name} 内核失败"
    bin_name=$original_bin_name
    return 1
  fi

  find "${cfr_dir}" -maxdepth 1 -type f -name "${file_kernel}.*" -delete

  chown ${cfr_user_group} "${bin_dir}/${target_bin_name}"
  chmod 0700 "${bin_dir}/${target_bin_name}"
  rm -f "${bin_dir}/backup/${target_bin_name}.bak" 2>/dev/null

  if [ -f "${cfr_pid}" ]; then
    if [ "$original_bin_name" = "$target_bin_name" ]; then
      log Info "检测到正在运行的内核已被更新，将自动重启服务..."
      restart_cfr "$target_bin_name"
    else
      log Info "${target_bin_name} 已更新，但当前运行的是 ${original_bin_name}，无需重启。"
    fi
  else
    log Info "服务未在运行，无需重启。"
  fi

  bin_name=$original_bin_name
}
upxui() {
  local ui_path
  local ui_url
  ui_path=$(busybox awk '!/^ *#/ && /^external-ui:/ {print $2; exit}' "${mihomo_config}" | sed "s/[\"']//g")
  ui_url=$(busybox awk '!/^ *#/ && /^external-ui-url:/ {print $2; exit}' "${mihomo_config}" 2>/dev/null | sed "s/[\"']//g")

  if [ -z "${ui_path}" ]; then
    ui_path="./dashboard"
    log Warning "配置文件中未找到 external-ui 字段，使用默认路径: ${ui_path}"
  fi

    local dashboard_dir
    if [[ "${ui_path}" == ./* ]]; then
      dashboard_dir="${cfr_dir}/${bin_name}/${ui_path#./}"
    elif [[ "${ui_path}" == /* ]]; then
      dashboard_dir="${ui_path}"
    else
      dashboard_dir="${cfr_dir}/${bin_name}/${ui_path}"
    fi
    log Info "面板目录: ${dashboard_dir}"

    if [ -n "${ui_url}" ]; then
      url="${ui_url}"
    else
      url="https://github.com/Zephyruso/zashboard/releases/latest/download/dist-firasans-only.zip"
    fi

    local ui_repo="" ui_tag="" ui_tag_file="${cfr_run_state}/ui.tag"
    case "${url}" in
      https://github.com/*/releases/latest/download/*)
        ui_repo="${url#https://github.com/}"
        ui_repo="${ui_repo%%/releases/latest/download/*}"
        ui_tag="$(resolve_github_latest_tag "${ui_repo}")"
        if [ -n "${ui_tag}" ] && [ -f "${dashboard_dir}/index.html" ] && [ -s "${ui_tag_file}" ] && [ "${FORCE_UPDATE:-false}" != "true" ]; then
          if [ "$(busybox tr -d '[:space:]' < "${ui_tag_file}" 2>/dev/null)" = "${ui_tag}" ]; then
            log Info "面板已是最新版本 (${ui_tag})，跳过更新"
            return 0
          fi
        fi
        ;;
    esac

    local is_zip="false"
    case "${url}" in
      *.zip|*.zip\?*) is_zip="true" ;;
    esac
    if [ "${is_zip}" = "true" ]; then
      file_dashboard="${cfr_dir}/${bin_name}_ui.zip"
    else
      file_dashboard="${cfr_dir}/${bin_name}_ui.tgz"
    fi

    if upfile "${file_dashboard}" "${url}"; then
      if [ ! -d "${dashboard_dir}" ]; then
        log Info "面板目录不存在，正在创建: ${dashboard_dir}"
        mkdir -p "${dashboard_dir}"
      else
        rm -rf "${dashboard_dir}/"*
      fi

      log Info "正在解压面板..."
      local temp_extract_dir="${cfr_dir}/${bin_name}_ui_temp"
      rm -rf "${temp_extract_dir}"
      mkdir -p "${temp_extract_dir}"

      local extract_ok="false"
      if [ "${is_zip}" = "true" ]; then
        if command -v unzip >/dev/null 2>&1 && unzip -oq "${file_dashboard}" -d "${temp_extract_dir}" 2>/dev/null; then
          extract_ok="true"
        elif busybox unzip -oq "${file_dashboard}" -d "${temp_extract_dir}" 2>/dev/null; then
          extract_ok="true"
        fi
      else
        if command -v tar >/dev/null; then
          tar_command="tar"
        else
          tar_command="busybox tar"
        fi
        if "${tar_command}" -xzf "${file_dashboard}" -C "${temp_extract_dir}" 2>/dev/null; then
          extract_ok="true"
        elif gunzip -c "${file_dashboard}" 2>/dev/null | "${tar_command}" -xf - -C "${temp_extract_dir}" 2>/dev/null; then
          extract_ok="true"
        fi
      fi

      if [ "${extract_ok}" != "true" ]; then
        log Error "解压面板失败"
        rm -f "${file_dashboard}"
        rm -rf "${temp_extract_dir}"
        return 1
      fi

      local html_path
      html_path=$(busybox find "${temp_extract_dir}" -maxdepth 3 -type f -name index.html | head -n 1)
      if [ -n "${html_path}" ]; then
        local html_dir
        html_dir="${html_path%/*}"
        mv -f "${html_dir}"/* "${dashboard_dir}/"
      else
        local top_dir
        top_dir=$(find "${temp_extract_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)
        if [ -n "${top_dir}" ] && [ -z "$(find "${temp_extract_dir}" -mindepth 1 -maxdepth 1 -type d | sed -n '2p')" ]; then
          mv -f "${top_dir}"/* "${dashboard_dir}/"
        else
          mv -f "${temp_extract_dir}"/* "${dashboard_dir}/"
        fi
      fi

      if [ -z "$(find "${dashboard_dir}" -mindepth 1 -maxdepth 1 | head -n 1)" ]; then
        log Error "面板目录为空，更新失败"
        rm -f "${file_dashboard}"
        rm -rf "${temp_extract_dir}"
        return 1
      fi
      rm -f "${file_dashboard}"
      rm -rf "${temp_extract_dir}"
      chown -R "${cfr_user_group}" "${dashboard_dir}" 2>/dev/null || true
      find "${dashboard_dir}" -type d -exec chmod 0700 {} + 2>/dev/null || true
      find "${dashboard_dir}" -type f -exec chmod 0600 {} + 2>/dev/null || true
      if [ -n "${ui_tag}" ]; then
        mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true
        printf '%s\n' "${ui_tag}" > "${ui_tag_file}" 2>/dev/null || true
      fi
      log Info "面板更新成功 → ${dashboard_dir}"
    else
      log Error "下载面板失败"
      return 1
    fi
    return 0
}

cgroup_blkio() {
  local pid_file="$1"
  local fallback_weight="${2:-900}"

  if [ -z "$pid_file" ] || [ ! -f "$pid_file" ]; then
    log Warning "PID 文件丢失或无效: $pid_file"
    return 1
  fi

  local PID
  PID=$(<"$pid_file" 2>/dev/null)
  if [ -z "$PID" ] || ! kill -0 "$PID" >/dev/null 2>&1; then
    log Warning "来自 ${pid_file} 的 PID $PID 无效或未运行"
    return 1
  fi

  if [ -z "$blkio_path" ]; then
    blkio_path=$(mount | grep cgroup | busybox awk '/blkio/{print $3}' | head -1)
    if [ -z "$blkio_path" ] || [ ! -d "$blkio_path" ]; then
      log Warning "blkio cgroup 路径未找到"
      return 1
    fi
  fi

  local target="${blkio_path}/cfr"

  if [ ! -d "$target" ]; then
    mkdir -p "$target" 2>/dev/null
    if [ ! -d "$target" ]; then
      log Warning "无法创建 cfr blkio 目录: $target"
      if [ -d "${blkio_path}/foreground" ]; then
        target="${blkio_path}/foreground"
        log Info "回退使用现有 blkio 目录: foreground"
      elif [ -d "${blkio_path}/top-app" ]; then
        target="${blkio_path}/top-app"
        log Info "回退使用现有 blkio 目录: top-app"
      else
        log Warning "blkio 目标未找到，无法设置 IO 权重"
        return 1
      fi
    else
      log Info "成功创建专用 cfr blkio 目录: $target"
      echo "$fallback_weight" > "${target}/blkio.weight" 2>/dev/null
      if [ $? -ne 0 ]; then
        log Warning "无法设置 blkio 权重到 ${target}/blkio.weight"
      else
        log Info "已设置 blkio 权重: $fallback_weight"
      fi
    fi
  fi

  echo "$PID" > "${target}/cgroup.procs" 2>/dev/null
  if [ $? -eq 0 ]; then
    log Info "已分配 PID $PID 到 ${target}，IO 权重 [$fallback_weight]"
    return 0
  else
    log Warning "无法将 PID $PID 分配到 ${target}"
    return 1
  fi
}

cgroup_memcg() {
  local pid_file="$1"
  local raw_limit="$2"

  if [ -z "$pid_file" ] || [ ! -f "$pid_file" ]; then
    log Warning "PID 文件丢失或无效: $pid_file"
    return 1
  fi

  if [ -z "$raw_limit" ]; then
    log Warning "未指定 memcg 限制"
    return 1
  fi

  local limit
  case "$raw_limit" in
    *[Mm])
      limit=$(( ${raw_limit%[Mm]} * 1024 * 1024 ))
      ;;
    *[Gg])
      limit=$(( ${raw_limit%[Gg]} * 1024 * 1024 * 1024 ))
      ;;
    *[Kk])
      limit=$(( ${raw_limit%[Kk]} * 1024 ))
      ;;
    *[0-9])
      limit=$raw_limit
      ;;
    *)
      log Warning "无效的 memcg 限制格式: $raw_limit"
      return 1
      ;;
  esac

  local PID
  PID=$(<"$pid_file" 2>/dev/null)
  if [ -z "$PID" ] || ! kill -0 "$PID" >/dev/null 2>&1; then
    log Warning "来自 ${pid_file} 的 PID $PID 无效或未运行"
    return 1
  fi

  if [ -z "$memcg_path" ]; then
    memcg_path=$(mount | grep cgroup | busybox awk '/memory/{print $3}' | head -1)
    if [ -z "$memcg_path" ] || [ ! -d "$memcg_path" ]; then
      log Warning "memory cgroup 路径未找到"
      return 1
    fi
  fi

  local target="${memcg_path}/cfr"

  if [ ! -d "$target" ]; then
    mkdir -p "$target" 2>/dev/null
    if [ ! -d "$target" ]; then
      log Warning "无法创建 cfr memory 目录: $target"
      local name="${bin_name:-app}"
      target="${memcg_path}/${name}"
      mkdir -p "$target" 2>/dev/null
      if [ ! -d "$target" ]; then
        log Warning "无法创建 memory 目录: $target"
        return 1
      fi
      log Info "回退使用 memory 目录: $target"
    else
      log Info "成功创建专用 cfr memory 目录: $target"
    fi
  fi

  local hr_limit="$limit B"
  if [ "$limit" -ge 1073741824 ]; then
    hr_limit="$(busybox awk -v b=$limit 'BEGIN{printf "%.2f GiB", b/1073741824}')"
  elif [ "$limit" -ge 1048576 ]; then
    hr_limit="$(busybox awk -v b=$limit 'BEGIN{printf "%.2f MiB", b/1048576}')"
  elif [ "$limit" -ge 1024 ]; then
    hr_limit="$(busybox awk -v b=$limit 'BEGIN{printf "%.2f KiB", b/1024}')"
  fi

  echo "$limit" > "${target}/memory.limit_in_bytes" 2>/dev/null
  if [ $? -ne 0 ]; then
    log Warning "无法设置内存限制到 ${target}/memory.limit_in_bytes"
    return 1
  fi
  log Info "已设置内存限制: ${hr_limit} (${limit} 字节)"

  echo "$PID" > "${target}/cgroup.procs" 2>/dev/null
  if [ $? -eq 0 ]; then
    log Info "已分配 PID $PID 到 ${target}，内存限制 [$hr_limit]"
    return 0
  else
    log Warning "无法将 PID $PID 分配到 ${target}"
    return 1
  fi
}

cgroup_cpuset() {
  local pid_file="${1}"
  local cores="${2}"

  if [ -z "${pid_file}" ] || [ ! -f "${pid_file}" ]; then
    log Warning "PID 文件丢失或无效: ${pid_file}"
    return 1
  fi

  local PID
  PID=$(<"${pid_file}" 2>/dev/null)
  if [ -z "$PID" ] || ! kill -0 "$PID" >/dev/null; then
    log Warning "来自 ${pid_file} 的 PID $PID 无效或未运行"
    return 1
  fi

  if [ -z "${cores}" ]; then
    local total_core
    total_core=$(nproc --all 2>/dev/null)
    if [ -z "$total_core" ] || [ "$total_core" -le 0 ]; then
      log Warning "检测 CPU 核心失败"
      return 1
    fi
    cores="0-$((total_core - 1))"
  fi

  if [ -z "${cpuset_path}" ]; then
    cpuset_path=$(mount | grep cgroup | busybox awk '/cpuset/{print $3}' | head -1)
    if [ -z "${cpuset_path}" ] || [ ! -d "${cpuset_path}" ]; then
      log Warning "cpuset_path 未找到"
      return 1
    fi
  fi

  local cpuset_target="${cpuset_path}/cfr"

  if [ ! -d "${cpuset_target}" ]; then
    mkdir -p "${cpuset_target}" 2>/dev/null
    if [ ! -d "${cpuset_target}" ]; then
      log Warning "无法创建 cfr cpuset 目录: ${cpuset_target}"
      cpuset_target="${cpuset_path}/foreground"
      if [ ! -d "${cpuset_target}" ]; then
        cpuset_target="${cpuset_path}/top-app"
      fi
      if [ ! -d "${cpuset_target}" ]; then
        cpuset_target="${cpuset_path}/apps"
        if [ ! -d "${cpuset_target}" ]; then
          log Warning "cpuset 目标未找到，无法设置 CPU 核心"
          return 1
        fi
      fi
      log Info "回退使用现有 cpuset 目录: ${cpuset_target}"
    else
      log Info "成功创建专用 cfr cpuset 目录: ${cpuset_target}"
      if [ -f "${cpuset_path}/cpus" ]; then
        cat "${cpuset_path}/cpus" > "${cpuset_target}/cpus" 2>/dev/null
      fi
      if [ -f "${cpuset_path}/mems" ]; then
        cat "${cpuset_path}/mems" > "${cpuset_target}/mems" 2>/dev/null
      fi
    fi
  fi

  echo "${cores}" > "${cpuset_target}/cpus" 2>/dev/null
  if [ $? -ne 0 ]; then
    log Warning "无法设置 CPU 核心到 ${cpuset_target}/cpus"
    return 1
  fi

  echo "0" > "${cpuset_target}/mems" 2>/dev/null
  if [ $? -ne 0 ]; then
    log Warning "无法设置内存节点到 ${cpuset_target}/mems"
    return 1
  fi

  echo "${PID}" > "${cpuset_target}/cgroup.procs" 2>/dev/null
  if [ $? -eq 0 ]; then
    log Info "已分配 PID $PID 到 ${cpuset_target}，CPU 核心 [$cores]"
    return 0
  else
    log Warning "无法将 PID $PID 分配到 ${cpuset_target}"
    return 1
  fi
}

webroot() {
  local ip_port path_webroot secret_val
  # 0.0.0.0 是监听地址，浏览器无法访问，统一换成 127.0.0.1
  ip_port=$(busybox awk '!/^ *#/ && /^external-controller:/ {print $2; exit}' "${mihomo_config}" 2>/dev/null | sed "s/[\"']//g; s/0\.0\.0\.0/127.0.0.1/")
  secret_val=$(busybox awk '!/^ *#/ && /^secret:/ {print $2; exit}' "${mihomo_config}" 2>/dev/null | sed "s/[\"']//g")
  # 订阅覆盖后可能丢失 external-controller，用默认值兜底，避免生成 http:///ui/
  if [ -z "${ip_port}" ]; then
    log Warning "配置中未找到 external-controller，WebUI 使用默认地址 127.0.0.1:23450"
    ip_port="127.0.0.1:23450"
  fi
  path_webroot="/data/adb/modules/cfr/webroot/index.html"
  mkdir -p "${path_webroot%/*}" >/dev/null 2>&1 || true
  local target_url="http://${ip_port}/ui/"
  if [ -n "${secret_val}" ]; then
    target_url="http://${ip_port}/ui/?hostname=${ip_port%%:*}&port=${ip_port##*:}&secret=${secret_val}"
  fi
  cat > "${path_webroot}" <<EOF
<!DOCTYPE html>
<script>
    document.location = '${target_url}'
</script>
</html>
EOF
  log Info "已生成/更新 WebUI 页面: ${path_webroot} → http://${ip_port}/ui/ (内核: ${bin_name})"
}

bond0() {
  sysctl -w net.ipv4.tcp_low_latency=0 >/dev/null 2>&1

  for dev in /sys/class/net/wlan*; do ip link set dev $(basename $dev) txqueuelen 3000; done

  for txqueuelen in /sys/class/net/rmnet_data*; do txqueuelen_name=$(basename $txqueuelen); ip link set dev $txqueuelen_name txqueuelen 1000; done

  for mtu in /sys/class/net/rmnet_data*; do mtu_name=$(basename $mtu); ip link set dev $mtu_name mtu 1500; done
}

bond1() {
  sysctl -w net.ipv4.tcp_low_latency=1 >/dev/null 2>&1

  for dev in /sys/class/net/wlan*; do ip link set dev $(basename $dev) txqueuelen 4000; done

  for txqueuelen in /sys/class/net/rmnet_data*; do txqueuelen_name=$(basename $txqueuelen); ip link set dev $txqueuelen_name txqueuelen 2000; done

  for mtu in /sys/class/net/rmnet_data*; do mtu_name=$(basename $mtu); ip link set dev $mtu_name mtu 9000; done
}

case "$1" in
  memcg|cpuset|blkio)
    case "$1" in
      memcg)
        memcg_path=""
        cgroup_memcg "${cfr_pid}" ${memcg_limit}
        ;;
      cpuset)
        cpuset_path=""
        cgroup_cpuset "${cfr_pid}" ${allow_cpu}
        ;;
      blkio)
        blkio_path=""
        cgroup_blkio "${cfr_pid}" "${weight}"
        ;;
    esac
    ;;
  bond0|bond1)
    $1
    ;;
  geosub)
    # 各项开关互相独立：任一关闭只跳过对应部分
    KERNEL_RESTARTED="false"
    GEOX_UPDATED="false"
    upsubs
    upgeox
    [ "${bypass_cn_ip}" = "true" ] && upcnip
    if [ "${update_components:-false}" = "true" ]; then
      upcurl
      upxui
      upkernel mihomo
    fi
    if [ "${KERNEL_RESTARTED}" != "true" ] && [ "${GEOX_UPDATED}" = "true" ] && [ -f "${cfr_pid}" ]; then
      kill -0 "$(<"${cfr_pid}" 2>/dev/null)" && reload
    fi
    ;;
  geox|subs)
    GEOX_UPDATED="false"
    if [ "$1" = "geox" ]; then
      upgeox
      if [ "${GEOX_UPDATED}" = "true" ] && [ -f "${cfr_pid}" ]; then
        kill -0 "$(<"${cfr_pid}" 2>/dev/null)" && reload
      fi
    else
      upsubs || exit 1
    fi
    ;;
  upkernel)
    upkernel "$2"
    ;;
  upkernels)
    shift
    upkernels "$@"
    ;;
  upgeox_all)
    upgeox_all
    ;;
  upgeox_fill)
    upgeox_fill
    ;;
  upxui)
    upxui
    ;;
  upcnip)
    upcnip
    ;;
  upcurl)
    $1
    ;;
  reload)
    reload
    ;;
  webroot)
    webroot
    ;;
  all)
    upcurl
    upgeox_all
    upkernels mihomo
    for bin_name in "${bin_list[@]}"; do
      upsubs
      upxui
    done
    ;;
  *)
    log Error "$0 $1 未找到"
    log Info "用法: $0 {memcg|cpuset|blkio|geosub|geox|subs|upkernel [name]|upkernels [name...]|upgeox_all|upgeox_fill|upxui|upcurl|upcnip|reload|webroot|bond0|bond1|all}"
    log Info "upkernel 支持的内核: mihomo"
    ;;
esac