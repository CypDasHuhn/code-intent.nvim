local config = require("cint.core.config")
local live_ops = require("cint.ops.live_ops")
local render = require("cint.render")
local state = require("cint.core.state")

local M = {}

M.meanings = { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" }
M._meaning_set = {}
for _, meaning in ipairs(M.meanings) do
  M._meaning_set[meaning] = true
end

local function notify(message, level)
  vim.notify("cint: " .. tostring(message), level or vim.log.levels.INFO)
end

local function normalize(value)
  return vim.trim(tostring(value or "")):upper()
end

local function canonical_intent(value, buf)
  local name = vim.trim(tostring(value or ""))
  if name == "" then
    return ""
  end
  for _, intent in ipairs(M.intent_names(buf)) do
    if intent:lower() == name:lower() then
      return intent
    end
  end
  return name
end

local function overrides_for(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end
  return vim.deepcopy(vim.b[buf].cint_meanings or {})
end

local function store_overrides(buf, overrides)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if next(overrides) == nil then
    vim.b[buf].cint_meanings = nil
  else
    vim.b[buf].cint_meanings = overrides
  end
end

local function target_buffers(opts)
  if opts.global then
    local bufs = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        bufs[#bufs + 1] = buf
      end
    end
    return bufs
  end
  return { opts.buf or vim.api.nvim_get_current_buf() }
end

local function resolved_config(buf)
  local root = config.buffer_root(buf)
  return config.resolve_profile(root, config.active_profile(root, buf), buf)
end

local function apply_overrides()
  state.configs = {}
  render.reset()
  for buf in pairs(state.rendered) do
    if vim.api.nvim_buf_is_loaded(buf) then
      live_ops.render_buf(buf)
    end
  end
end

local function add_live_intents(names, buf)
  local tags = state.live_tags[buf]
  for _, annotation in ipairs(tags and tags.annotations or {}) do
    for _, intent in ipairs(annotation.intents or {}) do
      names[tostring(intent)] = true
    end
  end
end

function M.is_meaning(value)
  return M._meaning_set[normalize(value)] == true
end

function M.intent_names(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local names = {}
  for intent in pairs(resolved_config(buf).tags or {}) do
    names[tostring(intent)] = true
  end
  add_live_intents(names, buf)
  local result = {}
  for intent in pairs(names) do
    result[#result + 1] = intent
  end
  table.sort(result)
  return result
end

function M.display_map(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local cfg = resolved_config(buf)
  local default = cfg.resolve and cfg.resolve.default or "SHOW"
  local result = {}
  for _, intent in ipairs(M.intent_names(buf)) do
    local spec = (cfg.tags or {})[intent]
    local meaning = type(spec) == "table" and spec.meaning or nil
    result[#result + 1] = {
      intent = intent,
      meaning = meaning or default,
    }
  end
  return result
end

function M.set_meanings(intents, meaning, opts)
  opts = opts or {}
  meaning = normalize(meaning)
  if not M.is_meaning(meaning) then
    return false, "unknown meaning " .. tostring(meaning)
  end
  local lookup_buf = opts.buf or vim.api.nvim_get_current_buf()
  local normalized = {}
  for _, intent in ipairs(intents or {}) do
    local name = canonical_intent(intent, lookup_buf)
    if name ~= "" then
      normalized[#normalized + 1] = name
    end
  end
  if #normalized == 0 then
    return false, "no intents given"
  end
  for _, buf in ipairs(target_buffers(opts)) do
    local overrides = overrides_for(buf)
    for _, intent in ipairs(normalized) do
      overrides[intent] = meaning
    end
    store_overrides(buf, overrides)
  end
  apply_overrides()
  if not opts.silent then
    notify(table.concat(normalized, ", ") .. " = " .. meaning)
  end
  return true
end

function M.set_meaning(intent, meaning, opts)
  return M.set_meanings({ intent }, meaning, opts)
end

function M.cycle_meaning(intent, opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local current
  local target = canonical_intent(intent, buf)
  for _, entry in ipairs(M.display_map(buf)) do
    if entry.intent == target then
      current = entry.meaning
      break
    end
  end
  local index = 0
  for position, meaning in ipairs(M.meanings) do
    if meaning == current then
      index = position
      break
    end
  end
  local next_meaning = M.meanings[(index % #M.meanings) + 1]
  return M.set_meaning(intent, next_meaning, opts)
end

function M.reset_meanings(intents, opts)
  opts = opts or {}
  local lookup_buf = opts.buf or vim.api.nvim_get_current_buf()
  local normalized = {}
  for _, intent in ipairs(intents or {}) do
    local name = canonical_intent(intent, lookup_buf)
    if name ~= "" then
      normalized[#normalized + 1] = name
    end
  end
  for _, buf in ipairs(target_buffers(opts)) do
    if #normalized == 0 then
      store_overrides(buf, {})
    else
      local overrides = overrides_for(buf)
      for _, intent in ipairs(normalized) do
        overrides[intent] = nil
      end
      store_overrides(buf, overrides)
    end
  end
  apply_overrides()
  if not opts.silent then
    notify("temporary meanings reset")
  end
  return true
end

function M.reset_meaning(intent, opts)
  return M.reset_meanings({ intent }, opts)
end

function M.open_display(buf)
  local ui = require("cint.ui.display")
  return ui.open(buf or vim.api.nvim_get_current_buf())
end

function M.close_display()
  local ui = require("cint.ui.display")
  return ui.close()
end

function M.display_active()
  local ui = require("cint.ui.display")
  return ui.active()
end

return M
