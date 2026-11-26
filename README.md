# cfr

Magisk / KernelSU / APatch 模块，为 Android 提供 Clash (mihomo) 全局透明代理，默认面板为 zashboard。

- 网络模式：TUN / TPROXY / REDIRECT / MIXED / ENHANCE
- 环境：Android 11+，Magisk / KernelSU / APatch
- 组件可内置进安装包（离线安装），也可在线更新

## 安装

1. 在管理器中「从本地安装」`cfr.zip`
2. 安装优先使用安装包内 `components/` 的内置文件（只移动/解压，不联网），缺失才在线下载
3. **先填订阅，再重启设备**

### 升级

整体替换 `/data/adb/cfr`，只有下面这些会先暂存再放回：

| 保留 | 清空 / 重建 |
|---|---|
| `bin/`（不含 `bin/backup/`） | `settings.ini`：仅回填订阅链接，其余回默认值 |
| `mihomo/geoip.dat`、`mihomo/geosite.dat` | `mihomo/config.yaml`：先换回安装包内的模板，开启 `update_subscription` 时启动拉取再覆盖（默认关闭，推荐配合 `proxy-providers` 仅更新节点） |
| `mihomo/dashboard/`、`mihomo/providers/` | `scripts/`、`module.prop`、`webroot/` 等代码文件 |
| `package.list.cfg`、`gid.list.cfg`、`ap.list.cfg`、`crontab.cfg` | `log/`、`run/`：清空重建，PID、UID 映射、能力缓存全部丢失 |

`mihomo/` 下除 `geoip.dat`、`geosite.dat`、`dashboard/`、`providers/` 以外的文件（自建 rule-provider、证书、`Country.mmdb` 等）**不会保留**，需要自己备份。安装收尾还会删除 `bin/backup/`、全部 `*.log` 与 `*.bak`；已存在的组件直接跳过、不重新下载。

### 内置组件（可选）

```text
components/
├── aarch64/{mihomo,curl}    # 架构名 = uname -m
├── geoip.dat
├── geosite.dat
└── zashboard.zip            # 解压到 mihomo/dashboard/
```

放齐后安装完全不联网；装完 `components/` 会被删除。

## 配置订阅（必做）

```sh
vi /data/adb/cfr/settings.ini
# subscription_url_mihomo=("https://你的订阅链接")
su -c "/data/adb/cfr/scripts/service.sh restart"
```

启动时若开启 `update_subscription` 会整份覆盖 `mihomo/config.yaml`；若保持默认 `false` 且 `config.yaml` 含 `proxy-providers.airport`，模块启动时会自动将 `settings.ini` 里的 `subscription_url_mihomo` 同步写入 `proxy-providers.airport.url`（升级自动继承，只更节点不覆盖规则）。模块还会强制改写其中几项：

| 键 | 值 |
|---|---|
| `log-level` | 跟随 `settings.ini` 的 `mihomo_log_level`（默认 `error`） |
| `ipv6` | 跟随 `settings.ini` 的 `ipv6` |
| `geodata-mode` | `true` |
| `geo-auto-update` | `false` |

同时检查 `rules:`：

- 缺 `GEOSITE,CN` → 插到 `GEOIP,CN` 之前（无 `GEOIP,CN` 则 `MATCH` 前 / 末尾，策略沿用 `GEOIP,CN`）
- `GEOSITE,CN` 排在 `GEOIP,CN` 之后 → 自动前移

## 主要配置项

`/data/adb/cfr/settings.ini`

| 项 | 默认 | 说明 |
|---|---|---|
| `network_mode` | `tproxy` | tun / tproxy / redirect / mixed / enhance；不支持 TPROXY 自动降级 redirect |
| `ipv6` | `false` | `false` 时系统级禁用（`disable_ipv6=1` + unreachable 路由） |
| `proxy_mode` | `core` | core / blacklist / whitelist，名单见 `package.list.cfg`、`gid.list.cfg` |
| `bypass_cn_ip` | `false` | 需 ipset，国内 IP 直连 |
| `quic` | `disable` | `disable` 时阻断 UDP 443/80 强制回退 TCP；`enable` 放行 UDP |
| `dns_hijack_mode` | `tproxy` | disable / tproxy / redirect；不支持 TPROXY 自动降级 |
| `performance_mode` | `true` | 仅非 tun 模式生效（启用 conntrack/connmark 快速路径） |
| `stealth_mode` | `true` | 控制器收紧 `127.0.0.1` + 自动随机 `secret`、隐藏本地代理端口、中性 TUN 网卡名、日志脱敏 |
| `block_dot` | `true` | 阻断 Android Private DNS (TCP 853)，防止绕过透明代理 DNS 劫持 |
| `kill_switch` | `true` | 开机早期及启停切换间隙临时阻断普通应用直连，防止窗口期流量泄漏 |
| `tls_verify` | `true` | 下载更新与订阅时校验 TLS 证书（自动探测 Android 系统 CA 目录） |
| `upsubs_after_start` | `true` | 已有 `config.yaml` 时先拉起代理再走代理更新订阅，避免直连暴露订阅特征 |
| `tun_device_name` | `tun0` | TUN/Mixed 模式下使用的中性网卡名 |
| `tun_force_gvisor` | `false` | `false` 时 TUN+CNIP 保留 `mixed`/`system` 协议栈；`true` 时强制 `gvisor` |
| `mac_filter` | `false` | 热点 MAC 黑白名单（`mac_mode`、`macs_list`） |
| `mihomo_stable` | `enable` | enable 稳定版 / disable Prerelease Alpha |
| `update_subscription` | `false` | 启动及定时是否整份拉取订阅覆盖 `config.yaml`（使用 `proxy-providers` 时建议保持 `false`） |
| `update_geo` | `true` | 定时任务更新 GeoX |
| `update_components` | `true` | 定时任务检查更新 `mihomo` 内核、面板与 `curl`（比对版本号，无新版则跳过不重启） |
| `run_crontab` | `true` | 启用定时任务 |
| `interva_update` | `0 0,12 * * *` | 5 段 cron，默认每天 00:00 与 12:00 执行 `tool.sh geosub` |
| `enable_network_service_control` | `false` | 按 WiFi 自动启停（`use_module_on_wifi`、`use_ssid_matching` 等） |
| `cgroup_memcg` / `cgroup_cpuset` / `cgroup_blkio` | `false` | 仅 cgroup v1（Android 11 及以下）有效 |

定时任务里订阅、`GeoX`、`CNIP` 与组件更新（`update_components`）互相独立，关掉哪个就跳过哪个；内核与各组件会先比对版本号，已是最新版时自动跳过、不重启。自定义任务写 `crontab.cfg`。

## 常用命令

```sh
su -c "/data/adb/cfr/scripts/service.sh start"        # 另有 stop / restart / status
su -c "/data/adb/cfr/scripts/tool.sh subs"            # 更新订阅 + 重载
su -c "/data/adb/cfr/scripts/tool.sh geosub"          # 订阅 + GeoX
su -c "/data/adb/cfr/scripts/tool.sh upgeox_all"      # 强制重下 geoip / geosite
su -c "/data/adb/cfr/scripts/tool.sh upkernel mihomo" # 升级内核
su -c "/data/adb/cfr/scripts/tool.sh upxui"           # 升级面板
su -c "/data/adb/cfr/scripts/tool.sh upcurl"          # 升级 curl
su -c "/data/adb/cfr/scripts/tool.sh upcnip"          # 需开启 bypass_cn_ip
```

`iptables.sh` 支持以下参数：

| 参数 | 作用 |
|---|---|
| `renew` | 先清掉旧规则再重新下发（TUN 路由 / NAT / 防回环），切网后规则错乱时用 |
| `disable` | 撤掉全部规则并恢复 IPv6；内核继续运行，但流量不再经过代理 |
| `killswitch` / `unkillswitch` | 临时开启/关闭普通应用防漏阻断（仅放行 root、内核与内网） |

```sh
su -c "/data/adb/cfr/scripts/iptables.sh renew"
su -c "/data/adb/cfr/scripts/iptables.sh disable"
```

## 目录结构

### 安装包（zip）内

```text
cfr.zip
├── META-INF/                 安装元数据
├── customize.sh              安装脚本
├── module.prop               模块信息
├── action.sh                 Magisk 操作按钮：启停服务
├── cfr.sh                    开机自启入口
├── uninstall.sh              卸载脚本
├── cfr/
│   ├── settings.ini          主配置
│   ├── ap.list.cfg           网络接口允许/忽略列表
│   ├── package.list.cfg      黑白名单应用
│   ├── gid.list.cfg          黑白名单 GID
│   ├── crontab.cfg           自定义定时任务
│   ├── mihomo/config.yaml    配置模板
│   └── scripts/              各种sh脚本文件
├── components/               内置文件
│   ├── aarch64/              架构名 = uname -m
│   │   ├── mihomo            内核
│   │   └── curl              下载工具
│   ├── geoip.dat             GeoX 数据
│   ├── geosite.dat           GeoX 数据
│   └── zashboard.zip         面板压缩包
└── webroot/                  管理器入口页面（http://127.0.0.1:23450/ui/）
```

### 设备上（安装后）

```text
/data/adb/cfr/
├── settings.ini              主配置
├── ap.list.cfg               网络接口允许/忽略列表
├── package.list.cfg          黑白名单应用
├── gid.list.cfg              黑白名单 GID
├── crontab.cfg               自定义定时任务
├── bin/
│   ├── mihomo                内核
│   └── curl                  下载工具
├── mihomo/
│   ├── config.yaml           运行时配置
│   ├── geoip.dat             地理数据
│   ├── geosite.dat           域名数据
│   ├── providers/            节点订阅缓存
│   └── dashboard/            面板
├── log/                      日志目录，每次启动前清空
│   ├── runs.log              模块运行日志
│   ├── tool.log              工具日志
│   ├── mihomo.log            内核运行日志
│   └── debug.log             网络事件 / 模块开关 / 网络控制 调试日志
├── run/                      运行时状态目录，跨启动保留
│   ├── cfr.pid               内核 PID
│   └── state/                运行时缓存（能力探测、ipset 标记、UID 映射、crond spool）
└── scripts/                  模块脚本
```

## 行为要点

- 开机早期启用 Kill-Switch 防漏（如开启 `kill_switch`），待 `bootanim` 结束后拉起内核与透明代理规则再解除；已有配置时优先拉起代理后再经代理更新订阅
- 订阅下载失败或内容异常会回滚，不影响现有配置；配置改写后自动通过 `mihomo -t` 校验，失败自动回滚
- GeoX 不在启动时更新，只在定时任务里更新
- 运行期自动监听 `/data/system/packages.list` 变动并刷新黑白名单 UID 规则
- 日志：安装与每次启动前清空；iptables 运行信息每次启动只记一次；能力探测结果缓存在 `run/state/iptables.cap.env`
- 面板：`http://127.0.0.1:23450/ui/`，端口以 `external-controller` 为准（隐匿模式下自动绑定 `127.0.0.1` 并配置随机 `secret`）

## 常见问题

- **面板打不开**：先运行 `service.sh status` 确认内核在跑，再查看 `log/mihomo.log`；必要时执行 `tool.sh upxui` 重下面板，浏览器确认访问 `http://127.0.0.1:23450/ui/` 并填写 `secret`。
- **能连上但上不了网**：确认 `config.yaml` 里已有 `proxies:` 或有效的 `proxy-providers` 节点缓存，排查 `log/mihomo.log`，并检查转发规则（`iptables -t nat -S | head -20`）。
- **提示 `Can't find geoip.dat` / `geosite.dat`**：执行 `tool.sh upgeox_all` 后运行 `service.sh restart`。
- **`config.yaml` 丢失**：当 `update_subscription="true"` 时启动会自动尝试从订阅补回（限时 10 秒）；保持默认 `"false"` 时需手动放回 `config.yaml`（或临时开启后执行 `tool.sh subs`）。
- **内核启动失败**：自动打印内核日志末尾，并重下订阅后重试一次（开启订阅更新时）；仍失败则停止服务、模块描述显示「内核启动失败」，详情见 `log/mihomo.log`。
- **改了 `settings.ini` 不生效**：执行 `service.sh restart`。
- **安装时在线下载失败**：手动将对应文件放入 `bin/mihomo`、`bin/curl`、`mihomo/geoip.dat`、`mihomo/geosite.dat`、`mihomo/dashboard/`，然后执行 `service.sh restart`。

## 卸载

```sh
su -c "rm -rf /data/adb/cfr"
su -c "rm -f /data/adb/service.d/cfr.sh /data/adb/ksu/service.d/cfr.sh"
```
