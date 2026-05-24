#!/usr/bin/env lua

pcall(require, "luarocks.loader")

local ok_cjson, cjson = pcall(require, "cjson")

local function usage()
	io.stderr:write([[usage: lca-context-stats [--session PATH] [--log PATH] [--top N] [--json]

Summarize LCA session/context and Codex debug-log pressure points.

Defaults:
  --session .lca-session.json
  --log     /tmp/lca.log
  --top     8
]])
end

local function parse_args(argv)
	local opts = {
		session = ".lca-session.json",
		log = "/tmp/lca.log",
		top = 8,
		json = false,
	}
	local i = 1
	while i <= #argv do
		local arg = argv[i]
		if arg == "--session" then
			i = i + 1
			opts.session = argv[i]
		elseif arg == "--log" then
			i = i + 1
			opts.log = argv[i]
		elseif arg == "--top" then
			i = i + 1
			opts.top = math.max(1, tonumber(argv[i]) or opts.top)
		elseif arg == "--json" then
			opts.json = true
		elseif arg == "-h" or arg == "--help" then
			usage()
			os.exit(0)
		else
			error("unknown argument: " .. tostring(arg))
		end
		i = i + 1
	end
	return opts
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	return text
end

local function estimate_tokens(text)
	return math.ceil(#tostring(text or "") / 4)
end

local function label_for(message)
	if message.tool_name then
		return "tool:" .. tostring(message.tool_name)
	end
	return tostring(message.role or "unknown")
end

local function preview(text)
	text = tostring(text or ""):gsub("\r", ""):gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	if #text > 120 then
		text = text:sub(1, 117) .. "..."
	end
	return text
end

local function sorted_pairs_by_value(map)
	local rows = {}
	for key, value in pairs(map) do
		rows[#rows + 1] = { key = key, value = value }
	end
	table.sort(rows, function(a, b)
		if a.value == b.value then return a.key < b.key end
		return a.value > b.value
	end)
	return rows
end

local function analyze_session(path, top)
	local text = read_file(path)
	local out = {
		path = path,
		exists = text ~= nil,
		messages = 0,
		session_tokens = 0,
		buckets = {},
		largest = {},
		slimmed = { count = 0, bytes_removed = 0 },
		last_usage = nil,
		usage_history = {},
		usage_summary = nil,
		compaction = nil,
	}
	if not text then
		return out
	end
	if not ok_cjson then
		out.error = "lua-cjson not available"
		return out
	end
	local ok, data = pcall(cjson.decode, text)
	if not ok or type(data) ~= "table" then
		out.error = "invalid JSON"
		return out
	end
	local messages = type(data.messages) == "table" and data.messages or {}
	out.messages = #messages
	out.last_usage = type(data.last_usage) == "table" and data.last_usage or nil
	out.usage_history = type(data.usage_history) == "table" and data.usage_history or {}
	if #out.usage_history > 0 then
		local min_pct = nil
		local max_pct = nil
		local sum_pct = 0
		local trend = {}
		local trend_start = math.max(1, #out.usage_history - 4)
		for i, sample in ipairs(out.usage_history) do
			local prompt = tonumber(sample.prompt_tokens) or 0
			local cached = tonumber(sample.cached_tokens) or 0
			local pct = tonumber(sample.cached_percent)
			if not pct then
				pct = prompt > 0 and (cached / prompt * 100) or 0
			end
			min_pct = min_pct and math.min(min_pct, pct) or pct
			max_pct = max_pct and math.max(max_pct, pct) or pct
			sum_pct = sum_pct + pct
			if i >= trend_start then
				trend[#trend + 1] = string.format("%.1f%%", pct)
			end
		end
		out.usage_summary = {
			count = #out.usage_history,
			avg_cached_percent = sum_pct / #out.usage_history,
			min_cached_percent = min_pct or 0,
			max_cached_percent = max_pct or 0,
			trend = table.concat(trend, " -> "),
		}
	end
	out.compaction = {
		has_summary = type(data.compaction_summary) == "string" and data.compaction_summary ~= "",
		details = type(data.compaction_details) == "table" and data.compaction_details or nil,
	}
	for index, message in ipairs(messages) do
		local label = label_for(message)
		local tokens = estimate_tokens(message.role) + estimate_tokens(message.tool_name) + estimate_tokens(message.text) + 6
		out.session_tokens = out.session_tokens + tokens
		out.buckets[label] = (out.buckets[label] or 0) + tokens
		if message.slimmed then
			out.slimmed.count = out.slimmed.count + 1
			local before = tonumber(message.slimmed_from_bytes) or #(message.text or "")
			out.slimmed.bytes_removed = out.slimmed.bytes_removed + math.max(0, before - #(message.text or ""))
		end
		out.largest[#out.largest + 1] = {
			index = index,
			label = label,
			tokens = tokens,
			bytes = #(message.text or ""),
			preview = preview(message.text),
		}
	end
	table.sort(out.largest, function(a, b) return a.tokens > b.tokens end)
	while #out.largest > top do
		out.largest[#out.largest] = nil
	end
	return out
end

local function parse_kv_numbers(line)
	local row = {}
	for key, value in line:gmatch("([%w_]+)=([%w%.%-]+)") do
		local n = tonumber(value)
		row[key] = n or value
	end
	return row
end

local function analyze_log(path)
	local text = read_file(path)
	local out = {
		path = path,
		exists = text ~= nil,
		attempts = 0,
		successes = 0,
		first_byte_timeouts = 0,
		other_timeouts = 0,
		cache_samples = {},
		cache_unavailable = 0,
		cache_unavailable_reasons = {},
		prefix_hashes = {},
		prefix_stability = {},
		requests = {},
		early_cutoffs = 0,
		canonicalized = 0,
		slim_audits = {},
		max_body_bytes = 0,
		max_longest_message = 0,
	}
	if not text then
		return out
	end
	for line in text:gmatch("[^\n]+") do
		if line:find("%[codex%] attempt %d+/%d+ model=") then
			out.attempts = out.attempts + 1
			local kv = parse_kv_numbers(line)
			local prefix = line:match('prefix_hashes="([^"]*)"') or ""
			local req = {
				body_bytes = tonumber(kv.body_bytes) or 0,
				longest_message = tonumber(kv.longest_message) or 0,
				message_chars = tonumber(kv.message_chars) or 0,
				prefix_hashes = prefix,
			}
			out.requests[#out.requests + 1] = req
			out.max_body_bytes = math.max(out.max_body_bytes, req.body_bytes)
			out.max_longest_message = math.max(out.max_longest_message, req.longest_message)
			for size, hash in prefix:gmatch("(%w+)=([%x]+)") do
				out.prefix_hashes[size] = out.prefix_hashes[size] or {}
				out.prefix_hashes[size][hash] = true
			end
		elseif line:find("[codex] prefix stability", 1, true) then
			for size, status in line:gmatch("(%w+)=([%w_]+)") do
				if size ~= "cache_key" then
					out.prefix_stability[size] = out.prefix_stability[size] or {}
					out.prefix_stability[size][status] = (out.prefix_stability[size][status] or 0) + 1
				end
			end
		elseif line:find("%[codex%] attempt %d+ succeeded") then
			out.successes = out.successes + 1
		elseif line:find("timeout/first_byte", 1, true) then
			out.first_byte_timeouts = out.first_byte_timeouts + 1
		elseif line:find("Codex transport error %(timeout", 1, false) then
			out.other_timeouts = out.other_timeouts + 1
		elseif line:find("%[codex%] prompt cache prompt_tokens=") then
			local prompt, cached, pct = line:match("prompt_tokens=(%d+)%s+cached_tokens=(%d+)%s+cached=([%d%.]+)%%")
			out.cache_samples[#out.cache_samples + 1] = {
				prompt_tokens = tonumber(prompt) or 0,
				cached_tokens = tonumber(cached) or 0,
				cached_percent = tonumber(pct) or 0,
			}
		elseif line:find("%[codex%] prompt cache usage unavailable") then
			out.cache_unavailable = out.cache_unavailable + 1
			local reason = line:match("reason=([%w_%-]+)") or "unknown"
			out.cache_unavailable_reasons[reason] = (out.cache_unavailable_reasons[reason] or 0) + 1
		elseif line:find("%[codex%] early tool%-call cutoff") then
			out.early_cutoffs = out.early_cutoffs + 1
		elseif line:find("%[codex%] canonicalized tool response") then
			out.canonicalized = out.canonicalized + 1
		elseif line:find("[context] slim audit", 1, true) then
			local kv = parse_kv_numbers(line)
			out.slim_audits[#out.slim_audits + 1] = {
				messages = tonumber(kv.messages) or 0,
				bytes_removed = tonumber(kv.bytes_removed) or 0,
				approx_tokens_saved = tonumber(kv.approx_tokens_saved) or 0,
				session_tokens = tonumber(kv.session_tokens) or 0,
				reasons = line:match('reasons="([^"]*)"') or "",
				labels = line:match('labels="([^"]*)"') or "",
				files = line:match('files="([^"]*)"') or "",
			}
		end
	end
	return out
end

local function count_set(set)
	local count = 0
	for _ in pairs(set or {}) do count = count + 1 end
	return count
end

local function fmt_num(n)
	n = tonumber(n) or 0
	if n >= 1000000 then return string.format("%.1fm", n / 1000000) end
	if n >= 1000 then return string.format("%.1fk", n / 1000) end
	return tostring(math.floor(n))
end

local function print_text(summary)
	local session = summary.session
	local log = summary.log

	print("lca context stats")
	print("")
	print("session: " .. session.path .. (session.exists and "" or " (missing)"))
	if session.error then
		print("  error: " .. session.error)
	else
		print("  messages:       " .. tostring(session.messages))
		print("  session tokens: " .. fmt_num(session.session_tokens))
		print("  slimmed:        " .. tostring(session.slimmed.count) .. " messages, " .. tostring(session.slimmed.bytes_removed) .. " bytes removed")
		if session.last_usage then
			print("  last usage:     total=" .. fmt_num(session.last_usage.total_tokens) ..
				" prompt=" .. fmt_num(session.last_usage.prompt_tokens) ..
				" cached=" .. fmt_num(session.last_usage.cached_tokens) ..
				" at_message=#" .. tostring(session.last_usage.message_index or "?"))
		end
		if session.usage_summary then
			print("  usage history:  " .. tostring(session.usage_summary.count) ..
				" samples, avg cache=" .. string.format("%.1f", session.usage_summary.avg_cached_percent) .. "%" ..
				", range=" .. string.format("%.1f", session.usage_summary.min_cached_percent) .. "-" .. string.format("%.1f", session.usage_summary.max_cached_percent) .. "%")
			print("  cache trend:    " .. session.usage_summary.trend)
		end
		if session.compaction and session.compaction.details then
			local details = session.compaction.details
			local read_files = details.read_files or details.readFiles or {}
			local modified_files = details.modified_files or details.modifiedFiles or {}
			print("  file context:   read=" .. tostring(#read_files) .. " modified=" .. tostring(#modified_files))
		end
		print("")
		print("by source")
		for _, row in ipairs(sorted_pairs_by_value(session.buckets)) do
			print(string.format("  %-16s %8s tokens", row.key, fmt_num(row.value)))
		end
		print("")
		print("largest messages")
		for _, item in ipairs(session.largest) do
			print(string.format("  #%d %-16s %8s tokens  %d bytes  %s",
				item.index,
				item.label,
				fmt_num(item.tokens),
				item.bytes,
				item.preview))
		end
	end

	print("")
	print("log: " .. log.path .. (log.exists and "" or " (missing)"))
	if log.exists then
		print("  attempts:       " .. tostring(log.attempts))
		print("  successes:      " .. tostring(log.successes))
		print("  first-byte t/o: " .. tostring(log.first_byte_timeouts))
		print("  other t/o:      " .. tostring(log.other_timeouts))
		print("  max body bytes: " .. fmt_num(log.max_body_bytes))
		print("  longest msg:    " .. fmt_num(log.max_longest_message) .. " bytes")
		print("  early cutoffs:  " .. tostring(log.early_cutoffs))
		print("  canonicalized:  " .. tostring(log.canonicalized))
		print("  slim audits:    " .. tostring(#log.slim_audits))
		if #log.slim_audits > 0 then
			local last = log.slim_audits[#log.slim_audits]
			print("  latest slim:    " .. tostring(last.messages) .. " messages, saved ~" .. fmt_num(last.approx_tokens_saved) .. " tokens, reasons=" .. tostring(last.reasons))
		end
		local unavailable = tostring(log.cache_unavailable) .. " unavailable"
		local unavailable_reasons = sorted_pairs_by_value(log.cache_unavailable_reasons or {})
		if #unavailable_reasons > 0 then
			local parts = {}
			for _, row in ipairs(unavailable_reasons) do
				parts[#parts + 1] = row.key .. "=" .. tostring(row.value)
			end
			unavailable = unavailable .. " (" .. table.concat(parts, ", ") .. ")"
		end
		print("  cache samples:  " .. tostring(#log.cache_samples) .. " measured, " .. unavailable)
		if #log.cache_samples > 0 then
			local last = log.cache_samples[#log.cache_samples]
			print("  latest cache:   " .. fmt_num(last.cached_tokens) .. "/" .. fmt_num(last.prompt_tokens) .. " tokens (" .. string.format("%.1f", last.cached_percent) .. "%)")
		end
		local sizes = {}
		for size in pairs(log.prefix_hashes) do sizes[#sizes + 1] = size end
		table.sort(sizes, function(a, b)
			if a == "full" then return false end
			if b == "full" then return true end
			return tonumber(a) < tonumber(b)
		end)
		if #sizes > 0 then
			print("")
			print("prefix hash stability")
			for _, size in ipairs(sizes) do
				local stability = log.prefix_stability[size] or {}
				local suffix = ""
				if stability.same or stability.changed or stability.new then
					suffix = string.format("  same=%d changed=%d new=%d",
						tonumber(stability.same) or 0,
						tonumber(stability.changed) or 0,
						tonumber(stability.new) or 0)
				end
				print(string.format("  %-6s %d unique%s", size, count_set(log.prefix_hashes[size]), suffix))
			end
		end
	end
end

local function main()
	local opts = parse_args(arg)
	local summary = {
		session = analyze_session(opts.session, opts.top),
		log = analyze_log(opts.log),
	}
	if opts.json then
		if not ok_cjson then
			error("lua-cjson is required for --json")
		end
		cjson.encode_sparse_array(true)
		print(cjson.encode(summary))
	else
		print_text(summary)
	end
end

local ok, err = pcall(main)
if not ok then
	io.stderr:write("error: " .. tostring(err) .. "\n")
	usage()
	os.exit(1)
end
