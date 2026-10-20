local palette = require("cint.core.colors")

local M = {}

M.name = "ignore"

M.default_fg = "#555555"

function M.define(ctx, opts)
  local fg = (opts and (opts.fg or opts.color)) or M.default_fg
  vim.api.nvim_set_hl(0, palette.ignore_group(ctx.meaning), { fg = fg })
end

function M.extmark(ctx, opts)
  return {
    hl_group = palette.ignore_group(ctx.meaning),
  }
end

return M
