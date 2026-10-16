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
  'fun main() {\n    log.info("hi")\n    println("noise")\n    val x = compute()\n    val y = compute()\n}\n'
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
        {"tag":"Logging","startLine":1,"startCol":4,"endLine":1,"endCol":18},
        {"tag":"Noise","startLine":2,"startCol":4,"endLine":2,"endCol":20},
        {"tag":"Other","startLine":3,"startCol":4,"endLine":3,"endCol":21},
        {"tag":"Hollow","startLine":4,"startCol":4,"endLine":4,"endCol":21}
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
    Hollow = { conceal = { lines = true } },
  },
})

vim.cmd.edit(vim.fn.fnameescape(src))

local count = scp.render()
assert(count == 4, "expected 4 spans rendered, got " .. tostring(count))

local marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(#marks == 4, "expected 4 extmarks, got " .. #marks)
assert(vim.trim(marks[1][4].sign_text or "") == "L", "Logging color handler should apply icon 'L'")
assert(marks[2][4].sign_text == nil, "inline conceal-only tag should not place a sign")
assert(
  vim.trim(marks[3][4].sign_text or "") == palette.fallback.icon,
  "unconfigured tag should use default handler"
)
assert(marks[4][4].conceal_lines == "", "vertical conceal should set conceal_lines")

local height = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 5 }).all
assert(height == 5, "vertical conceal should reduce text height to 5, got " .. height)

vim.api.nvim_win_set_cursor(0, { 5, 0 })
scp.reveal_block()
local revealed = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 5 }).all
assert(revealed == 6, "cursor inside concealed block should reveal it, got height " .. revealed)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
scp.reveal_block()
local reconcealed = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 5 }).all
assert(reconcealed == 5, "cursor leaving the block should re-conceal it, got height " .. reconcealed)

scp.clear()
assert(#vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, {}) == 0, "expected clear to remove extmarks")

local stale_lines = { "fun main() {", '    println("hi")', "}" }
write(tmp .. "/Stale.kt", table.concat(stale_lines, "\n") .. "\n")
write(
  tmp .. "/tags.json",
  string.format(
    [[
{
  "files": [
    { "path": "Stale.kt", "hash": "%s", "spans": [
      {"tag":"Hollow","startLine":1,"startCol":4,"endLine":1,"endCol":18}
    ] }
  ]
}
]],
    vim.fn.sha256(table.concat(stale_lines, "\n"))
  )
)

scp.setup({ root = tmp, tags = { Hollow = { conceal = { lines = true } } } })
vim.cmd.edit(vim.fn.fnameescape(tmp .. "/Stale.kt"))
local fresh = scp.render()
assert(fresh == 1, "matching hash should render, got " .. tostring(fresh))

vim.api.nvim_buf_set_lines(0, -1, -1, false, { "// edited" })
local stale = scp.render()
assert(stale == 0, "stale artifact should not render, got " .. tostring(stale))
assert(#vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, {}) == 0, "stale file should have no extmarks")

print("PASS")
vim.cmd("qa!")
