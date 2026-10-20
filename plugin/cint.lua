if vim.g.loaded_cint == 1 then
  return
end
vim.g.loaded_cint = 1

local cint = require("cint")

require("cint.commands").register(cint)
