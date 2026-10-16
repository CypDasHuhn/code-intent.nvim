local palette = require("semantic_code_painter.colors")

local M = {}

M.name = "color"

local function spec(tag, opts)
  return vim.tbl_extend("force", palette.spec(tag), opts or {})
end

function M.define(tag, opts)
  local s = spec(tag, opts)
  vim.api.nvim_set_hl(0, palette.group(tag), { bg = s.bg })
  vim.api.nvim_set_hl(0, palette.sign_group(tag), { fg = s.sign })
end

function M.extmark(tag, opts)
  local s = spec(tag, opts)
  return {
    hl_group = palette.group(tag),
    sign_text = s.icon,
    sign_hl_group = palette.sign_group(tag),
  }
end

return M
