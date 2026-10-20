local palette = require("cint.core.colors")

local M = {}

M.name = "color"

local function spec(ctx, opts)
  return vim.tbl_extend("force", ctx.tag_spec, opts or {})
end

function M.define(ctx, opts)
  local s = spec(ctx, opts)
  vim.api.nvim_set_hl(0, palette.group(ctx.tag), { bg = s.bg or s.color })
  vim.api.nvim_set_hl(0, palette.sign_group(ctx.tag), { fg = s.sign })
end

function M.extmark(ctx, opts)
  local s = spec(ctx, opts)
  return {
    hl_group = palette.group(ctx.tag),
    sign_text = s.icon,
    sign_hl_group = palette.sign_group(ctx.tag),
  }
end

return M
