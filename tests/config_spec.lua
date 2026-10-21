local cint = require("cint")
local live = require("cint.transport.live")
local live_ops = require("cint.ops.live_ops")
local state = require("cint.core.state")

local function write(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.cint", "p")
local source = root .. "/Foo.kt"
write(source, 'fun f() { log.audit("x") }\n')

cint.setup({
  root = root,
  resolve = { precedence = { "HIGHLIGHT" }, default = "HIGHLIGHT" },
  rules = { HIGHLIGHT = { highlight = true } },
  tags = { LOGGING = { meaning = "HIGHLIGHT" } },
})
vim.cmd.edit(vim.fn.fnameescape(source))
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = "kotlin"
assert(cint.language_for(buf) == "kotlin", "test buffer should map to Kotlin")

local packs = {
  {
    packId = "logging",
    languages = { "kotlin", "javascript" },
    rules = { { id = "logging:logging", owns = "LOGGING", reads = {} } },
    fields = {
      { key = "methods", kind = "STRINGS", scope = "LANGUAGE", languages = { "kotlin", "javascript" } },
      { key = "types", kind = "BOOLEAN", scope = "LANGUAGE", languages = { "kotlin" } },
    },
  },
  {
    packId = "validation",
    languages = { "kotlin", "javascript" },
    rules = { { id = "validation:validation", owns = "VALIDATION", reads = {} } },
    fields = {
      { key = "predicates", kind = "STRING_LIST", scope = "PACK", languages = {} },
      { key = "magicComment", kind = "STRING", scope = "PACK", languages = {} },
    },
  },
  {
    packId = "javascript-only",
    languages = { "javascript" },
    rules = { { id = "javascript-only:rule", owns = "JS", reads = {} } },
    fields = {
      { key = "names", kind = "STRINGS", scope = "PACK", languages = {} },
    },
  },
  {
    packId = "other-language-field",
    languages = { "kotlin" },
    rules = { { id = "other-language-field:rule", owns = "OTHER", reads = {} } },
    fields = {
      { key = "javascriptOnly", kind = "STRINGS", scope = "LANGUAGE", languages = { "javascript" } },
    },
  },
}

state.live_config_packs = packs
state.live_config_overlay = {}
state.live_config_protocol = 2

local choices = cint.config_choices(buf)
local keys = {}
for _, choice in ipairs(choices) do
  keys[choice.packId .. "." .. choice.field] = choice
end
assert(keys["logging.methods"], "language-scoped string fields should be selectable")
assert(keys["validation.predicates"], "pack-scoped string-list fields should be selectable")
assert(not keys["logging.types"], "boolean fields must be filtered out")
assert(not keys["validation.magicComment"], "string fields must be filtered out")
assert(not keys["javascript-only.names"], "packs for another language must be filtered out")
assert(
  not keys["other-language-field.javascriptOnly"],
  "language-scoped fields for another language must be filtered out"
)
assert(
  keys["logging.methods"].label:find("logging:logging", 1, true)
    and keys["logging.methods"].label:find("LOGGING", 1, true),
  "picker labels should name the owning rule and intent"
)

local requests = {}
local original_request = live.request
local original_refresh = live_ops.live_request_analysis
local original_select = vim.ui.select
live_ops.live_request_analysis = function()
  return true
end
live.request = function(method, params, callback)
  requests[#requests + 1] = { method = method, params = params }
  if method == "cint/config/append" then
    state.live_config_overlay = { logging = { kotlin = { methods = { "audit" } } } }
    if callback then
      callback(nil, { packs = packs, overlay = state.live_config_overlay })
    end
  elseif method == "cint/config/remove" then
    state.live_config_overlay = {}
    if callback then
      callback(nil, { packs = packs, overlay = state.live_config_overlay })
    end
  end
  return true
end
vim.ui.select = function(items, _, on_choice)
  for index, label in ipairs(items) do
    if label:find("logging:logging", 1, true) and label:find("methods", 1, true) then
      on_choice(label, index)
      return
    end
    if label:find("methods = audit", 1, true) then
      on_choice(label, index)
      return
    end
  end
  on_choice(nil, nil)
end

vim.api.nvim_win_set_cursor(0, { 1, 17 })
vim.cmd("CintConfigAdd")
assert(#requests == 1, "CintConfigAdd should send one config request")
assert(requests[1].method == "cint/config/append", "CintConfigAdd should append")
assert(requests[1].params.packId == "logging", "append should target the selected pack")
assert(requests[1].params.language == "kotlin", "append should target the buffer language")
assert(requests[1].params.field == "methods", "append should target the selected field")
assert(requests[1].params.value == "audit", "append should use the word under the cursor")

local removals = cint.config_remove_choices(buf)
assert(#removals == 1, "remove picker should list the user overlay value")
assert(removals[1].value == "audit", "remove picker should expose the overlay value")
assert(
  removals[1].label:find("logging:logging", 1, true) and removals[1].label:find("methods = audit", 1, true),
  "remove labels should name the owning rule/field/value"
)

vim.cmd("CintConfigRemove")
assert(#requests == 2, "CintConfigRemove should send one config request")
assert(requests[2].method == "cint/config/remove", "CintConfigRemove should remove")
assert(requests[2].params.packId == "logging", "remove should target the selected pack")
assert(requests[2].params.field == "methods", "remove should target the selected field")
assert(requests[2].params.value == "audit", "remove should target the overlay value")

state.live_config_packs = packs
state.live_config_overlay = {}
state.live_config_protocol = 1
local before_protocol_one = #requests
cint.config_on_initialize({ protocol = 1, config = { packs = packs, overlay = {} } })
assert(#requests == before_protocol_one, "protocol 1 must not trigger config/read")
assert(#state.live_config_packs == 0, "protocol 1 should not cache descriptors")
local protocol_one_ok = cint.config_add("audit", buf)
assert(not protocol_one_ok, "config commands must be gated on protocol 2")
assert(#requests == before_protocol_one, "protocol 1 config add must not send a request")

live.request = original_request
live_ops.live_request_analysis = original_refresh
vim.ui.select = original_select

local render = require("cint.render")
vim.api.nvim_set_current_buf(buf)
local path = vim.api.nvim_buf_get_name(buf)
local version = vim.b[buf].changedtick
state.live_docs[buf] = { path = path, version = version, text = "" }
state.live_tags[buf] = nil
state.rendered[buf] = nil
cint.live_on_tags({
  uri = path,
  version = version,
  hash = "same-hash",
  revision = 0,
  annotations = {
    { role = "source-intent", intents = { "LOGGING" }, startLine = 0, startCol = 0, endLine = 0, endCol = 1 },
  },
})
assert(
  #vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {}) == 1,
  "first publish should render one extmark"
)
cint.live_on_tags({
  uri = path,
  version = version,
  hash = "same-hash",
  revision = 1,
  annotations = {
    { role = "source-intent", intents = { "LOGGING" }, startLine = 0, startCol = 0, endLine = 0, endCol = 1 },
    { role = "source-intent", intents = { "LOGGING" }, startLine = 0, startCol = 2, endLine = 0, endCol = 3 },
  },
})
assert(
  #vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {}) == 2,
  "an unchanged hash with a new revision should re-render extmarks"
)
cint.live_on_tags({
  uri = path,
  version = version,
  hash = "same-hash",
  revision = 0,
  annotations = {
    { role = "source-intent", intents = { "LOGGING" }, startLine = 0, startCol = 0, endLine = 0, endCol = 1 },
    { role = "source-intent", intents = { "LOGGING" }, startLine = 0, startCol = 2, endLine = 0, endCol = 3 },
    { role = "source-intent", intents = { "LOGGING" }, startLine = 0, startCol = 4, endLine = 0, endCol = 5 },
  },
})
assert(
  #vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {}) == 2,
  "a lower revision must not replace newer rendered tags"
)
assert(state.live_tags[buf].revision == 1, "a lower revision must not replace the cached revision")

print("PASS")
vim.cmd("qa!")
