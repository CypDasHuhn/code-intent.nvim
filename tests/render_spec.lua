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

local meaning_src = tmp .. "/Meaning.kt"
write(
  meaning_src,
  'fun main() {\n    log.info("hi")\n    error("boom")\n    val x = compute()\n}\n'
)
write(
  tmp .. "/tags.json",
  [[
{
  "language": "kotlin",
  "intents": ["Logging", "ErrorHandling"],
  "files": [
    {
      "path": "Meaning.kt",
      "spans": [
        {"role":"source-intent","intents":["Logging"],"startLine":1,"startCol":4,"endLine":1,"endCol":18},
        {"role":"source-intent","intents":["ErrorHandling"],"startLine":2,"startCol":4,"endLine":2,"endCol":18},
        {"role":"source-intent","intents":["Logging"],"startLine":3,"startCol":4,"endLine":3,"endCol":23}
      ]
    }
  ]
}
]]
)

local function meaning_setup(intent_logging)
  scp.setup({
    root = tmp,
    intentMeanings = {
      Logging = intent_logging,
      ErrorHandling = "SHOW",
      UNTAGGED = "SHOW",
    },
    resolve = {
      precedence = { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" },
      default = "SHOW",
    },
    rules = {
      CONCEAL = { conceal = { lines = true } },
      SHOW = { highlight = true },
      IGNORE = { ignore = true },
    },
    tags = {
      Logging = { bg = "#101010", priority = 10 },
      ErrorHandling = { bg = "#202020", priority = 50 },
    },
  })
end

meaning_setup("CONCEAL")
vim.cmd.edit(vim.fn.fnameescape(meaning_src))
local meaning_count = scp.render()
assert(meaning_count == 3, "expected 3 meaning spans rendered, got " .. tostring(meaning_count))

local meaning_marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(#meaning_marks == 3, "expected 3 meaning extmarks, got " .. #meaning_marks)
assert(meaning_marks[1][4].conceal_lines == "", "CONCEAL should hide the line")
assert(meaning_marks[3][4].conceal_lines == "", "CONCEAL should hide the second Logging line")

local highlight_group = meaning_marks[2][4].hl_group
assert(
  highlight_group and highlight_group:find("SCPainter_HL_SHOW_ErrorHandling", 1, true),
  "SHOW should use the ErrorHandling highlight group, got " .. tostring(highlight_group)
)
local highlight_hl = vim.api.nvim_get_hl(0, { name = highlight_group })
assert(
  highlight_hl.bg == tonumber("202020", 16),
  "highlight bg should come from the tag, got " .. tostring(highlight_hl.bg)
)

meaning_setup("IGNORE")
scp.render()
local switched_marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(#switched_marks == 3, "expected 3 switched extmarks, got " .. #switched_marks)
for _, index in ipairs({ 1, 3 }) do
  local ignore_group = switched_marks[index][4].hl_group
  assert(
    ignore_group and ignore_group:find("SCPainter_IGNORE_IGNORE", 1, true),
    "switching Logging to IGNORE should use the ignore group, got " .. tostring(ignore_group)
  )
  assert(switched_marks[index][4].conceal_lines == nil, "IGNORE should not conceal")
end
local ignore_hl = vim.api.nvim_get_hl(0, { name = switched_marks[1][4].hl_group })
assert(
  ignore_hl.fg == tonumber("555555", 16),
  "ignore should use dark gray, got " .. tostring(ignore_hl.fg)
)

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
