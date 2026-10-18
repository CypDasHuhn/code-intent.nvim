local cint = require("cint")
local render = require("cint.render")
local palette = require("cint.colors")

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function publish(buf, annotations)
  cint._live_tags[buf] = {
    version = vim.b[buf].changedtick,
    hash = "test-" .. tostring(vim.b[buf].changedtick),
    annotations = annotations,
  }
end

local function open(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local src = tmp .. "/Foo.kt"
write(
  src,
  'fun main() {\n    log.info("hi")\n    println("noise")\n    val x = compute()\n    val y = compute()\n}\n'
)

cint.setup({
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

local foo_buf = open(src)
publish(foo_buf, {
  { tag = "LOGGING", startLine = 1, startCol = 4, endLine = 1, endCol = 18 },
  { tag = "NOISE", startLine = 2, startCol = 4, endLine = 2, endCol = 20 },
  { tag = "OTHER", startLine = 3, startCol = 4, endLine = 3, endCol = 21 },
  { tag = "HOLLOW", startLine = 4, startCol = 4, endLine = 4, endCol = 21 },
})

local count = cint.render()
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
cint.reveal_block()
local revealed = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 5 }).all
assert(revealed == 6, "cursor inside concealed block should reveal it, got height " .. revealed)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
cint.reveal_block()
local reconcealed = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 5 }).all
assert(reconcealed == 5, "cursor leaving the block should re-conceal it, got height " .. reconcealed)

cint.clear()
assert(#vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, {}) == 0, "expected clear to remove extmarks")

local nested_src = tmp .. "/Nested.kt"
write(nested_src, "a\nb\nc\nd\ne\nf\n")
local nested_buf = open(nested_src)
local nested_spans = {
  { tag = "HOLLOW", startLine = 1, startCol = 0, endLine = 3, endCol = 0 },
  { tag = "HOLLOW", startLine = 2, startCol = 0, endLine = 2, endCol = 1 },
}
local nested_config = cint.config_for(nested_buf)
cint._rendered[nested_buf] = nested_spans
cint._configs[nested_buf] = nested_config
render.render_buffer(nested_buf, nested_spans, nested_config)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
cint._active[nested_buf] = nil
cint.reveal_block(nested_buf)
local nested_height = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 5 }).all
assert(
  nested_height == 6,
  "entering a concealed block should reveal nested spans, got height " .. nested_height
)

local mixed_src = tmp .. "/Mixed.kt"
write(mixed_src, "a\nb\nc\nd\ne\nf\n")
local mixed_buf = open(mixed_src)
local mixed_spans = {
  { role = "scaffold", tag = "LOGGING", startLine = 1, startCol = 0, endLine = 3, endCol = 0 },
  { tag = "HOLLOW", startLine = 2, startCol = 0, endLine = 2, endCol = 1 },
}
local mixed_config = cint.config_for(mixed_buf)
cint._rendered[mixed_buf] = mixed_spans
cint._configs[mixed_buf] = mixed_config
render.render_buffer(mixed_buf, mixed_spans, mixed_config)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
cint._active[mixed_buf] = nil
cint.reveal_block(mixed_buf)
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
local meaning_spans = {
  { role = "source-intent", intents = { "LOGGING" }, startLine = 1, startCol = 4, endLine = 1, endCol = 18 },
  { role = "source-intent", intents = { "ERROR_HANDLING" }, startLine = 2, startCol = 4, endLine = 2, endCol = 18 },
  { role = "source-intent", intents = { "LOGGING" }, startLine = 3, startCol = 4, endLine = 3, endCol = 23 },
}

local function meaning_setup(intent_logging)
  cint.setup({
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
local meaning_buf = open(meaning_src)
publish(meaning_buf, meaning_spans)
local meaning_count = cint.render()
assert(meaning_count == 3, "expected 3 meaning spans rendered, got " .. tostring(meaning_count))

local meaning_marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(#meaning_marks == 3, "expected 3 meaning extmarks, got " .. #meaning_marks)
assert(meaning_marks[1][4].conceal_lines == "", "CONCEAL should hide the line")
assert(meaning_marks[3][4].conceal_lines == "", "CONCEAL should hide the second Logging line")

local highlight_group = meaning_marks[2][4].hl_group
assert(
  highlight_group and highlight_group:find("Cint_HL_SHOW_ERROR_HANDLING", 1, true),
  "SHOW should use the ErrorHandling highlight group, got " .. tostring(highlight_group)
)
local highlight_hl = vim.api.nvim_get_hl(0, { name = highlight_group })
assert(
  highlight_hl.bg == tonumber("202020", 16),
  "highlight bg should come from the tag, got " .. tostring(highlight_hl.bg)
)

meaning_setup("IGNORE")
publish(open(meaning_src), meaning_spans)
cint.render()
local switched_marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(#switched_marks == 3, "expected 3 switched extmarks, got " .. #switched_marks)
for _, index in ipairs({ 1, 3 }) do
  local ignore_group = switched_marks[index][4].hl_group
  assert(
    ignore_group and ignore_group:find("Cint_IGNORE_IGNORE", 1, true),
    "switching Logging to IGNORE should use the ignore group, got " .. tostring(ignore_group)
  )
  assert(switched_marks[index][4].conceal_lines == nil, "IGNORE should not conceal")
end
local ignore_hl = vim.api.nvim_get_hl(0, { name = switched_marks[1][4].hl_group })
assert(
  ignore_hl.fg == tonumber("555555", 16),
  "ignore should use dark gray, got " .. tostring(ignore_hl.fg)
)

cint.setup({
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

publish(open(meaning_src), meaning_spans)
local profile_count = cint.render()
assert(profile_count == 3, "profile render should produce 3 spans, got " .. tostring(profile_count))

local base_marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(base_marks[1][4].conceal_lines == "", "base profile should conceal Logging")

cint.set_profile("review")
local review_marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(
  review_marks[1][4].hl_group and review_marks[1][4].hl_group:find("Cint_IGNORE_IGNORE", 1, true),
  "review profile should switch Logging to IGNORE"
)
assert(review_marks[1][4].conceal_lines == nil, "review profile should not conceal Logging")

cint.setup({
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

publish(open(meaning_src), meaning_spans)
cint.render()
local shard_base = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(shard_base[1][4].conceal_lines == "", "base profile should conceal before shards")

cint.apply_shard("ignore_logging")
local shard_applied = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(
  shard_applied[1][4].hl_group and shard_applied[1][4].hl_group:find("Cint_IGNORE_IGNORE", 1, true),
  "applying a shard should override Logging"
)

cint.undo_shard()
local shard_undone = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(shard_undone[1][4].conceal_lines == "", "undoing a shard should restore the profile")

cint.apply_shard("ignore_logging")
cint.set_profile("base")
local shard_reset = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(shard_reset[1][4].conceal_lines == "", "profile change should discard shard history")

local profiles_file = tmp .. "/.cint/profiles.lua"
vim.fn.mkdir(tmp .. "/.cint", "p")
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

cint.setup({
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

publish(open(meaning_src), meaning_spans)
cint.render()
local project_marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(
  project_marks[1][4].hl_group and project_marks[1][4].hl_group:find("Cint_IGNORE_IGNORE", 1, true),
  "project default profile should switch Logging to IGNORE"
)

local profile_buf = cint.edit_profiles("base")
assert(vim.bo[profile_buf].filetype == "lua", "profile editor should be a Lua buffer")
assert(vim.fn.filereadable(profiles_file) == 1, "profile editor should create the profiles file")

local mixed_root = tmp .. "/mixed"
vim.fn.mkdir(mixed_root, "p")
local mixed_scaffold_src = tmp .. "/MixedScaffold.kt"
write(
  mixed_scaffold_src,
  "fun f() {\n    log.info(\"x\")\n    throw IllegalStateException(\"y\")\n}\n"
)
local mixed_scaffold_buf = open(mixed_scaffold_src)
local mixed_scaffold_spans = {
  { role = "scaffold", intents = { "LOGGING", "ERROR_HANDLING" }, startLine = 0, startCol = 0, endLine = 3, endCol = 1 },
  { role = "source-intent", intents = { "LOGGING" }, startLine = 1, startCol = 4, endLine = 1, endCol = 18 },
  { role = "source-intent", intents = { "ERROR_HANDLING" }, startLine = 2, startCol = 4, endLine = 2, endCol = 40 },
}

cint.setup({
  root = mixed_root,
  resolve = { precedence = { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" }, default = "SHOW" },
  rules = { CONCEAL = { conceal = { lines = true } }, SHOW = { highlight = true } },
  tags = {
    LOGGING = { meaning = "CONCEAL", priority = 10, bg = "#101010" },
    ERROR_HANDLING = { meaning = "SHOW", priority = 50, bg = "#202020" },
  },
})
render.render_buffer(mixed_scaffold_buf, mixed_scaffold_spans, cint.config_for(mixed_scaffold_buf))
local mixed_scaffold_marks = vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })
assert(#mixed_scaffold_marks == 2, "mixed scaffold should not add a color extmark, got " .. #mixed_scaffold_marks)
for _, mark in ipairs(mixed_scaffold_marks) do
  assert(mark[2] ~= 0, "mixed scaffold should not render on its first line")
end

cint.setup({
  root = mixed_root,
  resolve = { precedence = { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" }, default = "SHOW" },
  rules = { CONCEAL = { conceal = { lines = true } }, SHOW = { highlight = true } },
  tags = {
    LOGGING = { meaning = "CONCEAL", priority = 10, bg = "#101010" },
    ERROR_HANDLING = { meaning = "CONCEAL", priority = 50, bg = "#202020" },
  },
})
render.render_buffer(mixed_scaffold_buf, mixed_scaffold_spans, cint.config_for(mixed_scaffold_buf))
local concealed_scaffold = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })) do
  if mark[2] == 0 and mark[4].conceal_lines ~= nil then
    concealed_scaffold = true
  end
end
assert(concealed_scaffold, "mixed scaffold should still conceal when all intents resolve to CONCEAL")

cint.setup({
  root = mixed_root,
  resolve = { precedence = { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" }, default = "SHOW" },
  rules = { CONCEAL = { conceal = { lines = true } }, SHOW = { highlight = true } },
  tags = {
    ERROR_HANDLING = { meaning = "SHOW", priority = 50, bg = "#202020" },
  },
})
render.render_buffer(
  mixed_scaffold_buf,
  { { role = "scaffold", intents = { "ERROR_HANDLING" }, startLine = 0, startCol = 0, endLine = 3, endCol = 1 } },
  cint.config_for(mixed_scaffold_buf)
)
local single_scaffold_colored = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })) do
  if mark[4].hl_group and mark[4].hl_group:find("Cint_HL_SHOW_ERROR_HANDLING", 1, true) then
    single_scaffold_colored = true
  end
end
assert(single_scaffold_colored, "single-intent scaffold should still render its color")

cint.setup({ root = mixed_root })
render.render_buffer(
  mixed_scaffold_buf,
  { { role = "source-intent", intents = { "ERROR_HANDLING" }, startLine = 1, startCol = 4, endLine = 1, endCol = 18 } },
  cint.config_for(mixed_scaffold_buf)
)
assert(
  #vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, {}) == 0,
  "default SHOW should not render an extmark"
)

cint.setup({ root = mixed_root, tags = { ERROR_HANDLING = { meaning = "HIGHLIGHT" } } })
render.render_buffer(
  mixed_scaffold_buf,
  { { role = "source-intent", intents = { "ERROR_HANDLING" }, startLine = 1, startCol = 4, endLine = 1, endCol = 18 } },
  cint.config_for(mixed_scaffold_buf)
)
local highlighted_show = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, render.ns, 0, -1, { details = true })) do
  if mark[4].hl_group and mark[4].hl_group:find("Cint_HL_HIGHLIGHT_ERROR_HANDLING", 1, true) then
    highlighted_show = true
  end
end
assert(highlighted_show, "HIGHLIGHT should paint a background")

local scope_root = tmp .. "/scope"
vim.fn.mkdir(scope_root .. "/.cint", "p")
write(
  scope_root .. "/.cint/profiles.lua",
  [[
return {
  profiles = {
    cint_test_project_only = { tags = { LOGGING = { meaning = "IGNORE" } } },
  },
}
]]
)
cint.setup({
  root = scope_root,
  scope = "global",
  profiles = {
    cint_test_global = { tags = { LOGGING = { meaning = "SHOW" } } },
  },
})
local global_profiles = cint.get_profiles(scope_root)
assert(global_profiles.profiles.cint_test_project_only == nil, "global scope should ignore project profiles")
assert(global_profiles.profiles.cint_test_global ~= nil, "global scope should keep setup profiles")
assert(
  cint.profiles_path(scope_root):find("/cint/profiles.lua", 1, true) ~= nil,
  "global scope should use the config profile path"
)
assert(cint.defaults.scope == "project", "project scope should be the default")

assert(cint.defaults.artifact == nil, "offline artifact support should be removed")
assert(cint.defaults.live == nil, "live toggle should be removed; the renderer is socket-only")

local function language_of(path, filetype)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = filetype
  return cint.language_for(buf)
end

assert(language_of(tmp .. "/Foo.kt", "kotlin") == "kotlin")
assert(language_of(tmp .. "/App.js", "javascript") == "javascript")
assert(language_of(tmp .. "/App.ts", "typescript") == "typescript")
assert(language_of(tmp .. "/App.vue", "vue") == "vue")
assert(language_of(tmp .. "/App.cs", "cs") == "csharp")
assert(language_of(tmp .. "/Notes.txt", "text") == nil)

local unsupported = tmp .. "/Notes.txt"
write(unsupported, "hello\n")
open(unsupported)
assert(cint.render() == 0, "unsupported buffers should not render")

assert(vim.fn.exists(":CintProfile") == 2, "profile command should exist")
assert(vim.fn.exists(":CintProfileEdit") == 2, "profile edit command should exist")

local original_select = vim.ui.select
vim.ui.select = function(_, _, on_choice)
  on_choice("base")
end
cint.pick_profile()
vim.ui.select = original_select
assert(cint.profile() == "base", "picker should set the active profile")

print("PASS")
vim.cmd("qa!")
