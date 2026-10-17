local M = {}

M.defaults = {
  Logging = { bg = "#1f2d1f", sign = "#7fbf7f", icon = "≡", priority = 10 },
  ErrorHandling = { bg = "#2d1f1f", sign = "#e06c75", icon = "!", priority = 50 },
  ["Error Handling"] = { bg = "#2d1f1f", sign = "#e06c75", icon = "!", priority = 50 },
  Validation = { bg = "#2d2a1f", sign = "#e5c07b", icon = "?", priority = 30 },
  ["Business Logic"] = { bg = "#1f2430", sign = "#61afef", icon = "◆", priority = 40 },
  UNTAGGED = { bg = "#2a2a2a", sign = "#9aa0a6", icon = "·", priority = 0 },
}

M.fallback = { bg = "#2a2a2a", sign = "#9aa0a6", icon = "·", priority = 0 }

function M.sanitize(tag)
  return (tostring(tag or "default"):gsub("[^%w]", "_"))
end

function M.group(tag)
  return "SCPainter_" .. M.sanitize(tag)
end

function M.sign_group(tag)
  return "SCPainter_" .. M.sanitize(tag) .. "_Sign"
end

function M.highlight_group(meaning, tag)
  return "SCPainter_HL_" .. M.sanitize(meaning) .. "_" .. M.sanitize(tag)
end

function M.ignore_group(meaning)
  return "SCPainter_IGNORE_" .. M.sanitize(meaning)
end

function M.spec(tag)
  return M.defaults[tag] or M.fallback
end

return M
