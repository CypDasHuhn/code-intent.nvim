local cint = require("cint")
local stripes = require("cint.render.stripes")

local function write(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local src = tmp .. "/Stripes.kt"
write(src, "alpha beta gamma delta\n\n")

cint.setup({
  root = tmp,
  resolve = { precedence = { "HIGHLIGHT" }, default = "HIGHLIGHT" },
  rules = { HIGHLIGHT = { highlight = true } },
  tags = {
    A = { meaning = "HIGHLIGHT", bg = "#101010" },
    B = { meaning = "HIGHLIGHT", bg = "#202020" },
  },
})

vim.cmd.edit(vim.fn.fnameescape(src))
local buf = vim.api.nvim_get_current_buf()
local function publish(intents, end_col)
  cint._live_tags[buf] = {
    version = vim.b[buf].changedtick,
    hash = "stripes-" .. tostring(end_col) .. table.concat(intents, ","),
    annotations = {
      { role = "scaffold", intents = intents, startLine = 0, startCol = 0, endLine = 0, endCol = end_col },
    },
  }
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  cint.render()
end

local function marks()
  return vim.api.nvim_buf_get_extmarks(buf, stripes.ns, 0, -1, { details = true })
end

publish({ "A", "B" }, 22)
assert(#marks() == 0, "stripes must be off by default")
assert(cint.toggle_stripes() == true, "toggle should enable stripes")
local active = marks()
assert(#active > 0, "the active mixed span should be striped")
local groups = {}
for _, mark in ipairs(active) do
  groups[mark[4].hl_group] = true
end
assert(groups.CintStripe_A, "first intent color should be used")
assert(groups.CintStripe_B, "second intent color should be used")
assert(#active <= stripes.max_segments, "segment cap should be respected")

vim.api.nvim_win_set_cursor(0, { 2, 0 })
cint.reveal_block()
assert(#marks() == 0, "moving outside the mixed span should clear stripes")

publish({ "A" }, 5)
assert(#marks() == 0, "single-intent spans must not be striped")

local words = {}
for index = 1, 120 do
  words[index] = "w" .. index
end
write(src, table.concat(words, " ") .. "\n")
vim.cmd.edit(vim.fn.fnameescape(src))
buf = vim.api.nvim_get_current_buf()
cint._live_tags[buf] = {
  version = vim.b[buf].changedtick,
  hash = "stripes-cap",
  annotations = {
    { role = "scaffold", intents = { "A", "B" }, startLine = 0, startCol = 0, endLine = 0, endCol = #words[1] },
  },
}
vim.api.nvim_win_set_cursor(0, { 1, 0 })
cint.render()
assert(#marks() <= stripes.max_segments, "many-word spans should be capped")

assert(cint.toggle_stripes() == false, "toggle should disable stripes")
assert(#marks() == 0, "disabling stripes should clear marks")

print("PASS")
vim.cmd("qa!")
