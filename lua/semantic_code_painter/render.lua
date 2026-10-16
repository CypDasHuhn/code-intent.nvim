local colors = require("semantic_code_painter.colors")

local M = {}

M.ns = vim.api.nvim_create_namespace("semantic_code_painter")

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

function M.render_buffer(buf, spans)
  M.clear(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, s in ipairs(spans) do
    local start_row = math.max(0, math.min(s.startLine, line_count - 1))
    local end_row = math.max(start_row, math.min(s.endLine, line_count - 1))
    local start_col = math.max(0, math.min(s.startCol, line_len(buf, start_row)))
    local end_col = math.max(0, math.min(s.endCol, line_len(buf, end_row)))
    if end_row == start_row and end_col < start_col then
      end_col = start_col
    end
    local spec = colors.spec(s.tag)
    vim.api.nvim_buf_set_extmark(buf, M.ns, start_row, start_col, {
      end_row = end_row,
      end_col = end_col,
      hl_group = colors.group(s.tag),
      sign_text = spec.icon,
      sign_hl_group = colors.sign_group(s.tag),
      priority = 1000,
    })
  end
end

return M
