---
feature: session-hist-per-user-window
status: designed
updated: 2026-09-17
branch: fix/session-hist-per-user-window
commits:
---

# Session History: Per-User + Time Window

## Report

## [S1] Problem

1. 选择不同用户时历史曲线完全一样。
2. 「最近5分钟」与「最近1小时」曲线一模一样。

根因：
- `series_for` 在 `hist.macs[mac]` 为空时 **回退到全局 `hist.t`**，所有用户共用全网曲线。
- `resample` 只取「最近 N 个采样」，**不按时间窗过滤**；5min/1h 都是 last 60 点，数据不足时输出相同。

## [S2] Design

### Per-user

- 用户曲线 **只** 使用 `hist.macs[mac]`。
- 无该 MAC 历史时：`list` 为当前值或空序列，**绝不** 使用 `hist.t`。
- 全局 `hist.t` 仅用于「全局会话」页面（本改动不涉及）。

### Time window

| range | 窗口 | 最多点数 |
|---|---|---|
| 1 | 300s | 60 |
| 2 | 3600s | 60 |
| 3 | 86400s | 1440 |

流程：按 `ts` 过滤窗口内样本 → 截取最近 `points` 个 → 输出 compact 序列（不补 5s 零桶）。

### C daemon

- `hist_point` 增加 `ts`。
- `hist_fill` / `hist_avg_peak` 按 range 窗口过滤后再截断。
- ubus `get_session_history` 继续按 mac 查 ring；Lua 仅在 ubus 返回非空 list 时采用。

## [S3] Out of Scope

- 不改全局会话统计页。
- 不改 UA3F/PassWall。
- 不做 24h 全分辨率持久化（仅内存 ring）。

## Tasks

- [ ] T1: Lua series_for 仅 per-mac + 时间窗 — acceptance: 两 MAC 曲线可不同；5min⊂1h 窗口 (covers: S2)
- [ ] T2: C hist_point.ts + 窗口过滤 — acceptance: 源码含 ts 与 window_sec (covers: S2; depends: T1)
- [ ] T3: 热部署 Lua 并在设备上对比两用户/两 range — acceptance: JSON list 不同或 5min 为 1h 子集 (covers: S1,S2; depends: T1)
