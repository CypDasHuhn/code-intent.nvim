local M = {}

M.name = "conceal"

function M.extmark(tag, opts)
  return { conceal = (opts and opts.char) or "…" }
end

return M
