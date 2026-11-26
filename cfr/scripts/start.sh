#!/system/bin/sh

# $0 不含 / 时（如 sh start.sh）${0%/*} 会原样返回，需兜底
case "$0" in
  */*) scripts_dir="${0%/*}" ;;
  *) scripts_dir="/data/adb/cfr/scripts" ;;
esac
file_settings="/data/adb/cfr/settings.ini"
moddir="/data/adb/modules/cfr"

if [ -f "$file_settings" ]; then
    . "$file_settings"
fi

busybox="/data/adb/magisk/busybox"
[ -f "/data/adb/ksu/bin/busybox" ] && busybox="/data/adb/ksu/bin/busybox"
[ -f "/data/adb/ap/bin/busybox" ] && busybox="/data/adb/ap/bin/busybox"

wait_for_data_ready() {
  local waited=0
  while [ ! -f "/data/system/packages.xml" ] && [ "${waited}" -lt 60 ]; do
    sleep 1
    waited=$((waited + 1))
  done
}

refresh_cfr() {
  if [ -f "/data/adb/cfr/run/cfr.pid" ]; then
    "${scripts_dir}/service.sh" stop > "/dev/null" 2>&1
    "${scripts_dir}/iptables.sh" disable > "/dev/null" 2>&1
  fi
}

start_service() {
  if [ "$boot_auto_start" = "false" ]; then
    log Info "开机自启已禁用，跳过启动内核服务。"
    return 0
  fi

  if [ ! -f "${moddir}/disable" ]; then
    "${scripts_dir}/service.sh" start > "/dev/null" 2>&1
  fi
}

enable_iptables() {
  PIDS=("${bin_list[@]}")
  [ "${#PIDS[@]}" -eq 0 ] && PIDS=("mihomo")
  PID=""
  i=0
  while [ -z "$PID" ] && [ "$i" -lt "${#PIDS[@]}" ]; do
    PID=$($busybox pidof "${PIDS[$i]}")
    i=$((i+1))
  done

  if [ -n "$PID" ] && [ ! -f "${cfr_run_state}/runtime.iptables.env" ]; then
    "${scripts_dir}/iptables.sh" enable > "/dev/null" 2>&1
  fi
}

net_inotifyd() {
  local waited=0
  while [ ! -f /data/misc/net/rt_tables ] && [ "${waited}" -lt 60 ]; do
    sleep 1
    waited=$((waited + 1))
  done

  net_dir="/data/misc/net"
  # 用 inotifyd 监听 /data/misc/net 的网络变化（/proc 不支持，轮询不可取）
  inotifyd "${scripts_dir}/net.sh" "${net_dir}" > "/dev/null" 2>&1 &
}

start_inotifyd() {
  PIDs=($($busybox pidof inotifyd))
  for PID in "${PIDs[@]}"; do
    if grep -q -e "inotify.sh" -e "net.sh" -e "pkg_watch.sh" "/proc/$PID/cmdline"; then
      kill -9 "$PID"
    fi
  done
  inotifyd "${scripts_dir}/inotify.sh" "${moddir}" > "/dev/null" 2>&1 &
  [ -d "/data/system" ] && inotifyd "${scripts_dir}/pkg_watch.sh" "/data/system" > "/dev/null" 2>&1 &
  net_inotifyd
}

mkdir -p /data/adb/cfr/run/ /data/adb/cfr/run/state/ /data/adb/cfr/log/ >/dev/null 2>&1 || true
if [ -f "/data/adb/cfr/manual" ]; then
  if [ -f "/data/adb/cfr/run/cfr.pid" ]; then
      rm -f /data/adb/cfr/run/cfr.pid
  fi
  net_inotifyd
  exit 1
fi

if [ -f "$file_settings" ] && [ -r "$file_settings" ] && [ -s "$file_settings" ]; then
  wait_for_data_ready
  refresh_cfr
  start_service
  enable_iptables
fi

start_inotifyd
