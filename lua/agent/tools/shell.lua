local shell_util = require("agent.util.shell")

local shell_tool = {}

function shell_tool.run(command)
	if not command or command == "" then
		error("command is required")
	end
	return shell_util.capture(command)
end

return shell_tool
