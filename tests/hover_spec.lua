local cint = require("cint")
local hover = require("cint.hover")
local palette = require("cint.core.colors")

local function write(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local function publish(buf, annotations)
  cint._live_tags[buf] = {
    version = vim.b[buf].changedtick,
    hash = "hover-test",
    annotations = annotations,
  }
end

local function floats()
  local result = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      result[#result + 1] = win
    end
  end
  return result
end

local function hex(value)
  return tonumber(value:gsub("^#", ""), 16)
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local src = tmp .. "/Hover.kt"
write(src, 'fun main() {\n    log.info("hi")\n    validate(x)\n    return x\n}\n')

local tags = {
  LOGGING = { meaning = "SHOW", bg = "#1f2d1f" },
  VALIDATION = { meaning = "SHOW", sign = "#abcdef" },
  BOOKKEEPING = { meaning = "SHOW" },
  SEARCH = { meaning = "SHOW" },
}

cint.setup({
  root = tmp,
  resolve = { precedence = { "SHOW", "HIGHLIGHT" }, default = "SHOW" },
  rules = { SHOW = false, HIGHLIGHT = { highlight = true } },
  tags = tags,
})

vim.cmd.edit(vim.fn.fnameescape(src))
local buf = vim.api.nvim_get_current_buf()
local annotations = {
  {
    role = "scaffold",
    intents = { "SCAFFOLD" },
    startLine = 0,
    startCol = 0,
    endLine = 0,
    endCol = 12,
  },
  {
    role = "source-intent",
    intents = { "SEARCH" },
    startLine = 0,
    startCol = 4,
    endLine = 0,
    endCol = 8,
  },
  {
    role = "source-intent",
    intents = { "LOGGING", "VALIDATION" },
    startLine = 1,
    startCol = 4,
    endLine = 1,
    endCol = 18,
  },
  {
    role = "derivative-use",
    intents = { "PACK_NEW_INTENT" },
    startLine = 1,
    startCol = 4,
    endLine = 1,
    endCol = 18,
  },
  {
    role = "scaffold",
    intents = { "SCAFFOLD" },
    startLine = 1,
    startCol = 12,
    endLine = 2,
    endCol = 5,
  },
  { intents = { "BOOKKEEPING" }, startLine = 3, startCol = 0, endLine = 3, endCol = 1 },
  { intents = { "SEARCH" }, startLine = 4, startCol = 0, endLine = 4, endCol = 0 },
}
publish(buf, annotations)

assert(#cint.annotations_at_position(buf, 1, 3) == 0, "a position before the span should not match")
assert(#cint.annotations_at_position(buf, 1, 4) == 2, "coincident spans should both match the start column")
assert(#cint.annotations_at_position(buf, 1, 12) == 3, "overlapping spans should all match")
assert(#cint.annotations_at_position(buf, 1, 18) == 1, "the same-line end column should be exclusive")
assert(#cint.annotations_at_position(buf, 2, 4) == 1, "a non-final line should match its end")
assert(#cint.annotations_at_position(buf, 2, 5) == 0, "the final end column should be exclusive")
assert(#cint.annotations_at_position(buf, 4, 0) == 1, "a zero-width span should match its point")
assert(#cint.annotations_at_position(buf, 4, 1) == 0, "a zero-width span should not match beyond its point")
assert(#cint.annotations_at(buf, 1) == 3, "the line-only lookup should keep its existing behavior")
local point = cint.intents_at_position(buf, 4, 0)
assert(#point == 1 and point[1] == "SEARCH", "a zero-width point should return its intent")

local nested = cint.intents_at_position(buf, 0, 5)
assert(#nested == 1, "only the innermost nested span should contribute intents")
assert(nested[1] == "SEARCH", "the nested source intent should win over the scaffold")
assert(#cint.annotations_at_position(buf, 0, 5) == 2, "the nested lookup should still see both annotations")
local scaffold_only = cint.intents_at_position(buf, 0, 1)
assert(#scaffold_only == 1, "a scaffold-only position should return its intents")
assert(scaffold_only[1] == "SCAFFOLD", "the scaffold intent should show when it is innermost")

local coincident = cint.intents_at_position(buf, 1, 5)
assert(#coincident == 3, "coincident source and derivative spans should combine their intents")
assert(coincident[1] == "LOGGING", "the source intent order should be preserved")
assert(coincident[2] == "VALIDATION", "the source intents should keep their order")
assert(coincident[3] == "PACK_NEW_INTENT", "the coincident derivative intent should follow")
assert(#cint.annotations_at_position(buf, 1, 5) == 2, "the coincident lookup should only see the two spans")

local ordered = cint.intents_at_position(buf, 1, 12)
assert(#ordered == 3, "only the innermost span intents should be returned once each")
assert(ordered[1] == "LOGGING", "annotation intent order should be preserved")
assert(ordered[2] == "VALIDATION", "the source annotation should keep its intent order")
assert(ordered[3] == "PACK_NEW_INTENT", "coincident derivative intents should follow")

vim.api.nvim_win_set_cursor(0, { 2, 12 })
local from_cursor = cint.intents_at_position(buf)
assert(#from_cursor == 3, "the position lookup should default to the cursor")
assert(from_cursor[1] == "LOGGING" and from_cursor[3] == "PACK_NEW_INTENT", "cursor intents should match")

local byte_src = tmp .. "/ByteHover.kt"
write(byte_src, 'fun bytes() {\n    log.info("bytes")\n    validate(x)\n    return x\n}\n')
local byte_buf = vim.fn.bufadd(byte_src)
vim.fn.bufload(byte_buf)
publish(byte_buf, {
  {
    role = "scaffold",
    intents = { "BYTE_SCAFFOLD" },
    startLine = 0,
    startCol = 0,
    endLine = 0,
    endCol = 12,
    startByte = 0,
    endByte = 12,
  },
  {
    role = "source-intent",
    intents = { "BYTE_SOURCE" },
    startLine = 0,
    startCol = 4,
    endLine = 0,
    endCol = 8,
    startByte = 4,
    endByte = 8,
  },
  {
    role = "source-intent",
    intents = { "BYTE_COINCIDENT_SOURCE" },
    startLine = 1,
    startCol = 4,
    endLine = 1,
    endCol = 18,
    startByte = 17,
    endByte = 31,
  },
  {
    role = "derivative-use",
    intents = { "BYTE_COINCIDENT_DERIVATIVE" },
    startLine = 1,
    startCol = 4,
    endLine = 1,
    endCol = 18,
    startByte = 17,
    endByte = 31,
  },
  {
    role = "source-intent",
    intents = { "BYTE_FIRST" },
    startLine = 2,
    startCol = 0,
    endLine = 2,
    endCol = 10,
    startByte = 32,
    endByte = 42,
  },
  {
    role = "derivative-use",
    intents = { "BYTE_SECOND" },
    startLine = 2,
    startCol = 2,
    endLine = 2,
    endCol = 12,
    startByte = 34,
    endByte = 44,
  },
  { intents = { "FALLBACK_FIRST" }, startLine = 3, startCol = 0, endLine = 3, endCol = 10 },
  { intents = { "FALLBACK_SECOND" }, startLine = 3, startCol = 2, endLine = 3, endCol = 12 },
})

local byte_nested = cint.intents_at_position(byte_buf, 0, 5)
assert(#byte_nested == 1, "the byte path should select only the nested source span")
assert(byte_nested[1] == "BYTE_SOURCE", "the nested byte source intent should win")

local byte_coincident = cint.intents_at_position(byte_buf, 1, 5)
assert(#byte_coincident == 2, "exactly coincident byte spans should combine their intents")
assert(byte_coincident[1] == "BYTE_COINCIDENT_SOURCE", "the source byte intent should come first")
assert(byte_coincident[2] == "BYTE_COINCIDENT_DERIVATIVE", "the derivative byte intent should follow")

local byte_shifted = cint.intents_at_position(byte_buf, 2, 5)
assert(#byte_shifted == 1, "equal-size shifted byte spans should not combine")
assert(byte_shifted[1] == "BYTE_FIRST", "the earliest minimum-size byte annotation should win")

local fallback_shifted = cint.intents_at_position(byte_buf, 3, 5)
assert(#fallback_shifted == 1, "equal-size shifted line/column spans should not combine")
assert(fallback_shifted[1] == "FALLBACK_FIRST", "the earliest minimum-size fallback annotation should win")

assert(vim.fn.exists(":CintHover") == 2, "the hover command should be registered")
assert(#floats() == 0, "no hover window should exist before invoking it")
vim.cmd("CintHover")
assert(cint.hover_active(), "the command should open the hover")
local wins = floats()
assert(#wins == 1, "the hover should create exactly one floating window")
local win = wins[1]
local win_config = vim.api.nvim_win_get_config(win)
assert(
  win_config.relative == "cursor"
    or (win_config.relative == "win" and win_config.win == vim.api.nvim_get_current_win()),
  "the hover should anchor to the cursor"
)
assert(win_config.focusable == false, "the hover must not be focusable")
local border = win_config.border
assert(
  border == "rounded" or (type(border) == "table" and border[1] == "╭" and border[3] == "╮"),
  "the hover should use a rounded border"
)
assert(win_config.width <= hover.max_width, "the hover width should be clamped")
assert(win_config.height <= hover.max_height, "the hover height should be clamped")
assert(vim.wo[win].wrap == false, "the hover should not wrap")
assert(vim.wo[win].cursorline == false, "the hover should not show a cursorline")
assert(vim.api.nvim_get_current_win() ~= win, "the hover must not take focus")

local hover_buf = vim.api.nvim_win_get_buf(win)
local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)
assert(#lines == 3, "the hover should have one line per distinct intent")
assert(lines[1] == "LOGGING", "the first hover line should be the first intent")
assert(lines[2] == "VALIDATION", "the second hover line should be the second intent")
assert(lines[3] == "PACK_NEW_INTENT", "the third hover line should be the fallback intent")

local marks = vim.api.nvim_buf_get_extmarks(hover_buf, hover.ns, 0, -1, { details = true })
assert(#marks == 3, "every hover line should be highlighted")
assert(marks[1][4].hl_group == "CintHover_LOGGING", "the first intent should use its tag group")
assert(marks[2][4].hl_group == "CintHover_VALIDATION", "the second intent should use its tag group")
assert(marks[3][4].hl_group == "CintHover_PACK_NEW_INTENT", "unknown intents should use a fallback group")
local logging_hl = vim.api.nvim_get_hl(0, { name = "CintHover_LOGGING" })
assert(logging_hl.bg == hex(tags.LOGGING.bg), "tag backgrounds should reach the hover group")
local validation_hl = vim.api.nvim_get_hl(0, { name = "CintHover_VALIDATION" })
assert(validation_hl.fg == hex(tags.VALIDATION.sign), "tag sign colors should reach the hover group")
local fallback_hl = vim.api.nvim_get_hl(0, { name = "CintHover_PACK_NEW_INTENT" })
assert(fallback_hl.bg == hex(palette.fallback.bg), "unknown intents should use the fallback background")
assert(fallback_hl.fg == hex(palette.fallback.sign), "unknown intents should use the fallback foreground")

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
assert(not cint.hover_active(), "moving the cursor should close the hover")
assert(#floats() == 0, "moving the cursor should remove the hover window")

vim.api.nvim_win_set_cursor(0, { 1, 6 })
assert(cint.hover(), "a source span nested in a scaffold should open the hover")
local nested_wins = floats()
assert(#nested_wins == 1, "the nested hover should create exactly one float")
local nested_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(nested_wins[1]), 0, -1, false)
assert(#nested_lines == 1, "the nested hover should show only the innermost span intents")
assert(nested_lines[1] == "SEARCH", "the nested source intent should be the only hover line")
cint.hover_close()

vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(cint.hover(), "a scaffold-only position should open the hover")
local scaffold_wins = floats()
assert(#scaffold_wins == 1, "the scaffold hover should create exactly one float")
local scaffold_lines =
  vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(scaffold_wins[1]), 0, -1, false)
assert(#scaffold_lines == 1, "the scaffold hover should show the scaffold intents")
assert(scaffold_lines[1] == "SCAFFOLD", "the scaffold intent should be the only hover line")
cint.hover_close()

vim.api.nvim_win_set_cursor(0, { 2, 12 })
local plug = vim.fn.maparg("<Plug>(CintHover)", "n", false, true)
assert(type(plug) == "table" and plug.lhs ~= nil and plug.lhs ~= "", "the <Plug> mapping should exist")
assert(type(plug.callback) == "function", "the <Plug> mapping should invoke the hover callback")
plug.callback()
assert(cint.hover_active(), "the <Plug> mapping should open the hover")
assert(#floats() == 1, "the <Plug> mapping should create the hover window")
vim.api.nvim_exec_autocmds("VimResized", {})
assert(not cint.hover_active(), "resizing should close the hover")
assert(#floats() == 0, "resizing should remove the hover window")

vim.api.nvim_win_set_cursor(0, { 3, 10 })
assert(cint.hover() == false, "a position without intents should not open a hover")
assert(#floats() == 0, "a position without intents should not create a window")

local other_src = tmp .. "/OtherHover.kt"
write(other_src, 'fun other() {\n    log.info("other")\n}\n')
local other_buf = vim.fn.bufadd(other_src)
vim.fn.bufload(other_buf)
publish(other_buf, {
  { intents = { "VALIDATION", "BOOKKEEPING" }, startLine = 1, startCol = 4, endLine = 1, endCol = 18 },
})
local main_win = vim.api.nvim_get_current_win()
vim.cmd("vsplit " .. vim.fn.fnameescape(other_src))
local other_win = vim.api.nvim_get_current_win()
assert(other_win ~= main_win, "the non-current hover test needs a separate target window")
assert(vim.api.nvim_win_get_buf(other_win) == other_buf, "the target window should show the target buffer")
vim.api.nvim_win_set_cursor(main_win, { 1, 0 })
vim.api.nvim_win_set_cursor(other_win, { 2, 12 })
vim.api.nvim_set_current_win(main_win)
assert(vim.api.nvim_get_current_buf() == buf, "the target buffer must not be current")
local other_cursor = vim.api.nvim_win_get_cursor(other_win)
local main_cursor = vim.api.nvim_win_get_cursor(main_win)
local other_screen = vim.fn.screenpos(other_win, other_cursor[1], other_cursor[2] + 1)
local main_screen = vim.fn.screenpos(main_win, main_cursor[1], main_cursor[2] + 1)
assert(cint.hover(other_buf), "the API should hover a non-current buffer")
local other_floats = floats()
assert(#other_floats == 1, "the non-current hover should create exactly one float")
local other_float = other_floats[1]
local other_config = vim.api.nvim_win_get_config(other_float)
assert(other_config.relative == "editor", "a non-current hover should use screen coordinates")
assert(other_config.row == other_screen.row, "the hover should sit below the visible target caret row")
assert(other_config.col == other_screen.col - 1, "the hover should align with the visible target caret column")
assert(
  other_config.row ~= main_screen.row or other_config.col ~= main_screen.col - 1,
  "the hover should anchor to the target caret, not the current window caret"
)
assert(vim.api.nvim_get_current_win() == main_win, "the non-current hover must not take focus")
local other_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(other_float), 0, -1, false)
assert(#other_lines == 2, "the non-current hover should list the target intents")
assert(other_lines[1] == "VALIDATION", "the non-current hover should keep target intent order")
assert(other_lines[2] == "BOOKKEEPING", "the non-current hover should include every target intent")
vim.api.nvim_exec_autocmds("BufLeave", {})
assert(not cint.hover_active(), "leaving the buffer should close the hover")
assert(#floats() == 0, "leaving the buffer should remove the hover window")
vim.api.nvim_set_current_win(main_win)
vim.cmd("only")

local scroll_src = tmp .. "/ScrollHover.kt"
local scroll_lines = {}
for index = 1, 40 do
  scroll_lines[index] = string.format("line %02d abcdefghij", index)
end
write(scroll_src, table.concat(scroll_lines, "\n") .. "\n")
local scroll_buf = vim.fn.bufadd(scroll_src)
vim.fn.bufload(scroll_buf)
publish(scroll_buf, {
  { intents = { "SEARCH" }, startLine = 29, startCol = 0, endLine = 29, endCol = 10 },
})
local scroll_main_win = vim.api.nvim_get_current_win()
vim.cmd("vsplit " .. vim.fn.fnameescape(scroll_src))
local scroll_win = vim.api.nvim_get_current_win()
assert(scroll_win ~= scroll_main_win, "the scrolled hover test needs a separate target window")
vim.api.nvim_win_set_cursor(scroll_win, { 30, 4 })
vim.fn.winrestview({ topline = 28 })
local scroll_cursor = vim.api.nvim_win_get_cursor(scroll_win)
local scroll_screen = vim.fn.screenpos(scroll_win, scroll_cursor[1], scroll_cursor[2] + 1)
assert(
  scroll_screen.row > 0 and scroll_screen.row < scroll_cursor[1],
  "the scrolled target should place the caret above its buffer line"
)
vim.api.nvim_set_current_win(scroll_main_win)
assert(vim.api.nvim_get_current_buf() == buf, "the scrolled target buffer must not be current")
assert(cint.hover(scroll_buf), "the API should hover a scrolled non-current buffer")
local scroll_floats = floats()
assert(#scroll_floats == 1, "the scrolled non-current hover should create exactly one float")
local scroll_config = vim.api.nvim_win_get_config(scroll_floats[1])
assert(scroll_config.relative == "editor", "the scrolled hover should use screen coordinates")
assert(scroll_config.row == scroll_screen.row, "the scrolled hover should follow the visible caret row")
assert(scroll_config.col == scroll_screen.col - 1, "the scrolled hover should follow the visible caret column")
assert(scroll_config.row ~= scroll_cursor[1], "the scrolled hover must not use the raw buffer row")
vim.api.nvim_exec_autocmds("WinScrolled", {})
assert(not cint.hover_active(), "scrolling should close the hover")
assert(#floats() == 0, "scrolling should remove the hover window")
vim.api.nvim_set_current_win(scroll_main_win)
vim.cmd("only")

local quiet_src = tmp .. "/Quiet.kt"
write(quiet_src, "fun quiet() {}\n")
vim.cmd.edit(vim.fn.fnameescape(quiet_src))
local quiet_buf = vim.api.nvim_get_current_buf()
assert(cint.hover() == false, "a buffer without published annotations should not open a hover")
assert(#floats() == 0, "a buffer without published annotations should not create a window")

vim.cmd.edit(vim.fn.fnameescape(src))
buf = vim.api.nvim_get_current_buf()
publish(buf, annotations)

cint.setup({
  root = tmp,
  resolve = { precedence = { "SHOW", "HIGHLIGHT" }, default = "SHOW" },
  rules = { SHOW = false, HIGHLIGHT = { highlight = true } },
  tags = tags,
  hover = { enabled = true, on_cursor_hold = false },
})
publish(buf, annotations)
vim.api.nvim_win_set_cursor(0, { 2, 12 })
vim.api.nvim_exec_autocmds("CursorHold", {})
assert(#floats() == 0, "on_cursor_hold = false should disable the automatic trigger")
assert(not cint.hover_active(), "the automatic trigger should leave the hover closed")

cint.setup({
  root = tmp,
  resolve = { precedence = { "SHOW", "HIGHLIGHT" }, default = "SHOW" },
  rules = { SHOW = false, HIGHLIGHT = { highlight = true } },
  tags = tags,
  hover = { enabled = false, on_cursor_hold = true },
})
publish(buf, annotations)
vim.api.nvim_win_set_cursor(0, { 2, 12 })
vim.cmd("CintHover")
assert(#floats() == 0, "hover.enabled = false should disable the command path")
assert(cint.hover_active() == false, "the disabled command should not leave an active hover")
vim.api.nvim_exec_autocmds("CursorHold", {})
assert(#floats() == 0, "hover.enabled = false should disable the automatic trigger")

cint.setup({
  root = tmp,
  profile = "base",
  profiles = {
    base = {},
    quiet = { extends = "base", hover = { on_cursor_hold = false } },
    off = { extends = "base", hover = { enabled = false } },
  },
  resolve = { precedence = { "SHOW", "HIGHLIGHT" }, default = "SHOW" },
  rules = { SHOW = false, HIGHLIGHT = { highlight = true } },
  tags = tags,
  hover = { enabled = true, on_cursor_hold = true },
})
publish(buf, annotations)
assert(cint.set_profile("quiet"), "the quiet profile should apply")
vim.api.nvim_win_set_cursor(0, { 2, 12 })
vim.api.nvim_exec_autocmds("CursorHold", {})
assert(#floats() == 0, "a profile with on_cursor_hold = false should disable the automatic trigger")
assert(not cint.hover_active(), "the quiet profile should leave the hover closed")

assert(cint.set_profile("base"), "the base profile should apply")
vim.api.nvim_exec_autocmds("CursorHold", {})
assert(cint.hover_active(), "the base profile should enable the automatic trigger")
assert(#floats() == 1, "the base profile trigger should create the hover window")
cint.hover_close()
assert(not cint.hover_active(), "hover_close should close the automatic hover")

assert(cint.set_profile("off"), "the off profile should apply")
vim.cmd("CintHover")
assert(#floats() == 0, "a profile with enabled = false should disable the command path")
vim.api.nvim_exec_autocmds("CursorHold", {})
assert(#floats() == 0, "a profile with enabled = false should disable the automatic trigger")

print("PASS")
vim.cmd("qa!")
