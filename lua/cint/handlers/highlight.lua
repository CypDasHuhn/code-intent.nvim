local palette = require("cint.colors")

local M = {}

M.name = "highlight"

local function spec(ctx, opts)
  return vim.tbl_extend("force", ctx.tag_spec, opts or {})
end

function M.define(ctx, opts)
  local s = spec(ctx, opts)
  vim.api.nvim_set_hl(0, palette.highlight_group(ctx.meaning, ctx.tag), {
    bg = s.bg or s.color,
  })
end

function M.extmark(ctx, opts)
  return {
    hl_group = palette.highlight_group(ctx.meaning, ctx.tag),
  }
end

return M
