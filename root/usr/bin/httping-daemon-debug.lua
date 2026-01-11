#!/usr/bin/lua

local nixio = require "nixio"
local uci = require "luci.model.uci".cursor()
local string = require "string"

local DEFAULT_DB_PATH = "/etc/httping_data.db"
local CURL_TIMEOUT = 5
local last_run_map = {}

local function get_db_path()
    local db_path = uci:get("httping", "global", "db_path")
    if not db_path or db_path == "" then db_path = DEFAULT_DB_PATH end
    return db_path
end

local function init_db(db_path)
    if not nixio.fs.access(db_path) then
        -- init logic (omitted for debug brevity)
    end
end

local function log_result(db_path, name, ts, duration, type_str)
    print(string.format("DEBUG: Log Result -> Name: %s, Duration: %s, Type: %s", name, tostring(duration), type_str))
    local val_duration = "NULL"
    if duration then val_duration = string.format("%.3f", duration) end
    local sql = string.format("INSERT INTO monitor_log (server_name, timestamp, duration, type) VALUES ('%s', %d, %s, '%s');", name, ts, val_duration, type_str)
    local cmd = string.format("sqlite3 '%s' \"%s\"", db_path, sql)
    os.execute(cmd)
end

local function do_tcping(url)
    print("DEBUG: Starting TCPing for " .. tostring(url))
    local host, port
    if url:match("^%[") then
        host = url:match("^%[(.-)%]")
        port = url:match("]:(%d+)$")
    else
        host = url:match("^(.-):(%d+)$")
        if not host then host = url end
    end
    if not port then port = 80 end
    port = tonumber(port)
    if not host then print("DEBUG: Invalid host/url extraction") return nil end

    print(string.format("DEBUG: Resolving host: %s, port: %d", host, port))
    local addr_iter = nixio.getaddrinfo(host, "inet")
    if not addr_iter or #addr_iter == 0 then
        addr_iter = nixio.getaddrinfo(host, "inet6")
    end
    
    if not addr_iter or #addr_iter == 0 then
        print("DEBUG: DNS Resolve FAILED")
        return nil
    end
    
    local target = addr_iter[1]
    print("DEBUG: DNS Resolved IP: " .. target.address)
    
    local sock = nixio.socket(target.family, "stream")
    if not sock then print("DEBUG: Socket creation FAILED") return nil end
    
    sock:setblocking(false)
    local t1_sec, t1_usec = nixio.gettimeofday()
    local stat, code, err = sock:connect(target.address, port)
    
    if not stat and code ~= nixio.const.EINPROGRESS then
        print("DEBUG: Connect immediate fail: " .. tostring(code))
        sock:close()
        return nil
    end
    
    local pstat = nixio.poll({{fd=sock, events=nixio.const.POLLOUT}}, 2000)
    
    local success = false
    if pstat and pstat > 0 then
        local err_code = sock:getopt("socket", "error")
        print("DEBUG: Poll returned, socket error code: " .. tostring(err_code))
        if err_code == 0 then success = true end
    else
        print("DEBUG: Poll timed out or failed. pstat: " .. tostring(pstat))
    end
    
    local t2_sec, t2_usec = nixio.gettimeofday()
    sock:close()
    
    if success then
        local ms = (t2_sec - t1_sec) * 1000 + (t2_usec - t1_usec) / 1000
        print("DEBUG: TCPing SUCCESS: " .. ms .. "ms")
        return ms
    else
        print("DEBUG: TCPing FAILED")
        return nil
    end
end

local function do_httping(url)
    print("DEBUG: Starting HTTPing for " .. tostring(url))
    local cmd = string.format("curl -L -k -s -o /dev/null -w \"%%{time_namelookup} %%{time_total}\" --max-time %d \"%s\"", CURL_TIMEOUT, url)
    print("DEBUG: Executing: " .. cmd)
    local f = io.popen(cmd)
    if not f then print("DEBUG: popen failed") return nil end
    local output = f:read("*a")
    f:close()
    
    print("DEBUG: Curl output: [" .. tostring(output) .. "]")
    if not output or output == "" then return nil end
    
    local t_dns, t_total = output:match("([%d%.]+)%s+([%d%.]+)")
    if t_dns and t_total then
        local duration = (tonumber(t_total) - tonumber(t_dns)) * 1000
        if duration < 0 then duration = 0 end
        print("DEBUG: HTTPing SUCCESS: " .. duration .. "ms")
        return duration
    else
        print("DEBUG: Cannot parse curl output")
    end
    return nil
end

local function check_server(section_name, config)
    local enabled = config.enabled or "0"
    if enabled ~= "1" then return end
    local url = config.url
    if not url or url == "" then return end
    local interval = tonumber(config.interval) or 60
    local check_type = config.type or "httping"
    local name = config.name or section_name
    
    -- Force check every time for debug
    -- local now = os.time()
    -- local last = last_run_map[section_name] or 0
    -- if (now - last) >= interval then
        local now = os.time()
        local duration = nil
        if check_type == "tcping" then
            duration = do_tcping(url)
        else
            duration = do_httping(url)
        end
        log_result(get_db_path(), name, now, duration, check_type)
        print("------------------------------------------------")
    -- end
end

local function main_loop()
    print("DEBUG: Starting main loop...")
    uci:load("httping")
    uci:foreach("httping", "server", function(s)
        check_server(s[".name"], s)
    end)
    print("DEBUG: One pass completed. Exiting for debug safety.")
end

main_loop()
