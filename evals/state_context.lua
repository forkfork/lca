-- Eval-only context intervention. Production sessions never install these hooks.
local json = require("agent.util.json")
local M = {}
local LIMIT = 8000
local fields = { "current_beliefs", "completed", "open_questions", "planned_next", "constraints", "rejected", "verification" }

local function clone(value)
	return json.decode(json.encode(value))
end

function M.parse(text)
	local body = tostring(text or ""):match("<agent_state>%s*(.-)%s*</agent_state>")
	assert(body, "state protocol: missing agent_state JSON block")
	assert(#body <= LIMIT, "state protocol: state exceeds 8000 bytes")
	local ok, state = pcall(json.decode, body)
	assert(ok and type(state) == "table", "state protocol: invalid JSON object")
	assert(type(state.goal) == "string" and state.goal ~= "", "state protocol: missing goal")
	for _, key in ipairs(fields) do
		assert(type(state[key]) == "table", "state protocol: missing list " .. key)
		for index in pairs(state[key]) do
			assert(type(index) == "number", "state protocol: expected list " .. key)
		end
	end
	return state, body
end

function M.new(mode, session, directory)
	assert(mode == "normal" or mode == "state_only" or mode == "state_history", "invalid context mode")
	local self = { mode = mode, requests = 0, responses = 0, updates = 0, errors = {}, usage = {}, state_bytes = {}, observations = 0 }
	local seen, instructions = {}, {}
	local function save(name, value)
		local file = assert(io.open(directory .. "/" .. name, "w"))
		file:write(json.encode(value), "\n")
		file:close()
	end
	save("initial-context.json", session.messages)
	for _, message in ipairs(session.messages) do
		seen[message] = true
		if message.role == "user" and not message.tool_name then
			instructions[#instructions + 1] = { role = "user", text = message.text }
		end
	end
	if mode ~= "normal" then
		session.system_prompt = session:get_system_prompt() .. [[

Experimental explicit-state protocol:
On EVERY response, including the final answer, emit one <agent_state>JSON</agent_state>
block in your assistant text, alongside any normal native tool calls or final answer.
Use this object: {"goal":"...","current_beliefs":[],"completed":[],"open_questions":[],
"planned_next":[],"constraints":[],"rejected":[],"verification":[]}.
Keep the entire JSON under 8000 UTF-8 bytes. This is working memory, not a reasoning transcript.
Update it from the latest results BEFORE choosing the next action. Preserve exact paths,
critical edit tags, user constraints, unresolved questions, and disproved hypotheses.
Use concise objects with evidence references for beliefs, completed work, and rejected
hypotheses. Distinguish speculation from observed facts. Verification must name the command,
result, and which file versions it covers; invalidate it after relevant changes.
Original user instructions remain authoritative, with later corrections superseding earlier ones.
The harness supplies your current state and latest observations. Older transcript may be
unavailable. Raw observation files are retrievable with read or run at the paths supplied
with observations. Retrieve specific evidence when needed. Do not store memory files in the repo.
Do not spend a separate tool call updating state. Continue the actual task in the same response.
]]
	end
	function self.before_step(current)
		local fresh = {}
		for _, message in ipairs(current.messages) do
			if not seen[message] and not message._explicit_state then fresh[#fresh + 1] = message end
		end
		local archive
		if #fresh > 0 then
			self.observations = self.observations + 1
			archive = string.format("observation-%04d.json", self.observations)
			save(archive, fresh)
		end
		if mode == "state_only" then
			local active = clone(instructions)
			if self.state then active[#active + 1] = { role = "user", text = "Current explicit state:\n" .. self.state, _explicit_state = true } end
			for _, message in ipairs(fresh) do
				if message.role == "assistant" then
					local calls = {}
					for _, item in ipairs(message.provider_items or {}) do
						if item.type == "function_call" then calls[#calls + 1] = clone(item) end
					end
					if #calls > 0 then active[#active + 1] = { role = "assistant", text = "", provider_items = calls } end
				else
					active[#active + 1] = clone(message)
				end
			end
			current.messages = active
			current.compaction_summary, current.compaction_details, current.last_usage = nil, nil, nil
		elseif mode == "state_history" then
			local active = {}
			for _, message in ipairs(current.messages) do
				if not message._explicit_state then active[#active + 1] = message end
			end
			if self.state then active[#active + 1] = { role = "user", text = "Current explicit state:\n" .. self.state, _explicit_state = true } end
			current.messages = active
		end
		if mode ~= "normal" and archive then
			current.messages[#current.messages + 1] = { role = "user", text = "Latest observation evidence: " .. directory .. "/" .. archive, _explicit_state = true }
		end
		for _, message in ipairs(current.messages) do seen[message] = true end
	end
	function self.on_request(request)
		self.requests = self.requests + 1
		local request_index = self.requests
		-- Capture the actual serialized provider body, not merely an option label.
		request.on_request_body = function(body)
			-- Preserve serialization and object order for cache-prefix investigations.
			local file = assert(io.open(directory .. string.format("/provider-request-%04d.json", request_index), "w"))
			file:write(body, "\n")
			file:close()
		end
		if request_index == 1 then
			local baseline = {}
			for key, value in pairs(request) do baseline[key] = value end
			baseline.tool_scope = "all"
			local body = require("agent.providers.codex")._request_body(baseline)
			save("tool-scope-baseline.json", { tools = json.decode(body).tools })
		end
		-- Snapshot the exact model-facing message fields, including provider items.
		save(string.format("request-%04d.json", self.requests), {
			system_prompt = request.system_prompt, messages = request.messages,
			model = request.model, reasoning_effort = request.reasoning_effort, context_mode = mode,
			tool_scope = request.tool_scope or "all",
		})
		if mode == "state_only" then
			for _, message in ipairs(request.messages) do
				for _, item in ipairs(message.provider_items or {}) do
					assert(item.type == "function_call", "state-only leaked provider history")
				end
			end
		end
	end
	function self.on_response(response)
		self.responses = self.responses + 1
		save(string.format("response-%04d.json", self.responses), response)
		if response._usage then self.usage[#self.usage + 1] = clone(response._usage) end
		if mode == "normal" then return end
		local ok, state, body = pcall(M.parse, response.text)
		if not ok then
			self.errors[#self.errors + 1] = tostring(state)
			error(state)
		end
		self.state = body
		self.updates = self.updates + 1
		self.state_bytes[#self.state_bytes + 1] = #body
		save(string.format("state-%04d.json", self.responses), state)
		response.text = response.text:gsub("<agent_state>.-</agent_state>", ""):match("^%s*(.-)%s*$")
	end
	function self.report()
		return { mode = mode, requests = self.requests, responses = self.responses, updates = self.updates,
			errors = self.errors, state_bytes = self.state_bytes, observations = self.observations }
	end
	return self
end

return M
