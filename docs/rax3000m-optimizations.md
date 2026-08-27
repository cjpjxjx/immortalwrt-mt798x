# CMCC RAX3000M 编译优化说明

记录 CMCC RAX3000M（MT7981，128M SPI-NAND）固件的编译期定制内容。

> 原项目作者介绍：https://cmi.hanwckf.top/p/immortalwrt-mt798x/

## 1. 已移除的组件

| 移除项 | 一并移除的依赖 |
|---|---|
| `luci-app-usb-printer` | `p910nd`、`kmod-usb-printer`、中文语言包 |
| `luci-app-samba4` | `samba4-server`、`samba4-libs`（约8MB）、中文语言包 |
| `luci-app-eqos-mtk` | `tc-tiny`、`tc-mod-iptables`、`kmod-ifb`、`kmod-sched-core` |
| `luci-app-upnp` | `miniupnpd` |
| （无对应 LuCI 页面） | `libfido2`、`libcbor`（FIDO2 硬件密钥支持） |

对应的"网络存储"（USB打印服务器、Network Shares）、"服务"（网速控制、UPnP）菜单项自动从后台消失。

## 2. 转发加速相关现状

- **Turbo ACC / MediaTek HNAT**：首次开机由 `luci-app-turboacc-mtk` 的 uci-defaults 脚本自动探测并设为 `mediatek_hnat`，默认生效。
- **Flow offloading**：`luci.turboacc` rpcd 后端硬编码 `hasFLOWOFFLOADING=false`，LuCI 不显示该选项，避免与 HNAT 冲突。
- `kmod-shortcut-fe`、`kmod-shortcut-fe-cm`、`kmod-fast-classifier` 均未编译，不与 HNAT 混用。
- `mtk_eth_soc.h` 中 `MT7981_CAPS` 只含 `MTK_NETSYS_V2`、不含 `MTK_NETSYS_RX_V2`，ADMA 为官方要求的 v1 回退方案。
- `kmod-usb-net-rndis`、`kmod-usb-net-cdc-ether`、`kmod-usb-net-cdc-ncm`、`kmod-usb-net-huawei-cdc-ncm`、`kmod-usb-wdm` 已包含在默认 USB 包组，支持外接 USB 网卡/USB 4G 上网卡的双向 HNAT 加速。其中 `kmod-usb-net-rndis` 来自 `target/linux/mediatek/image/mt7981.mk` 的 `MT7981_USB_PKGS`（逐设备包列表，RAX3000M NAND 版仅过滤掉 USB 打印服务器），`kmod-usb-net-cdc-ether` 是 RNDIS 包的弱依赖（`AddDepends/usb-net,+kmod-usb-net-cdc-ether`）间接带入；`kmod-usb-net-cdc-ncm`、`kmod-usb-net-huawei-cdc-ncm`、`kmod-usb-wdm` 则是显式加入 `defconfig/mt7981-ax3000.config`。

## 2.1 ADB 支持

- `adb`（package/utils/adb）已加入 defconfig，OpenWrt 终端可直接用 `adb devices`/`adb shell` 连接 USB 口上的 Android 设备（USB CPE、安卓手机等）。ADB 走 usbfs 原始批量传输，不依赖 usbnet 驱动栈，内核层面只需 `CONFIG_USB_COMMON`+XHCI 主控（均已内置），无需额外 Kconfig。
- 部分 4G/5G USB CPE 出厂默认非调试模式，需先用 `adb-enablemodem`（package/network/utils/adb-enablemodem）之类的模式切换脚本触发才能同时暴露 modem 和 adb 接口；本仓库暂未默认启用该包，如遇设备插上后 adb 识别不到，可按需加入。
- 安卓手机的 USB 网络共享是另一条独立通路（走 RNDIS 或 NCM 驱动，见上一节），与 ADB 使用不同的 USB interface，两者可同时使用、互不冲突。

## 3. LuCI 登录页精简（Argon 主题）

- **运行时**（手动编译路径）：`target/linux/mediatek/base-files/etc/uci-defaults/31_luci-theme-argon-sysauth` 首次开机删除 `sysauth.htm`、`bg1.jpg`、`online_wallpaper`、背景目录 `README.md`。仅在可写 overlay 层生效，不减小固件体积。
- **编译期**（`build.sh` 一键编译路径）：`feeds update` 后直接在 `feeds/luci/themes/luci-theme-argon` 源码里删除同一批文件，squashfs 不再包含，真正减小固件体积（约160KB）。

## 4. 编译范围：仅 RAX3000M NAND 版

`defconfig/mt7981-ax3000.config` 只启用 `CONFIG_TARGET_DEVICE_mediatek_mt7981_DEVICE_cmcc_rax3000m=y` 一个设备。手动编译（README 步骤）与 `build.sh` 共用同一份 defconfig，均只产出 RAX3000M NAND 版固件。

## 5. 保留不变的默认项

- **zram-swap**：默认开启。
- **cpufreq/governor**：当前内核版本无相关内核模块，无可调项。
- **irqbalance**：未安装。

## 5.1 默认 LAN 网段

首次开机由 `target/linux/mediatek/base-files/etc/uci-defaults/32_default-lan-ip` 将 `network.lan.ipaddr` 从 OpenWrt 默认的 `192.168.1.1` 改为 `192.168.64.1`（`/24`）。仅对 `cmcc,rax3000m` / `cmcc,rax3000m-emmc` 生效，通过 `board_name` 判断，不影响其他设备。仅在首次开机（或 `firstboot` 后）生效，已配置过的设备不会被覆盖。

## 6. 需刷机后手动配置的事项

1. **无线加密方式**：WPA2-PSK/WPA3-PSK。
2. **ApCli 中继模式**：扫描 AP 时用有线或非扫描频段连接管理界面；不用中继时将 ApClient 设为"禁用"，WAN 自动切回 `eth1`。
3. **老旧 2.4G 设备连接异常**：可尝试 WPA-PSK+AES/WPA2-PSK+AES、切 N 模式、关 MU-MIMO、锁 20MHz、关强制 40MHz。
4. **IGMP Snooping**：多播/视频卡顿可在无线设置中关闭。
5. **双 WAN 故障转移**：mwan3 及其依赖（`ip-full`、`curl`、`openssl-util` 等）不在固件内，需刷机后 opkg 安装并部署配套脚本，详见 [rax3000m-mwan3-failover.md](rax3000m-mwan3-failover.md)。

## 7. 涉及的源码改动

- `target/linux/mediatek/image/mt7981.mk` —— RAX3000M 设备包移除 USB 打印服务器、Network Shares
- `defconfig/mt7981-ax3000.config` —— 移除 eQoS、UPnP 及其依赖、libfido2/libcbor；仅保留 `cmcc_rax3000m` 设备；新增 `kmod-usb-net-cdc-ether`、`kmod-usb-net-cdc-ncm`、`kmod-usb-net-huawei-cdc-ncm`、`kmod-usb-wdm`（USB 4G 上网卡支持）、`adb`（USB CPE/安卓设备 ADB 调试）
- `target/linux/mediatek/base-files/etc/uci-defaults/31_luci-theme-argon-sysauth`（新增）—— 运行时精简 Argon 登录页
- `target/linux/mediatek/base-files/etc/uci-defaults/32_default-lan-ip`（新增）—— 首次开机将默认 LAN 网段改为 `192.168.64.1/24`
- `build.sh`（新增，仓库根目录）—— 一键编译：更新 feeds、编译期删除 Argon 登录页文件、清理编译缓存、执行 `make`
