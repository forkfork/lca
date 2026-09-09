local json = require("agent.util.json")
local fs = require("agent.util.fs")
local uv = require("luv")
local config = require("agent.config")
local codex_oauth = require("agent.codex_oauth")

local providers = {}
local cache = {}
local EXPIRY_BUFFER_SEC = 300
local refresh_handler = codex_oauth.refresh

local function get_mtime(path)
	local stat = uv.fs_stat(path)
	return stat and stat.mtime.sec or 0
end

local function decode_body(body)
	local ok, value = pcall(json.decode, body or "")
	return ok and type(value) == "table" and value or nil
end

local function codex_credentials_body(root_body)
	local root = decode_body(root_body)
	if not root then error("invalid Codex credentials file; run lca login") end
	local selected = root
	if type(root.providers) == "table" then
		selected = root.providers.codex or root.providers.openai
	end
	if type(selected) ~= "table" or not selected.access or not selected.accountId then
		error("credentials file has no Codex OAuth credentials; run lca login")
	end
	selected.provider = "codex"
	return json.encode(selected)
end

local function bedrock_credentials_body(root_body)
	local root = decode_body(root_body)
	if not root then error("invalid credentials file") end
	local selected = type(root.providers) == "table" and root.providers.bedrock or root
	if type(selected) ~= "table" then error("credentials file has no Bedrock provider configuration") end
	selected.provider = "bedrock"
	return json.encode(selected)
end

local function selected_provider(root_body)
	local root = decode_body(root_body)
	if type(root) == "table" and root.provider == "bedrock" then return "bedrock" end
	return "codex"
end

local function credentials_tables(root_body)
	local root = decode_body(root_body)
	if not root then error("invalid Codex credentials file; run lca login") end
	local selected = root
	if type(root.providers) == "table" then
		selected = root.providers.codex or root.providers.openai
	end
	if type(selected) ~= "table" or not selected.access or not selected.accountId then
		error("credentials file has no Codex OAuth credentials; run lca login")
	end
	return root, selected
end

local function is_expired(body)
	local expires_at = json.number_field(body, "expiresAt")
	if not expires_at then
		local expires_ms = json.number_field(body, "expiresAtMs") or json.number_field(body, "expires")
		if expires_ms then expires_at = expires_ms / 1000 end
	end
	return expires_at ~= nil and os.time() >= (expires_at - EXPIRY_BUFFER_SEC)
end

local function read_credentials(path)
	local mtime = get_mtime(path)
	if cache.path == path and cache.mtime == mtime and cache.body then return cache.body end
	local body = fs.read_file(path)
	if not body then error("cannot read Codex credentials at " .. tostring(path) .. "; run lca login") end
	cache.path, cache.mtime, cache.body = path, mtime, body
	return body
end

local function write_credentials_atomic(path, root)
	local body = json.encode(root) .. "\n"
	local tmp = path .. ".refresh-" .. tostring(uv.getpid()) .. "-" .. tostring(uv.hrtime())
	local file, open_err = io.open(tmp, "w")
	if not file then return nil, open_err end
	local wrote, write_err = file:write(body)
	local closed, close_err = file:close()
	if not wrote or not closed then
		pcall(uv.fs_unlink, tmp)
		return nil, write_err or close_err or "failed to write credentials"
	end
	local chmod_ok, chmod_err = uv.fs_chmod(tmp, tonumber("600", 8))
	if not chmod_ok then
		pcall(uv.fs_unlink, tmp)
		return nil, chmod_err
	end
	local renamed, rename_err = uv.fs_rename(tmp, path)
	if not renamed then
		pcall(uv.fs_unlink, tmp)
		return nil, rename_err
	end
	local stat = uv.fs_stat(path)
	cache.path, cache.mtime, cache.body = path, stat and stat.mtime.sec or 0, body
	return true
end

local function refresh_credentials(path, failed_access)
	local root_body = fs.read_file(path)
	if not root_body then error("cannot read Codex credentials at " .. tostring(path) .. "; run lca login") end
	local root, selected = credentials_tables(root_body)
	if failed_access and selected.access ~= failed_access then
		cache.path, cache.mtime, cache.body = nil, nil, nil
		return codex_credentials_body(root_body)
	end
	if type(selected.refresh) ~= "string" or selected.refresh == "" then
		error("Codex credentials cannot be refreshed automatically; run lca login")
	end
	local ok, refreshed = pcall(refresh_handler, selected.refresh)
	if not ok then
		error("Codex token refresh failed: " .. tostring(refreshed) .. "; run lca login")
	end
	if type(refreshed) ~= "table" or type(refreshed.access) ~= "string"
		or refreshed.access == "" or type(refreshed.expires_in) ~= "number"
	then
		error("Codex token refresh returned invalid credentials; run lca login")
	end
	selected.access = refreshed.access
	selected.refresh = refreshed.refresh or selected.refresh
	selected.expires = math.floor((os.time() + refreshed.expires_in) * 1000)
	selected.expiresAt = nil
	selected.expiresAtMs = nil
	selected.provider = "codex"
	local wrote, write_err = write_credentials_atomic(path, root)
	if not wrote then
		error("failed to persist refreshed Codex credentials: " .. tostring(write_err))
	end
	return json.encode(selected)
end

function providers.credentials_body(credentials_path)
	local path = credentials_path or config.default_credentials_path()
	local root_body = read_credentials(path)
	if selected_provider(root_body) == "bedrock" then
		return bedrock_credentials_body(root_body)
	end
	local selected = codex_credentials_body(root_body)
	if is_expired(selected) then
		return refresh_credentials(path)
	end
	return selected
end

function providers.refresh_credentials(credentials_path, failed_access)
	return refresh_credentials(credentials_path or config.default_credentials_path(), failed_access)
end

function providers.load(credentials_path)
	local body = read_credentials(credentials_path or config.default_credentials_path())
	if selected_provider(body) == "bedrock" then
		return require("agent.providers.bedrock"), "bedrock"
	end
	return require("agent.providers.codex"), "codex"
end

function providers.default_model()
	return config.default_model()
end

function providers._invalidate_cache()
	cache.path, cache.mtime, cache.body = nil, nil, nil
end

function providers._set_refresh_handler(handler)
	refresh_handler = handler or codex_oauth.refresh
end

return providers
