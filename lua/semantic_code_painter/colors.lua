local M = {}

M.defaults = {
  Logging = { bg = "#1f2d1f", sign = "#7fbf7f", icon = "≡" },
  ["Error Handling"] = { bg = "#2d1f1f", sign = "#e06c75", icon = "!" },
  Validation = { bg = "#2d2a1f", sign = "#e5c07b", icon = "?" },
  ["Business Logic"] = { bg = "#1f2430", sign = "#61afef", icon = "◆" },
}

M.fallback = { bg = "#2a2a2a", sign = "#9aa0a6", icon = "·" }

function M.sanitize(tag)
  return (tag:gsub("[^%w]", "_"))
end

function M.group(tag)
  return "SCPainter_" .. M.sanitize(tag)
end

function M.sign_group(tag)
  return "SCPainter_" .. M.sanitize(tag) .. "_Sign"
end

function M.spec(tag, user_colors)
  return (user_colors and user_colors[tag]) or M.defaults[tag] or M.fallback
end

function M.define(tag, user_colors)
  local spec = M.spec(tag, user_colors)
  vim.api.nvim_set_hl(0, M.group(tag), { bg = spec.bg })
  vim.api.nvim_set_hl(0, M.sign_group(tag), { fg = spec.sign })
  return spec
end

return M
