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

local function handler_opts(tag, config)
  local opts = {}
  local function add(name, hopts)
    local handler = handlers.get(name)
    if not handler then
      return
    end
    local key = tag .. "|" .. name
    if not M._defined[key] then
      if handler.define then
        handler.define(tag, hopts)
      end
      M._defined[key] = true
    end
    if handler.extmark then
      opts = vim.tbl_extend("force", opts, handler.extmark(tag, hopts))
    end
  end

  local spec = config.tags[tag]
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

function M.render_buffer(buf, spans, config)
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
    local opts = handler_opts(s.tag, config)
    if opts.conceal then
      used_conceal = true
    end
    opts.end_row = end_row
    opts.end_col = end_col
    opts.priority = 1000
    vim.api.nvim_buf_set_extmark(buf, M.ns, start_row, start_col, opts)
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
