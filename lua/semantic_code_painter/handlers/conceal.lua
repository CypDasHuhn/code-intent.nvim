local M = {}

M.name = "conceal"

function M.extmark(tag, opts)
  if opts and opts.lines then
    return { conceal_lines = "" }
  end
  return { conceal = (opts and opts.char) or "…" }
end

return M
