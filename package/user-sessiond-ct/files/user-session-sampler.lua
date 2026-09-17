-- user-session-sampler.lua
-- Background per-MAC session sampler for FanchmWrt.
-- Writes the same hist format LuCI reads. Atomic + merge on restore.
local HIST_FILE = "/tmp/user_session_hist.json"
local HIST_MAX = 1440
local HOSTS_LEASES = "/tmp/dhcp.leases"
local HOSTS_FILE = "/tmp/hosts"

local function mac_norm(m)
  return (m or ""):lower()
end

local function read_arp_ip_mac()
  local by_mac, by_ip = {}, {}
  local f = io.open("/proc/net/arp", "r")
  if not f then return by_mac, by_ip end
  f:read("*l")
  for line in f:lines() do
    local ip, _hw, fl, mac = line:match("(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
    if ip and mac and mac ~= "00:00:00:00:00:00" then
      if tonumber(fl, 16) and (tonumber(fl, 16) % 2 == 1) then
        mac = mac_norm(mac)
        by_mac[mac] = ip
        by_ip[ip] = mac
      end
    end
  end
  f:close()
  return by_mac, by_ip
end

local function count_sessions(by_ip_mac)
  local by_mac = {}
  local f = io.open("/proc/net/nf_conntrack", "r")
  if not f then return by_mac end
  for line in f:lines() do
    local src = line:match("src=([%d%.]+)")
    local mac = src and by_ip_mac[src]
    if mac then
      local s = by_mac[mac]
      if not s then
        s = { total = 0, tcp = 0, udp = 0, other = 0 }
        by_mac[mac] = s
      end
      s.total = s.total + 1
      if line:find(" tcp ", 1, true) then s.tcp = s.tcp + 1
      elseif line:find(" udp ", 1, true) then s.udp = s.udp + 1
      else s.other = s.other + 1 end
    end
  end
  f:close()
  return by_mac
end

local function append_points(dst, parts)
  local seen = {}
  for _, p in ipairs(dst) do seen[p.ts] = true end
  for part in parts:gmatch("[^;]+") do
    local ts, tot, tcp, udp, oth = part:match("^(%d+),(%d+),?(%d*),?(%d*),?(%d*)$")
    if ts then
      ts = tonumber(ts)
      if not seen[ts] then
        seen[ts] = true
        dst[#dst + 1] = {
          ts = ts, total = tonumber(tot) or 0,
          tcp = tonumber(tcp) or 0, udp = tonumber(udp) or 0, other = tonumber(oth) or 0,
        }
      end
    end
  end
  table.sort(dst, function(a, b) return a.ts < b.ts end)
  while #dst > HIST_MAX do table.remove(dst, 1) end
end

local function restore()
  local hist = { t = {}, macs = {} }
  local f = io.open(HIST_FILE, "r")
  if not f then return hist end
  for line in f:lines() do
    if line:sub(1, 2) == "t=" then
      append_points(hist.t, line:sub(3))
    elseif line:sub(1, 2) == "m=" then
      local mac, rest = line:sub(3):match("^([^;]+)(.*)$")
      if mac then
        local arr = hist.macs[mac]
        if not arr then arr = {}; hist.macs[mac] = arr end
        append_points(arr, rest)
      end
    end
  end
  f:close()
  return hist
end

local function save(hist)
  local tmp = HIST_FILE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write("t=")
  for i, p in ipairs(hist.t) do
    if i > 1 then f:write(";") end
    f:write(string.format("%d,%d,%d,%d,%d", p.ts, p.total, p.tcp or 0, p.udp or 0, p.other or 0))
  end
  f:write("\n")
  for mac, arr in pairs(hist.macs) do
    f:write("m=" .. mac)
    for i, p in ipairs(arr) do
      f:write(string.format(";%d,%d,%d,%d,%d", p.ts, p.total, p.tcp or 0, p.udp or 0, p.other or 0))
    end
    f:write("\n")
  end
  f:close()
  os.remove(HIST_FILE)
  os.rename(tmp, HIST_FILE)
end

local function main()
  local by_mac, by_ip = read_arp_ip_mac()
  local stats = count_sessions(by_ip)
  local hist = restore()
  local t = os.time()
  local tt, tu, to = 0, 0, 0
  for mac, s in pairs(stats) do
    tt = tt + s.tcp
    tu = tu + s.udp
    to = to + s.other
    local arr = hist.macs[mac]
    if not arr then arr = {}; hist.macs[mac] = arr end
    append_points(arr, string.format(";%d,%d,%d,%d,%d", t, s.total, s.tcp, s.udp, s.other))
  end
  local total = 0
  for _, s in pairs(stats) do total = total + s.total end
  append_points(hist.t, string.format(";%d,%d,%d,%d,%d", t, total, tt, tu, to))
  save(hist)
end

main()
