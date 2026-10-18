local M = {}

M.defaults = {}

M.fallback = { bg = "#2a2a2a", sign = "#9aa0a6", icon = "·", priority = 0 }

function M.sanitize(tag)
	return (tostring(tag or "default"):gsub("[^%w]", "_"))
end

function M.group(tag)
	return "Cint_" .. M.sanitize(tag)
end

function M.sign_group(tag)
	return "Cint_" .. M.sanitize(tag) .. "_Sign"
end

function M.highlight_group(meaning, tag)
	return "Cint_HL_" .. M.sanitize(meaning) .. "_" .. M.sanitize(tag)
end

function M.ignore_group(meaning)
	return "Cint_IGNORE_" .. M.sanitize(meaning)
end

function M.spec(tag)
	return M.defaults[tag] or M.fallback
end

return M
