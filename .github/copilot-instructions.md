This repository is an OpenWrt LuCI package that provides a simple HTTP latency monitor.
Use these notes to help implement changes quickly and safely.

Overview
- Purpose: a LuCI front-end + background daemon that records HTTP latency to a sqlite DB.
- Key runtime parts:
  - Systemd/procd service: `root/etc/init.d/httping` (uses `procd` to respawn the daemon).
  - Daemon: `root/usr/bin/httping-daemon.sh` — reads UCI config, runs `curl`, writes to sqlite3 DB.
  - LuCI frontend: `root/usr/lib/lua/luci/controller/httping.lua`, `.../model/cbi/httping/setting.lua`, `.../view/httping/graph.htm`.
  - Package metadata: `Makefile` describes OpenWrt package layout and dependencies (`curl`, `sqlite3-cli`, LuCI libs).

Important patterns & conventions
- OpenWrt package layout: files under `root/` map 1:1 to target install locations (e.g. `root/usr/bin/*` => `/usr/bin/`).
- Configuration: stored in UCI at `/etc/config/httping` (see `root/etc/config/httping`). Use `config_load`, `config_get`, and `config_foreach` in shell code.
- Daemon behavior:
  - Runs an infinite loop reading `httping.global.enabled` and iterates `server` sections.
  - Uses `curl -L -k -s -o /dev/null -w "%{time_namelookup} %{time_total}"` to measure latency and stores durations (ms) into sqlite `monitor_log` table.
  - Database path is configurable via `httping.global.db_path` (default `/etc/httping_data.db`).
- LuCI controller `action_get_data` calls `sqlite3 -json <db> "SELECT ..."` and streams JSON to the browser — ensure the build environment provides a `sqlite3` CLI that supports `-json`.
- Deletion and safety: `setting.lua` escapes single quotes when building sqlite commands. Follow the same escaping pattern when generating SQL from user-supplied names.

Developer workflows
- Build/package: this is an OpenWrt package. To build it inside an OpenWrt buildroot, add this repo to `package/` (or feeds) and run:

```sh
# from OpenWrt root
make package/luci-app-httping/compile V=s
```

- Install locally for testing on a device: build the package `.ipk` and install with `opkg install`. After install, postinst will `enable` and `start` the service.
- Run the daemon manually on a test device (safe mode):

```sh
chmod +x /usr/bin/httping-daemon.sh
/bin/sh /usr/bin/httping-daemon.sh
```

Key files to edit for common tasks
- Add/change UI: edit `root/usr/lib/lua/luci/view/httping/graph.htm` (JS + ECharts rendering). The frontend calls the controller API `get_data`.
- Change data model or queries: edit `root/usr/lib/lua/luci/controller/httping.lua` (see `action_get_data` and `action_clear_data`).
- Change UCI form or deletion behavior: edit `root/usr/lib/lua/luci/model/cbi/httping/setting.lua` (note `ts.remove` is overridden to clear DB rows by name).
- Change background probe logic: edit `root/usr/bin/httping-daemon.sh` (timing, curl options, DB schema).

Integration & runtime requirements
- Requires `curl` and `sqlite3` CLI available on target. The Makefile lists `sqlite3-cli` and `curl` as package dependencies.
- The controller relies on `sqlite3 -json`. If your target `sqlite3` lacks `-json`, alter `action_get_data` to produce JSON differently (e.g., `sqlite3` + manual serialization or `jq` if available).
- Uses UCI and LuCI model APIs — test changes on a real OpenWrt device or an accurate emulator.

Examples & pitfalls
- When updating SQL with string values, escape single quotes: `name:gsub("'","''")` (see `setting.lua`).
- Daemon writes `NULL` duration on curl error — frontend treats `null` as packet loss/timeout.
- `Makefile` marks `/etc/config/httping` as a `conffiles` entry so upgrades won't overwrite local config.

If anything here is unclear or you want this file to include additional examples (packaging commands, test steps, or exact sqlite version expectations), tell me what to expand and I'll update it.
