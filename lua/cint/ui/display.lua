local display = require("cint.ops.display_ops")

local M = {}

M.ns = vim.api.nvim_create_namespace("cint-display")

local active = nil

local function define_highlights()
  vim.api.nvim_set_hl(0, "CintUiIntent", { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "CintUiMeaningSHOW", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "CintUiMeaningHIGHLIGHT", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "CintUiMeaningIGNORE", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "CintUiMeaningCONCEAL", { link = "NonText", default = true })
  vim.api.nvim_set_hl(0, "CintUiCursorLine", { link = "PmenuSel", default = true })
end

local function meaning_group(meaning)
  return "CintUiMeaning" .. tostring(meaning or "SHOW"):gsub("[^%w]", "_"):upper()
end

local function close()
  local current = active
  active = nil
  if not current then
    return false
  end
  if current.win and vim.api.nvim_win_is_valid(current.win) then
    pcall(vim.api.nvim_win_close, current.win, true)
  end
  if current.buf and vim.api.nvim_buf_is_valid(current.buf) then
    pcall(vim.api.nvim_buf_delete, current.buf, { force = true })
  end
  return true
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
end

local function layout(rows)
  local intent_width = 0
  local meaning_width = 0
  for _, row in ipairs(rows) do
    intent_width = math.max(intent_width, #row.intent)
    meaning_width = math.max(meaning_width, #row.meaning)
  end
  local offset = 1 + intent_width + 2
  local width = math.max(24, offset + meaning_width + 1)
  local lines = {}
  for index, row in ipairs(rows) do
    lines[index] = " " .. string.format("%-" .. intent_width .. "s", row.intent) .. "  " .. row.meaning .. " "
  end
  return lines, offset, width
end

local function refresh()
  if not active then
    return false
  end
  if not vim.api.nvim_buf_is_valid(active.target) then
    close()
    return false
  end
  if not active.win or not vim.api.nvim_win_is_valid(active.win) then
    close()
    return false
  end
  local current_row = vim.api.nvim_win_get_cursor(active.win)[1]
  active.rows = display.display_map(active.target)
  local lines, meaning_col, width = layout(active.rows)
  set_lines(active.buf, lines)
  vim.api.nvim_buf_clear_namespace(active.buf, M.ns, 0, -1)
  for index, row in ipairs(active.rows) do
    local line = index - 1
    vim.api.nvim_buf_set_extmark(active.buf, M.ns, line, 1, {
      end_col = 1 + #row.intent,
      hl_group = "CintUiIntent",
    })
    vim.api.nvim_buf_set_extmark(active.buf, M.ns, line, meaning_col, {
      end_col = meaning_col + #row.meaning,
      hl_group = meaning_group(row.meaning),
    })
  end
  local config = vim.api.nvim_win_get_config(active.win)
  if config.width ~= width then
    vim.api.nvim_win_set_config(active.win, { width = width })
  end
  active.meaning_col = meaning_col
  local row = math.max(1, math.min(current_row, #active.rows))
  vim.api.nvim_win_set_cursor(active.win, { row, 0 })
  return true
end

local function current_row()
  if not active or not active.win or not vim.api.nvim_win_is_valid(active.win) then
    return nil
  end
  local index = vim.api.nvim_win_get_cursor(active.win)[1]
  return active.rows[index]
end

local function cycle()
  local row = current_row()
  if not row then
    return false
  end
  local ok, err = display.cycle_meaning(row.intent, { buf = active.target, silent = true })
  if not ok then
    vim.notify("cint: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return refresh()
end

local function reset()
  local row = current_row()
  if not row then
    return false
  end
  local ok, err = display.reset_meaning(row.intent, { buf = active.target, silent = true })
  if not ok then
    vim.notify("cint: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return refresh()
end

function M.open(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if active and active.buf == buf then
    return true
  end
  close()
  define_highlights()

  local rows = display.display_map(buf)
  local lines, _, width = layout(rows)
  local height = math.max(1, math.min(#rows, 20))
  local ui_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[ui_buf].buftype = "nofile"
  vim.bo[ui_buf].bufhidden = "wipe"
  vim.bo[ui_buf].swapfile = false
  vim.bo[ui_buf].filetype = "cint-ui"
  set_lines(ui_buf, lines)

  local win = vim.api.nvim_open_win(ui_buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " CodeIntent ",
    title_pos = "center",
    zindex = 50,
  })

  active = {
    buf = ui_buf,
    win = win,
    target = buf,
    rows = rows,
  }

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:CintUiCursorLine"

  vim.keymap.set("n", "<Leader>", cycle, {
    buffer = ui_buf,
    nowait = true,
    silent = true,
    desc = "Cint: cycle intent meaning",
  })
  vim.keymap.set("n", "<BS>", reset, {
    buffer = ui_buf,
    nowait = true,
    silent = true,
    desc = "Cint: reset intent meaning",
  })
  vim.keymap.set("n", "q", close, {
    buffer = ui_buf,
    nowait = true,
    silent = true,
    desc = "Cint: close display",
  })
  vim.keymap.set("n", "<Esc>", close, {
    buffer = ui_buf,
    nowait = true,
    silent = true,
    desc = "Cint: close display",
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = ui_buf,
    once = true,
    callback = function()
      if active and active.buf == ui_buf then
        active = nil
      end
    end,
  })

  refresh()
  return true
end

function M.close()
  return close()
end

function M.active()
  return active ~= nil and active.win ~= nil and vim.api.nvim_win_is_valid(active.win)
end

return M
