local M = {}

M.ns = vim.api.nvim_create_namespace("cint-candidates")

local function define_highlights()
  vim.api.nvim_set_hl(0, "CintCandidate", { undercurl = true, underdouble = true })
  vim.api.nvim_set_hl(0, "CintCandidateSign", { fg = "#8a8a8a", italic = true })
end

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

function M.render(buf, candidates)
  define_highlights()
  M.clear(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local rendered = 0
  for _, candidate in ipairs(candidates or {}) do
    local start_row = math.max(0, math.min(candidate.startLine or 0, line_count - 1))
    local end_row = math.max(start_row, math.min(candidate.endLine or start_row, line_count - 1))
    local line = vim.api.nvim_buf_get_lines(buf, start_row, start_row + 1, false)[1] or ""
    local start_col = math.max(0, math.min(candidate.startCol or 0, #line))
    local end_line = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ""
    local end_col = math.max(0, math.min(candidate.endCol or 0, #end_line))
    if end_row == start_row and end_col < start_col then
      end_col = start_col
    end
    vim.api.nvim_buf_set_extmark(buf, M.ns, start_row, start_col, {
      end_row = end_row,
      end_col = end_col,
      hl_group = "CintCandidate",
      priority = 1100,
    })
    vim.api.nvim_buf_set_extmark(buf, M.ns, start_row, 0, {
      sign_text = "?",
      sign_hl_group = "CintCandidateSign",
      priority = 1100,
    })
    rendered = rendered + 1
  end
  return rendered
end

return M
