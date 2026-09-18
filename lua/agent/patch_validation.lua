local lint = require("agent.lint")
local function normalize_lint_output(lint_output, display_path)
	local text = tostring(lint_output or ""):gsub("%s+$", "")
	if text == "" then
		return "syntax checker reported an error"
	end
	return text:gsub("/tmp/%S+%.%w+", display_path)
end

local function introduced_lint_error(target, original_content, candidate_content)
	local candidate_lint = lint.check_content(target, candidate_content)
	if not candidate_lint then
		return nil
	end

	local original_lint = lint.check_content(target, original_content)
	if original_lint and normalize_lint_output(original_lint, target) == normalize_lint_output(candidate_lint, target) then
		return nil
	end

	return candidate_lint
end

return { check_candidate = introduced_lint_error }
