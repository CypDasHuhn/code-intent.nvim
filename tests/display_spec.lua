vim.g.mapleader = " "

local cint = require("cint")

local function write(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local source = root .. "/Sample.kt"
write(source, 'fun f() {\n    log.info("x")\n    error("y")\n}\n')

cint.setup({
  root = root,
  profile = "base",
  profiles = {
    base = {
      resolve = { precedence = { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" }, default = "SHOW" },
      rules = {
        CONCEAL = { conceal = { lines = true } },
        HIGHLIGHT = { highlight = true },
        IGNORE = { ignore = true },
      },
      tags = {
        LOGGING = { meaning = "CONCEAL" },
        ERROR_HANDLING = { meaning = "SHOW" },
        VALIDATION = { meaning = "HIGHLIGHT" },
      },
    },
    review = {
      extends = "base",
      tags = { LOGGING = { meaning = "HIGHLIGHT" } },
    },
  },
  shards = {
    ignore_logging = { tags = { LOGGING = { meaning = "IGNORE" } } },
  },
})

vim.cmd.edit(vim.fn.fnameescape(source))
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = "kotlin"
cint._live_tags[buf] = { version = vim.b[buf].changedtick, annotations = {} }
cint._rendered[buf] = {}

local names = cint.intent_names(buf)
local sorted = vim.deepcopy(names)
table.sort(sorted)
assert(vim.deep_equal(names, sorted), "intent names should be sorted alphabetically")
assert(#names > 0, "display should list known intents")

local map = cint.display_map(buf)
assert(map[1].intent == names[1], "display map should sort intents alphabetically")
assert(map[1].meaning ~= nil, "display map should resolve a meaning")

assert(cint.set_meaning("LOGGING", "IGNORE", { buf = buf }), "set_meaning should apply")
assert(cint.config_for(buf).tags.LOGGING.meaning == "IGNORE", "override should win over the profile")

cint.set_profile("review")
assert(
  cint.config_for(buf).tags.LOGGING.meaning == "IGNORE",
  "temporary meanings should survive a profile change"
)

cint.set_meaning("LOGGING", "HIGHLIGHT", { buf = buf })
cint.apply_shard("ignore_logging")
assert(
  cint.config_for(buf).tags.LOGGING.meaning == "HIGHLIGHT",
  "temporary meanings should win over shards"
)

assert(cint.reset_meaning("LOGGING", { buf = buf }), "reset_meaning should clear the override")
assert(
  cint.config_for(buf).tags.LOGGING.meaning == "IGNORE",
  "reset should restore the profile plus shard value"
)
cint.reset_shards()
cint.set_profile("base")

assert(cint.open_display(buf), "display should open")
local ui_buf = vim.api.nvim_get_current_buf()
local ui_win = vim.api.nvim_get_current_win()
assert(vim.bo[ui_buf].filetype == "cint-ui", "display should use its own filetype")
assert(cint.display_active(), "display should report itself active")

local ui_lines = vim.api.nvim_buf_get_lines(ui_buf, 0, -1, false)
local ui_map = cint.display_map(buf)
assert(#ui_lines == #ui_map, "display should show one row per intent")
for index, entry in ipairs(ui_map) do
  assert(
    ui_lines[index]:find(entry.intent, 1, true) and ui_lines[index]:find(entry.meaning, 1, true),
    "display row should show intent and meaning"
  )
end

local logging_row
for index, entry in ipairs(ui_map) do
  if entry.intent == "LOGGING" then
    logging_row = index
    break
  end
end
assert(logging_row ~= nil, "display should include LOGGING")

vim.api.nvim_win_set_cursor(ui_win, { logging_row, 0 })
feed(vim.g.mapleader)
local cycled = cint.display_map(buf)[logging_row].meaning
assert(cycled == "SHOW", "leader should cycle CONCEAL to SHOW, got " .. tostring(cycled))
assert(
  cint.config_for(buf).tags.LOGGING.meaning == "SHOW",
  "leader should update the effective meaning"
)

feed("<BS>")
assert(
  cint.config_for(buf).tags.LOGGING.meaning == "CONCEAL",
  "backspace should restore the inherited meaning"
)

feed("q")
assert(not cint.display_active(), "q should close the display")

vim.cmd("CintSet IGNORE LOGGING ERROR_HANDLING")
assert(cint.config_for(buf).tags.LOGGING.meaning == "IGNORE", "CintSet should apply LOGGING")
assert(
  cint.config_for(buf).tags.ERROR_HANDLING.meaning == "IGNORE",
  "CintSet should apply multiple intents"
)

vim.cmd("CintReset LOGGING")
assert(cint.config_for(buf).tags.LOGGING.meaning == "CONCEAL", "CintReset should reset one intent")
assert(
  cint.config_for(buf).tags.ERROR_HANDLING.meaning == "IGNORE",
  "CintReset should keep other overrides"
)

vim.cmd("CintReset")
assert(
  cint.config_for(buf).tags.ERROR_HANDLING.meaning == "SHOW",
  "CintReset should clear every override"
)

local meaning_completions = vim.fn.getcompletion("CintSet IGN", "cmdline")
assert(vim.tbl_contains(meaning_completions, "IGNORE"), "CintSet should complete meanings")
local intent_completions = vim.fn.getcompletion("CintSet IGNORE LOG", "cmdline")
assert(vim.tbl_contains(intent_completions, "LOGGING"), "CintSet should complete intents")

local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(other, root .. "/Other.kt")
vim.bo[other].filetype = "kotlin"
cint._live_tags[other] = { version = 0, annotations = {} }
cint._rendered[other] = {}
vim.api.nvim_set_current_buf(other)

vim.cmd("CintSet! SHOW VALIDATION")
assert(cint.config_for(buf).tags.VALIDATION.meaning == "SHOW", "CintSet! should update other buffers")
assert(cint.config_for(other).tags.VALIDATION.meaning == "SHOW", "CintSet! should update the current buffer")

vim.cmd("CintReset! VALIDATION")
assert(cint.config_for(buf).tags.VALIDATION.meaning == "HIGHLIGHT", "CintReset! should clear other buffers")
assert(cint.config_for(other).tags.VALIDATION.meaning == "HIGHLIGHT", "CintReset! should clear the current buffer")

print("PASS")
vim.cmd("qa!")
