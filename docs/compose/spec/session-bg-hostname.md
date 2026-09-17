---
feature: session-bg-hostname
status: delivered
updated: 2026-09-17
branch: feat/session-bg-hostname
commits: dfc59b3..2de777b
---

# Session Stats: Background Sampling + Friendly User Labels

## Report

**What was built** — 后台采样守护（Lua+procd，每 5s）在不打开 LuCI 时持续写 hist；用户列表增加 dhcp.leases 主机名与 IP（LuCI 已支持 hostname 显示）。保留 per-MAC、时间窗、分桶、MAC 解析等已修逻辑。

**Verification** — 路由器上 sampler 进程在跑；hist 体积增长且含连续 5s 时间戳；dhcp.leases 有 LAPTOP/iPad/DESKTOP 等主机名。

**Journey log** — 页面打开才采样会导致曲线从零开始；UI 已能显示 hostname，只需后端填充；不改 value=mac 契约。

## [S1] Problem

1. 用户会话历史 **只在打开 LuCI 页面时** 采样；关页后再开，曲线从空开始。
2. 用户下拉框只显示 MAC，难以辨认设备。

## [S2] Design

### 后台采样

- 常驻 `user-sessiond-ct`（已有 5s timer）负责 ubus 历史。
- 另加 **采样守护**（Lua + procd）每 5s：
  - 读 `/proc/net/arp` + `/proc/net/nf_conntrack`
  - 按 MAC 累加会话数
  - **原子写入** `/tmp/user_session_hist.json`（与 LuCI 同格式，merge+去重）
- LuCI 打开时继续读同一文件；**不依赖页面轮询**。
- 保留：per-MAC 曲线、时间窗、5min/1h 分桶、MAC 解析 `^([^;]+)`、不回退全局曲线。

### 友好用户名

用户列表字段：

| 字段 | 来源 |
|---|---|
| `mac` | ARP |
| `ip` | ARP |
| `hostname` | `/tmp/dhcp.leases`（按 MAC）或 `/tmp/hosts` |
| `nickname` | uci `user_info`（若无则空） |
| `label` | `hostname (ip) [mac]` 或退化为 `ip [mac]` / `mac` |

LuCI 下拉框优先显示 `label`，value 仍为 `mac`（接口契约不变）。

### 不回归

- 不把 hist 路径改到 `/overlay`
- 不杀 UA3F/PassWall/fwxd
- PassWall `redirect` 红线不变

## [S3] Out of Scope

- 不改全局会话页
- 不做跨重启的磁盘持久化（仍在 tmpfs）
- 不改 UA3F/PassWall/MT7922

## Tasks

- [ ] T1: 采样守护 + init 写入 hist — acceptance: 关页 30s 后 hist mts/点数仍增长 (covers: S2)
- [ ] T2: 列表返回 hostname/ip/label — acceptance: 下拉非纯 MAC (covers: S2)
- [ ] T3: 回归历史逻辑 — acceptance: 按用户不同；5min≠1h 分桶仍在 (covers: S1)
