local scp = require("semantic_code_painter")
local render = require("semantic_code_painter.render")
local palette = require("semantic_code_painter.colors")

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local src = tmp .. "/Foo.kt"
write(
  src,
  'fun main() {\n    log.info("hi")\n    println("noise")\n    val x = compute()\n}\n'
)
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
        {"tag":"Noise","rule":"x","evidence":"println(\"noise\")","startLine":2,"startCol":4,"endLine":2,"endCol":20},
        {"tag":"Other","rule":"y","evidence":"val x = compute()","startLine":3,"startCol":4,"endLine":3,"endCol":21}
      ]
    }
  ]
}
]]
)

scp.setup({
  root = tmp,
  tags = {
    Logging = {
      color = { bg = "#101010", sign = "#202020", icon = "L" },
      conceal = { char = "~" },
    },
    Noise = { conceal = { char = "." } },
  },
})

vim.cmd.edit(vim.fn.fnameescape(src))

local count = scp.render()
assert(count == 3, "expected 3 spans rendered, got " .. tostring(count))

local marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(#marks == 3, "expected 3 extmarks, got " .. #marks)
assert(vim.trim(marks[1][4].sign_text or "") == "L", "Logging color handler should apply icon 'L'")
assert(marks[2][4].sign_text == nil, "conceal-only tag should not place a sign")
assert(
  vim.trim(marks[3][4].sign_text or "") == palette.fallback.icon,
  "unconfigured tag should use default handler"
)
assert(vim.wo.conceallevel == 2, "conceal handler should enable conceallevel")

scp.clear()
assert(#vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, {}) == 0, "expected clear to remove extmarks")

print("PASS")
vim.cmd("qa!")
