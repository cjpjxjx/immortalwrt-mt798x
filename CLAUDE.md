# CLAUDE.md

本文档为 Claude Code 提供指导，帮助在开发 **immortalwrt-mt798x（CMCC RAX3000M 定制编译分支）** 时理解项目上下文、设计原则与开发约束。

无论用户输入的内容包含哪种语言（尤其是包含英文代码、报错信息或专业术语时），请始终强制使用简体中文进行回答和解释。只有当用户明确发出"用英语回答"或"翻译"的请求时，才可以使用其他语言。

## 需求处理流程（强制）

除非用户明确说明是"顺手""小改""直接改"这类不需要确认的琐碎调整，否则收到任何功能性需求时，**必须先完成理解与确认，再动手实现**：

1. **复述需求**：用自己的话简要复述理解到的需求，包含隐含的前提/边界（如涉及范围、是否要兼容旧数据、是否要动已有行为等）。如果需求本身有歧义或多种合理理解，明确指出分歧点，不要自行选一种理解就往下做。
2. **给出简要计划**：列出打算改动的文件/模块、大致思路，以及会不会涉及本文件"核心设计原则"或"关键设计决策"里的约束。计划要简短（几行到十几行即可），不是完整设计文档。
3. **等待用户确认后才动手实现**，包括写代码、跑测试、提交代码。用户可能会在这一步纠正理解偏差或调整方向，此时按新的理解重新给出复述和计划，而不是直接开始改。

该流程的意义是尽早发现"需求理解错了"或"方向错了"，避免做完一大圈工作后才发现要推倒重来；能省一步确认的简单任务不必生搬硬套。

[README.md](README.md) 面向使用者，讲编译环境准备、编译步骤与支持渠道；本文件面向开发，讲关键设计决策与操作性约束；[docs/rax3000m-optimizations.md](docs/rax3000m-optimizations.md) 是 RAX3000M 定制编译的详细技术记录（组件增删清单、源码改动清单、刷机后配置事项），本文件的"核心设计原则"与"关键设计决策"是对该文档的提炼总结，具体实现细节以该文档为准，两者冲突时以 docs/rax3000m-optimizations.md 为准并同步修订本文件。

[docs/rax3000m-mwan3-failover.md](docs/rax3000m-mwan3-failover.md) 记录本机 mwan3 双 WAN 故障转移的**刷机后运行时配置**（含踩坑结论与自研运维脚本），不参与编译、不影响固件产物；配套脚本与配置副本在 [docs/mwan3/](docs/mwan3/)。改动该目录下的脚本时，须同步更新该文档中对应小节的说明。

## 项目概述

本仓库是 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)（OpenWrt 分支）针对联发科 MT798x 系列芯片（[immortalwrt-mt798x](https://cmi.hanwckf.top/p/immortalwrt-mt798x/)）的固件源码，在此基础上进一步定制为**仅面向 CMCC RAX3000M（MT7981，128M SPI-NAND）单设备**的精简编译分支：移除不需要的 LuCI 组件与依赖以节省固件体积、保留 MediaTek HNAT 转发加速、补齐 USB 4G 上网卡与 ADB 调试支持，并提供一键编译脚本。

- **一键编译**（[build.sh](build.sh)）：更新 feeds → 编译期精简 Argon 登录页资源 → 清理陈旧构建缓存 → 应用 defconfig → 编译，替代 README.md 里的手动多步流程。
- **设备包定制**（[target/linux/mediatek/image/mt7981.mk](target/linux/mediatek/image/mt7981.mk) 的 `Device/cmcc_rax3000m`）：从默认 USB 包组中过滤掉不需要的组件。
- **首次开机定制**（`target/linux/mediatek/base-files/etc/uci-defaults/`）：登录页精简（运行时兜底）、默认 LAN 网段调整，仅在首次开机生效。

当前处于**持续迭代**阶段：跟随上游 immortalwrt-mt798x 同步，按需追加针对 RAX3000M 的定制。

## 核心设计原则（最高优先级）

1. **【MUST】仅面向 CMCC RAX3000M NAND 版单设备编译** —— `defconfig/mt7981-ax3000.config` 只启用 `CONFIG_TARGET_DEVICE_mediatek_mt7981_DEVICE_cmcc_rax3000m=y`，手动编译流程与 `build.sh` 共用同一份 defconfig。新增其他设备（如 RAX3000M eMMC 版、MT7986 系列）需要新增/切换 defconfig 文件，不要往这份 defconfig 里混入其他设备。

2. **【MUST】转发加速统一走 MediaTek HNAT，不与 shortcut-fe 混用** —— `kmod-shortcut-fe`、`kmod-shortcut-fe-cm`、`kmod-fast-classifier` 均不编译；`luci.turboacc` rpcd 后端硬编码 `hasFLOWOFFLOADING=false`。改动转发加速相关配置前，需同时确认这几处不会被重新引入造成冲突。

3. **【MUST】已移除的高体积/低使用率 LuCI 组件不要随意恢复** —— 已移除 `luci-app-usb-printer`、`luci-app-samba4`、`luci-app-eqos-mtk`、`luci-app-upnp` 及其依赖（含 `libfido2`/`libcbor`），详见 [docs/rax3000m-optimizations.md](docs/rax3000m-optimizations.md#1-已移除的组件)。128M NAND 空间有限，新增 LuCI 组件前先评估固件体积影响；确需恢复某项时同步更新该文档的表格。

4. **【MUST】Argon 登录页精简必须编译期与运行时两处保持同步** —— `target/linux/mediatek/base-files/etc/uci-defaults/31_luci-theme-argon-sysauth` 只在可写 overlay 层生效（运行时兜底，不减体积）；真正减小固件体积依赖 `build.sh` 里 `feeds update` 后对 `feeds/luci/themes/luci-theme-argon` 源码的直接删除。改动要删除的文件列表时，两处必须同时改，否则会出现体积未减小或运行时报错的不一致。

5. **【MUST】首次开机定制脚本必须限定设备范围且只在首次生效** —— `32_default-lan-ip` 通过 `board_name` 判断仅对 `cmcc,rax3000m` / `cmcc,rax3000m-emmc` 生效，不影响其他 MT798x 设备；且只应在首次开机（或 `firstboot` 后）写入，不覆盖用户已有配置。新增同类 uci-defaults 脚本须遵循同样的设备判断与幂等约束。

## 通用开发约束

- **【MUST】** 保持代码简洁易懂，避免过度设计和不必要的抽象；不擅自添加用户未要求的功能。
- **【MUST】** 用户提出需求时，先阅读 [README.md](README.md) 和 [docs/rax3000m-optimizations.md](docs/rax3000m-optimizations.md)，理解当前项目目标、架构与实现方式。
- **【MUST】** 功能/架构发生变化后同步更新 README.md、docs/rax3000m-optimizations.md 与本文件，避免文档与代码脱节。
- **【MUST】** 项目特性按用户需求分阶段实现，不需要一次性把文档里列出的所有特性都做完。
- **【MUST】** 处理需求前先查"架构说明"定位到相关模块，用 grep/关键字搜索确认涉及范围，只读取真正相关的文件；不要在不确定范围时就通读整个项目或大量无关文件（本仓库体量巨大，含完整 OpenWrt 构建系统源码树），避免不必要的上下文消耗。
- **【SHOULD】** 查询外部资源时优先参考 OpenWrt/ImmortalWrt 官方文档与 immortalwrt-mt798x 项目页，中文互联网资源仅供参考。

## 代码风格

- **【MUST】** 不在代码注释、日志输出、控制台输出中使用 emoji 表情及特殊符号；README.md 与文档中可以使用。
- **【MUST】** 敏感信息（签名密钥 `key-build*`、token 等）严禁提交到仓库，`.gitignore` 已覆盖 `key-build*`，新增同类文件须同步加入。
- **【MUST】** Makefile / defconfig 改动遵循 OpenWrt buildroot 既有惯例（`Device/xxx` 定义块、`DEVICE_PACKAGES` 追加方式等），不引入与上游风格不一致的写法，便于后续 rebase 上游改动。
- **【SHOULD】** `build.sh` 等 shell 脚本使用 `set -e`，关键步骤前用 `echo "==> ..."` 输出阶段说明，与现有脚本风格保持一致。

## 文档规范

README.md、CLAUDE.md、docs/*.md 及代码注释遵守：

- 只客观描述功能、现状、使用方法与约束，不强调"做了哪些修改/优化"、不解释"为什么这么改"（代码注释、commit message、对话回复同理）；确需长期保留原因的，写进"关键设计决策"这类明确标注为决策记录的章节。
- 篇幅精简，不写长篇大论：一句话能说清楚的不写第二句，不铺垫背景、不重复自证。
- "关键设计决策"只记录当前结论与必要的取舍/风险点，不归因到"业务方拍板/确认"、不写审批日期或人名。
- 使用中文编写，代码块、表格、列表等不同元素之间需要有空行隔开，合理缩进，避免网页渲染时出现问题。
- 全角中文字符与半角英文字符之间，应有一个半角空格；全角中文字符与半角阿拉伯数字之间，有没有半角空格都可，但必须保证风格统一，不能两种风格混杂。

## 架构说明

数据流：`defconfig` → `build.sh`（feeds 更新 + 编译期资源精简）→ `make`（生成固件）→ `uci-defaults`（首次开机定制）。

- **[build.sh](build.sh)** —— 一键编译入口：`feeds update/install` → 删除 `feeds/luci/themes/luci-theme-argon` 下 4 个登录页资源文件 → 清理 `tmp`/`.config.old` → `cp defconfig/mt7981-ax3000.config .config` → `make defconfig` → `make -j$(nproc)`。改一键编译流程看这里。
- **[defconfig/mt7981-ax3000.config](defconfig/mt7981-ax3000.config)** —— RAX3000M NAND 版包选择清单（仅启用 `cmcc_rax3000m` 一个设备）。新增/移除固件包看这里。
- **[target/linux/mediatek/image/mt7981.mk](target/linux/mediatek/image/mt7981.mk)** —— `Device/cmcc_rax3000m`（约 584 行）定义设备镜像参数与 `DEVICE_PACKAGES`；`MT7981_USB_PKGS`（文件头，约第 3 行）是逐设备复用的 USB 包组基线。改设备级别的默认包组（区别于 defconfig 的全局包）看这里。
- **[target/linux/mediatek/base-files/etc/uci-defaults/31_luci-theme-argon-sysauth](target/linux/mediatek/base-files/etc/uci-defaults/31_luci-theme-argon-sysauth)** —— 首次开机删除 Argon 登录页资源文件（运行时兜底，仅对可写 overlay 生效）。
- **[target/linux/mediatek/base-files/etc/uci-defaults/32_default-lan-ip](target/linux/mediatek/base-files/etc/uci-defaults/32_default-lan-ip)** —— 首次开机将 `network.lan.ipaddr` 改为 `192.168.64.1`，按 `board_name` 限定设备范围。改首次开机默认配置看这里，新增同类脚本参考此文件的判断结构。
- **[docs/rax3000m-mwan3-failover.md](docs/rax3000m-mwan3-failover.md) + [docs/mwan3/](docs/mwan3/)** —— mwan3 双 WAN 故障转移（5G 无线中继主线 + USB CPE 备线）的运行时部署记录与自研脚本（`mwan3-check`/`cpe-usb-watchdog` 两个看门狗、`mwan3-cpe-trigger.sh` 事件触发入口、`mwan3-notify*` + `dingtalk-notify.sh` 钉钉告警）。相关软件包由 opkg 刷机后安装，不在 defconfig 中；改运行时联网/告警行为看这里。
- **[docs/rax3000m-optimizations.md](docs/rax3000m-optimizations.md)** —— RAX3000M 定制编译的详细技术记录：已移除组件清单、转发加速现状、ADB 支持细节、刷机后需手动配置的事项、涉及的全部源码改动文件列表。体量不大可整份阅读，但优先按需定位对应小节。

## 关键设计决策

### 1. 仅编译 RAX3000M NAND 版，不含其他设备

`defconfig/mt7981-ax3000.config` 只启用 `cmcc_rax3000m` 一个设备，手动编译（README 步骤）与 `build.sh` 共用同一份 defconfig，均只产出 RAX3000M NAND 版固件。若要支持 RAX3000M eMMC 版或 MT7986 系列，应使用/新增独立的 defconfig 文件，不修改这份单设备 defconfig 的设备范围。

### 2. 转发加速选型：MediaTek HNAT，不使用 shortcut-fe

首次开机由 `luci-app-turboacc-mtk` 的 uci-defaults 自动探测并设为 `mediatek_hnat`。`kmod-shortcut-fe`、`kmod-shortcut-fe-cm`、`kmod-fast-classifier` 均未编译；`luci.turboacc` rpcd 后端硬编码 `hasFLOWOFFLOADING=false`，LuCI 不显示该选项。`mtk_eth_soc.h` 中 `MT7981_CAPS` 只含 `MTK_NETSYS_V2`、不含 `MTK_NETSYS_RX_V2`，ADMA 为官方要求的 v1 回退方案，非本仓库可调整项。

### 3. 移除高体积/低使用率 LuCI 组件与依赖

| 移除项 | 一并移除的依赖 |
|---|---|
| `luci-app-usb-printer` | `p910nd`、`kmod-usb-printer`、中文语言包 |
| `luci-app-samba4` | `samba4-server`、`samba4-libs`（约 8MB）、中文语言包 |
| `luci-app-eqos-mtk` | `tc-tiny`、`tc-mod-iptables`、`kmod-ifb`、`kmod-sched-core` |
| `luci-app-upnp` | `miniupnpd` |
| （无对应 LuCI 页面） | `libfido2`、`libcbor`（FIDO2 硬件密钥支持） |

对应的"网络存储"（USB 打印服务器、Network Shares）、"服务"（网速控制、UPnP）菜单项自动从后台消失。RAX3000M eMMC 版（`Device/cmcc_rax3000m-emmc`）目前仍保留 `luci-app-samba4`，未做同等精简，如需要可参照本设备的方案单独调整。

### 4. Argon 登录页精简：编译期删除才真正减小固件体积

- **运行时**（手动编译路径）：`31_luci-theme-argon-sysauth` 首次开机删除 `sysauth.htm`、`bg1.jpg`、`online_wallpaper`、背景目录 `README.md`。仅在可写 overlay 层生效，不减小固件体积。
- **编译期**（`build.sh` 一键编译路径）：`feeds update` 后直接在 `feeds/luci/themes/luci-theme-argon` 源码里删除同一批文件，squashfs 不再包含，真正减小固件体积（约 160KB）。

两处删除的文件列表必须保持一致，改动其一时同步改另一处。

### 5. 默认 LAN 网段改为 192.168.64.1/24

`32_default-lan-ip` 将 `network.lan.ipaddr` 从 OpenWrt 默认的 `192.168.1.1` 改为 `192.168.64.1`（`/24`）。仅对 `cmcc,rax3000m` / `cmcc,rax3000m-emmc` 生效（通过 `board_name` 判断），不影响其他设备；仅在首次开机（或 `firstboot` 后）生效，已配置过的设备不会被覆盖。

## 配置与凭证约束

- **【MUST】** 固件签名密钥 `key-build`、`key-build.pub`、`key-build.ucert`、`key-build.ucert.revoke` **绝不入库**，`.gitignore` 已通过 `key-build*` 规则覆盖；新增同类密钥文件需确认命名能被该规则匹配，否则显式补充忽略规则。
- **【MUST】** `.gitignore` 已覆盖编译产物与中间状态（`/bin`、`/build_dir`、`/staging_dir`、`/tmp`、`/dl/*`、`/.config`、`/.config.old`、`/feeds` 等），新增此类目录/文件不要误加入版本控制。
- 本仓库不涉及运行时账号密码/API token 类配置，无需环境变量注入机制。

## 运行与部署

一键编译：

```bash
./build.sh
```

手动编译（等价于 README.md 的 Quickstart 步骤 3-8）：

```bash
./scripts/feeds update -a
./scripts/feeds install -a
cp -f defconfig/mt7981-ax3000.config .config
make menuconfig   # 可选，调整配置
make -j$(nproc)
```

编译环境要求（Ubuntu 20.04 LTS、依赖包列表、避坑事项）详见 [README.md](README.md#requirements)。

### 测试与检查

没有配置测试、lint 或类型检查流程。验证方式为实机刷机后手动测试核心功能（无线连接、转发加速、USB 网卡/ADB、LuCI 登录页），刷机后需人工确认的事项见 [docs/rax3000m-optimizations.md 第 6 节](docs/rax3000m-optimizations.md#6-需刷机后手动配置的事项)。

## 实现状态

- **已实现**：RAX3000M NAND 单设备精简编译、一键构建脚本（`build.sh`）、移除臃肿 LuCI 组件、MediaTek HNAT 转发加速、USB 网卡/USB 4G 上网卡驱动、ADB 调试支持、Argon 登录页精简（运行时 + 编译期双路径）、默认 LAN 网段调整为 `192.168.64.1/24`。
- **未覆盖**：`adb-enablemodem`（USB CPE 模式切换）默认未启用，需要时按 [docs/rax3000m-optimizations.md 2.1 节](docs/rax3000m-optimizations.md#21-adb-支持)所述按需加入；RAX3000M eMMC 版尚未做同等组件精简。

## 开发执行检查清单

### 需求确认阶段

- [ ] 已按"需求处理流程"复述需求、给出简要计划，并等到用户确认（琐碎调整除外）

### 编码阶段

- [ ] 是否遵循本文件"核心设计原则"中的约束（单设备编译范围、HNAT 独占、已移除组件不擅自恢复、Argon 精简两处同步、uci-defaults 设备范围与幂等性）
- [ ] `defconfig` / `*.mk` 改动是否遵循 OpenWrt buildroot 既有写法
- [ ] 签名密钥等敏感文件未出现在提交内容中

### 验证阶段

- [ ] `make defconfig` / `make menuconfig` 确认配置项符合预期，无遗留冲突项
- [ ] 实机刷机验证核心流程无异常（如适用）

### 提交阶段

- [ ] 更新 README.md（如编译流程变更）、docs/rax3000m-optimizations.md（如 RAX3000M 定制细节变更）与本文件（如设计原则/约束变更）
- [ ] 提交信息清晰说明改动内容
