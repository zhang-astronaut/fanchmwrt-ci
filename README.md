# FanchmWrt x86/64 自动编译固件

基于 [fanchmwrt/fanchmwrt](https://github.com/fanchmwrt/fanchmwrt) 上游源码，自动检测上游更新并编译定制固件。

## 定制内容

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
