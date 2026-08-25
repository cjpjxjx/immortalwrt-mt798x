# RAX3000M 双 WAN 故障转移（mwan3）

记录本机 RAX3000M 上 mwan3 双 WAN 故障转移的部署方式、配套自研脚本，以及踩过的坑与对应结论。

本文是**故障与决策记录**，会说明"为什么这么配"，与 [rax3000m-optimizations.md](rax3000m-optimizations.md)（编译期定制说明）分工不同。这里的内容全部是**刷机后的运行时配置**，不进固件、不影响编译流程；相关软件包由 opkg 安装，脚本副本存放在 [docs/mwan3/](mwan3/)。

## 1. 拓扑与目标

两条上行链路，主线断了自动切备线，恢复后自动切回，并发邮件告警。

| mwan3 接口 | 载体 | 地址方式 | member metric |
|---|---|---|---|
| `wifi5g` | 5G 无线中继（ApCli/sta，设备 `apclix0`） | DHCP | 1（主） |
| `cpe5g` | USB 4G/5G CPE（设备 `usb0`） | 静态 `192.168.66.10/24`，网关 `192.168.66.1` | 2（备） |

有线 WAN 口（`eth1`）未参与，LAN 为 `br-lan`（`192.168.64.1/24`）。

## 2. 无线中继的两个坑

### 2.1 不要同时中继同一台上游路由器的 2.4G 和 5G

最初想用 2.4G + 5G 两条 sta 同时中继同一台上游路由器，当作两条独立链路。实际不可行：

- 上游两个频段属于同一个 LAN，两条 sta 从同一个 DHCP 池拿地址、指向**同一个网关 IP**。
- 结果是两条默认路由下一跳相同、只是出口设备不同，mwan3 的策略路由表和 ARP 无法区分二者，源地址选择和探测结果随机漂移。
- 表现为：上下线状态乱跳、failover 切换后流量并未真正换路、`mwan3 status` 与实际连通性对不上。

**结论**：一台上游路由器只中继一个频段。本机保留 5G 中继（`wifi5g`），2.4G 只作 AP 供终端接入。两条链路必须来自**物理上不同的上游**（这里是上游路由器 + USB CPE）。

### 2.2 上游 AP 的信道必须与本机 AP 信道一致

MT7981 是 DBDC，每个频段只有一个射频。mtwifi 驱动下 AP 与 ApCli 共用同一个 phy，**只能工作在同一个信道**。

- 本机 5G AP 固定在信道 149，上游 5G 若不在 149，ApCli 就连不上；即使扫描能看到该 SSID，连接也会失败或握手后立刻断开。
- 症状容易被误判成密码错、信号弱、加密方式不兼容。

**结论**：把上游 AP 的信道**固定**成与本机 5G AP 相同的值（本机为 149），两边都不要用 `auto`——自动选信道会让上游在某次重启后漂走，中继随之失联。本机 2.4G 因为不做中继，保持 `auto` 无妨。

另注：扫描上游 AP 时用有线或另一个频段接管理界面，否则扫描会打断你正在用的那条无线连接。

## 3. 固件自带的 ip-tiny 不够用

mwan3 依赖 `ip rule` 和多路由表（`ip route ... table <id>`）实现策略路由，固件自带的 `ip-tiny` 裁掉了这部分能力。装了 mwan3 但不换 `ip`，表现是策略规则装不上、`mwan3 status` 里 policy 恒为 unreachable，而报错并不显眼。

```sh
opkg update
opkg install ip-full
ls -l /sbin/ip    # 应指向 /usr/libexec/ip-full
```

`ip-tiny` 保留在 `/usr/libexec/` 下不用删，`/sbin/ip` 指向 `ip-full` 即可。

## 4. 软件包与配置

刷机后需要安装（均不在 defconfig 中，固件不自带）：

```sh
opkg update
opkg install mwan3 luci-app-mwan3 luci-i18n-mwan3-zh-cn ip-full msmtp
```

依赖会一并带入 `libbpf0`、`libelf1`、`libgnutls`、`libuci-lua`。

**mwan3 配置**：见 [docs/mwan3/config-mwan3](mwan3/config-mwan3)，可直接覆盖 `/etc/config/mwan3`。要点：

- 两个 member 的 metric 为 1（`wifi5g`）/ 2（`cpe5g`），policy `wan_failover` 因此是主备而非负载均衡。
- 探测目标 `119.29.29.29` / `223.5.5.5`，`interval=5`、`down=3`、`up=3`，即约 15 秒确认一次状态翻转——这层确认也顺带过滤掉了瞬时抖动，是第 6 节告警不必再做防抖的前提。
- 只配了 IPv4 规则（`family ipv4`）。IPv6 在 policy 里显示 unreachable，属预期。

**network 配置**要点：

```
config interface 'cpe5g'
	option device 'usb0'
	option proto 'static'
	option ipaddr '192.168.66.10'
	option netmask '255.255.255.0'
	option gateway '192.168.66.1'
	option peerdns '0'
	option dns '119.29.29.29 223.5.5.5'
	option metric '20'

config interface 'wifi5g'
	option proto 'dhcp'
	option metric '10'
```

`wifi5g` 不写 device，由 `wireless.sta_MT7981_1_2.network='wifi5g'` 关联。两个接口的 `metric`（10/20）是 netifd 默认路由优先级，与 mwan3 member 的 metric（1/2）是两套独立的值，但方向要一致，否则主备判断会互相打架。

**firewall**：两个接口都加入 `wan` 区域，`masq='1'`、`mtu_fix='1'`：

```sh
uci set firewall.@zone[1].network='cpe5g wifi5g'
```

## 5. 看门狗：mwan3-check

脚本：[docs/mwan3/mwan3-check](mwan3/mwan3-check) → 装到 `/usr/bin/mwan3-check`。

修复 mwan3 在本设备上的两类异常状态：

1. **tracker 永久 paused**：mwan3 的 `START=19` 早于 network 的 `START=20`，procd 注册完成时 network 的首批 ifup 事件已经发完，丢事件后 tracker 卡在 `hotplug called on <iface> before mwan3 has been set up`，自己不会恢复。开机必现；运行中执行 `wifi reload`、或在 LuCI 里改 mwan3 配置触发重启时也会复现。
2. **丢默认路由**：多个 member 并发 ifup 时，某个接口的默认路由可能没进 main 表或没进自己的策略表，探测随之失败，一条好链路被判为离线。

判定逻辑：只检查 netifd 报告为 up 的 member。`paused` 或缺策略规则 → 重启 mwan3；缺路由 → **逐个**（不能并发，并发正是丢路由的成因）bounce 该接口。最多 3 轮，仍不健康就打日志交给 mwan3 自己的 failover。

注意：`mwan3 status` 里的 "tracking is paused" **不能**单独作为故障信号——一条真的断了的链路同样会这么显示，所以脚本先用 ubus 查 netifd 状态，down 的直接跳过。

触发方式：

```sh
# /etc/rc.local，exit 0 之前
/usr/bin/mwan3-check --boot &

# crontab -e
*/5 * * * * /usr/bin/mwan3-check >/dev/null 2>&1
```

`--boot` 模式先等所有 member 起来（最多 180 秒）再检查。运行期间持有 `/tmp/mwan3-check.lock`（防止两次运行互相 bounce），修复动作期间额外持有 `/tmp/mwan3-check.repairing`，供第 6 节的告警脚本区分"看门狗正在修"和"链路真的变了"。

## 6. 邮件告警

三个文件配合：

- `/etc/mwan3.user` —— 末尾追加一行 `/usr/bin/mwan3-notify.sh`
- [docs/mwan3/mwan3-notify.sh](mwan3/mwan3-notify.sh) → `/usr/bin/mwan3-notify.sh`
- [docs/mwan3/mwan3-notify-worker.sh](mwan3/mwan3-notify-worker.sh) → `/usr/bin/mwan3-notify-worker.sh`

配置（路由器本地，不入库）：

```sh
mkdir -p /etc/mwan3-notify
# 按 docs/mwan3/msmtprc.example 填好真实凭据
vi /etc/mwan3-notify/msmtprc && chmod 600 /etc/mwan3-notify/msmtprc
echo 'you@example.com' > /etc/mwan3-notify/mail_to
```

两个文件缺一时脚本静默跳过，所以可以先部署脚本、后配凭据。

### 6.1 入口脚本必须立刻返回

`mwan3.user` 是在 netifd/mwan3track 的 hotplug 链里**同步**调用的，而 `/etc/hotplug.d/iface/16-mwan3-user` 在调用前持有 `procd_lock`。在这里直接发邮件会把锁按住几十秒，阻塞后续接口事件。

所以入口脚本只做参数检查，然后用 `start-stop-daemon -S -b -m` 把 worker 甩到后台，慢活（等锁、重试发信）全在 worker 里做。

### 6.2 BusyBox start-stop-daemon 的 -x 要写解释器

BusyBox 的 `start-stop-daemon -x` 匹配的是 `/proc/PID/cmdline` 里的 `argv[0]`。对 shell 脚本来说那是**解释器** `/bin/sh`，不是脚本路径。把脚本路径写成 `-x` 参数会匹配不到任何进程，去重静默失效，两个事件会各起一个 worker（实测确认）。正确写法：

```sh
start-stop-daemon -S -b -m -p "$PIDFILE" -x /bin/sh -- "$WORKER" "$ACTION" "$INTERFACE" "$DEVICE"
```

### 6.3 cryptodev 硬件加速导致 SMTP 发信失败

msmtp 走 gnutls，gnutls 会通过 `/dev/crypto`（cryptodev-linux）使用硬件加速。在本设备上这条路径与腾讯云 SES 的 SMTP（465，隐式 TLS）配合时会出错，发信直接失败；同样的凭据在别处正常，排查方向极易跑偏到证书、账号、端口上。

禁用 cryptodev 后 gnutls 回落到软件实现，发信恢复正常：

```sh
cp /etc/modules.d/50-cryptodev /root/50-cryptodev.bak
rm /etc/modules.d/50-cryptodev
reboot
```

`50-cryptodev` 的原始内容是 `cryptodev cryptodev_verbosity=-1`；本机备份留在 `/root/50-cryptodev.bak`。本设备无其它组件依赖 cryptodev 加速。

### 6.4 worker 的两级等待

1. **等修复锁**：看门狗自己重启 mwan3 或 bounce 接口，会让 mwan3track 对一条**从未真正断过**的链路重新播报 connected/disconnected。所以 worker 先等 `/tmp/mwan3-check.repairing` 消失（每 60 秒查一次，最多 2 次）。若一直没消失，说明看门狗 3 轮修复都没解决，此时发一封**"看门狗修复超时"**的告警，而不是把问题被去噪逻辑吞掉。
2. **发信重试**：链路切换时网络本身就在抖，SMTP 发送很可能同时失败。失败后每 10 秒重试一次，最多 5 次。

同一接口同时只允许一个 worker（pidfile 按接口区分）。第二个事件在前一个还在等锁/重试时会被**丢弃**而不是排队——mwan3 自己的 down=3/up=3（约 15 秒）已经过滤过抖动，能连续到达这里的重复事件没有保留价值。

## 7. 从零部署清单

```sh
# 1. 换 ip
opkg update && opkg install ip-full

# 2. 装 mwan3 与发信工具
opkg install mwan3 luci-app-mwan3 luci-i18n-mwan3-zh-cn msmtp

# 3. 配置两条上行（见第 4 节），确认 wifi5g、cpe5g 都能单独上网

# 4. 覆盖 mwan3 配置
scp docs/mwan3/config-mwan3 root@192.168.64.1:/etc/config/mwan3

# 5. 部署脚本
scp docs/mwan3/mwan3-check docs/mwan3/mwan3-notify.sh \
    docs/mwan3/mwan3-notify-worker.sh root@192.168.64.1:/usr/bin/
ssh root@192.168.64.1 'chmod +x /usr/bin/mwan3-check /usr/bin/mwan3-notify.sh /usr/bin/mwan3-notify-worker.sh'

# 6. 挂钩子：/etc/mwan3.user 末尾加 /usr/bin/mwan3-notify.sh
#    /etc/rc.local 加 /usr/bin/mwan3-check --boot &
#    crontab 加 */5 * * * * /usr/bin/mwan3-check >/dev/null 2>&1

# 7. 配 SMTP（见第 6 节），并禁用 cryptodev（见 6.3）

# 8. 重启验证
reboot
```

## 8. 排查速查

```sh
mwan3 status                       # 接口状态与当前策略
mwan3-check                        # 手动跑一次看门狗，会打印判定结果
logread -e mwan3-check             # 看门狗日志
logread -e mwan3-notify            # 告警日志
ip rule show                       # 策略规则是否存在（没有 = ip-full 没生效或 mwan3 没起来）
ip route show table main           # 各接口默认路由
msmtp -C /etc/mwan3-notify/msmtprc -a default --debug you@example.com < /dev/null   # 单独测发信
```

对照表：

| 现象 | 先查 |
|---|---|
| policy 恒为 unreachable | `/sbin/ip` 是否指向 `ip-full`（第 3 节） |
| 一直 "tracking is paused" 但链路正常 | 看门狗是否在跑（第 5 节） |
| 中继连不上、握手即断 | 上游信道是否与本机 5G 一致（2.2 节） |
| 状态乱跳、切换后流量没换路 | 两条链路是否来自同一台上游（2.1 节） |
| 告警邮件发不出 | cryptodev 是否已禁用（6.3 节）、`msmtprc` 权限是否 600 |
