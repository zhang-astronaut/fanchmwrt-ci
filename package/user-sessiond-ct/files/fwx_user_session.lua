
module("luci.controller.fwx_user_session", package.seeall)

function index()
    local user_session_node
    entry({"admin", "fwx_monitor"}, firstchild(), _("System Monitor"), 12).dependent = true
    user_session_node = entry({"admin", "fwx_monitor", "user_session"}, template("fwx_user_session/user_session"), _("User Session Count"), 50)
    user_session_node.leaf = true
    user_session_node.dependent = true
    entry({"admin", "user_session_api", "get_session_user_list"}, call("get_session_user_list")).leaf = true
    entry({"admin", "user_session_api", "get_session_history"}, call("get_session_history")).leaf = true
    entry({"admin", "user_session_api", "get_session_detail"}, call("get_session_detail")).leaf = true
end

local HIST_MAX = 1440
local HIST_FILE = "/tmp/user_session_hist.json"
local HIST_SAVE_TS = "/tmp/user_session_hist.saved"
local hist = { t = {}, macs = {} }
local last_sample = 0

local function split_ws(s)
    local t = {}
    for w in s:gmatch("%S+") do t[#t+1] = w end
    return t
end

local function save_hist()
    -- Atomic + serialized: concurrent CGI forks used to interleave writes
    -- and leave one sample per m= line; restore then kept only the last line.
    local lock = io.open(HIST_FILE .. ".lock", "w")
    if lock then lock:write(tostring(os.time())) lock:close() end
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

local function append_hist_points(dst, parts)
    local seen = {}
    for _, p in ipairs(dst) do seen[p.ts] = true end
    for part in parts:gmatch("[^;]+") do
        local ts, tot, tcp, udp, oth = part:match("^(%d+),(%d+),?(%d*),?(%d*),?(%d*)$")
        if ts then
            ts = tonumber(ts)
            if not seen[ts] then
                seen[ts] = true
                dst[#dst+1] = {
                    ts = ts, total = tonumber(tot) or 0,
                    tcp = tonumber(tcp) or 0, udp = tonumber(udp) or 0, other = tonumber(oth) or 0,
                }
            end
        end
    end
    table.sort(dst, function(a, b) return a.ts < b.ts end)
    while #dst > HIST_MAX do table.remove(dst, 1) end
end

local function restore_hist()
    local f = io.open(HIST_FILE, "r")
    if not f then return end
    for line in f:lines() do
        if line:sub(1, 2) == "t=" then
            if #hist.t == 0 then hist.t = {} end
            append_hist_points(hist.t, line:sub(3))
        elseif line:sub(1, 2) == "m=" then
            -- MAC is everything before the first ';' — NOT %S+ (greedy, ate samples)
            local mac, rest = line:sub(3):match("^([^;]+)(.*)$")
            if mac then
                local arr = hist.macs[mac]
                if not arr then arr = {}; hist.macs[mac] = arr end
                append_hist_points(arr, rest)
            end
        end
    end
    f:close()
    if #hist.t > 0 then last_sample = hist.t[#hist.t].ts end
end
restore_hist()

local function read_arp()
    local map = {}
    local f = io.open("/proc/net/arp", "r")
    if not f then return map end
    f:read("*l")
    for line in f:lines() do
        local ip, mac = line:match("(%S+)%s+%S+%s+%S+%s+(%S+)")
        if ip and mac and mac ~= "00:00:00:00:00:00" then
            map[ip] = mac:lower()
        end
    end
    f:close()
    return map
end

local function read_apps()
    -- index by sip|sport|dip|dport (MAC optional; af_active_app is sparse)
    local apps = {}
    local f = io.open("/proc/net/af_active_app", "r")
    if not f then return apps end
    f:read("*l")
    for line in f:lines() do
        local w = split_ws(line)
        if #w >= 10 then
            local appid, mac, sip, sport, dip, dport = w[1], w[2], w[3], w[4], w[5], w[6]
            local host, uri = w[10], w[12]
            if not host or host == "-" or host:match("^%d+%.%d+%.%d+%.%d+$") then
                host = ""
            end
            if not uri or uri == "-" then uri = "" end
            if sip and sport and dip and dport then
                local key = sip .. "|" .. sport .. "|" .. dip .. "|" .. dport
                local name = host
                if name == "" then name = "App " .. (appid or "?") end
                apps[key] = {
                    app_name = name,
                    url = (uri ~= "" and uri) or host,
                    host = host,
                }
            end
        end
    end
    f:close()
    return apps
end

local function parse_sessions(arp, apps)
    local by_mac = {}
    local rows_by_mac = {}
    local f = io.open("/proc/net/nf_conntrack", "r")
    if not f then return by_mac, rows_by_mac end
    for line in f:lines() do
        local proto = "other"
        if line:find(" tcp ", 1, true) then proto = "tcp"
        elseif line:find(" udp ", 1, true) then proto = "udp" end
        local src = line:match("src=([%d%.]+)")
        local dst = line:match("dst=([%d%.]+)")
        local sport = line:match("sport=(%d+)")
        local dport = line:match("dport=(%d+)")
        local bytes1 = tonumber(line:match("bytes=(%d+)")) or 0
        local mac = src and arp[src]
        if mac and dst and sport and dport then
            local s = by_mac[mac]
            if not s then
                s = { session_count=0, tcp_count=0, udp_count=0, other_count=0 }
                by_mac[mac] = s
            end
            s.session_count = s.session_count + 1
            if proto == "tcp" then s.tcp_count = s.tcp_count + 1
            elseif proto == "udp" then s.udp_count = s.udp_count + 1
            else s.other_count = s.other_count + 1 end

            local key = src .. "|" .. sport .. "|" .. dst .. "|" .. dport
            local app = apps[key]
            local rows = rows_by_mac[mac]
            if not rows then rows = {}; rows_by_mac[mac] = rows end
            local app_name, url
            if app and app.host ~= "" then
                app_name = app.host
                url = app.url ~= "" and app.url or app.host
            elseif app then
                app_name = app.app_name
                url = app.url
            else
                -- fallback so column is not empty: show destination
                app_name = "-"
                url = dst .. ":" .. dport
            end
            rows[#rows+1] = {
                src_ip = src, src_port = tonumber(sport),
                dst_ip = dst, dst_port = tonumber(dport),
                protocol = proto:upper(),
                state = line:find("ESTABLISHED", 1, true) and "ESTABLISHED"
                    or (line:find("TIME_WAIT", 1, true) and "TIME_WAIT"
                    or (line:find("SYN_SENT", 1, true) and "SYN_SENT" or "-")),
                up_bytes = bytes1,
                down_bytes = 0,
                app_name = app_name,
                url = url,
            }
        end
    end
    f:close()
    return by_mac, rows_by_mac
end

local SNAP_TTL = 2
local SNAP_FILE = "/tmp/us_snap.tsv"
local last_save = 0
local snap_cache = { ts = 0 }

local function read_dhcp_names()
    local by_mac = {}
    local f = io.open("/tmp/dhcp.leases", "r")
    if not f then return by_mac end
    for line in f:lines() do
        -- exp mac ip hostname clientid
        local exp, mac, ip, host = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mac and ip and host and host ~= "*" then
            by_mac[mac:lower()] = { hostname = host, ip = ip }
        end
    end
    f:close()
    return by_mac
end

local function annotate_users(list)
    local names = read_dhcp_names()
    local arp = read_arp() -- ip -> mac
    local mac_ip = {}
    for ip, mac in pairs(arp) do
        mac_ip[mac] = ip
    end
    for _, u in ipairs(list) do
        local n = names[u.mac]
        u.ip = mac_ip[u.mac] or (n and n.ip) or ""
        u.hostname = (n and n.hostname) or ""
        u.nickname = u.nickname or ""
        if u.nickname ~= "" then
            -- keep nickname for UI
        elseif u.hostname ~= "" then
            -- hostname used by LuCI parseUserDisplayName
        end
    end
    return list
end

local function snapshot_now()
    local arp = read_arp()
    local apps = read_apps()
    local stats, rows = parse_sessions(arp, apps)
    local list = {}
    local seen = {}
    local total_sessions = 0
    for ip, mac in pairs(arp) do
        if not seen[mac] then
            seen[mac] = true
            local s = stats[mac] or { session_count=0, tcp_count=0, udp_count=0, other_count=0 }
            list[#list+1] = {
                mac = mac, hostname = "", nickname = "", ip = ip,
                online = 1,
                session_count = s.session_count,
                tcp_count = s.tcp_count,
                udp_count = s.udp_count,
                other_count = s.other_count,
            }
            total_sessions = total_sessions + s.session_count
        end
    end
    table.sort(list, function(a,b) return a.mac < b.mac end)
    annotate_users(list)
    return list, rows, total_sessions
end

local function load_snap_file()
    local f = io.open(SNAP_FILE, "r")
    if not f then return nil end
    local ts = tonumber(f:read("*l") or "")
    local total = tonumber(f:read("*l") or "")
    if not ts or not total then f:close(); return nil end
    if os.time() - ts >= SNAP_TTL then f:close(); return nil end
    local list = {}
    for line in f:lines() do
        local mac, sc, tc, uc, oc = line:match("^(%S+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)$")
        if mac then
            list[#list+1] = {
                mac = mac, hostname = "", nickname = "", online = 1,
                session_count = tonumber(sc) or 0,
                tcp_count = tonumber(tc) or 0,
                udp_count = tonumber(uc) or 0,
                other_count = tonumber(oc) or 0,
            }
        end
    end
    f:close()
    return ts, list, total
end

local function save_snap_file(list, total)
    local f = io.open(SNAP_FILE, "w")
    if not f then return end
    f:write(os.time(), "\n", total, "\n")
    for _, u in ipairs(list) do
        f:write(u.mac, "\t", u.session_count, "\t", u.tcp_count, "\t", u.udp_count, "\t", u.other_count, "\n")
    end
    f:close()
end

-- 2s cache across requests (uhttpd may fork per XHR — file fallback).
-- list/total: cached; rows: only built when caller needs detail.
local function snapshot_list()
    local t = os.time()
    if snap_cache.ts ~= 0 and (t - snap_cache.ts) < SNAP_TTL and snap_cache.list then
        return snap_cache.list, snap_cache.total
    end
    local fts, flist, ftotal = load_snap_file()
    if fts and flist then
        snap_cache.ts = fts
        snap_cache.list = flist
        snap_cache.total = ftotal
        return flist, ftotal
    end
    local list, rows, total = snapshot_now()
    snap_cache.ts = t
    snap_cache.list = list
    snap_cache.rows = rows
    snap_cache.total = total
    save_snap_file(list, total)
    return list, total
end

local function snapshot_rows()
    local _list, rows, _total = snapshot_now()
    return rows
end

local function snapshot()
    local list, total = snapshot_list()
    local rows = snap_cache.rows
    if not rows then
        rows = snapshot_rows()
        snap_cache.rows = rows
    end
    return list, rows, total
end

-- LuCI must NOT write hist: CGI memory is often stale/nearly empty and
-- used to overwrite the sampler file → chart collapsed to 1 point.
local function reload_hist_from_file()
    hist.t = {}
    hist.macs = {}
    local f = io.open(HIST_FILE, "r")
    if not f then return end
    for line in f:lines() do
        if line:sub(1, 2) == "t=" then
            append_hist_points(hist.t, line:sub(3))
        elseif line:sub(1, 2) == "m=" then
            local mac, rest = line:sub(3):match("^([^;]+)(.*)$")
            if mac then
                local arr = hist.macs[mac]
                if not arr then arr = {}; hist.macs[mac] = arr end
                append_hist_points(arr, rest)
            end
        end
    end
    f:close()
end

local function sample_history(total, list)
    -- no-op for disk: sampler owns the file. Keep signature for callers.
    return
end

-- Bucket-average samples inside the time window by step_sec.
-- Without bucketing, 5min and 1h return the same compact list when
-- total history is shorter than 1 hour.
local function series_from_window(src, window_sec, points, step_sec)
    local now = os.time()
    step_sec = step_sec or 60
    local buckets = {} -- key = absolute bucket id
    local order = {}
    for _, p in ipairs(src) do
        local age = now - (p.ts or 0)
        if age >= 0 and age <= window_sec then
            local bid = math.floor((p.ts or 0) / step_sec)
            local b = buckets[bid]
            if not b then
                b = { n = 0, total = 0, tcp = 0, udp = 0, other = 0, bid = bid }
                buckets[bid] = b
                order[#order+1] = bid
            end
            b.n = b.n + 1
            b.total = b.total + (p.total or 0)
            b.tcp = b.tcp + (p.tcp or 0)
            b.udp = b.udp + (p.udp or 0)
            b.other = b.other + (p.other or 0)
        end
    end
    table.sort(order)
    local out = { list = {}, tcp_list = {}, udp_list = {}, other_list = {} }
    local sum, peak, cur = 0, 0, 0
    local cnt = 0
    local start = math.max(1, #order - points + 1)
    for i = start, #order do
        local b = buckets[order[i]]
        local v = math.floor(b.total / b.n)
        local tv = math.floor(b.tcp / b.n)
        local uv = math.floor(b.udp / b.n)
        local ov = math.floor(b.other / b.n)
        out.list[#out.list+1] = v
        out.tcp_list[#out.tcp_list+1] = tv
        out.udp_list[#out.udp_list+1] = uv
        out.other_list[#out.other_list+1] = ov
        sum = sum + v
        if v > peak then peak = v end
        cur = v
        cnt = cnt + 1
    end
    if cnt == 0 then
        out.list = {0}; out.tcp_list={0}; out.udp_list={0}; out.other_list={0}
    end
    return out, cur, (cnt > 0 and math.floor(sum / cnt) or 0), peak
end

local function series_for(mac, range, step, cur_user)
    local window_sec, points, step_sec
    if range == 1 then
        window_sec, points, step_sec = 300, 60, 5
    elseif range == 3 then
        window_sec, points, step_sec = 86400, 1440, 60
    else
        window_sec, points, step_sec = 3600, 60, 60
    end

    local src = {}
    if mac and hist.macs[mac] then
        src = hist.macs[mac]
    end

    local out, cur, avg, peak = series_from_window(src, window_sec, points, step_sec)
    if cur_user then
        if #out.list <= 1 and (out.list[1] or 0) == 0 then
            local c = cur_user.session_count or 0
            out = { list = {c}, tcp_list = {cur_user.tcp_count or 0},
                    udp_list = {cur_user.udp_count or 0}, other_list = {cur_user.other_count or 0} }
            cur, avg, peak = c, c, c
        end
    end
    return out, cur, avg, peak
end

function get_session_user_list()
    luci.http.prepare_content("application/json")
    local list, total = snapshot_list()
    annotate_users(list)
    sample_history(total, list)
    luci.http.write_json({ total_num = #list, list = list })
end

function get_session_detail()
    local mac = (luci.http.formvalue("mac") or ""):lower()
    local page = tonumber(luci.http.formvalue("page") or "1") or 1
    local page_size = tonumber(luci.http.formvalue("page_size") or "20") or 20
    if page < 1 then page = 1 end
    if page_size < 1 then page_size = 20 elseif page_size > 200 then page_size = 200 end
    luci.http.prepare_content("application/json")
    local list, rows, total_all = snapshot()
    sample_history(total_all, list)
    local all = rows[mac] or {}
    local total = #all
    local total_page = math.max(1, math.ceil(total / page_size))
    local out = {}
    local start = (page - 1) * page_size
    for i = start + 1, math.min(total, start + page_size) do
        local r = all[i]
        out[#out+1] = {
            mac = mac,
            src_ip = r.src_ip, src_port = r.src_port,
            dst_ip = r.dst_ip, dst_port = r.dst_port,
            protocol = r.protocol,
            state = r.state,
            up_bytes = r.up_bytes, down_bytes = r.down_bytes,
            app_name = r.app_name, url = r.url,
            timeout = 0,
        }
    end
    luci.http.write_json({
        total_num = total, page = page, page_size = page_size,
        total_page = total_page, list = out,
    })
end

function get_session_history()
    local mac = (luci.http.formvalue("mac") or ""):lower()
    local range = tonumber(luci.http.formvalue("range") or "2") or 2
    if range ~= 1 and range ~= 2 and range ~= 3 then range = 2 end
    luci.http.prepare_content("application/json")

    -- Always read sampler-owned hist file (fresh).
    reload_hist_from_file()

    local list = snapshot_list()
    list = annotate_users(list)
    local step = (range == 1) and 5 or 60
    local cur_user = nil
    local online = 0
    for _, u in ipairs(list) do
        if u.mac == mac then
            online = 1
            cur_user = u
            break
        end
    end
    local ser, cur, avg, peak = series_for(mac, range, step, cur_user)
    local hostname = cur_user and cur_user.hostname or ""
    luci.http.write_json({
        mac = mac, hostname = hostname, online = online,
        range = range, step_sec = step,
        current = cur, avg = avg, peak = peak,
        list = ser.list,
        tcp_list = ser.tcp_list,
        udp_list = ser.udp_list,
        other_list = ser.other_list,
    })
end
