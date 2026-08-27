# RAX3000M 双 WAN 故障转移（mwan3）

记录本机 RAX3000M 上 mwan3 双 WAN 故障转移的部署方式、配套自研脚本，以及踩过的坑与对应结论。

本文是**故障与决策记录**，会说明"为什么这么配"，与 [rax3000m-optimizations.md](rax3000m-optimizations.md)（编译期定制说明）分工不同。这里的内容全部是**刷机后的运行时配置**，不进固件、不影响编译流程；相关软件包由 opkg 安装，脚本副本存放在 [docs/mwan3/](mwan3/)。

## 1. 拓扑与目标

两条上行链路，主线断了自动切备线，恢复后自动切回；两个用户态看门狗（第 5、6 节）分别兜底 mwan3 自身与 CPE 侧的已知异常状态。链路 up/down 由第 7 节的钉钉机器人 webhook 推送通知。

| mwan3 接口 | 载体 | 地址方式 | member metric |
|---|---|---|---|
| `wifi5g` | 5G 无线中继（ApCli/sta，设备 `apclix0`） | DHCP | 1（主） |
| `cpe5g` | USB 4G/5G CPE（设备 `usb0`） | 静态 `192.168.66.10/24`，网关 `192.168.66.1` | 2（备） |

有线 WAN 口（`eth1`）未参与，LAN 为 `br-lan`（`192.168.64.1/24`）。

`cpe5g` 的载体不止一层：路由器通过 USB 挂载 CPE 设备，二者以 USB 网络 gadget（`usb0`，CDC 类接口）组网——路由器侧 `usb0` 即 `192.168.66.10/24`，CPE 侧 `usb0` 为网关 `192.168.66.1/24`。CPE 同一根 USB 线上还复合了 `adb` function，与网络 function 相互独立、互不影响，第 6 节的看门狗正是靠这条通路在网络假死时远程修复 CPE。`adb` 命令行工具已随 defconfig 编译进固件（详见 [rax3000m-optimizations.md 2.1 节](rax3000m-optimizations.md#21-adb-支持)），无需额外安装。

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
opkg install mwan3 luci-app-mwan3 luci-i18n-mwan3-zh-cn ip-full curl openssl-util
```

依赖会一并带入 `libbpf0`、`libelf1`、`libuci-lua`。

**mwan3 配置**：见 [docs/mwan3/config-mwan3](mwan3/config-mwan3)，可直接覆盖 `/etc/config/mwan3`。要点：

- 两个 member 的 metric 为 1（`wifi5g`）/ 2（`cpe5g`），policy `wan_failover` 因此是主备而非负载均衡，作为 `default_rule_v4` 的兜底策略覆盖所有目的 IP。
- 另有 policy `prefer_cpe5g`：`member_cpe5g_primary`/`member_wifi5g_backup` 把主备关系反过来，只对少数几个特定目的 IP 生效（`dest_ip` 规则，归档文件里用 RFC 5737 文档保留地址占位，实际生产 IP 不入库，按需在路由器本地追加同结构的 `config rule`）。用于让个别对出口 IP 敏感的服务固定走 cpe5g，其余流量不受影响。
- 探测目标 `119.29.29.29` / `223.5.5.5`，`interval=5`、`down=3`、`up=3`，即约 15 秒确认一次状态翻转——这层确认也顺带过滤掉了瞬时抖动，是第 7 节告警不必再做防抖的前提。
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

`--boot` 模式先等所有 member 起来（最多 180 秒）再检查。运行期间持有 `/tmp/mwan3-check.lock`（防止两次运行互相 bounce），修复动作期间额外持有 `/tmp/mwan3-check.repairing`，供第 7 节的告警脚本区分"看门狗正在修"和"链路真的变了"；第 6 节的 `cpe-usb-watchdog` 也会读这两把锁来避让。

## 6. 看门狗：cpe-usb-watchdog

脚本：[docs/mwan3/cpe-usb-watchdog](mwan3/cpe-usb-watchdog) → 装到 `/usr/bin/cpe-usb-watchdog`。

修复第 1 节提到的 CPE 侧 USB 网络 gadget 假死：两端 `usb0` 都报 `UP,LOWER_UP`、CPE 自身蜂窝数据与本机正常，但路由器 ping/HTTP 到 CPE 网关地址（`192.168.66.1`）持续不通，`ip neigh` 长时间无应答后连 MAC 都会丢（`FAILED`）。这不是内核感知到的硬件掉线（无 USB 断开/复位日志），是 gadget 数据通路本身卡住，netifd 和 mwan3 都观察不到异常，只能端到端探测才能发现。

`adb` 在整个假死期间不受影响，因为它是 CPE 这台 USB 复合设备上独立于网络 function 的另一条通道，这也是"修复必须发生在 CPE 上、探测和触发却能放在路由器上"的前提：两端地址都在路由器 UCI 里声明（`network.cpe5g.ipaddr` / `.gateway`），链路断的时候依然读得到，不存在"不知道探测谁"的问题；CPE 侧则相反——它自己的邻居表在链路断时会连对端 MAC 一起丢，且该固件的 busybox 没有 `ip neigh`/`arping`，无法反查，所以看门狗只能放在路由器一侧。

判定与修复逻辑：

1. **前置检查**：`network.cpe5g` 未被 netifd 判定 up、或路由器侧 `usb0` 没有 UP/没有预期地址，说明是路由器自己的问题，直接让位给 `mwan3-check`，不碰 CPE。
2. **探测**：ICMP 和 `/api/health` 互为第二意见，任一成功即判健康；连续 3 轮（间隔 8 秒）都失败才判定异常，避免瞬时抖动触发修复。
3. **修复升级**：`adb shell` 里重置 connman 的 gadget tethering 会话并重新下发 `usb0` 地址（`connmanctl tether gadget off/disable/enable/tether gadget on` + `ifconfig`/`ip link set up`），复测；不行再来一轮；两轮仍不通就 `adb reboot` 重启 CPE。全程不碰 USB gadget 本身或 UDC，因为那会连 adb 一起重新枚举掉，等于自断退路。
4. **重启限速**：最短间隔 1800 秒，6 小时窗口内最多 3 次，超过只记 `CRITICAL` 日志不再重启，交给人工介入，避免重启循环。
5. **adb 也不通**：只记 `CRITICAL` 日志退出——多半是物理层问题，此时没有任何带外通道可用，看门狗无能为力。

**钉钉推送**：复用第 7 节的 [docs/mwan3/dingtalk-notify.sh](mwan3/dingtalk-notify.sh) 共享推送函数（同一份 `dingtalk.conf`）。cron 每 5 分钟跑一次，若直接照搬"每次判定异常就推"会在长时间故障时刷屏，所以用两个跨轮次的标记文件控制只在状态**变化**时推送：

- `/tmp/cpe-usb-watchdog.faulted` —— 一次故障期间存在。首次判定假死（非 `--check`）时创建并推"CPE 假死，开始处理"；探测恢复健康时删除并推"CPE 已恢复"（无论恢复发生在本轮软重置之后，还是重启 CPE 后的某一轮被动探测确认，都会补这条确认）。
- `/tmp/cpe-usb-watchdog.escalated` —— 本次故障期间是否已经发过"需要人工介入"的提醒。adb 也联系不上、或重启次数触顶这两种"脚本自己已经无能为力"的情况各自只推一次，不会每 5 分钟重复；与 `.faulted` 一起在恢复时清除。
- 真正触发 `adb reboot` 这一步不受上面两个标记限制，每次实际重启都会推一条——重启本身已经被限速（最短间隔 1800 秒、6 小时最多 3 次），不会变成刷屏源。

触发方式：cron 定时 + mwan3 掉线事件（见 6.1）两条入口。

```sh
# crontab -e，与 mwan3-check 错开 2 分钟，避免同时抢 adb/USB
2-59/5 * * * * /usr/bin/cpe-usb-watchdog >/dev/null 2>&1
```

**与 mwan3-check 的协调**：`cpe-usb-watchdog` 启动时检查 `mwan3-check.lock` 与 `.repairing`，只要 mwan3-check 在跑（不论是否在修复）就整轮跳过，因为 mwan3-check 的 `ifdown`/`ifup` 会让 CPE 短暂合理地不可达。这个避让只在入口检查一次，长达数分钟的修复过程中不会复查，是单向而非互斥锁——但两者故障域基本不重叠：`cpe-usb-watchdog` 只有路由器侧接口/地址都正常时才会继续（否则让位给 mwan3-check），而 mwan3-check 完全基于 netifd/`ip rule`/`ip route` 判断，不做端到端探测，CPE 网关假死但路由器侧一切正常时它根本不认为 `cpe5g` 有问题；`cpe-usb-watchdog` 的修复动作也只通过 adb 操作 CPE 内部，不触碰路由器侧 `cpe5g` 接口本身，不会产生 netifd 事件。两者极少会同时对同一目标动手，即使撞上，最坏后果也只是多花一轮探测时间，不会互相破坏。

健康时只更新心跳文件 `/tmp/cpe-usb-watchdog.last-ok`，不写 syslog，避免每 5 分钟一条日志噪音；异常与修复动作走 `logread -e cpe-usb-watchdog`。

### 6.1 事件触发：mwan3 判定 cpe5g 掉线时立即检查

脚本：[docs/mwan3/mwan3-cpe-trigger.sh](mwan3/mwan3-cpe-trigger.sh) → 装到 `/usr/bin/mwan3-cpe-trigger.sh`，在 `/etc/mwan3.user` 里与 `mwan3-notify.sh` 并列追加一行。

只靠 cron，一次假死最多要等 5 分钟才被发现。而 CPE 假死会让 mwan3 的 track 探测失败（mwan3track 与流量走哪条线无关，备线也一直在探），约 15 秒后就报 `cpe5g` `disconnected`——这个事件是现成的提示，收到就立刻跑一次看门狗，把发现延迟压到秒级。

- 只对 `ACTION=disconnected` + `INTERFACE=cpe5g` 生效，其余事件直接退出。
- 冷却 300 秒（与 cron 周期一致），时间戳记在 `/tmp/cpe-usb-watchdog.last-trigger`。链路抖动会连着丢来多个 `disconnected`，而软重置本身没有限速（只有 CPE 重启有），事件驱动不能把修复节奏抬得比定时更快。
- 与 cron 撞车由看门狗自己的 `mkdir` 锁裁决（原子，谁先谁赢，输的整轮跳过），单轮 `MAX_RUNTIME=240` 秒小于 cron 的 300 秒间隔，正常不会重叠。
- 判定"是不是真假死"完全交给看门狗原有的入口检查，触发器不做任何判断：netifd 层真掉线、路由器侧接口/地址异常、CPE 刚被重启还在启动中，这几种情况看门狗本来就会让位或等待。

cron 那条不能撤，它承担事件路径覆盖不到的部分：mwan3 自己的 tracker 卡在 paused 时根本不会有事件；一次修复没成功（重启被限速、运行预算耗尽）后链路持续断着也不会再来新事件，重试靠 cron；`adb reboot` 之后的"CPE 已恢复"确认同样由后续某轮 cron 的被动探测补上。

部署了第 7 节的钉钉告警时，一次假死会收到两条推送：`mwan3` 源的"cpe5g 掉线"和 `cpe-usb-watchdog` 源的"CPE 假死"，分别回答"线路断了"和"原因已定位、正在修"，属预期。

入口脚本同样受 7.1、7.2 两条约束（procd_lock 下必须立刻返回、`start-stop-daemon -x` 要写解释器），且刻意不合并进 `mwan3-notify.sh`：后者在 `curl`/`openssl`/`dingtalk.conf` 任一缺失时会提前退出，合并会把修复触发一起静默掉。

## 7. 钉钉机器人告警

mwan3 链路 up/down 事件、以及第 6 节 `cpe-usb-watchdog` 的假死检测/处理结果，都通过钉钉自定义机器人 webhook 推送通知，安全设置用**加签**（[官方文档](https://open.dingtalk.com/document/robots/custom-robot-access)）。此前用过邮件（msmtp/SMTP）告警，已替换为本方案。

推送内容只保留结论性信息，不带 `mwan3 status` 的完整状态表——需要排查再手动登录看，告警本身只回答"发生了什么、结果如何"。格式由 `dingtalk-notify.sh` 的 `dingtalk_notify` 统一生成，`mwan3-notify` 和 `cpe-usb-watchdog` 两个推送源用的是同一套模板：标题固定为"`RAX3000M - <事件>`"（`RAX3000M` 是本仓库唯一面向的设备型号，写死在库里，不依赖可能没改过的 `system.hostname`）。钉钉 markdown 消息的 `title` 字段只用于会话列表/通知栏预览，消息气泡本身只渲染 `text`，所以同一个标题会在正文开头以 `####` 标题重复一次，接着是固定的来源/接口/时间/详情四行，详情只写一句话——发生了什么、处理方式或结果，不加括号解释。

四个文件配合：

- `/etc/mwan3.user` —— 末尾追加一行 `/usr/bin/mwan3-notify.sh`
- [docs/mwan3/dingtalk-notify.sh](mwan3/dingtalk-notify.sh) → `/usr/bin/dingtalk-notify.sh`，加签、JSON 转义、推送重试的公共逻辑，被 `mwan3-notify-worker.sh` 和第 6 节的 `cpe-usb-watchdog` 一起 `.` source，只写一份
- [docs/mwan3/mwan3-notify.sh](mwan3/mwan3-notify.sh) → `/usr/bin/mwan3-notify.sh`
- [docs/mwan3/mwan3-notify-worker.sh](mwan3/mwan3-notify-worker.sh) → `/usr/bin/mwan3-notify-worker.sh`

配置（路由器本地，不入库，`mwan3-notify` 和 `cpe-usb-watchdog` 共用同一份）：

```sh
mkdir -p /etc/mwan3-notify
# 按 docs/mwan3/dingtalk-notify.conf.example 填好真实的 access_token、加签 secret
vi /etc/mwan3-notify/dingtalk.conf && chmod 600 /etc/mwan3-notify/dingtalk.conf
```

`dingtalk.conf` 缺失或缺 `ACCESS_TOKEN`/`SECRET` 时，`dingtalk_push` 静默跳过并返回非 0；`cpe-usb-watchdog` 在 `dingtalk-notify.sh` 缺失时也会定义一个空的 `dingtalk_push` 存根，不影响看门狗本身的探测/修复逻辑，只是不推送。所以可以先部署脚本、后配凭据。

### 7.1 入口脚本必须立刻返回

`mwan3.user` 是在 netifd/mwan3track 的 hotplug 链里**同步**调用的，而 `/etc/hotplug.d/iface/16-mwan3-user` 在调用前持有 `procd_lock`。在这里直接发 HTTP 请求会把锁按住几十秒（尤其是重试期间），阻塞后续接口事件。

所以入口脚本只做参数检查，然后用 `start-stop-daemon -S -b -m` 把 worker 甩到后台，慢活（等锁、重试推送）全在 worker 里做。

### 7.2 BusyBox start-stop-daemon 的 -x 要写解释器

BusyBox 的 `start-stop-daemon -x` 匹配的是 `/proc/PID/cmdline` 里的 `argv[0]`。对 shell 脚本来说那是**解释器** `/bin/sh`，不是脚本路径。把脚本路径写成 `-x` 参数会匹配不到任何进程，去重静默失效，两个事件会各起一个 worker（实测确认）。正确写法：

```sh
start-stop-daemon -S -b -m -p "$PIDFILE" -x /bin/sh -- "$WORKER" "$ACTION" "$INTERFACE" "$DEVICE"
```

### 7.3 cryptodev 硬件加速不影响 curl

此前用 msmtp/gnutls 走 SMTP（465，隐式 TLS）时，本机的 cryptodev 硬件加速（`/dev/crypto`）会导致 gnutls 发信失败，需禁用后才能回落到软件实现：

```sh
cp /etc/modules.d/50-cryptodev /root/50-cryptodev.bak
rm /etc/modules.d/50-cryptodev
reboot
```

`50-cryptodev` 的原始内容是 `cryptodev cryptodev_verbosity=-1`；本机备份留在 `/root/50-cryptodev.bak`（当时为 msmtp 停用的，现无需再管）。

钉钉 webhook 走 `curl` + HTTPS，已在本机 `cryptodev` 模块正常加载（`lsmod` 可见）的情况下实测推送成功，不受此坑影响，无需禁用 cryptodev。curl 走的 TLS 后端与依赖链和 msmtp 的 gnutls 路径不同，是这条坑不复现的原因。

### 7.4 worker 的两级等待

1. **等修复锁**：看门狗自己重启 mwan3 或 bounce 接口，会让 mwan3track 对一条**从未真正断过**的链路重新播报 connected/disconnected。所以 worker 先等 `/tmp/mwan3-check.repairing` 消失（每 60 秒查一次，最多 2 次）。若一直没消失，说明看门狗 3 轮修复都没解决，此时发一封**"看门狗修复超时"**的告警，而不是把问题被去噪逻辑吞掉。
2. **推送重试**：链路切换时网络本身就在抖，webhook 请求很可能同时失败。失败后每 10 秒重试一次，最多 5 次。

同一接口同时只允许一个 worker（pidfile 按接口区分）。第二个事件在前一个还在等锁/重试时会被**丢弃**而不是排队——mwan3 自己的 down=3/up=3（约 15 秒）已经过滤过抖动，能连续到达这里的重复事件没有保留价值。

## 8. 从零部署清单

```sh
# 1. 换 ip
opkg update && opkg install ip-full

# 2. 装 mwan3
opkg install mwan3 luci-app-mwan3 luci-i18n-mwan3-zh-cn

# 3. 配置两条上行（见第 4 节），确认 wifi5g、cpe5g 都能单独上网

# 4. 覆盖 mwan3 配置
scp docs/mwan3/config-mwan3 root@192.168.64.1:/etc/config/mwan3

# 5. 部署看门狗脚本
scp docs/mwan3/mwan3-check docs/mwan3/cpe-usb-watchdog docs/mwan3/mwan3-cpe-trigger.sh root@192.168.64.1:/usr/bin/
ssh root@192.168.64.1 'chmod +x /usr/bin/mwan3-check /usr/bin/cpe-usb-watchdog /usr/bin/mwan3-cpe-trigger.sh'

# 6. 挂钩子：/etc/rc.local 加 /usr/bin/mwan3-check --boot &
#    crontab 加 */5 * * * * /usr/bin/mwan3-check >/dev/null 2>&1
#    crontab 加 2-59/5 * * * * /usr/bin/cpe-usb-watchdog >/dev/null 2>&1
#    /etc/mwan3.user 末尾加 /usr/bin/mwan3-cpe-trigger.sh（第 6.1 节，与钉钉告警无关，必装）

# 7. 重启验证
reboot
```

（可选）钉钉机器人告警按第 7 节部署：`opkg install curl openssl-util`、拷贝 `dingtalk-notify.sh`/`mwan3-notify.sh`/`mwan3-notify-worker.sh`、配置 `dingtalk.conf`、`/etc/mwan3.user` 追加 hook；`cpe-usb-watchdog` 已经在第 5 步部署过，只要 `dingtalk-notify.sh` 和 `dingtalk.conf` 就位就会自动一起推送，不用额外步骤。

## 9. 排查速查

```sh
mwan3 status                       # 接口状态与当前策略
mwan3-check                        # 手动跑一次 mwan3 看门狗，会打印判定结果
cpe-usb-watchdog --check           # 手动探测 CPE 链路，只报告不修复
logread -e mwan3-check             # mwan3 看门狗日志
logread -e cpe-usb-watchdog        # CPE 看门狗日志
logread -e mwan3-cpe-trigger       # 事件触发入口日志（启动了、还是被冷却/去重挡掉）
ip rule show                       # 策略规则是否存在（没有 = ip-full 没生效或 mwan3 没起来）
ip route show table main           # 各接口默认路由
```

以下两条仅在按第 7 节部署了钉钉告警后才有意义：

```sh
logread -e mwan3-notify            # 告警日志
curl -sS -m 10 -H 'Content-Type: application/json' \
  -d '{"msgtype":"text","text":{"content":"mwan3-notify 手动测试"}}' \
  "https://oapi.dingtalk.com/robot/send?access_token=<access_token>&timestamp=<ms>&sign=<urlencoded_sign>"   # 单独测推送，timestamp/sign 需现算
```

对照表：

| 现象 | 先查 |
|---|---|
| policy 恒为 unreachable | `/sbin/ip` 是否指向 `ip-full`（第 3 节） |
| 路由器 `usb0` 状态正常但 ping/HTTP 不通 CPE，`adb` 仍可达 | CPE 端 USB gadget 假死，看门狗是否在跑（第 6 节） |
| 连 `adb` 都连不上 CPE | 物理层/CPE 本身故障，看门狗无带外通道可用（第 6 节） |
| CPE 假死后要等到下一个 cron 周期才处理 | `/etc/mwan3.user` 是否挂了 `mwan3-cpe-trigger.sh`，以及本轮是否落在 300 秒冷却内（6.1 节） |
| 一直 "tracking is paused" 但链路正常 | 看门狗是否在跑（第 5 节） |
| 中继连不上、握手即断 | 上游信道是否与本机 5G 一致（2.2 节） |
| 状态乱跳、切换后流量没换路 | 两条链路是否来自同一台上游（2.1 节） |
| （部署钉钉告警后）推送发不出 | `curl`/`openssl-util` 是否已装、`dingtalk.conf` 权限是否 600、`sign` 是否算错（7.3、7 节） |
