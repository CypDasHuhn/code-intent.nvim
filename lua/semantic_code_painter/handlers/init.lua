local M = {}

M.registry = {
  color = require("semantic_code_painter.handlers.color"),
  conceal = require("semantic_code_painter.handlers.conceal"),
}

function M.get(name)
  return M.registry[name]
end

return M
