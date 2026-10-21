local cint = require("cint")
local labels = require("cint.render.labels")

local function write(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local src = tmp .. "/Labels.kt"
write(src, "fun main() {\n    log.info(\"hi\")\n    validate(x)\n}\n")

cint.setup({
  root = tmp,
  resolve = { precedence = { "SHOW", "HIGHLIGHT" }, default = "HIGHLIGHT" },
  rules = { SHOW = false, HIGHLIGHT = { highlight = true } },
  tags = {
    LOGGING = { meaning = "HIGHLIGHT", bg = "#101010" },
    VALIDATION = { meaning = "HIGHLIGHT", bg = "#202020" },
  },
})

vim.cmd.edit(vim.fn.fnameescape(src))
local buf = vim.api.nvim_get_current_buf()
cint._live_tags[buf] = {
  version = vim.b[buf].changedtick,
  hash = "labels-test",
  annotations = {
    { role = "source-intent", intents = { "LOGGING" }, startLine = 1, startCol = 4, endLine = 1, endCol = 18 },
    { role = "source-intent", intents = { "VALIDATION" }, startLine = 2, startCol = 4, endLine = 2, endCol = 14 },
  },
}

assert(cint.render() == 2, "labels test needs two rendered annotations")
local function marks()
  return vim.api.nvim_buf_get_extmarks(buf, labels.ns, 0, -1, { details = true })
end

assert(#marks() == 0, "labels must be off by default")
assert(cint.intent_labels_toggle() == true, "toggle should enable labels")
local enabled = marks()
assert(#enabled == 2, "every annotation should get a virtual intent line")
local function has_text(needle)
  for _, mark in ipairs(enabled) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      for _, chunk in ipairs(line) do
        if type(chunk[1]) == "string" and chunk[1]:find(needle, 1, true) then
          return true
        end
      end
    end
  end
  return false
end
assert(has_text("LOGGING"), "LOGGING label text should be rendered")
assert(has_text("VALIDATION"), "VALIDATION label text should be rendered")
assert(cint.intent_labels_toggle() == false, "toggle should disable labels")
assert(#marks() == 0, "disabling labels should clear them")

print("PASS")
vim.cmd("qa!")
