local protocol = require("agent.tool_protocol")
local json = require("agent.util.json")

local fixture = {}
local sequence = 0

-- Legacy XML strings remain convenient human-readable test data. Convert them
-- at the fake-provider boundary so core tests exercise only the native runtime.
function fixture.response(value)
	if type(value) == "table" then
		if value._native_tool_calls ~= nil then return value end
		local copy = {}
		for key, child in pairs(value) do copy[key] = child end
		value = copy
	else
		value = { text = value or "" }
	end
	local calls = protocol.extract_all_tool_calls(value.text or "")
	value._native_tool_calls = {}
	value._output_items = value._output_items or {}
	for _, call in ipairs(calls) do
		sequence = sequence + 1
		local id = "fixture_call_" .. tostring(sequence)
		local args = {}
		for key, child in pairs(call.args or {}) do
			if key ~= "_raw_content" then args[key] = child end
		end
		if call.args and call.args._raw_content ~= nil then args.content = call.args._raw_content end
		value._native_tool_calls[#value._native_tool_calls + 1] = {
			name = call.name, args = args, raw = call.raw, native_call_id = id,
		}
		value._output_items[#value._output_items + 1] = {
			type = "function_call", call_id = id, name = call.name, arguments = json.encode(args),
		}
	end
	return value
end

return fixture
