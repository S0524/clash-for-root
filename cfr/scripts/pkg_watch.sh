#!/system/bin/sh

if [ -f "/data/adb/modules/cfr/disable" ]; then
  exit 0
fi

events="$1"
monitor_file="$3"

# 仅关注 packages.list 的写入/覆盖事件（w=close_write, y=moved_to）
[ "${monitor_file}" = "packages.list" ] || exit 0
case "${events}" in
  w|y|n) ;;
  *) exit 0 ;;
esac

case "$0" in
  */*) scripts_dir="${0%/*}" ;;
  *) scripts_dir="/data/adb/cfr/scripts" ;;
esac

settings_file="/data/adb/cfr/settings.ini"
[ -f "${settings_file}" ] || exit 0
. "${settings_file}"

[ "${proxy_mode}" = "core" ] && exit 0
[ -f "${cfr_pid}" ] && kill -0 "$(cat "${cfr_pid}" 2>/dev/null)" 2>/dev/null || exit 0

stamp_file="${cfr_run_state}/last_pkg_refresh"
now=$(date +%s)
last=0
[ -f "${stamp_file}" ] && last=$(cat "${stamp_file}" 2>/dev/null || echo 0)
if [ $((now - last)) -lt 2 ]; then
  exit 0
fi
mkdir -p "${cfr_run_state}" >/dev/null 2>&1 || true
printf '%s\n' "${now}" > "${stamp_file}" 2>/dev/null || true

"${scripts_dir}/service.sh" refresh_uids >/dev/null 2>&1 || true
