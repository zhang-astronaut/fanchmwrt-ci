# FanchmWrt x86/64 自动编译固件

基于 [fanchmwrt/fanchmwrt](https://github.com/fanchmwrt/fanchmwrt) 上游源码，自动检测上游更新并编译定制固件。

## 定制内容

- **UA3F（内置）**：直接内置 UA3F 主程序 + LuCI 管理界面（源码取自官方仓库 master），
  并应用**开机竞态修复**——原版 init 脚本 procd respawn 默认只重试 5 次，
  开机时 WAN 默认路由未就绪会导致 BPF TC 初始化失败连崩 6 次后被 procd 永久放弃
  （校园网看到裸 UA 导致封禁的根因）。修复为无限重试，路由就绪后自动恢复。
- **PassWall2（内置）**：luci-app-passwall2 + 中文语言包 + xray-core / sing-box 双核心，
  开箱即用（feed 取自 [Openwrt-Passwall](https://github.com/Openwrt-Passwall)）。
- **UA3F 全套依赖**：kmod-ipt-nfqueue、kmod-nfnetlink-queue、iptables-mod-nfqueue、
  kmod-ipt-tproxy/ipopt/conntrack-extra（+对应 iptables-mod-*）、iptables-mod-extra、
  ipset、kmod-ipt-ipset、kmod-nf-conntrack-netlink、kmod-nft-queue/nft-socket/nft-tproxy、
  kmod-sched-bpf + kmod-sched-core（eBPF 卸载）、luci-compat
- **fwx 流量统计修复补丁**（`fwx-tproxy-stat.patch`）：修复 TPROXY 类代理
  （UA3F/Passwall 等）下 dashboard 用户流量统计严重偏低的问题——
  原版统计 hook 挂在 FORWARD 链，TPROXY 流量绕过 FORWARD 导致漏计；
  补丁将上行/下行统计点挪到 PRE_ROUTING/POST_ROUTING 并修正出接口匹配。
- **Docker 支持**：docker、dockerd、docker-compose、luci-app-dockerman（含中文）
- **FanchmWrt 原生应用中心**：luci-app-fwx-app-center（含中文）
- **rootfs 4G**（首次开机自动扩容到整盘）

## UA3F 与 PassWall2 共存说明（重要）

两者可以同时运行，数据流为：`LAN 客户端 → UA3F(TPROXY 改写 UA) → PassWall2(加密出口)`。
已验证的共存要点：

1. **PassWall2 的 TCP 代理方式保持默认 `redirect`**，不要改成 `tproxy`——
   会与 UA3F 的 TPROXY 在 mangle/PREROUTING 抢包。
2. 端口无冲突（UA3F 监听 1080 / PassWall2 SOCKS 1070）。
3. 启动顺序无冲突（同为 S99，PassWall2 自带 60s 延迟，UA3F 无限 respawn 兜底）。
4. `localhost_proxy` 开启时 PassWall2 会接管 UA3F 的出站流量——这是预期行为
   （改写完 UA 再走节点加密出口），但节点故障时会影响 UA3F 出站，排查时注意。

## 文件说明

| 文件 | 说明 |
|---|---|
| `fanchmwrt.config` | 完整编译配置（上述定制已全部勾选） |
| `fwx-tproxy-stat.patch` | fwx 流量统计 TPROXY 兼容补丁 |
| `.github/workflows/build.yml` | 自动编译工作流 |

## 自动编译机制

工作流每 6 小时检查一次上游（`fanchmwrt/fanchmwrt`）的最新提交：

1. 对比上游 HEAD 与最近一次成功编译的提交（记录在仓库 tag 中）
2. 有更新 → 拉取源码 → 打补丁 → 按 `fanchmwrt.config` 编译
3. 产物（squashfs/ext4 × UEFI/BIOS 四种 combined 镜像）上传为 Release
4. 无更新 → 跳过（约 1 分钟）

也可在 Actions 页面手动触发（workflow_dispatch）。

## 镜像选择

- UEFI 启动：`openwrt-x86-64-generic-squashfs-combined-efi.img.gz`（推荐，可恢复出厂）
- 老式 BIOS：不带 `-efi` 的 combined
- ext4 版方便手动折腾分区

首次开机 rootfs 会自动扩容到整盘（>300MB 触发）。
