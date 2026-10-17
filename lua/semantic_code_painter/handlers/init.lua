local M = {}

M.registry = {
  color = require("semantic_code_painter.handlers.color"),
  conceal = require("semantic_code_painter.handlers.conceal"),
  highlight = require("semantic_code_painter.handlers.highlight"),
  ignore = require("semantic_code_painter.handlers.ignore"),
}

function M.get(name)
  return M.registry[name]
end

return M
