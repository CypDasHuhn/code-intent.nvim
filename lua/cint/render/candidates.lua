local M = {}

M.ns = vim.api.nvim_create_namespace("cint-candidates")

local function define_highlights()
  vim.api.nvim_set_hl(0, "CintCandidate", { undercurl = true, underdouble = true })
  vim.api.nvim_set_hl(0, "CintCandidateSign", { fg = "#8a8a8a", italic = true })
  vim.api.nvim_set_hl(0, "CintCandidateReview", { bg = "#3a3320", underline = true, bold = true })
  vim.api.nvim_set_hl(0, "CintCandidateReviewSign", { fg = "#e5c07b", bold = true })
  vim.api.nvim_set_hl(0, "CintCandidateReviewLine", { fg = "#e5c07b", italic = true })
end

local function candidate_text(candidate)
  local intents = {}
  for _, intent in ipairs(candidate.intents or {}) do
    intents[#intents + 1] = tostring(intent)
  end
  local label = #intents > 0 and table.concat(intents, ",") or "?"
  local parts = {
    string.format("%s  %.2f", label, tonumber(candidate.confidence) or 0),
  }
  if candidate.source and candidate.source ~= "" then
    parts[#parts + 1] = tostring(candidate.source)
  end
  if candidate.reason and candidate.reason ~= "" then
    parts[#parts + 1] = tostring(candidate.reason)
  end
  local rationale = candidate.rationale and vim.trim(tostring(candidate.rationale)) or ""
  if rationale ~= "" then
    if #rationale > 72 then
      rationale = rationale:sub(1, 69) .. "..."
    end
    parts[#parts + 1] = rationale
  end
  return "  " .. table.concat(parts, " | ") .. "  "
end

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

function M.render(buf, candidates, review)
  define_highlights()
  M.clear(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local hl_group = review and "CintCandidateReview" or "CintCandidate"
  local sign_hl_group = review and "CintCandidateReviewSign" or "CintCandidateSign"
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
      hl_group = hl_group,
      priority = 1100,
    })
    vim.api.nvim_buf_set_extmark(buf, M.ns, start_row, 0, {
      sign_text = "?",
      sign_hl_group = sign_hl_group,
      priority = 1100,
    })
    if review then
      vim.api.nvim_buf_set_extmark(buf, M.ns, start_row, 0, {
        virt_lines = { { { candidate_text(candidate), "CintCandidateReviewLine" } } },
        virt_lines_above = true,
        priority = 1100,
      })
    end
    rendered = rendered + 1
  end
  return rendered
end

return M
