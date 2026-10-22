local state = require("cint.core.state")

local M = {}

local function stored_annotations(buf)
  local tags = state.live_tags[buf]
  if tags then
    return tags.annotations or {}
  end
  return state.rendered[buf] or {}
end

local function annotation_covers(annotation, line)
  local start_line = annotation.startLine
  local end_line = annotation.endLine
  if line < start_line or line > end_line then
    return false
  end
  if start_line == end_line then
    return annotation.endCol >= annotation.startCol
  end
  if line == end_line then
    return annotation.endCol > 0
  end
  return true
end

local function annotation_covers_position(annotation, line, col)
  local start_line = annotation.startLine
  local start_col = annotation.startCol or 0
  local end_line = annotation.endLine
  local end_col = annotation.endCol or 0
  if line < start_line or line > end_line then
    return false
  end
  if start_line == end_line and start_col == end_col then
    return line == start_line and col == start_col
  end
  if line == start_line and col < start_col then
    return false
  end
  if line == end_line and col >= end_col then
    return false
  end
  return true
end

local function cursor_for(buf)
  local win
  if buf == vim.api.nvim_get_current_buf() then
    win = vim.api.nvim_get_current_win()
  else
    win = vim.fn.win_findbuf(buf)[1]
  end
  if not win then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  return { cursor[1] - 1, cursor[2] }
end

local function cursor_line_for(buf)
  local cursor = cursor_for(buf)
  return cursor and cursor[1] or nil
end

function M.annotations_at_position(buf, line, col)
  buf = buf or vim.api.nvim_get_current_buf()
  if line == nil then
    local cursor = cursor_for(buf)
    if not cursor then
      return {}
    end
    line, col = cursor[1], cursor[2]
  end
  col = col or 0
  local result = {}
  for _, annotation in ipairs(stored_annotations(buf)) do
    if annotation_covers_position(annotation, line, col) then
      result[#result + 1] = annotation
    end
  end
  return result
end

function M.intents_at_position(buf, line, col)
  local result = {}
  local seen = {}
  for _, annotation in ipairs(M.annotations_at_position(buf, line, col)) do
    for _, intent in ipairs(annotation.intents or {}) do
      if not seen[intent] then
        seen[intent] = true
        result[#result + 1] = intent
      end
    end
  end
  return result
end

function M.provenance_at_position(buf, line, col)
  local result = {}
  for _, annotation in ipairs(M.annotations_at_position(buf, line, col)) do
    for _, contribution in ipairs(annotation.provenance or {}) do
      result[#result + 1] = contribution
    end
  end
  return result
end

function M.annotations_at(buf, line)
  buf = buf or vim.api.nvim_get_current_buf()
  if line == nil then
    line = cursor_line_for(buf)
    if line == nil then
      return {}
    end
  end
  local result = {}
  for _, annotation in ipairs(stored_annotations(buf)) do
    if annotation_covers(annotation, line) then
      result[#result + 1] = annotation
    end
  end
  return result
end

function M.provenance_at(buf, line)
  local result = {}
  for _, annotation in ipairs(M.annotations_at(buf, line)) do
    for _, contribution in ipairs(annotation.provenance or {}) do
      result[#result + 1] = contribution
    end
  end
  return result
end

return M
