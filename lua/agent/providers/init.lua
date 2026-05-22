local json = require("agent.util.json")
local fs = require("agent.util.fs")
local uv = require("luv")
local config = require("agent.config")

local providers = {}

local PROVIDER_MODULES = {
	codex = "agent.providers.codex",
	bedrock = "agent.providers.bedrock",
}

local cache = {}

-- Buffer before actual expiry to refresh early (5 minutes)
local EXPIRY_BUFFER_SEC = 300

local function get_mtime(path)
	local stat = uv.fs_stat(path)
	if stat then
		return stat.mtime.sec
	end
	return 0
end

local function is_expired(body)
	-- Check for expiresAt (epoch seconds) or expiresAtMs (epoch milliseconds)
	local expires_at = json.number_field(body, "expiresAt")
	if not expires_at then
		local expires_ms = json.number_field(body, "expiresAtMs")
		if expires_ms then
			expires_at = expires_ms / 1000
		end
	end
	if not expires_at then
		-- Also check "expires" field (used by codex OAuth tokens, in ms)
		local expires = json.number_field(body, "expires")
		if expires then
			expires_at = expires / 1000
		end
	end
	if not expires_at then
		return false
	end
	local now = os.time()
	return now >= (expires_at - EXPIRY_BUFFER_SEC)
end

local function run_credential_process(command)
	local handle = io.popen(command .. " 2>/dev/null", "r")
	if not handle then
		return nil, "failed to run credential_process"
	end
	local output = handle:read("*a")
	local ok = handle:close()
	if not ok or not output or output == "" then
		return nil, "credential_process returned no output"
	end
	return output
end

local function refresh_credentials(credentials_path, body)
	-- Strategy 1: credential_process field in the credentials file
	-- If present, run the command and use its output as new credentials
	local credential_process = json.field(body, "credential_process")
	if credential_process then
		local new_body, err = run_credential_process(credential_process)
		if new_body then
			-- Validate the new credentials have required fields
			local access_key = json.field(new_body, "accessKeyId")
			if access_key then
				-- Preserve the credential_process and provider fields
				local cjson = require("cjson")
				local ok_decode, new_tbl = pcall(cjson.decode, new_body)
				if ok_decode and type(new_tbl) == "table" then
					new_tbl.credential_process = credential_process
					local provider = json.field(body, "provider")
					if provider then
						new_tbl.provider = provider
					end
					local model = json.field(body, "model")
					if model then
						new_tbl.model = model
					end
					new_body = cjson.encode(new_tbl)
				end
				-- Write refreshed credentials back to disk
				pcall(fs.write_file, credentials_path, new_body)
				cache.path = credentials_path
				cache.mtime = get_mtime(credentials_path)
				cache.body = new_body
				cache.parsed = nil
				return new_body
			end
		end
		-- credential_process failed; fall through to return stale credentials
		io.stderr:write("[warn] credential_process failed: " .. (err or "unknown error") .. "\n")
	end

	-- Strategy 2: If the file has been updated externally (e.g., by a cron job
	-- or another process), re-read it from disk by invalidating the cache
	cache.path = nil
	cache.mtime = nil
	cache.body = nil
	cache.parsed = nil
	local fresh_body = fs.read_file(credentials_path)
	if fresh_body and not is_expired(fresh_body) then
		cache.path = credentials_path
		cache.mtime = get_mtime(credentials_path)
		cache.body = fresh_body
		return fresh_body
	end

	-- Could not refresh — return the original (possibly expired) body
	io.stderr:write("[warn] credentials at " .. credentials_path .. " appear expired and could not be refreshed\n")
	return body
end

local function read_credentials(credentials_path)
	local mtime = get_mtime(credentials_path)
	if cache.path == credentials_path and cache.mtime == mtime and cache.body then
		-- Check if cached credentials are expired
		if is_expired(cache.body) then
			return refresh_credentials(credentials_path, cache.body)
		end
		return cache.body
	end
	local body = fs.read_file(credentials_path)
	cache.path = credentials_path
	cache.mtime = mtime
	cache.body = body
	cache.parsed = nil

	-- Check if freshly-read credentials are already expired
	if is_expired(body) then
		return refresh_credentials(credentials_path, body)
	end

	return body
end

function providers.credentials_body(credentials_path)
	return read_credentials(credentials_path or config.default_credentials_path())
end

local function detect_provider(credentials_path)
	local body = read_credentials(credentials_path)
	local provider = json.field(body, "provider")
	if provider and PROVIDER_MODULES[provider] then
		return provider
	end
	return "codex"
end

function providers.load(credentials_path)
	credentials_path = credentials_path or config.default_credentials_path()
	local name = detect_provider(credentials_path)
	local mod = require(PROVIDER_MODULES[name])
	return mod, name
end
function providers._invalidate_cache()
	cache.path = nil
	cache.mtime = nil
	cache.body = nil
	cache.parsed = nil
end

return providers
