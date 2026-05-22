local uv = require("luv")

local async = {}

function async.spawn(cmd, args, opts)
	opts = opts or {}
	local stdout_pipe = uv.new_pipe()
	local stderr_pipe = uv.new_pipe()

	local handle, pid
	handle, pid = uv.spawn(cmd, {
		args = args,
		stdio = { nil, stdout_pipe, stderr_pipe },
		cwd = opts.cwd,
		env = opts.env,
	}, function(code, signal)
		stdout_pipe:close()
		stderr_pipe:close()
		handle:close()
		if opts.on_exit then
			opts.on_exit(code, signal)
		end
	end)

	if not handle then
		stdout_pipe:close()
		stderr_pipe:close()
		return nil, pid -- pid is error message on failure
	end

	return {
		handle = handle,
		pid = pid,
		stdout = stdout_pipe,
		stderr = stderr_pipe,
	}
end

function async.read_stream(pipe, on_data, on_end)
	pipe:read_start(function(err, data)
		if err then
			pipe:read_stop()
			if on_end then on_end(err) end
		elseif data then
			on_data(data)
		else
			pipe:read_stop()
			if on_end then on_end(nil) end
		end
	end)
end

function async.timer(interval_ms, callback)
	local t = uv.new_timer()
	t:start(0, interval_ms, callback)
	return t
end

function async.stop_timer(t)
	if t and not t:is_closing() then
		t:stop()
		t:close()
	end
end

function async.run()
	uv.run()
end

function async.run_once()
	uv.run("once")
end

return async
