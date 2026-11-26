#!/system/bin/sh

cfr_dir="/data/adb/cfr"
cfr_run="${cfr_dir}/run"
cfr_pid="${cfr_run}/cfr.pid"

run_as_su() {
    su -c "$1"
}

is_running() {
    [ -f "${cfr_pid}" ] || return 1
    local PID
    PID=$(cat "${cfr_pid}" 2>/dev/null)
    [ -n "${PID}" ] || return 1
    kill -0 "${PID}" 2>/dev/null || return 1
    grep -qa mihomo "/proc/${PID}/cmdline" 2>/dev/null
}

show_status() {
    if is_running; then
        echo "当前状态: 运行中 (PID $(cat "${cfr_pid}" 2>/dev/null))"
        return 0
    fi
    echo "当前状态: 已停止"
    return 1
}

stop_service() {
    echo "正在关闭服务..."
    run_as_su "${cfr_dir}/scripts/iptables.sh disable"
    run_as_su "${cfr_dir}/scripts/service.sh stop"
}

start_service() {
    echo "正在启动服务，请稍候..."
    run_as_su "${cfr_dir}/scripts/service.sh start"
    run_as_su "${cfr_dir}/scripts/iptables.sh enable"
}

show_status

if is_running; then
    stop_service
else
    start_service
fi

echo ""
show_status