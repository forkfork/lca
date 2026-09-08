local config = {}

config.DEFAULT_MODEL = "gpt-6-astra"

function config.home()
	return os.getenv("HOME") or "."
end

function config.default_credentials_path()
	return config.home() .. "/.lca-credentials.json"
end

function config.bedrock_credentials_path()
	return config.home() .. "/.lca-bedrock-credentials.json"
end

function config.default_model()
	return config.DEFAULT_MODEL
end

return config
