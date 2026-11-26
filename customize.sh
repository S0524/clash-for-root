#!/system/bin/sh

SKIPUNZIP=1
SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=false
LATESTARTSERVICE=true

if [ "$BOOTMODE" != true ]; then
  ui_print "! 请在 Magisk/KernelSU/APatch Manager 中安装本模块"
  ui_print "! 不支持从 Recovery 安装"
  abort "! 请在 Manager 中安装"
elif [ "$KSU" = true ] && [ "$KSU_VER_CODE" -lt 10670 ]; then
  ui_print "! 请升级您的 KernelSU 及其管理器"
  abort "! KernelSU 版本过低"
fi

service_dir="/data/adb/service.d"
if [ "$KSU" = "true" ]; then
  ui_print "- 检测到 KernelSU 版本：$KSU_VER ($KSU_VER_CODE)"
  [ "$KSU_VER_CODE" -lt 10683 ] && service_dir="/data/adb/ksu/service.d"
elif [ "$APATCH" = "true" ]; then
  APATCH_VER=$(cat "/data/adb/ap/version")
  ui_print "- 检测到 APatch 版本：$APATCH_VER"
else
  ui_print "- 检测到 Magisk 版本：$MAGISK_VER ($MAGISK_VER_CODE)"
fi

mkdir -p "${service_dir}"

ui_print "- 解压安装包"
unzip -o "$ZIPFILE" -x 'META-INF/*' -x 'webroot/*' -d "$MODPATH" >&2

# 安装/升级：新版全覆盖，仅保留组件与用户配置文件
keep_dir="${MODPATH}/.keep"
is_upgrade="false"
old_subscription=""
keep_cfgs="package.list.cfg gid.list.cfg ap.list.cfg crontab.cfg"
rm -rf "${keep_dir}"

if [ -d "/data/adb/cfr" ]; then
  is_upgrade="true"
  ui_print "- 检测到已安装的 cfr，保留组件与用户配置"
  mkdir -p "${keep_dir}"

  if [ -f "/data/adb/cfr/settings.ini" ]; then
    old_subscription=$(busybox grep -m1 '^subscription_url_mihomo=' "/data/adb/cfr/settings.ini" 2>/dev/null | tr -d '\r')
    case "${old_subscription}" in
      *你的订阅链接*) old_subscription="" ;;
    esac
  fi

  [ -d "/data/adb/cfr/bin" ] && mv /data/adb/cfr/bin "${keep_dir}/bin" 2>/dev/null
  [ -f "/data/adb/cfr/mihomo/geoip.dat" ] && mv /data/adb/cfr/mihomo/geoip.dat "${keep_dir}/geoip.dat" 2>/dev/null
  [ -f "/data/adb/cfr/mihomo/geosite.dat" ] && mv /data/adb/cfr/mihomo/geosite.dat "${keep_dir}/geosite.dat" 2>/dev/null
  [ -d "/data/adb/cfr/mihomo/dashboard" ] && mv /data/adb/cfr/mihomo/dashboard "${keep_dir}/dashboard" 2>/dev/null
  [ -d "/data/adb/cfr/mihomo/providers" ] && mv /data/adb/cfr/mihomo/providers "${keep_dir}/providers" 2>/dev/null

  for cfg in ${keep_cfgs}; do
    [ -f "/data/adb/cfr/${cfg}" ] && mv "/data/adb/cfr/${cfg}" "${keep_dir}/${cfg}" 2>/dev/null
  done
fi

rm -rf /data/adb/cfr
mv "$MODPATH/cfr" /data/adb/cfr

if [ ! -d "/data/adb/cfr" ]; then
  abort "! 安装失败：无法写入 /data/adb/cfr"
fi

# 放回保留的组件
if [ -d "${keep_dir}/bin" ]; then
  rm -rf /data/adb/cfr/bin
  mv "${keep_dir}/bin" /data/adb/cfr/bin 2>/dev/null
fi
if [ -f "${keep_dir}/geoip.dat" ]; then
  mv "${keep_dir}/geoip.dat" "/data/adb/cfr/mihomo/geoip.dat" 2>/dev/null
fi
if [ -f "${keep_dir}/geosite.dat" ]; then
  mv "${keep_dir}/geosite.dat" "/data/adb/cfr/mihomo/geosite.dat" 2>/dev/null
fi
if [ -d "${keep_dir}/dashboard" ]; then
  rm -rf "/data/adb/cfr/mihomo/dashboard"
  mv "${keep_dir}/dashboard" "/data/adb/cfr/mihomo/dashboard" 2>/dev/null
fi
if [ -d "${keep_dir}/providers" ]; then
  rm -rf "/data/adb/cfr/mihomo/providers"
  mv "${keep_dir}/providers" "/data/adb/cfr/mihomo/providers" 2>/dev/null
fi

# 放回用户配置文件
for cfg in ${keep_cfgs}; do
  [ -f "${keep_dir}/${cfg}" ] && mv -f "${keep_dir}/${cfg}" "/data/adb/cfr/${cfg}" 2>/dev/null
done
rm -rf "${keep_dir}"

# 继承订阅链接
if [ -n "${old_subscription}" ]; then
  if OLD_SUB="${old_subscription}" busybox awk '
      /^subscription_url_mihomo=/ { print ENVIRON["OLD_SUB"]; next }
      { print }
    ' /data/adb/cfr/settings.ini > /data/adb/cfr/settings.ini.tmp 2>/dev/null \
     && [ -s /data/adb/cfr/settings.ini.tmp ]; then
    mv -f /data/adb/cfr/settings.ini.tmp /data/adb/cfr/settings.ini
    ui_print "- 已继承订阅链接"
  else
    rm -f /data/adb/cfr/settings.ini.tmp
  fi
fi

ui_print "- 创建目录"
mkdir -p /data/adb/cfr/ /data/adb/cfr/run/ /data/adb/cfr/log/ /data/adb/cfr/bin/

ui_print "- 提取 uninstall.sh 和 cfr.sh"
unzip -j -o "$ZIPFILE" 'uninstall.sh' -d "$MODPATH" >&2
unzip -j -o "$ZIPFILE" 'cfr.sh' -d "${service_dir}" >&2

ui_print "- 设置权限"
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm_recursive /data/adb/cfr/ 0 3005 0700 0600
set_perm_recursive /data/adb/cfr/scripts/ 0 3005 0700 0700
set_perm ${service_dir}/cfr.sh 0 0 0700
set_perm $MODPATH/uninstall.sh 0 0 0700
chmod 0700 ${service_dir}/cfr.sh $MODPATH/uninstall.sh /data/adb/cfr/scripts/* 2>/dev/null || true

# set_perm_recursive 会把可执行文件设为 600，这里恢复二进制执行权限
chmod 0700 /data/adb/cfr/bin/* 2>/dev/null || true

ui_print " "
ui_print "- 安装组件"

# 组件检测：优先使用 zip 内置文件（components/），缺失时才在线下载
ui_print "- 检查组件"
components_dir="${MODPATH}/components"
arch="$(uname -m)"

take_component() {
  [ -e "$1" ] || return 1
  mkdir -p "${2%/*}" 2>/dev/null
  rm -rf "$2" 2>/dev/null
  mv -f "$1" "$2" 2>/dev/null
}

if [ -s /data/adb/cfr/bin/curl ]; then
  ui_print "- curl 已存在，跳过"
elif take_component "${components_dir}/${arch}/curl" /data/adb/cfr/bin/curl; then
  chmod 0700 /data/adb/cfr/bin/curl 2>/dev/null || true
  ui_print "- 已安装内置 curl (${arch})"
else
  ui_print "- 内置 curl 缺失，改为在线获取"
  /data/adb/cfr/scripts/tool.sh upcurl
fi

if [ -s /data/adb/cfr/mihomo/geoip.dat ] && [ -s /data/adb/cfr/mihomo/geosite.dat ]; then
  ui_print "- GeoX 已存在，跳过"
else
  [ -s /data/adb/cfr/mihomo/geoip.dat ] || take_component "${components_dir}/geoip.dat" /data/adb/cfr/mihomo/geoip.dat
  [ -s /data/adb/cfr/mihomo/geosite.dat ] || take_component "${components_dir}/geosite.dat" /data/adb/cfr/mihomo/geosite.dat
  if [ -s /data/adb/cfr/mihomo/geoip.dat ] && [ -s /data/adb/cfr/mihomo/geosite.dat ]; then
    ui_print "- 已安装内置 GeoX"
  else
    ui_print "- 内置 GeoX 缺失，改为在线获取"
    /data/adb/cfr/scripts/tool.sh upgeox_fill
  fi
fi

if [ -s /data/adb/cfr/bin/mihomo ]; then
  ui_print "- mihomo 内核已存在，跳过"
elif take_component "${components_dir}/${arch}/mihomo" /data/adb/cfr/bin/mihomo; then
  ui_print "- 已安装内置 mihomo 内核 (${arch})"
else
  ui_print "- 内置 mihomo 内核缺失，改为在线获取"
  /data/adb/cfr/scripts/tool.sh upkernel mihomo
fi

need_ui_install="false"
if [ ! -f /data/adb/cfr/mihomo/dashboard/index.html ]; then
  need_ui_install="true"
elif [ -s "${components_dir}/zashboard.zip" ] && ! busybox grep -qi 'zashboard' /data/adb/cfr/mihomo/dashboard/index.html 2>/dev/null; then
  ui_print "- 检测到旧面板非 zashboard，将替换为内置 zashboard"
  need_ui_install="true"
fi

if [ "${need_ui_install}" = "false" ]; then
  ui_print "- 面板已存在，跳过"
elif [ -s "${components_dir}/zashboard.zip" ] || [ -s "${components_dir}/metacubexd.tgz" ]; then
  ui_tmp="${MODPATH}/.ui_tmp"
  rm -rf "${ui_tmp}" /data/adb/cfr/mihomo/dashboard
  mkdir -p "${ui_tmp}" /data/adb/cfr/mihomo/dashboard
  if [ -s "${components_dir}/zashboard.zip" ]; then
    unzip -oq "${components_dir}/zashboard.zip" -d "${ui_tmp}" 2>/dev/null ||
      busybox unzip -oq "${components_dir}/zashboard.zip" -d "${ui_tmp}" 2>/dev/null
  else
    busybox tar -xzf "${components_dir}/metacubexd.tgz" -C "${ui_tmp}" 2>/dev/null ||
      busybox gunzip -c "${components_dir}/metacubexd.tgz" | busybox tar -xf - -C "${ui_tmp}" 2>/dev/null
  fi
  ui_html=$(busybox find "${ui_tmp}" -maxdepth 3 -type f -name index.html | head -n 1)
  if [ -n "${ui_html}" ]; then
    mv -f "${ui_html%/*}"/* /data/adb/cfr/mihomo/dashboard/ 2>/dev/null
  fi
  rm -rf "${ui_tmp}"
  if [ -f /data/adb/cfr/mihomo/dashboard/index.html ]; then
    ui_print "- 已安装内置面板"
  else
    ui_print "- 内置面板解压失败，改为在线获取"
    /data/adb/cfr/scripts/tool.sh upxui
  fi
else
  ui_print "- 内置面板缺失，改为在线获取"
  /data/adb/cfr/scripts/tool.sh upxui
fi

# 移动进来的文件不继承之前的 set_perm
chown -R 0:3005 /data/adb/cfr/bin /data/adb/cfr/mihomo 2>/dev/null
chmod 0700 /data/adb/cfr/bin/* 2>/dev/null
find /data/adb/cfr/mihomo/dashboard -type d -exec chmod 0700 {} + 2>/dev/null
find /data/adb/cfr/mihomo/dashboard -type f -exec chmod 0600 {} + 2>/dev/null
if [ -d /data/adb/cfr/mihomo/providers ]; then
  find /data/adb/cfr/mihomo/providers -type d -exec chmod 0700 {} + 2>/dev/null
  find /data/adb/cfr/mihomo/providers -type f -exec chmod 0600 {} + 2>/dev/null
fi

ui_print "- 组件检查完成"

# 清理旧内核备份、日志
ui_print "- 清理备份、日志"
rm -rf /data/adb/cfr/bin/backup
find /data/adb/cfr -type f -name "*.log" -delete 2>/dev/null
find /data/adb/cfr -maxdepth 2 -type f -name "*.bak" -delete 2>/dev/null
ui_print "- 清理完成"

if [ -z "$(find /data/adb/cfr/bin -type f -name '*' ! -name '*.bak')" ]; then
  ui_print "! 未找到内核，请手动放入 /data/adb/cfr/bin/mihomo"
  sed -Ei 's/^description=(\[.*][[:space:]]*)?/description=[ 😱 模块已安装但需手动下载内核 ] /g' $MODPATH/module.prop
fi

if [ "$KSU" = "true" ]; then
  sed -i "s/name=.*/name=Clash For KernelSU/g" $MODPATH/module.prop
elif [ "$APATCH" = "true" ]; then
  sed -i "s/name=.*/name=Clash For APatch/g" $MODPATH/module.prop
else
  sed -i "s/name=.*/name=Clash For Magisk/g" $MODPATH/module.prop
fi
unzip -o "$ZIPFILE" 'webroot/*' -d "$MODPATH" >&2

ui_print "- 清理残留文件"
rm -rf /data/adb/cfr/bin/.bin $MODPATH/cfr.sh
# 内置组件已就位，删除安装包内的副本
rm -rf "${components_dir}"

if [ "${is_upgrade}" = "true" ]; then
  ui_print "- 升级完成，请重启设备"
  ui_print "- 组件与用户配置：已保留"
  if [ -n "${old_subscription}" ]; then
    ui_print "- 订阅链接：已继承"
  else
    ui_print "- 订阅链接：未设置，需手动填写"
  fi
  ui_print "- settings.ini 其他配置：已重置"
else
  ui_print "- 安装完成，请重启设备"
fi
