
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
    local f = io.open(HIST_FILE, "w")
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
end

local function restore_hist()
    local f = io.open(HIST_FILE, "r")
    if not f then return end
    for line in f:lines() do
        if line:sub(1, 2) == "t=" then
            hist.t = {}
            for part in line:sub(3):gmatch("[^;]+") do
                local ts, tot, tcp, udp, oth = part:match("^(%d+),(%d+),?(%d*),?(%d*),?(%d*)$")
                if ts then
                    hist.t[#hist.t+1] = {
                        ts = tonumber(ts), total = tonumber(tot) or 0,
                        tcp = tonumber(tcp) or 0, udp = tonumber(udp) or 0, other = tonumber(oth) or 0,
                    }
                end
            end
        elseif line:sub(1, 2) == "m=" then
            local mac, rest = line:sub(3):match("^(%S+)(.*)$")
            if mac then
                local arr = {}
                for part in rest:gmatch(";([^;]+)") do
                    local ts, tot, tcp, udp, oth = part:match("^(%d+),(%d+),(%d+),(%d+),(%d+)$")
                    if ts then
                        arr[#arr+1] = {
                            ts = tonumber(ts), total = tonumber(tot) or 0,
                            tcp = tonumber(tcp) or 0, udp = tonumber(udp) or 0, other = tonumber(oth) or 0,
                        }
                    end
                end
                hist.macs[mac] = arr
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

local function snapshot_now()
    local arp = read_arp()
    local apps = read_apps()
    local stats, rows = parse_sessions(arp, apps)
    local list = {}
    local seen = {}
    local total_sessions = 0
    for _ip, mac in pairs(arp) do
        if not seen[mac] then
            seen[mac] = true
            local s = stats[mac] or { session_count=0, tcp_count=0, udp_count=0, other_count=0 }
            list[#list+1] = {
                mac = mac, hostname = "", nickname = "",
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

local function sample_history(total, list)
    local t = os.time()
    if t - last_sample < 5 then return end
    last_sample = t
    local tt, tu, to = 0, 0, 0
    for _, u in ipairs(list) do
        tt = tt + u.tcp_count
        tu = tu + u.udp_count
        to = to + u.other_count
        local h = hist.macs[u.mac]
        if not h then h = {}; hist.macs[u.mac] = h end
        h[#h+1] = {
            ts = t, total = u.session_count,
            tcp = u.tcp_count, udp = u.udp_count, other = u.other_count,
        }
        if #h > HIST_MAX then table.remove(h, 1) end
    end
    hist.t[#hist.t+1] = { ts = t, total = total, tcp = tt, udp = tu, other = to }
    if #hist.t > HIST_MAX then table.remove(hist.t, 1) end
    -- Throttle across CGI forks via sidecar timestamp
    local last_ts = last_save
    local sf = io.open(HIST_SAVE_TS, "r")
    if sf then
        last_ts = math.max(last_ts, tonumber(sf:read("*l") or "0") or 0)
        sf:close()
    end
    if t - last_ts >= 30 then
        last_save = t
        save_hist()
        local sf2 = io.open(HIST_SAVE_TS, "w")
        if sf2 then sf2:write(tostring(t)) sf2:close() end
    end
end

-- Resample into fixed time buckets matching LuCI getWindowPointCount/step.
-- range 1: 60 x 5s = 5min; range 2: 60 x 60s = 1h; range 3: 1440 x 60s = 24h
local function resample(src, points, step_sec)
    local now = os.time()
    local out = { list = {}, tcp_list = {}, udp_list = {}, other_list = {} }
    local acc = {}
    for i = 1, points do
        acc[i] = { n = 0, total = 0, tcp = 0, udp = 0, other = 0 }
    end
    for _, p in ipairs(src) do
        local age = now - (p.ts or 0)
        if age >= 0 and age < points * step_sec then
            local from_end = math.floor(age / step_sec) -- 0 = newest bucket
            local idx = points - from_end
            if idx >= 1 and idx <= points then
                local b = acc[idx]
                b.n = b.n + 1
                b.total = b.total + (p.total or 0)
                b.tcp = b.tcp + (p.tcp or 0)
                b.udp = b.udp + (p.udp or 0)
                b.other = b.other + (p.other or 0)
            end
        end
    end
    local sum, peak, cur = 0, 0, 0
    local cnt = 0
    for i = 1, points do
        local b = acc[i]
        local v, tv, uv, ov
        if b.n > 0 then
            v = math.floor(b.total / b.n)
            tv = math.floor(b.tcp / b.n)
            uv = math.floor(b.udp / b.n)
            ov = math.floor(b.other / b.n)
        else
            v, tv, uv, ov = 0, 0, 0, 0
        end
        out.list[i] = v
        out.tcp_list[i] = tv
        out.udp_list[i] = uv
        out.other_list[i] = ov
        if b.n > 0 then
            sum = sum + v
            if v > peak then peak = v end
            cur = v
            cnt = cnt + 1
        end
    end
    return out, cur, (cnt > 0 and math.floor(sum / cnt) or 0), peak
end

local function series_for(mac, range, step, cur_user)
    local points, step_sec
    if range == 1 then
        points, step_sec = 60, 5
    elseif range == 3 then
        points, step_sec = 1440, 60
    else
        points, step_sec = 60, 60
    end

    local src
    if mac and hist.macs[mac] and #hist.macs[mac] > 0 then
        src = hist.macs[mac]
    else
        src = hist.t
    end
    local out, cur, avg, peak = resample(src, points, step_sec)
    if cur_user and cur == 0 then
        cur = cur_user.session_count or 0
        avg = cur
        peak = cur
    end
    return out, cur, avg, peak
end

function get_session_user_list()
    luci.http.prepare_content("application/json")
    local list, total = snapshot_list()
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
    local list, total = snapshot_list()
    sample_history(total, list)
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
    luci.http.write_json({
        mac = mac, hostname = "", online = online,
        range = range, step_sec = step,
        current = cur, avg = avg, peak = peak,
        list = ser.list,
        tcp_list = ser.tcp_list,
        udp_list = ser.udp_list,
        other_list = ser.other_list,
    })
end
