---
feature: monitor-io-opt
status: in-progress
updated: 2026-09-16
branch: feat/monitor-io-opt
commits: 
---

# Monitor I/O Optimization

## Report

## [S1] Problem

FanchmWrt 监控链路在 LuCI 轮询时存在重复读写：

- 每次 `get_session_user_list` / `get_session_history` / `get_session_detail` 都完整读 `/proc/net/nf_conntrack`（约 3000+ 行）+ ARP + `af_active_app`。
- 热补丁 Lua 每 5s 采样后 **整文件重写** `/tmp/user_session_hist.json`（约 300KB）。
- 闭源 `user_sessiond` 仍常驻，读空的 `fwx_user`，属于无效工作。

硬件侧：`/tmp` 为 **tmpfs**，反复写不磨损 eMMC/SSD；根分区 ext4、盘 `rotational=0`。当前 CPU 空闲，压力主要是 **重复解析 conntrack 的 CPU** 与 **tmpfs 写放大**，不是闪存寿命。

## [S2] Design

### 缓存

- 对 conntrack+ARP+apps 的解析结果做 **2 秒进程内缓存**（LuCI 模块内 / C 守护内）。
- 同一缓存窗口内的多次 XHR 共用一份快照。

### 历史

- 采样间隔保持 **5s**（与 5min tab 对齐）。
- 序列只存内存环形（`HIST_MAX=1440`）。
- 落盘降频：**最多每 30s 写一次** `/tmp/user_session_hist.json`（tmpfs，可选保留，便于 uhttpd 重启恢复）。
- 不把 hist 路径改到 `/overlay` 或 `/`。

### 无效进程

- `user-sessiond-ct` init：覆盖 `/fwx_root/usr/bin/user_sessiond` 后仍 procd 可拉起我们的二进制。
- 可选：若 stock `user_sessiond` 仅读 `/proc/net/fwx_user` 且表为空，不额外杀；避免与应用中心冲突。
- 不主动 `killall fwxd` / UA3F。

### 契约（对外 API 不变）

- ubus/LuCI JSON 字段与现网一致：`list` / `tcp_list` / `udp_list` / `other_list`、`session_count` 等。
- `step_sec`：range1=5，range2/3=60；点数：60 / 60 / 1440。

## [S3] Out of Scope

- 不改 UA3F / PassWall / Docker。
- 不重写 `fwx.ko` / 闭源 `fwx_user.ko`。
- 不做跨重启的 24h 全分辨率持久化。
- 不关闭 LuCI 页面自动刷新（仅降后端重复解析）。

## Tasks

- [ ] T1: Lua 热补丁增加 2s 快照缓存 + 30s 落盘降频 — acceptance: 3s 内连续 XHR 只解析一次 conntrack；hist mtime 间隔 ≥30s (covers: S2)
- [ ] T2: user-sessiond-ct 增加 2s 快照缓存，采样仍 5s，无每请求落盘 — acceptance: 源码含 cache TTL；编译通过 (covers: S2; depends: T1)
- [ ] T3: 部署 Lua 到路由器并确认 CPU/读次数下降 — acceptance: 页面仍显示会话；hist 不再每 5s 全量重写 (covers: S1,S2; depends: T1)
