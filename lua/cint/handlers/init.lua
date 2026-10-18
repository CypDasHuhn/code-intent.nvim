local M = {}

M.registry = {
  color = require("cint.handlers.color"),
  conceal = require("cint.handlers.conceal"),
  highlight = require("cint.handlers.highlight"),
  ignore = require("cint.handlers.ignore"),
}

function M.get(name)
  return M.registry[name]
end

return M
