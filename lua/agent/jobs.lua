local json = require("agent.util.json")
local path_util = require("agent.util.path")
local shell = require("agent.util.shell")
local uv = require("luv")

local jobs = {}
local activity_cache = {}

local JOBS_DIR = ".lca/jobs"
local DEFAULT_OUTPUT_LIMIT = 20000
local DEFAULT_TAIL_LINES = 200
local DEFAULT_PRUNE_DAYS = 7
local DEFAULT_MIN_FINISHED = 20
local FAILED_TO_START_PRUNE_DAYS = 1
local SECONDS_PER_DAY = 86400
local FAILED_VISIBLE_SECONDS = 60

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
	file:write(body)
	file:close()
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
	local index = load_index(cwd)
	local found = false
	for i, item in ipairs(index.jobs) do
		if item.id == job.id then
			index.jobs[i] = summarize(job)
			found = true
			break
		end
	end
	if not found then
		index.jobs[#index.jobs + 1] = summarize(job)
	end
	return save_index(cwd, index)
end

local function process_alive(pid)
	if not pid then return false end
	local numeric_pid = tonumber(pid)
	if not numeric_pid then return false end
	local ok, reason, code = os.execute("kill -0 " .. shell.quote(tostring(math.floor(numeric_pid))) .. " >/dev/null 2>&1")
	return ok == true or code == 0 or (reason == "exit" and code == 0)
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
	return status == "exited" or status == "timed_out" or status == "stopped" or status == "failed_to_start"
end

local function file_size(path)
	local stat = path and uv.fs_stat(path)
	return stat and stat.size or 0
end

local function linux_proc_stat(pid)
	local path = "/proc/" .. tostring(math.floor(tonumber(pid) or 0)) .. "/stat"
	local body = read_file(path)
	if not body then return nil end
	local after = body:match("^%d+%s+%b()%s+(.+)$")
	if not after then return nil end
	local fields = {}
	for field in after:gmatch("%S+") do
		fields[#fields + 1] = field
	end
	local state = fields[1]
	local utime = tonumber(fields[12]) or 0
	local stime = tonumber(fields[13]) or 0
	return {
		state = state,
		cpu_ticks = utime + stime,
	}
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
	local probe = "require('luv'); require('cjson')"
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
end

function jobs.save(cwd, job)
	local dir = job_dir(cwd, job.id)
	local ok, err = mkdir_p(dir)
	if not ok then return nil, err end
	local saved, save_err = write_json(dir .. "/job.json", job)
	if not saved then return nil, save_err end
	return upsert_index_job(cwd, job)
end

function jobs.load(cwd, id)
	return read_json(job_path(cwd, id))
end

function jobs.start(args, context)
	if not args.command or args.command == "" then
		return nil, "command is required"
	end

	local base_cwd = (context and context.cwd) or "."
	local cwd = path_util.resolve(args.cwd or base_cwd, base_cwd)
	local id, id_err = jobs.allocate_id(cwd)
	if not id then return nil, id_err end

	local dir = job_dir(cwd, id)
	local stdout = dir .. "/stdout.log"
	local stderr = dir .. "/stderr.log"
	local job = {
		id = id,
		command = args.command,
		cwd = cwd,
		pid = nil,
		pgid = nil,
		started_at = now_iso(),
		finished_at = nil,
		status = "starting",
		exit_code = nil,
		timeout = tonumber(args.timeout),
		temporary = args.temporary == true,
		stdout = stdout,
		stderr = stderr,
	}

	local ok, err = jobs.save(cwd, job)
	if not ok then return nil, err end
	write_file(stdout, "")
	write_file(stderr, "")

	local supervisor_code = "package.path=" .. json.string(supervisor_package_path()) .. ";require('agent.job_supervisor').main({" .. json.string(cwd) .. "," .. json.string(id) .. "})"
	local lua = lua_command()
	local env = {}
	for name, value in pairs(lua.env or {}) do
		env[#env + 1] = name .. "=" .. value
	end
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
		jobs.save(cwd, job)
		return nil, "failed to start supervisor: " .. tostring(pid_or_err)
	end

	local current = jobs.load(cwd, id) or job
	current.supervisor_pid = pid_or_err
	jobs.save(cwd, current)
	handle:unref()
	return job
end

function jobs.status(cwd, id)
	local job = jobs.load(cwd, id)
	if not job then return nil, "unknown job: " .. tostring(id) end
	job.alive = job.status == "running" and process_alive(job.pid)
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
			if job.status == "failed_to_start" then
				local t = parse_iso(job.finished_at) or parse_iso(job.started_at) or now
				if now - t <= FAILED_VISIBLE_SECONDS then
					visible[#visible + 1] = job
				end
			else
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
	local job = jobs.status(cwd, id)
	if not job then return nil, "unknown job: " .. tostring(id) end
	if job.status == "running" and job.alive and not opts.force then
		return nil, "job is running: " .. tostring(id)
	end
	if job.status == "running" and job.alive and opts.stop then
		jobs.stop(cwd, id)
	end

	local removed, remove_err = remove_tree(job_dir(cwd, id))
	if not removed then
		return nil, remove_err
	end

	local index = load_index(cwd)
	local kept = {}
	for _, item in ipairs(index.jobs) do
		if item.id ~= id then
			kept[#kept + 1] = item
		end
	end
	index.jobs = kept
	local saved, save_err = save_index(cwd, index)
	if not saved then return nil, save_err end
	return true
end

function jobs.prune(cwd, opts)
	opts = opts or {}
	local prune_days = tonumber(opts.days) or DEFAULT_PRUNE_DAYS
	local min_finished = math.max(0, math.floor(tonumber(opts.min_finished) or DEFAULT_MIN_FINISHED))
	local failed_days = tonumber(opts.failed_days) or FAILED_TO_START_PRUNE_DAYS
	local now = opts.now or os.time()

	local finished = {}
	for _, job in ipairs(jobs.list(cwd)) do
		local running = job.status == "running" and job.alive
		if not running then
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
		local age_days = (now - (job._finished_at_epoch or 0)) / SECONDS_PER_DAY
		local threshold = job.status == "failed_to_start" and failed_days or prune_days
		if kept_finished > min_finished and age_days > threshold then
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

function jobs.wait(cwd, id, args)
	args = args or {}
	local timeout_ms = math.max(0, math.floor(tonumber(args.timeout) or tonumber(args.timeout_ms) or 1000))
	local deadline = (uv.hrtime() / 1000000) + timeout_ms
	local job, err
	while true do
		job, err = jobs.status(cwd, id)
		if not job then return nil, err end
		if job.status ~= "starting" and job.status ~= "running" then
			return job
		end
		local now_ms = uv.hrtime() / 1000000
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
	local read_size = math.min(size, math.max(65536, lines * 512))
	file:seek("set", size - read_size)
	local body = file:read("*a") or ""
	file:close()

	local collected = {}
	for line in (body .. "\n"):gmatch("(.-)\n") do
		collected[#collected + 1] = line
	end
	if collected[#collected] == "" then
		table.remove(collected)
	end
	while #collected > lines do
		table.remove(collected, 1)
	end
	return table.concat(collected, "\n")
end

local function read_since(path, offset, limit)
	offset = math.max(0, math.floor(tonumber(offset) or 0))
	limit = math.max(1, math.floor(tonumber(limit) or DEFAULT_OUTPUT_LIMIT))
	local file = io.open(path, "r")
	if not file then return nil, "missing output file: " .. path end
	file:seek("set", offset)
	local body = file:read(limit) or ""
	local next_offset = file:seek()
	file:close()
	return body, nil, next_offset
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
	local job = jobs.load(cwd, id)
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
	local job = jobs.load(cwd, id)
	if not job then return nil, "unknown job: " .. tostring(id) end
	if job.status ~= "running" and job.status ~= "starting" then
		return job
	end

	job.status = "stopped"
	job.finished_at = now_iso()
	jobs.save(cwd, job)

	local target = job.pgid or job.pid
	if target then
		target = tostring(math.floor(tonumber(target)))
		os.execute("/bin/kill -TERM -- -" .. target .. " >/dev/null 2>&1")
		uv.sleep(200)
		if process_alive(job.pid) then
			os.execute("/bin/kill -KILL -- -" .. target .. " >/dev/null 2>&1")
		end
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
