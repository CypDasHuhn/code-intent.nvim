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
  "tag": "LOGGING",
  "language": "kotlin",
  "files": [
    {
      "path": "Foo.kt",
      "spans": [
        {"tag":"LOGGING","startLine":1,"startCol":4,"endLine":1,"endCol":18},
        {"tag":"NOISE","startLine":2,"startCol":4,"endLine":2,"endCol":20},
        {"tag":"OTHER","startLine":3,"startCol":4,"endLine":3,"endCol":21},
        {"tag":"HOLLOW","startLine":4,"startCol":4,"endLine":4,"endCol":21}
      ]
    }
  ]
}
]]
)

scp.setup({
  root = tmp,
  tags = {
    LOGGING = {
      color = { bg = "#101010", sign = "#202020", icon = "L" },
      conceal = { char = "~" },
    },
    NOISE = { conceal = { char = "." } },
    HOLLOW = { conceal = { lines = true } },
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

local nested_src = tmp .. "/Nested.kt"
write(nested_src, "a\nb\nc\nd\ne\nf\n")
vim.cmd.edit(vim.fn.fnameescape(nested_src))
local nested_buf = vim.api.nvim_get_current_buf()
local nested_spans = {
  { tag = "HOLLOW", startLine = 1, startCol = 0, endLine = 3, endCol = 0 },
  { tag = "HOLLOW", startLine = 2, startCol = 0, endLine = 2, endCol = 1 },
}
local nested_config = scp.config_for(nested_buf)
scp._rendered[nested_buf] = nested_spans
scp._configs[nested_buf] = nested_config
render.render_buffer(nested_buf, nested_spans, nested_config)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
scp._active[nested_buf] = nil
scp.reveal_block(nested_buf)
local nested_height = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 5 }).all
assert(
  nested_height == 6,
  "entering a concealed block should reveal nested spans, got height " .. nested_height
)

local mixed_src = tmp .. "/Mixed.kt"
write(mixed_src, "a\nb\nc\nd\ne\nf\n")
vim.cmd.edit(vim.fn.fnameescape(mixed_src))
local mixed_buf = vim.api.nvim_get_current_buf()
local mixed_spans = {
  { role = "scaffold", tag = "LOGGING", startLine = 1, startCol = 0, endLine = 3, endCol = 0 },
  { tag = "HOLLOW", startLine = 2, startCol = 0, endLine = 2, endCol = 1 },
}
local mixed_config = scp.config_for(mixed_buf)
scp._rendered[mixed_buf] = mixed_spans
scp._configs[mixed_buf] = mixed_config
render.render_buffer(mixed_buf, mixed_spans, mixed_config)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
scp._active[mixed_buf] = nil
scp.reveal_block(mixed_buf)
local mixed_height = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 5 }).all
assert(
  mixed_height == 6,
  "entering a SHOW scaffold should reveal concealed children, got height " .. mixed_height
)

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
  "intents": ["LOGGING", "ERROR_HANDLING"],
  "files": [
    {
      "path": "Meaning.kt",
      "spans": [
        {"role":"source-intent","intents":["LOGGING"],"startLine":1,"startCol":4,"endLine":1,"endCol":18},
        {"role":"source-intent","intents":["ERROR_HANDLING"],"startLine":2,"startCol":4,"endLine":2,"endCol":18},
        {"role":"source-intent","intents":["LOGGING"],"startLine":3,"startCol":4,"endLine":3,"endCol":23}
      ]
    }
  ]
}
]]
)

local function meaning_setup(intent_logging)
  scp.setup({
    root = tmp,
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
      LOGGING = { meaning = intent_logging, bg = "#101010", priority = 10 },
      ERROR_HANDLING = { meaning = "SHOW", bg = "#202020", priority = 50 },
      UNTAGGED = { meaning = "SHOW" },
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
  highlight_group and highlight_group:find("SCPainter_HL_SHOW_ERROR_HANDLING", 1, true),
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

scp.setup({
  root = tmp,
  profile = "base",
  profiles = {
    base = {
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
        LOGGING = { meaning = "CONCEAL", bg = "#101010", priority = 10 },
        ERROR_HANDLING = { meaning = "SHOW", bg = "#202020", priority = 50 },
        UNTAGGED = { meaning = "SHOW" },
      },
    },
    review = {
      extends = "base",
      tags = { LOGGING = { meaning = "IGNORE" } },
    },
  },
})

vim.cmd.edit(vim.fn.fnameescape(meaning_src))
local profile_count = scp.render()
assert(profile_count == 3, "profile render should produce 3 spans, got " .. tostring(profile_count))

local base_marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(base_marks[1][4].conceal_lines == "", "base profile should conceal Logging")

scp.set_profile("review")
local review_marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(
  review_marks[1][4].hl_group and review_marks[1][4].hl_group:find("SCPainter_IGNORE_IGNORE", 1, true),
  "review profile should switch Logging to IGNORE"
)
assert(review_marks[1][4].conceal_lines == nil, "review profile should not conceal Logging")

scp.setup({
  root = tmp,
  profile = "base",
  profiles = {
    base = {
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
        LOGGING = { meaning = "CONCEAL", bg = "#101010", priority = 10 },
        ERROR_HANDLING = { meaning = "SHOW", bg = "#202020", priority = 50 },
        UNTAGGED = { meaning = "SHOW" },
      },
    },
  },
  shards = {
    ignore_logging = {
      tags = { LOGGING = { meaning = "IGNORE" } },
    },
  },
})

vim.cmd.edit(vim.fn.fnameescape(meaning_src))
scp.render()
local shard_base = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(shard_base[1][4].conceal_lines == "", "base profile should conceal before shards")

scp.apply_shard("ignore_logging")
local shard_applied = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(
  shard_applied[1][4].hl_group and shard_applied[1][4].hl_group:find("SCPainter_IGNORE_IGNORE", 1, true),
  "applying a shard should override Logging"
)

scp.undo_shard()
local shard_undone = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(shard_undone[1][4].conceal_lines == "", "undoing a shard should restore the profile")

scp.apply_shard("ignore_logging")
scp.set_profile("base")
local shard_reset = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(shard_reset[1][4].conceal_lines == "", "profile change should discard shard history")

local profiles_file = tmp .. "/.scpainter/profiles.lua"
vim.fn.mkdir(tmp .. "/.scpainter", "p")
write(
  profiles_file,
  [[
return {
  default = "project",
  profiles = {
    project = {
      extends = "base",
      tags = { LOGGING = { meaning = "IGNORE" } },
      rules = { IGNORE = { ignore = true }, SHOW = { highlight = true } },
    },
  },
}
]]
)

scp.setup({
  root = tmp,
  resolve = { precedence = { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" }, default = "SHOW" },
  rules = {
    CONCEAL = { conceal = { lines = true } },
    SHOW = { highlight = true },
    IGNORE = { ignore = true },
  },
  tags = {
    LOGGING = { meaning = "CONCEAL", bg = "#101010", priority = 10 },
    ERROR_HANDLING = { meaning = "SHOW", bg = "#202020", priority = 50 },
    UNTAGGED = { meaning = "SHOW" },
  },
})

vim.cmd.edit(vim.fn.fnameescape(meaning_src))
scp.render()
local project_marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(
  project_marks[1][4].hl_group and project_marks[1][4].hl_group:find("SCPainter_IGNORE_IGNORE", 1, true),
  "project default profile should switch Logging to IGNORE"
)

local profile_buf = scp.edit_profiles("base")
assert(vim.bo[profile_buf].filetype == "lua", "profile editor should be a Lua buffer")
assert(vim.fn.filereadable(profiles_file) == 1, "profile editor should create the profiles file")

local stale_lines = { "fun main() {", '    println("hi")', "}" }
write(tmp .. "/Stale.kt", table.concat(stale_lines, "\n") .. "\n")
write(
  tmp .. "/tags.json",
  string.format(
    [[
{
  "files": [
    { "path": "Stale.kt", "hash": "%s", "spans": [
      {"tag":"HOLLOW","startLine":1,"startCol":4,"endLine":1,"endCol":18}
    ] }
  ]
}
]],
    vim.fn.sha256(table.concat(stale_lines, "\n"))
  )
)

scp.setup({ root = tmp, tags = { HOLLOW = { conceal = { lines = true } } } })
vim.cmd.edit(vim.fn.fnameescape(tmp .. "/Stale.kt"))
local fresh = scp.render()
assert(fresh == 1, "matching hash should render, got " .. tostring(fresh))

vim.api.nvim_buf_set_lines(0, -1, -1, false, { "// edited" })
local stale = scp.render()
assert(stale == 0, "stale artifact should not render, got " .. tostring(stale))
assert(#vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, {}) == 0, "stale file should have no extmarks")

assert(vim.fn.exists(":SCPainterProfile") == 2, "profile command should exist")
assert(vim.fn.exists(":SCPainterProfileEdit") == 2, "profile edit command should exist")

local original_select = vim.ui.select
vim.ui.select = function(_, _, on_choice)
  on_choice("base")
end
scp.pick_profile()
vim.ui.select = original_select
assert(scp.profile() == "base", "picker should set the active profile")

print("PASS")
vim.cmd("qa!")
