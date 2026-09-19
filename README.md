# FanchmWrt x86/64 自动编译固件

基于 [fanchmwrt/fanchmwrt](https://github.com/fanchmwrt/fanchmwrt) 上游源码，自动检测上游更新并编译定制固件。

## 定制内容

### 代理 / 校园网

- **UA3F（内置）**：主程序 + LuCI；含**开机竞态修复**——原版 procd respawn 只重试 5 次，
  WAN 默认路由未就绪时 BPF TC 失败后被永久放弃（校园网裸 UA 封禁根因）。
  已改为 `respawn 3600 5 0`（无限重试），路由就绪后自动恢复。
- **PassWall（内置，非 PassWall2）**：`luci-app-passwall` + 中文包 + xray-core / sing-box 双核心
  （feed：[Openwrt-Passwall/openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)）。
- **SRunPy 校园网自动登录**：`srunpy` + `luci-app-srunpy` + `python3-requests`
  （[HofNature/SRunPy-OpenWRT](https://github.com/HofNature/SRunPy-OpenWRT)）；
  Release 会附带上游 apk/ipk，便于其它机器侧载。
- **EasyTier**：`easytier` + `luci-app-easytier`（feed：[EasyTier/luci-app-easytier](https://github.com/EasyTier/luci-app-easytier)）。

### 无线驱动

- **MT7922 USB**：`kmod-mt7921u` + `kmod-mt7922-firmware` + `wpad-basic-mbedtls`
- **MT7921 PCIe（客人机/VM）**：`kmod-mt7921e` + `kmod-mt7921-firmware`
- **其它常用无线**：`kmod-iwlwifi`（ax200/ax201 等固件）、`kmod-ath9k` / `kmod-ath10k`、
  `kmod-rtw88-8822ce`、`kmod-rtw89-8852ae` 等（按 CI 断言清单为准）

### 监控 / 系统

- **用户会话统计（TPROXY 兼容）**：`user-sessiond-ct` 用 conntrack+ARP 聚合每 MAC 会话数；
  后台采样 + 主机名（dhcp.leases）；UA3F TPROXY 下闭源 `fwx_user.ko` 会话表为空时可正常出数。
- **fwx 流量统计 TPROXY 补丁**（`fwx-tproxy-stat.patch`）：统计点从 FORWARD 改到
  PRE_ROUTING/POST_ROUTING，避免 TPROXY 流量漏计。
- **Docker**：docker / dockerd / docker-compose + luci-app-dockerman（中文）
- **SFTP**：`openssh-sftp-server` + Dropbear SFTP
- **FanchmWrt 应用中心**：`luci-app-fwx-app-center`（中文）
- **rootfs 4G**：首次开机自动扩容到整盘
- **UA3F 依赖**：nfqueue / tproxy / ipset / kmod-sched-bpf 等全套

## UA3F 与 PassWall 共存（重要）

数据流：`LAN → UA3F(TPROXY 改写 UA) → PassWall(redirect 加密出口) → WAN`

1. **PassWall 的 TCP 代理方式保持 `redirect`**，不要改成 `tproxy`（与 UA3F 抢 mangle/PREROUTING）。
2. 端口勿与 UA3F `1080` 重叠（PassWall SOCKS 端口见 LuCI）。
3. 启动同为 S99，PassWall 有延迟，UA3F 无限 respawn 兜底。
4. 本机代理开启时 PassWall 会接管 UA3F 出站——预期行为；节点故障会影响 UA 改写出站。

## 文件说明

| 文件 | 说明 |
|---|---|
| `fanchmwrt.config` | 完整编译配置（定制包已勾选） |
| `fwx-tproxy-stat.patch` | fwx 流量统计 TPROXY 补丁 |
| `.github/workflows/build.yml` | 自动编译 + defconfig 断言 |
| `package/user-sessiond-ct/` | 会话统计守护 / LuCI 控制器 / 采样脚本 |
| `package/srunpy/`、`package/luci-app-srunpy/` | 校园网登录（OpenWrt 包封装） |
| `docs/compose/spec/` | compose-next 设计与交付记录 |

## 自动编译机制

1. 每 6 小时检查上游 `fanchmwrt/fanchmwrt` 是否有新提交
2. push / workflow_dispatch 一律编译；定时任务仅在上游变更时编译
3. `defconfig` 后对 REQUIRED 包做**断言**，丢失则立即失败（防“CI 绿但包没进镜像”）
4. 产物：squashfs/ext4 × UEFI/BIOS 镜像 + manifest + sha256 + SRunPy 附件 → GitHub Release

## 镜像选择

- UEFI：`openwrt-x86-64-generic-squashfs-combined-efi.img.gz`（推荐）
- 老式 BIOS：不带 `-efi` 的 combined
- ext4 便于手动改分区

首次开机 rootfs 自动扩容到整盘。

## 刷机后快速自检（摘要）

```sh
pgrep ua3f
curl -s -A 'Chrome/120' http://httpbin.org/user-agent   # 期望 "FFF"
uci get passwall.@global_forwarding[0].tcp_proxy_way    # 期望 redirect
apk list --installed | grep -E 'passwall|mt7921e|easytier|sftp|user-sessiond|srunpy'
lsmod | grep -E 'mt7921|ath9k|iwlwifi|rtw'
```

PassWall 需在 LuCI 中自行启用并配置节点；TCP 方式务必保持 **redirect**。
