local config = {}

function config.home()
	return os.getenv("HOME") or "."
end

function config.default_credentials_path()
	return config.home() .. "/.lca-credentials.json"
end

return config
