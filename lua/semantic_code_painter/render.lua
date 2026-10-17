local handlers = require("semantic_code_painter.handlers")

local M = {}

M.ns = vim.api.nvim_create_namespace("semantic_code_painter")
M._defined = {}

function M.reset()
  M._defined = {}
end

function M.clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
end

function M.is_rendered(buf)
  return #vim.api.nvim_buf_get_extmarks(buf, M.ns, 0, -1, {}) > 0
end

local function line_len(buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  return line and #line or 0
end

local function visual_key(s)
  if s.meaning then
    return s.meaning
  end
  if s.tag then
    return s.tag
  end
  if s.intents and #s.intents > 0 then
    return s.intents[1]
  end
  return "default"
end

local function spec_for(s, config)
  if s.meaning ~= nil then
    local meanings = config.meanings or {}
    return meanings[s.meaning]
  end
  local tag = s.tag or (s.intents and s.intents[1])
  if tag ~= nil then
    return config.tags[tag]
  end
  return nil
end

local function handler_opts(s, config)
  local key = visual_key(s)
  local opts = {}
  local function add(name, hopts)
    local handler = handlers.get(name)
    if not handler then
      return
    end
    local defined_key = key .. "|" .. name
    if not M._defined[defined_key] then
      if handler.define then
        handler.define(key, hopts)
      end
      M._defined[defined_key] = true
    end
    if handler.extmark then
      opts = vim.tbl_extend("force", opts, handler.extmark(key, hopts))
    end
  end

  local spec = spec_for(s, config)
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
  return opts
end

function M.is_vertical(s, config)
  return handler_opts(s, config).conceal_lines ~= nil
end

function M.render_buffer(buf, spans, config, ropts)
  ropts = ropts or {}
  M.clear(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local used_conceal = false
  for _, s in ipairs(spans) do
    local start_row = math.max(0, math.min(s.startLine, line_count - 1))
    local end_row = math.max(start_row, math.min(s.endLine, line_count - 1))
    local start_col = math.max(0, math.min(s.startCol, line_len(buf, start_row)))
    local end_col = math.max(0, math.min(s.endCol, line_len(buf, end_row)))
    if end_row == start_row and end_col < start_col then
      end_col = start_col
    end
    local opts = handler_opts(s, config)
    if opts.conceal_lines ~= nil and ropts.reveal and ropts.reveal(s) then
      opts.conceal_lines = nil
    end
    if next(opts) ~= nil then
      if opts.conceal_lines ~= nil then
        used_conceal = true
        start_col = 0
        end_col = -1
        opts.strict = false
      elseif opts.conceal then
        used_conceal = true
      end
      opts.end_row = end_row
      opts.end_col = end_col
      opts.priority = 1000
      vim.api.nvim_buf_set_extmark(buf, M.ns, start_row, start_col, opts)
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
