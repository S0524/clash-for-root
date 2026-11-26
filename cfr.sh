#!/system/bin/sh
(
if [ ! -f /data/adb/modules/cfr/disable ] && [ ! -f /data/adb/cfr/manual ] && [ -f /data/adb/cfr/settings.ini ] && [ -f /data/adb/cfr/scripts/iptables.sh ]; then
    cfg_boot=$(grep -m1 '^boot_auto_start=' /data/adb/cfr/settings.ini 2>/dev/null | sed 's/^boot_auto_start=//; s/["'\''[:space:]]//g')
    cfg_ks=$(grep -m1 '^kill_switch=' /data/adb/cfr/settings.ini 2>/dev/null | sed 's/^kill_switch=//; s/["'\''[:space:]]//g')
    if [ "${cfg_boot:-true}" != "false" ] && [ "${cfg_ks:-true}" = "true" ]; then
        ks_waited=0
        while [ ! -x /system/bin/iptables ] && ! command -v iptables >/dev/null 2>&1 && [ ${ks_waited} -lt 30 ]; do
            sleep 1
            ks_waited=$((ks_waited + 1))
        done
        /data/adb/cfr/scripts/iptables.sh killswitch >/dev/null 2>&1 || true
    fi
fi

waited=0
while [ "$(getprop init.svc.bootanim)" != "stopped" ] && [ ${waited} -lt 300 ]; do
    sleep 5
    waited=$((waited + 5))
done

if [ -f /data/adb/cfr/scripts/start.sh ]; then
    chmod 700 /data/adb/cfr/scripts/* 2>/dev/null || true
    /data/adb/cfr/scripts/start.sh
else
    echo "未找到文件 /data/adb/cfr/scripts/start.sh"
fi
)&