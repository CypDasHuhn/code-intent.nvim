local state = require("cint.core.state")

local M = {}

M.ns = vim.api.nvim_create_namespace("cint-intent-labels")

local function define_highlights()
  vim.api.nvim_set_hl(0, "CintIntentLabel", { fg = "#8ab4f8", italic = true })
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(value, maximum))
end

function M.clear(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

function M.render(buf, spans, enabled)
  define_highlights()
  M.clear(buf)
  if not enabled or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local rendered = 0
  for _, span in ipairs(spans or {}) do
    local intents = span.intents or {}
    if #intents > 0 then
      local start_row = clamp(tonumber(span.startLine) or 0, 0, line_count - 1)
      local line = vim.api.nvim_buf_get_lines(buf, start_row, start_row + 1, false)[1] or ""
      local start_col = clamp(tonumber(span.startCol) or 0, 0, #line)
      local text = "▸ " .. table.concat(intents, ", ")
      vim.api.nvim_buf_set_extmark(buf, M.ns, start_row, start_col, {
        virt_lines = { { { text, "CintIntentLabel" } } },
        virt_lines_above = true,
        priority = 900,
      })
      rendered = rendered + 1
    end
  end
  return rendered
end

function M.render_all()
  local rendered = 0
  for buf, spans in pairs(state.rendered or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      rendered = rendered + M.render(buf, spans, state.intent_labels)
    end
  end
  return rendered
end

function M.toggle()
  state.intent_labels = not state.intent_labels
  M.render_all()
  return state.intent_labels
end

return M
