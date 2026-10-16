local scp = require("semantic_code_painter")
local render = require("semantic_code_painter.render")

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local src = tmp .. "/Foo.kt"
write(src, 'fun main() {\n    log.info("hi")\n    println("noise")\n}\n')
write(
  tmp .. "/tags.json",
  [[
{
  "feature": "logging",
  "tag": "Logging",
  "language": "kotlin",
  "files": [
    {
      "path": "Foo.kt",
      "spans": [
        {"tag":"Logging","rule":"call-on-logger-symbol","evidence":"log.info(\"hi\")","startLine":1,"startCol":4,"endLine":1,"endCol":18},
        {"tag":"Logging","rule":"print","evidence":"println(\"noise\")","startLine":2,"startCol":4,"endLine":2,"endCol":20}
      ]
    }
  ]
}
]]
)

scp.setup({ root = tmp })
vim.cmd.edit(vim.fn.fnameescape(src))

local count = scp.render()
assert(count == 2, "expected 2 spans rendered, got " .. tostring(count))

local marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(#marks == 2, "expected 2 extmarks, got " .. #marks)
assert(marks[1][4].sign_text ~= nil, "expected first extmark to carry a sign")

scp.clear()
assert(#vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, {}) == 0, "expected clear to remove extmarks")

print("PASS")
vim.cmd("qa!")
