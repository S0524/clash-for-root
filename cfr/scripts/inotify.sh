#!/system/bin/sh

# $0 不含 / 时（如 sh inotify.sh）${0%/*} 会原样返回，需兜底
case "$0" in
  */*) scripts_dir="${0%/*}" ;;
  *) scripts_dir="/data/adb/cfr/scripts" ;;
esac
service_path="${scripts_dir}/service.sh"
iptables_path="${scripts_dir}/iptables.sh"
log_path="/data/adb/cfr/log"
# 与 net.sh 共用同一个调试日志
debug_log_path="${log_path}/debug.log"
file_settings="/data/adb/cfr/settings.ini"
events="$1"
monitor_file="$3"

write_inotify_error() {
  mkdir -p "${log_path}" >/dev/null 2>&1 || true
  printf '%s [Error]: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${debug_log_path}" 2>/dev/null || true
}

service_control() {
  local capture="${log_path}/.inotify.$$.out"
  if [ "${monitor_file}" = "disable" ]; then
    if [ "${events}" = "d" ]; then
      # service.sh 启动时会删除 debug.log，先写临时文件再合并
      {
        printf '%s [Info]: 模块已启用，启动服务\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        "${service_path}" start
        "${iptables_path}" enable
      } > "${capture}" 2>&1
    elif [ "${events}" = "n" ]; then
      {
        printf '%s [Info]: 模块已禁用，停止服务\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        "${iptables_path}" disable
        "${service_path}" stop
      } > "${capture}" 2>&1
    fi
    if [ -s "${capture}" ]; then
      cat "${capture}" >> "${debug_log_path}" 2>/dev/null || true
    fi
    rm -f "${capture}" 2>/dev/null
  fi
}

mkdir -p "${log_path}" >/dev/null 2>&1 || true
if [ -f "${file_settings}" ] && [ -r "${file_settings}" ] && [ -s "${file_settings}" ]; then
  . "${file_settings}"
  service_control
else
  write_inotify_error "file /data/adb/cfr/settings.ini file not found"
  exit 1
fi
