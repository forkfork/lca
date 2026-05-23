local uv = require("luv")
local fs = require("agent.util.fs")
local json_util = require("agent.util.json")

local mcp = {}

local cjson = require("cjson")

local function create_connection(name, config)
	local stdin_pipe = uv.new_pipe()
	local stdout_pipe = uv.new_pipe()
	local stderr_pipe = uv.new_pipe()

	local handle
	handle = uv.spawn(config.command, {
		args = config.args or {},
		stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
		env = config.env,
	}, function(code)
		if not stdout_pipe:is_closing() then stdout_pipe:close() end
		if not stderr_pipe:is_closing() then stderr_pipe:close() end
		if not stdin_pipe:is_closing() then stdin_pipe:close() end
		if handle and not handle:is_closing() then handle:close() end
	end)

	if not handle then
		stdin_pipe:close()
		stdout_pipe:close()
		stderr_pipe:close()
		return nil, "failed to spawn: " .. config.command
	end

	local conn = {
		name = name,
		handle = handle,
		stdin = stdin_pipe,
		stdout = stdout_pipe,
		stderr = stderr_pipe,
		buf = "",
		next_id = 1,
		pending = {},
		tools = {},
	}

	stdout_pipe:read_start(function(err, data)
		if not data then return end
		conn.buf = conn.buf .. data
		while true do
			local nl = conn.buf:find("\n")
			if not nl then break end
			local line = conn.buf:sub(1, nl - 1)
			conn.buf = conn.buf:sub(nl + 1)
			if line ~= "" then
				local ok, msg = pcall(cjson.decode, line)
				if ok and msg.id and conn.pending[msg.id] then
					conn.pending[msg.id](msg)
					conn.pending[msg.id] = nil
				end
			end
		end
	end)

	stderr_pipe:read_start(function(_, _) end)

	return conn
end

local function rpc_call(conn, method, params, timeout_ms)
	local id = conn.next_id
	conn.next_id = conn.next_id + 1

	local request = cjson.encode({
		jsonrpc = "2.0",
		id = id,
		method = method,
		params = params or {},
	}) .. "\n"

	local result = nil
	local done = false

	conn.pending[id] = function(msg)
		result = msg
		done = true
	end

	conn.stdin:write(request)

	local repl_ok, repl_mod = pcall(require, "agent.repl")
	local deadline = uv.now() + (timeout_ms or 10000)
	while not done and uv.now() < deadline do
		uv.run("once")
		if repl_ok and repl_mod.cancelled then
			conn.pending[id] = nil
			return nil, "cancelled"
		end
	end

	if not done then
		conn.pending[id] = nil
		return nil, "timeout after " .. tostring(math.floor((timeout_ms or 10000) / 1000)) .. "s"
	end

	if result.error then
		return nil, result.error.message or "rpc error"
	end

	return result.result
end

local function initialize(conn)
	local result, err = rpc_call(conn, "initialize", {
		protocolVersion = "2024-11-05",
		capabilities = {},
			clientInfo = { name = "lca", version = "1.0" },
	})
	if not result then
		return nil, err
	end

	-- Send initialized notification
	local notification = cjson.encode({
		jsonrpc = "2.0",
		method = "notifications/initialized",
	}) .. "\n"
	conn.stdin:write(notification)

	return result
end

local function discover_tools(conn)
	local result, err = rpc_call(conn, "tools/list", {})
	if not result then
		return nil, err
	end
	conn.tools = result.tools or {}
	return conn.tools
end

-- Module state
local connections = {}

function mcp.load_config(path)
	path = path or "mcp_servers.json"
	local ok, content = pcall(fs.read_file, path)
	if not ok then
		return {}
	end
	local config = cjson.decode(content)
	return config.mcpServers or {}
end

function mcp.start(config_path)
	local servers = mcp.load_config(config_path)
	local all_tools = {}

	for name, config in pairs(servers) do
		local conn, err = create_connection(name, config)
		if conn then
			local init_result, init_err = initialize(conn)
			if init_result then
				local tools, tools_err = discover_tools(conn)
				if tools then
					for _, tool in ipairs(tools) do
						tool._server = name
						all_tools[#all_tools + 1] = tool
					end
					connections[name] = conn
				end
			end
		end
	end

	return all_tools
end

function mcp.call_tool(server_name, tool_name, arguments)
	local conn = connections[server_name]
	if not conn then
		return { is_error = true, content = "mcp server not connected: " .. server_name }
	end

	local result, err = rpc_call(conn, "tools/call", {
		name = tool_name,
		arguments = arguments or {},
	}, 30000)

	if not result then
		return { is_error = true, content = err or "mcp call failed" }
	end

	-- Extract text from MCP content blocks
	local parts = {}
	for _, block in ipairs(result.content or {}) do
		if block.type == "text" then
			parts[#parts + 1] = block.text
		end
	end

	return {
		is_error = result.isError or false,
		content = table.concat(parts, "\n"),
		summary = tool_name .. " completed",
	}
end

function mcp.stop()
	for name, conn in pairs(connections) do
		if not conn.stdin:is_closing() then
			conn.stdin:close()
		end
	end
	connections = {}
end

function mcp.connected_servers()
	local names = {}
	for name, _ in pairs(connections) do
		names[#names + 1] = name
	end
	return names
end

return mcp
