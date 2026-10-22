local palette = require("cint.core.colors")

local M = {}

M.ns = vim.api.nvim_create_namespace("cint-stripes")
M.max_segments = 40
local UNTAGGED = "UNTAGGED"

local function real_intents(span)
  local result = {}
  for _, intent in ipairs(span.intents or {}) do
    if intent ~= UNTAGGED then
      result[#result + 1] = intent
    end
  end
  if #result == 0 then
    return span.intents or {}
  end
  return result
end

local function contains(span, row, col)
  local start_row = tonumber(span.startLine) or 0
  local end_row = tonumber(span.endLine) or start_row
  if row < start_row or row > end_row then
    return false
  end
  local start_col = tonumber(span.startCol) or 0
  local end_col = tonumber(span.endCol) or start_col
  if row == start_row and col < start_col then
    return false
  end
  if row == end_row and col > end_col then
    return false
  end
  return true
end

local function active_mixed_span(spans, row, col)
  local best
  for _, span in ipairs(spans or {}) do
    if #real_intents(span) >= 2 and contains(span, row, col) then
      if not best or (span.endByte - span.startByte) < (best.endByte - best.startByte) then
        best = span
      end
    end
  end
  return best
end

local function group_for(config, intent)
  local spec = vim.tbl_extend("force", palette.spec(intent), (config.tags or {})[intent] or {})
  local group = "CintStripe_" .. palette.sanitize(intent)
  vim.api.nvim_set_hl(0, group, { bg = spec.bg or spec.color or palette.fallback.bg })
  return group
end

local function words(line, start_col, end_col)
  local text = line:sub(start_col + 1, end_col)
  local result = {}
  local init = 1
  while init <= #text do
    local first, last = text:find("%S+", init)
    if not first then
      break
    end
    result[#result + 1] = { start_col + first - 1, start_col + last }
    init = last + 1
  end
  if #result == 0 and end_col > start_col then
    result[1] = { start_col, end_col }
  end
  if #result > M.max_segments then
    local grouped = {}
    local per = math.ceil(#result / M.max_segments)
    for index = 1, #result, per do
      local last = math.min(index + per - 1, #result)
      grouped[#grouped + 1] = { result[index][1], result[last][2] }
    end
    result = grouped
  end
  return result
end

function M.clear(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

function M.render(buf, spans, config, enabled, row, col)
  M.clear(buf)
  if not enabled or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  local span = active_mixed_span(spans, row, col)
  if not span then
    return 0
  end
  local intents = real_intents(span)
  local groups = {}
  for _, intent in ipairs(intents) do
    groups[#groups + 1] = group_for(config, intent)
  end
  local rendered = 0
  local line_count = vim.api.nvim_buf_line_count(buf)
  local start_row = math.max(0, math.min(tonumber(span.startLine) or 0, line_count - 1))
  local end_row = math.max(start_row, math.min(tonumber(span.endLine) or start_row, line_count - 1))
  local choice = 1
  for line_index = start_row, end_row do
    local line = vim.api.nvim_buf_get_lines(buf, line_index, line_index + 1, false)[1] or ""
    local start_col = line_index == start_row and math.max(0, tonumber(span.startCol) or 0) or 0
    local end_col = line_index == end_row and math.min(#line, tonumber(span.endCol) or #line) or #line
    for _, segment in ipairs(words(line, start_col, end_col)) do
      vim.api.nvim_buf_set_extmark(buf, M.ns, line_index, segment[1], {
        end_row = line_index,
        end_col = segment[2],
        hl_group = groups[choice],
        priority = 1001,
      })
      choice = choice % #groups + 1
      rendered = rendered + 1
    end
  end
  return rendered
end

return M
