local commands = {}

local HELP = [[
/help                 show commands
/status               show cwd, model, credentials, and turn count
/model <id>           change model
/credentials <path>   change credentials file
/explain [path]       explain a project using read-only inspection
/save [path]          save session to file (default: .pi-lua-session.json)
/load [path]          load session from file (default: .pi-lua-session.json)
/clear                clear transcript and compaction summary
/exit                 quit
]]

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function commands.dispatch(line, session, ui)
	local name, rest = line:match("^/([^%s]+)%s*(.*)$")
	if not name then
		return false
	end
	rest = trim(rest or "")

	if name == "help" then
		ui.block(HELP)
	elseif name == "status" then
		ui.status(session)
	elseif name == "model" then
		if rest == "" then
			ui.error("usage: /model <id>")
		else
			session.model = rest
			ui.muted("model: " .. session.model)
		end
	elseif name == "credentials" then
		if rest == "" then
			ui.error("usage: /credentials <path>")
		else
			session.credentials_path = rest
			ui.muted("credentials: " .. session.credentials_path)
		end
	elseif name == "explain" then
		local target = rest ~= "" and rest or "."
		session:add_user(table.concat({
			"Explain the project at " .. target .. ".",
			"",
			"Use tools first. Follow this workflow:",
			"1. ls " .. target,
			"2. find " .. target .. " with maxDepth 2",
			"3. read README, AGENTS, manifest, package, build, or config files that exist",
			"4. grep for likely entrypoints and important functions if the structure is unclear",
			"5. read the central source files",
			"6. answer with: what it does, how it is structured, main entrypoints, how to run/check it, and where to make common changes",
			"",
			"Do not edit or write files for this explanation.",
		}, "\n"))
		return "run"
	elseif name == "clear" then
		session:clear()
		ui.muted("transcript cleared")
	elseif name == "save" then
		local path = rest ~= "" and rest or nil
		local ok, err = session:save(path)
		if ok then
			ui.muted("session saved to " .. (path or session.DEFAULT_SESSION_FILE))
		else
			ui.error(err)
		end
	elseif name == "load" then
		local path = rest ~= "" and rest or nil
		local ok, err = session:load(path)
		if ok then
			ui.muted("session loaded from " .. (path or session.DEFAULT_SESSION_FILE) .. " (" .. session:turn_count() .. " turns)")
		else
			ui.error(err)
		end
	elseif name == "exit" or name == "quit" then
		return true
	else
		ui.error("unknown command: /" .. name)
	end

	return false
end

return commands

