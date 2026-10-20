local handlers = require("cint.handlers")
local palette = require("cint.core.colors")

local M = {}

M.ns = vim.api.nvim_create_namespace("cint")
M._defined = {}
local plans = {}

function M.reset()
  M._defined = {}
  plans = {}
end

function M.clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  plans[buf] = nil
end

local function clear_marks(buf)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
end

function M.is_rendered(buf)
  return #vim.api.nvim_buf_get_extmarks(buf, M.ns, 0, -1, {}) > 0
end

local function resolve_meaning(s, config)
  local labels = {}
  for _, intent in ipairs(s.intents or {}) do
    local tag_spec = (config.tags or {})[intent]
    local label = type(tag_spec) == "table" and tag_spec.meaning or nil
    if label then
      labels[#labels + 1] = label
    end
  end
  local resolve = config.resolve or {}
  local precedence = resolve.precedence or { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" }
  for _, candidate in ipairs(precedence) do
    for _, label in ipairs(labels) do
      if label == candidate then
        return candidate
      end
    end
  end
  return resolve.default or "SHOW"
end

local function spec_for(config, meaning)
  return (config.rules or {})[meaning]
end

local function chosen_tag(s, config)
  local intents = s.intents or {}
  local best, best_priority = nil, -math.huge
  for _, intent in ipairs(intents) do
    local spec = (config.tags or {})[intent] or palette.spec(intent)
    local priority = spec and spec.priority or 0
    if priority > best_priority then
      best = intent
      best_priority = priority
    end
  end
  return best or intents[1] or "default"
end

local function cache_key(s, meaning, tag)
  return table.concat({
    tostring(meaning),
    tostring(tag),
    table.concat(s.intents or {}, ","),
  }, "|")
end

local function handler_opts(s, config, cache)
  local meaning = resolve_meaning(s, config)
  local key = meaning
  local tag = chosen_tag(s, config)
  local style_key = cache and cache_key(s, key, tag)
  local cached = style_key and cache[style_key]
  if cached then
    return cached
  end

  local tag_spec = vim.tbl_extend("force", palette.spec(tag), (config.tags or {})[tag] or {})
  local ctx = { meaning = key, tag = tag, tag_spec = tag_spec, span = s, config = config }
  local mixed_scaffold = s.role == "scaffold" and s.intents ~= nil and #s.intents > 1
  local opts = {}
  local function add(name, hopts)
    if mixed_scaffold and (name == "color" or name == "highlight") then
      return
    end
    local handler = handlers.get(name)
    if not handler then
      return
    end
    local defined_key = key .. "|" .. tag .. "|" .. name
    if not M._defined[defined_key] then
      if handler.define then
        handler.define(ctx, hopts)
      end
      M._defined[defined_key] = true
    end
    if handler.extmark then
      opts = vim.tbl_extend("force", opts, handler.extmark(ctx, hopts))
    end
  end

  local spec = spec_for(config, meaning)
  if spec == false then
    if style_key then
      cache[style_key] = opts
    end
    return opts
  end
  if spec == nil then
    for _, name in ipairs(config.handlers) do
      add(name, {})
    end
  else
    for name, hopts in pairs(spec) do
      if hopts ~= false then
        add(name, hopts == true and {} or hopts)
      end
    end
  end
  if style_key then
    cache[style_key] = opts
  end
  return opts
end

function M.is_vertical(s, config)
  return handler_opts(s, config).conceal_lines ~= nil
end

local function line_len(plan, buf, row)
  local cached = plan.line_lens[row]
  if cached ~= nil then
    return cached
  end
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  local len = line and #line or 0
  plan.line_lens[row] = len
  return len
end

function M.plan(buf, spans, config)
  local changedtick = vim.b[buf].changedtick
  local existing = plans[buf]
  if existing
    and existing.spans == spans
    and existing.config == config
    and existing.changedtick == changedtick
  then
    return existing
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local plan = {
    buf = buf,
    spans = spans,
    config = config,
    changedtick = changedtick,
    line_count = line_count,
    line_lens = {},
    items = {},
  }
  local cache = {}
  for index, s in ipairs(spans) do
    local start_row = math.max(0, math.min(s.startLine, line_count - 1))
    local end_row = math.max(start_row, math.min(s.endLine, line_count - 1))
    local start_col = math.max(0, math.min(s.startCol, line_len(plan, buf, start_row)))
    local end_col = math.max(0, math.min(s.endCol, line_len(plan, buf, end_row)))
    if end_row == start_row and end_col < start_col then
      end_col = start_col
    end

    local base = handler_opts(s, config, cache)
    local item = {
      index = index,
      span = s,
      start_row = start_row,
      start_col = start_col,
      end_row = end_row,
      end_col = end_col,
      vertical = base.conceal_lines ~= nil,
      revealed = false,
    }
    if next(base) ~= nil then
      item.concealed_start_col = item.vertical and 0 or start_col
      item.revealed_start_col = start_col
      item.concealed_opts = vim.deepcopy(base)
      item.concealed_opts.end_row = end_row
      item.concealed_opts.priority = 1000
      item.revealed_opts = vim.deepcopy(base)
      item.revealed_opts.end_row = end_row
      item.revealed_opts.priority = 1000
      if item.vertical then
        item.concealed_opts.conceal_lines = ""
        item.concealed_opts.strict = false
        item.concealed_opts.end_col = -1
        item.revealed_opts.conceal_lines = nil
        item.revealed_opts.end_col = end_col
      else
        item.concealed_opts.end_col = end_col
        item.revealed_opts = item.concealed_opts
      end
    end
    plan.items[index] = item
  end
  plans[buf] = plan
  return plan
end

function M.active_span(plan, row)
  for _, item in ipairs(plan.items) do
    if (item.span.role == "scaffold" or item.vertical)
      and row >= item.span.startLine
      and row <= item.span.endLine
    then
      return item
    end
  end
  return nil
end

function M.contains(active, span)
  return active ~= nil
    and span.startLine >= active.startLine
    and span.endLine <= active.endLine
end

function M.update_reveal(buf, plan, active)
  for _, item in ipairs(plan.items) do
    if item.vertical and item.concealed_opts then
      local should_reveal = M.contains(active and active.span, item.span)
      if should_reveal ~= item.revealed then
        item.revealed = should_reveal
        local opts = should_reveal and item.revealed_opts or item.concealed_opts
        local start_col = should_reveal and item.revealed_start_col or item.concealed_start_col
        if item.id then
          opts.id = item.id
        end
        item.id = vim.api.nvim_buf_set_extmark(buf, M.ns, item.start_row, start_col, opts)
        opts.id = nil
      end
    end
  end
end

function M.render_buffer(buf, spans, config, ropts)
  ropts = ropts or {}
  clear_marks(buf)
  local plan = ropts.plan or M.plan(buf, spans, config)
  plans[buf] = plan
  local used_conceal = false
  for _, item in ipairs(plan.items) do
    item.id = nil
    item.revealed = false
    if item.concealed_opts then
      local opts = item.concealed_opts
      local start_col = item.concealed_start_col
      if item.vertical then
        used_conceal = true
        if ropts.reveal and ropts.reveal(item.span) then
          item.revealed = true
          opts = item.revealed_opts
          start_col = item.revealed_start_col
        end
      elseif opts.conceal then
        used_conceal = true
      end
      item.id = vim.api.nvim_buf_set_extmark(buf, M.ns, item.start_row, start_col, opts)
    end
  end
  if used_conceal then
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      if vim.wo[win].conceallevel == 0 then
        vim.wo[win].conceallevel = 2
      end
    end
  end
end

return M
