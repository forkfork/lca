local json = require("agent.util.json")
local path_util = require("agent.util.path")
local shell = require("agent.util.shell")
local uv = require("luv")
local file_lock = require("agent.file_lock")

local jobs = {}
local activity_cache = {}

local JOBS_DIR = ".lca/jobs"
local DEFAULT_OUTPUT_LIMIT = 20000
local DEFAULT_TAIL_LINES = 200
local DEFAULT_PRUNE_SECONDS = 3600
local DEFAULT_MIN_FINISHED = 0
local SECONDS_PER_DAY = 86400
local FAILED_VISIBLE_SECONDS = 60
local FINISHED_VISIBLE_SECONDS = 300

local function now_iso()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function mkdir_p(path)
	local current = ""
	for part in path:gmatch("[^/]+") do
		if current == "" and path:sub(1, 1) == "/" then
			current = "/" .. part
		elseif current == "" then
			current = part
		else
			current = current .. "/" .. part
		end
		local ok = uv.fs_mkdir(current, tonumber("755", 8))
		if not ok then
			local stat = uv.fs_stat(current)
			if not stat or stat.type ~= "directory" then
				return nil, "failed to create directory: " .. current
			end
		end
	end
	return true
end

local function read_file(path)
	local file = io.open(path, "r")
	if not file then return nil end
	local body = file:read("*a")
	file:close()
	return body
end

local function write_file(path, body)
	local file, err = io.open(path, "w")
	if not file then
		return nil, err
	end
	local written, write_err = file:write(body)
	local closed, close_err = file:close()
	if not written then return nil, write_err end
	if not closed then return nil, close_err end
	return true
end

local function write_json(path, value)
	local tmp = path .. ".tmp." .. tostring(uv.getpid())
	local ok, err = write_file(tmp, json.encode(value))
	if not ok then return nil, err end
	local renamed, rename_err = uv.fs_rename(tmp, path)
	if not renamed then
		os.remove(tmp)
		return nil, rename_err
	end
	return true
end

local function read_json(path)
	local body = read_file(path)
	if not body or body == "" then return nil end
	local ok, decoded = pcall(json.decode, body)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	return decoded
end

local function jobs_root(cwd)
	return path_util.resolve(JOBS_DIR, cwd or ".")
end

local held_locks = {}

-- All writers in a store share one lock. Nested calls in this process reuse it;
-- callbacks must not yield or service the event loop while holding the lock.
function jobs.with_lock(cwd, fn)
	local root = jobs_root(cwd)
	if held_locks[root] then return fn() end
	local ok, err = mkdir_p(root)
	if not ok then return nil, err end
	local deadline = uv.hrtime() + 5000000000
	local lock
	repeat
		lock, err = file_lock.acquire(root .. "/.state.lock")
		if lock then break end
		if err ~= "busy" then return nil, err end
		if uv.hrtime() >= deadline then return nil, "timed out locking job store: " .. root end
		uv.sleep(5)
	until false
	held_locks[root] = true
	local result = table.pack(pcall(fn))
	held_locks[root] = nil
	lock:close()
	if not result[1] then error(result[2], 0) end
	return table.unpack(result, 2, result.n)
end

local function job_dir(cwd, id)
	return jobs_root(cwd) .. "/" .. id
end

local function job_path(cwd, id)
	return job_dir(cwd, id) .. "/job.json"
end

local function remove_tree(path)
	local stat = uv.fs_stat(path)
	if not stat then return true end
	if stat.type ~= "directory" then
		return uv.fs_unlink(path)
	end
	local handle = uv.fs_scandir(path)
	if handle then
		while true do
			local name = uv.fs_scandir_next(handle)
			if not name then break end
			remove_tree(path .. "/" .. name)
		end
	end
	return uv.fs_rmdir(path)
end

local function load_index(cwd)
	local index = read_json(jobs_root(cwd) .. "/index.json")
	if type(index) ~= "table" then
		index = { next_id = 1, jobs = {} }
	end
	if type(index.next_id) ~= "number" then index.next_id = 1 end
	if type(index.jobs) ~= "table" then index.jobs = {} end
	return index
end

local function save_index(cwd, index)
	local ok, err = mkdir_p(jobs_root(cwd))
	if not ok then return nil, err end
	return write_json(jobs_root(cwd) .. "/index.json", index)
end

local function summarize(job)
	return {
		id = job.id,
		command = job.command,
		cwd = job.cwd,
		store_cwd = job.store_cwd,
		pid = job.pid,
		pgid = job.pgid,
		started_at = job.started_at,
		finished_at = job.finished_at,
		status = job.status,
		exit_code = job.exit_code,
		timeout = job.timeout,
		stdout = job.stdout,
		stderr = job.stderr,
	}
end

local function upsert_index_job(cwd, job)
	return jobs.with_lock(cwd, function()
		local index = load_index(cwd)
		local store_cwd = job.store_cwd or job.cwd
		local found = false
		for i, item in ipairs(index.jobs) do
			local item_store_cwd = item.store_cwd or item.cwd
			if item.id == job.id and item_store_cwd == store_cwd then
				index.jobs[i] = summarize(job)
				found = true
				break
			end
		end
		if not found then
			index.jobs[#index.jobs + 1] = summarize(job)
		end
		return save_index(cwd, index)
	end)
end

local function remove_index_job(cwd, id)
	return jobs.with_lock(cwd, function()
		local index = load_index(cwd)
		local kept = {}
		local changed = false
		for _, item in ipairs(index.jobs) do
			if item.id == id then
				changed = true
			else
				kept[#kept + 1] = item
			end
		end
		if not changed then return true end
		index.jobs = kept
		return save_index(cwd, index)
	end)
end

local function resolve_job(cwd, id)
	local index = load_index(cwd)
	for _, item in ipairs(index.jobs) do
		local store_cwd = item.store_cwd
		if item.id == id and store_cwd and store_cwd ~= cwd then
			local resolved = jobs.load(store_cwd, id)
			if resolved then
				return resolved, store_cwd
			end
		end
	end

	local job = jobs.load(cwd, id)
	if job then return job, cwd end

	for _, item in ipairs(index.jobs) do
		if item.id == id and item.cwd and item.cwd ~= cwd then
			local resolved = jobs.load(item.cwd, id)
			if resolved then
				return resolved, item.cwd
			end
		end
	end
	return nil, cwd
end

local boot_id = (read_file("/proc/sys/kernel/random/boot_id") or ""):match("%S+")

local function linux_proc_stat(pid)
	local body = read_file("/proc/" .. tostring(math.floor(tonumber(pid) or 0)) .. "/stat")
	local after = body and body:match("^%d+%s+.*%)%s+(.+)$")
	if not after then return nil end
	local fields = {}
	for field in after:gmatch("%S+") do fields[#fields + 1] = field end
	return { state = fields[1], pgid = tonumber(fields[3]), session = tonumber(fields[4]),
		start_ticks = fields[20], cpu_ticks = (tonumber(fields[12]) or 0) + (tonumber(fields[13]) or 0) }
end

local function live_stat(stat)
	return stat and stat.state ~= "Z" and stat.state ~= "X"
end

function jobs.process_identity(pid)
	local stat = linux_proc_stat(pid)
	if stat then return stat.start_ticks, boot_id end
end

local function process_alive(pid, start_ticks, expected_boot)
	local numeric_pid = tonumber(pid)
	if not numeric_pid or numeric_pid <= 0 then return false end
	local ok, _, code = uv.kill(math.floor(numeric_pid), 0)
	if not ok and code ~= "EPERM" then return false end
	-- kill(0) also succeeds for zombies, which cannot supervise or do work.
	local stat = linux_proc_stat(numeric_pid)
	if start_ticks and (not stat or stat.start_ticks ~= tostring(start_ticks) or expected_boot ~= boot_id) then return false end
	return not stat or live_stat(stat)
end

-- A process group can outlive its leader. On Linux, verify the recorded boot
-- and start time before signalling; never trust a recycled numeric PID alone.
function jobs.group_alive(job)
	local target = tonumber(job.pgid or job.pid)
	if not target or target <= 0 then return false end
	if not boot_id then return process_alive(job.pid) end
	local leader = linux_proc_stat(target)
	if job.boot_id and job.boot_id ~= boot_id then return false, "process identity belongs to another boot" end
	if leader and job.process_start_ticks and leader.start_ticks ~= tostring(job.process_start_ticks) then
		return false, "process identity changed; refusing reused PID"
	end
	if live_stat(leader) and leader.pgid == target then return true end
	local entries = uv.fs_scandir("/proc")
	if entries then
		while true do
			local name = uv.fs_scandir_next(entries)
			if not name then break end
			if name:match("^%d+$") then
				local stat = linux_proc_stat(name)
				if live_stat(stat) and stat.pgid == target and stat.session == target then return true end
			end
		end
	end
	return false
end

function jobs.signal_group(job, signal)
	local alive, err = jobs.group_alive(job)
	if err then return nil, err end
	if not alive then return true end
	if boot_id and not job.process_start_ticks then
		return nil, "process identity unavailable for legacy job; cannot safely signal its group. "
			.. "Inspect job_status, job logs and `ps -o pid,pgid,lstart,args -p " .. tostring(job.pid)
			.. "` to identify the original command before stopping it in your process manager. "
			.. "Start its replacement with job_start to restore managed stopping."
	end
	local ok, kill_err, code = uv.kill(-tonumber(job.pgid or job.pid), signal)
	if not ok and code ~= "ESRCH" then return nil, kill_err end
	return true
end

local function parse_iso(value)
	if type(value) ~= "string" then return nil end
	local year, month, day, hour, min, sec = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
	if not year then return nil end
	local local_epoch = os.time({
		year = tonumber(year),
		month = tonumber(month),
		day = tonumber(day),
		hour = tonumber(hour),
		min = tonumber(min),
		sec = tonumber(sec),
		isdst = false,
	})
	local offset = os.difftime(os.time(os.date("*t", local_epoch)), os.time(os.date("!*t", local_epoch)))
	return local_epoch + offset
end

local function compact_command(value, limit)
	value = tostring(value or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	limit = limit or 60
	if #value > limit then
		return value:sub(1, limit - 3) .. "..."
	end
	return value
end

-- Keep model-facing status bounded; the full command remains in job.json.
function jobs.describe(job)
	local lines = {
		"id: " .. tostring(job.id),
		"status: " .. tostring(job.status),
		"command: " .. compact_command(job.command, 160),
	}
	if job.exit_code ~= nil then lines[#lines + 1] = "exit_code: " .. tostring(job.exit_code) end
	if job.signal then lines[#lines + 1] = "signal: " .. tostring(job.signal) end
	if job.finished_at then lines[#lines + 1] = "finished_at: " .. tostring(job.finished_at) end
	if job.start_error then lines[#lines + 1] = "start_error: " .. tostring(job.start_error) end
	if job.state_error then lines[#lines + 1] = "state_error: " .. tostring(job.state_error) end
	if job.supervisor_lost then lines[#lines + 1] = "supervisor_lost: true" end
	return table.concat(lines, "\n")
end

local function short_age(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	if seconds < 60 then
		return tostring(seconds) .. "s"
	end
	local minutes = math.floor(seconds / 60)
	if minutes < 60 then
		return tostring(minutes) .. "m"
	end
	local hours = math.floor(minutes / 60)
	if hours < 48 then
		return tostring(hours) .. "h"
	end
	return tostring(math.floor(hours / 24)) .. "d"
end

local function detect_port(command)
	command = tostring(command or "")
	local patterns = {
		'python%d*%s+%-m%s+http%.server%s+(%d%d%d%d%d?)',
		':(%d%d%d%d%d?)',
		'port%s*[=:]%s*(%d%d%d%d%d?)',
		'%-p%s+(%d%d%d%d%d?)',
		'%-%-port%s+(%d%d%d%d%d?)',
		'HTTPServer%(%([^,]+,%s*(%d%d%d%d%d?)%)',
	}
	for _, pattern in ipairs(patterns) do
		local port = command:match(pattern)
		if port then return ":" .. port end
	end
	return ""
end

local function command_label(command)
	command = tostring(command or "")
	if command:find("HTTPServer", 1, true) or command:find("http.server", 1, true) then
		return "python http server"
	end
	if command:match("python%d*%s+%-m%s+http%.server") then
		return "python http server"
	end
	if command:match("npm%s+run%s+dev") then
		return "npm dev server"
	end
	if command:match("pnpm%s+dev") then
		return "pnpm dev server"
	end
	if command:match("yarn%s+dev") then
		return "yarn dev server"
	end
	if command:match("^%s*sleep%s+") then
		return "sleep"
	end
	if command:match("for%s+.+echo%s+tick") then
		return "tick loop"
	end
	return compact_command(command, 60)
end

local function is_finished_status(status)
	return status == "exited" or status == "timed_out" or status == "stopped" or status == "failed_to_start" or status == "lost"
end

local function file_size(path)
	local stat = path and uv.fs_stat(path)
	return stat and stat.size or 0
end

local function is_linux()
	return uv.fs_stat("/proc/self/stat") ~= nil
end

local cached_lua_command

local function command_succeeds(command)
	local ok, reason, code = os.execute(command)
	return ok == true or ok == 0 or code == 0 or (reason == "exit" and code == 0)
end

local function executable_exists(value)
	if not value or value == "" then return false end
	if value:find("/", 1, true) then
		return uv.fs_stat(value) ~= nil
	end
	local path = os.getenv("PATH") or ""
	for dir in path:gmatch("[^:]+") do
		if uv.fs_stat(dir .. "/" .. value) then
			return true
		end
	end
	return false
end

local function parse_luarocks_env(lua_version)
	local handle = io.popen("luarocks --lua-version=" .. shell.quote(lua_version) .. " path --bin 2>/dev/null", "r")
	if not handle then return nil end
	local output = handle:read("*a")
	handle:close()

	local env = {}
	for name, value in output:gmatch("export%s+([A-Z_]+)='([^']*)'") do
		if name == "LUA_PATH" or name == "LUA_CPATH" or name == "PATH" then
			env[name] = value
		end
	end
	if not env.LUA_PATH and not env.LUA_CPATH then
		return nil
	end
	return env
end

local function lua_version_name(candidate)
	local handle = io.popen(shell.quote(candidate) .. " -e " .. shell.quote("print(_VERSION:match('%d+%.%d+'))") .. " 2>/dev/null", "r")
	if not handle then return nil end
	local output = handle:read("*l")
	handle:close()
	return output
end

local function supervisor_probe(candidate, env)
	local prefix = ""
	if env then
		for _, name in ipairs({ "LUA_PATH", "LUA_CPATH", "PATH" }) do
			if env[name] then
				prefix = prefix .. name .. "=" .. shell.quote(env[name]) .. " "
			end
		end
	end
	local probe = "require('luv'); require('cjson'); require('agent.file_lock')"
	return command_succeeds(prefix .. shell.quote(candidate) .. " -e " .. shell.quote(probe) .. " >/dev/null 2>&1")
end

local function lua_command()
	if cached_lua_command then return cached_lua_command end

	local candidates = {}
	for _, candidate in ipairs({
		os.getenv("LCA_LUA"),
		os.getenv("LUA"),
		uv.exepath and uv.exepath() or nil,
		arg and arg[-1] or nil,
	}) do
		if candidate and candidate ~= "" then
			candidates[#candidates + 1] = candidate
		end
	end
	for _, candidate in ipairs({ "lua5.5", "lua5.4", "lua5.3", "lua5.2", "lua5.1", "lua", "luajit" }) do
		candidates[#candidates + 1] = candidate
	end

	local seen = {}
	for _, candidate in ipairs(candidates) do
		if candidate and candidate ~= "" and not seen[candidate] and executable_exists(candidate) then
			seen[candidate] = true
			if supervisor_probe(candidate) then
				cached_lua_command = { executable = candidate, env = nil }
				return cached_lua_command
			end
			local version = lua_version_name(candidate)
			local rocks_env = version and parse_luarocks_env(version) or nil
			if rocks_env and supervisor_probe(candidate, rocks_env) then
				cached_lua_command = { executable = candidate, env = rocks_env }
				return cached_lua_command
			end
		end
	end

	cached_lua_command = { executable = "lua", env = nil }
	return cached_lua_command
end

local function supervisor_package_path()
	local found = package.searchpath and package.searchpath("agent.job_supervisor", package.path) or nil
	if not found then
		return package.path
	end
	if found:sub(1, 1) ~= "/" then
		found = uv.cwd() .. "/" .. found
	end
	local root = found:match("^(.*)/agent/job_supervisor%.lua$")
	if not root then
		return package.path
	end
	return root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/?/?.lua;" .. package.path
end

function jobs.allocate_id(cwd)
	return jobs.with_lock(cwd, function()
		local root = jobs_root(cwd)
		local ok, err = mkdir_p(root)
		if not ok then return nil, err end
		local index = load_index(cwd)
		local next_id = math.floor(tonumber(index.next_id) or 1)
		local id = "job_" .. tostring(next_id)
		index.next_id = next_id + 1
		local saved, save_err = save_index(cwd, index)
		if not saved then return nil, save_err end
		return id
	end)
end

function jobs.save(cwd, job)
	return jobs.with_lock(cwd, function()
		local dir = job_dir(cwd, job.id)
		local ok, err = mkdir_p(dir)
		if not ok then return nil, err end
		local saved, save_err = write_json(dir .. "/job.json", job)
		if not saved then return nil, save_err end
		return upsert_index_job(cwd, job)
	end)
end

function jobs.load(cwd, id)
	return read_json(job_path(cwd, id))
end

function jobs.start(args, context)
	if not args.command or args.command == "" then
		return nil, "command is required"
	end

	local base_cwd = path_util.resolve((context and context.cwd) or ".", ".")
	local cwd = path_util.resolve(args.cwd or base_cwd, base_cwd)
	local store_cwd = base_cwd
	local id, id_err = jobs.allocate_id(store_cwd)
	if not id then return nil, id_err end

	local dir = job_dir(store_cwd, id)
	local stdout = dir .. "/stdout.log"
	local stderr = dir .. "/stderr.log"
	local job = {
		id = id,
		command = args.command,
		cwd = cwd,
		store_cwd = store_cwd,
		pid = nil,
		pgid = nil,
		started_at = now_iso(),
		boot_id = boot_id,
		finished_at = nil,
		status = "starting",
		exit_code = nil,
		timeout = tonumber(args.timeout),
		temporary = args.temporary == true,
		stdout = stdout,
		stderr = stderr,
	}

	local ok, err = jobs.save(store_cwd, job)
	if not ok then return nil, err end
	write_file(stdout, "")
	write_file(stderr, "")

	local supervisor_code = "package.path=" .. json.string(supervisor_package_path()) .. ";require('agent.job_supervisor').main({" .. json.string(store_cwd) .. "," .. json.string(id) .. "})"
	local lua = lua_command()
	local env = {}
	for name, value in pairs(lua.env or {}) do
		env[#env + 1] = name .. "=" .. value
	end
	local current, launch_err = jobs.with_lock(store_cwd, function()
		local handle, pid_or_err = uv.spawn(lua.executable, {
			args = { "-e", supervisor_code },
			cwd = cwd,
			detached = true,
			stdio = { nil, nil, nil },
			env = #env > 0 and env or nil,
		})

		if not handle then
			job.status = "failed_to_start"
			job.finished_at = now_iso()
			job.start_error = tostring(pid_or_err)
			jobs.save(store_cwd, job)
			return nil, "failed to start supervisor: " .. tostring(pid_or_err)
		end

		local current = jobs.load(store_cwd, id) or job
		current.supervisor_pid = pid_or_err
		current.supervisor_start_ticks = jobs.process_identity(pid_or_err)
		local saved, save_err = jobs.save(store_cwd, current)
		if not saved then
			uv.kill(pid_or_err, "sigkill")
			handle:close()
			return nil, save_err
		end
		handle:unref()
		return current
	end)
	if not current then return nil, launch_err end
	if cwd ~= base_cwd then
		upsert_index_job(cwd, current)
	end
	return current
end

function jobs.status(cwd, id)
	local job, store = resolve_job(cwd, id)
	if not job then return nil, "unknown job: " .. tostring(id) end
	job.alive = job.status == "running" and jobs.group_alive(job)
	if (job.status == "running" or job.status == "starting")
		and job.supervisor_pid and not process_alive(job.supervisor_pid, job.supervisor_start_ticks, job.boot_id) then
		return jobs.with_lock(store, function()
			local current = jobs.load(store, id)
			if not current then return nil, "unknown job: " .. tostring(id) end
			current.alive = jobs.group_alive(current)
			if (current.status == "starting" or current.status == "running")
				and current.supervisor_pid and not process_alive(current.supervisor_pid, current.supervisor_start_ticks, current.boot_id) then
				current.state_error = "supervisor exited without recording completion; exit code unknown"
				if current.alive then
					current.supervisor_lost = true
				else
					current.status = "lost"
					current.finished_at = now_iso()
					local saved, err = jobs.save(store, current)
					if not saved then return nil, err end
				end
			end
			return current
		end)
	end
	return job
end

function jobs.list(cwd)
	local index = load_index(cwd)
	local items = {}
	for _, item in ipairs(index.jobs) do
		local job = item.id and jobs.status(cwd, item.id) or nil
		items[#items + 1] = job or item
	end
	table.sort(items, function(a, b)
		local ar = a.status == "running" and a.alive
		local br = b.status == "running" and b.alive
		if ar ~= br then return ar == true end
		local af = parse_iso(a.finished_at) or parse_iso(a.started_at) or 0
		local bf = parse_iso(b.finished_at) or parse_iso(b.started_at) or 0
		if af ~= bf then return af > bf end
		return tostring(a.id) < tostring(b.id)
	end)
	return items
end

function jobs.visible(cwd, opts)
	opts = opts or {}
	local all = opts.all == true
	local now = opts.now or os.time()
	local list = jobs.list(cwd)
	if all then return list end

	local has_running = false
	for _, job in ipairs(list) do
		if job.status == "running" and job.alive then
			has_running = true
			break
		end
	end

	local visible = {}
	for _, job in ipairs(list) do
		if job.status == "running" and job.alive then
			visible[#visible + 1] = job
		elseif not has_running and is_finished_status(job.status) then
			local t = parse_iso(job.finished_at) or parse_iso(job.started_at) or now
			if job.status == "failed_to_start" and now - t <= FAILED_VISIBLE_SECONDS then
				visible[#visible + 1] = job
			elseif job.status ~= "failed_to_start" and now - t <= FINISHED_VISIBLE_SECONDS then
				visible[#visible + 1] = job
			end
		end
	end
	return visible
end

function jobs.display(job, now)
	now = now or os.time()
	local started = parse_iso(job.started_at) or now
	local finished = parse_iso(job.finished_at)
	local age_base = finished or started
	local age = short_age(now - age_base)
	if finished then
		age = age .. " ago"
	end
	return {
		id = tostring(job.id or "-"),
		status = tostring(job.status or "unknown"),
		pid = job.pid,
		alive = job.alive == true,
		age = age,
		port = detect_port(job.command),
		activity = jobs.activity(job),
		timeout = job.timeout and tonumber(job.timeout) and tonumber(job.timeout) > 0 and short_age(tonumber(job.timeout) / 1000) or "",
		label = command_label(job.command),
		command = tostring(job.command or ""),
	}
end

function jobs.activity(job)
	if not job or job.status ~= "running" or job.alive ~= true or not job.pid then
		return ""
	end
	if not is_linux() then
		return ""
	end

	local stat = linux_proc_stat(job.pid)
	if not stat then return "" end
	local stdout_size = file_size(job.stdout)
	local stderr_size = file_size(job.stderr)
	local output_bytes = stdout_size + stderr_size
	local key = tostring(job.id or job.pid)
	local previous = activity_cache[key]
	activity_cache[key] = {
		cpu_ticks = stat.cpu_ticks,
		output_bytes = output_bytes,
	}

	if previous then
		if output_bytes > (previous.output_bytes or 0) then
			return "output"
		end
		if stat.cpu_ticks > (previous.cpu_ticks or 0) then
			return "cpu"
		end
	end

	if stat.state == "D" then return "io?" end
	if stat.state == "R" then return "active" end
	if stat.state == "S" then return "ready" end
	if stat.state == "T" or stat.state == "t" then return "stop" end
	if stat.state == "Z" then return "zombie" end
	if stat.state == "I" then return "ready" end
	return "wait"
end

function jobs.running(cwd)
	local running = {}
	for _, job in ipairs(jobs.list(cwd)) do
		if job.status == "running" and job.alive then
			running[#running + 1] = job
		end
	end
	return running
end

function jobs.remove(cwd, id, opts)
	opts = opts or {}
	local job, resolved_cwd = resolve_job(cwd, id)
	if not job then return nil, "unknown job: " .. tostring(id) end
	job.alive = job.status == "running" and jobs.group_alive(job)
	if (job.status == "starting" or job.status == "running") and not opts.force then
		return nil, "job is running: " .. tostring(id)
	end
	if job.status == "running" and job.alive and opts.stop then
		jobs.stop(resolved_cwd, id)
	end

	local saved, save_err = jobs.with_lock(resolved_cwd, function()
		local removed, remove_err = remove_tree(job_dir(resolved_cwd, id))
		if not removed then return nil, remove_err end
		return remove_index_job(resolved_cwd, id)
	end)
	if not saved then return nil, save_err end
	if resolved_cwd ~= cwd then
		local ref_saved, ref_err = remove_index_job(cwd, id)
		if not ref_saved then return nil, ref_err end
	end
	return true
end

function jobs.prune(cwd, opts)
	opts = opts or {}
	local prune_seconds = tonumber(opts.seconds)
	if not prune_seconds and opts.days ~= nil then
		prune_seconds = (tonumber(opts.days) or 0) * SECONDS_PER_DAY
	end
	prune_seconds = prune_seconds or DEFAULT_PRUNE_SECONDS
	local min_finished = math.max(0, math.floor(tonumber(opts.min_finished) or DEFAULT_MIN_FINISHED))
	local failed_seconds = tonumber(opts.failed_seconds)
	if not failed_seconds and opts.failed_days ~= nil then
		failed_seconds = (tonumber(opts.failed_days) or 0) * SECONDS_PER_DAY
	end
	failed_seconds = failed_seconds or prune_seconds
	local now = opts.now or os.time()

	local finished = {}
	for _, job in ipairs(jobs.list(cwd)) do
		if is_finished_status(job.status) then
			local finished_at = parse_iso(job.finished_at) or parse_iso(job.started_at) or 0
			job._finished_at_epoch = finished_at
			finished[#finished + 1] = job
		end
	end

	table.sort(finished, function(a, b)
		return (a._finished_at_epoch or 0) > (b._finished_at_epoch or 0)
	end)

	local kept_finished = 0
	local pruned = {}
	for _, job in ipairs(finished) do
		kept_finished = kept_finished + 1
		local age_seconds = now - (job._finished_at_epoch or 0)
		local threshold = job.status == "failed_to_start" and failed_seconds or prune_seconds
		if kept_finished > min_finished and age_seconds > threshold then
			local ok = jobs.remove(cwd, job.id, { force = false })
			if ok then
				pruned[#pruned + 1] = job.id
			end
		end
	end
	return {
		pruned = pruned,
		count = #pruned,
	}
end

function jobs.wait(cwd, id, args, context)
	args = args or {}
	context = context or {}
	local timeout_ms = math.max(0, math.floor(tonumber(args.timeout) or tonumber(args.timeout_ms) or 30000))
	local started_ms = uv.hrtime() / 1000000
	local deadline = started_ms + timeout_ms
	local next_progress_ms = started_ms
	local job, err
	while true do
		-- Tool waits run on the UI thread. Service input and rendering before
		-- polling again, including cancellation set by this pump.
		if context.on_wait then context.on_wait() end
		if context.cancelled and context.cancelled() then
			return nil, "cancelled waiting for job " .. tostring(id), "cancelled"
		end
		job, err = jobs.status(cwd, id)
		if not job then return nil, err end
		if job.supervisor_lost then return job, nil, "supervisor_lost" end
		if job.status ~= "starting" and job.status ~= "running" then
			return job
		end
		local now_ms = uv.hrtime() / 1000000
		if context.progress and now_ms >= next_progress_ms then
			context.progress({ elapsed_ms = math.floor(now_ms - started_ms) })
			next_progress_ms = now_ms + 2000
		end
		if now_ms >= deadline then
			return job
		end
		uv.sleep(math.floor(math.max(1, math.min(100, deadline - now_ms))))
	end
end

local function tail_lines(path, lines)
	lines = math.max(1, math.floor(tonumber(lines) or DEFAULT_TAIL_LINES))
	local file = io.open(path, "r")
	if not file then return nil, "missing output file: " .. path end
	local size = file:seek("end")
	local omitted = "[earlier output omitted]\n"
	local clipped = size > DEFAULT_OUTPUT_LIMIT
	local read_size = math.min(size, DEFAULT_OUTPUT_LIMIT - (clipped and #omitted or 0))
	file:seek("set", size - read_size)
	-- Read only the bounded snapshot, even if the writer is still appending.
	local body = file:read(read_size) or ""
	file:close()

	local collected = {}
	for line in (body .. "\n"):gmatch("(.-)\n") do
		collected[#collected + 1] = line
	end
	if collected[#collected] == "" then
		table.remove(collected)
	end
	local first = math.max(1, #collected - lines + 1)
	local prefix = clipped and first == 1 and omitted or ""
	return prefix .. table.concat(collected, "\n", first)
end

local function read_since(path, offset, limit)
	offset = math.max(0, math.floor(tonumber(offset) or 0))
	limit = math.min(DEFAULT_OUTPUT_LIMIT, math.max(1, math.floor(tonumber(limit) or DEFAULT_OUTPUT_LIMIT)))
	local file = io.open(path, "r")
	if not file then return nil, "missing output file: " .. path end
	local size, size_err = file:seek("end")
	if not size then file:close(); return nil, "cannot size output file: " .. tostring(size_err) end
	if offset > size then
		file:close()
		return nil, "offset " .. tostring(offset) .. " exceeds current output size " .. tostring(size)
			.. "; use the last returned cursor for this stream, or offset 0 to reread"
	end
	local position, seek_err = file:seek("set", offset)
	if not position then file:close(); return nil, "cannot seek output file: " .. tostring(seek_err) end
	local body = file:read(limit) or ""
	local next_offset = file:seek()
	local final_size, final_err = file:seek("end")
	file:close()
	if not next_offset or not final_size then return nil, "cannot locate output cursor: " .. tostring(final_err) end
	local more = final_size > next_offset
	return body, nil, next_offset, more
end

local function search_file(path, pattern, limit)
	if not pattern or pattern == "" then
		return nil, "search pattern is required"
	end
	limit = math.max(1, math.floor(tonumber(limit) or 50))
	local file = io.open(path, "r")
	if not file then return nil, "missing output file: " .. path end
	local matches = {}
	local line_no = 0
	for line in file:lines() do
		line_no = line_no + 1
		if line:find(pattern, 1, true) then
			matches[#matches + 1] = tostring(line_no) .. ":" .. line:sub(1, 1000)
			if #matches >= limit then break end
		end
	end
	file:close()
	return table.concat(matches, "\n")
end

function jobs.output(cwd, id, args)
	local job = resolve_job(cwd, id)
	if not job then return nil, "unknown job: " .. tostring(id) end
	local stream = args.stream or "stdout"
	if stream ~= "stdout" and stream ~= "stderr" then
		return nil, "stream must be stdout or stderr"
	end
	local path = job[stream]
	if args.search then
		return search_file(path, args.search, args.limit)
	end
	if args.offset then
		return read_since(path, args.offset, args.limit)
	end
	return tail_lines(path, args.tail)
end

function jobs.stop(cwd, id)
	local job, resolved_cwd = resolve_job(cwd, id)
	if not job then return nil, "unknown job: " .. tostring(id) end
	local err, stopping
	job, err = jobs.with_lock(resolved_cwd, function()
		local current = jobs.load(resolved_cwd, id)
		if not current then return nil, "unknown job: " .. tostring(id) end
		if current.status ~= "running" and current.status ~= "starting" then return current end
		local signalled, signal_err = jobs.signal_group(current, "sigterm")
		if not signalled then return nil, signal_err end
		current.status = "stopped"
		current.finished_at = now_iso()
		local saved, save_err = jobs.save(resolved_cwd, current)
		if not saved then return nil, save_err end
		stopping = true
		return current
	end)
	if not job then return nil, err end
	if not stopping then return job end
	if resolved_cwd ~= cwd then
		upsert_index_job(cwd, job)
	end

	local target = job.pgid or job.pid
	if target then
		target = tostring(math.floor(tonumber(target)))
		uv.sleep(200)
		-- The leader may exit on TERM while a descendant ignores it.
		local killed, kill_err = jobs.signal_group(job, "sigkill")
		if not killed then return nil, kill_err end
	end

	return job
end

jobs.JOBS_DIR = JOBS_DIR
jobs.job_dir = job_dir
jobs.job_path = job_path
jobs.process_alive = process_alive
jobs.now_iso = now_iso
jobs.parse_iso = parse_iso
jobs.short_age = short_age
jobs.FAILED_VISIBLE_SECONDS = FAILED_VISIBLE_SECONDS

return jobs
