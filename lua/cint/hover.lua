local api = require("cint.core.api")
local config = require("cint.core.config")
local palette = require("cint.core.colors")

local M = {}

M.ns = vim.api.nvim_create_namespace("cint-hover")
M.max_width = 60
M.max_height = 12

local active = nil

local function close_events()
  return {
    "CursorMoved",
    "CursorMovedI",
    "BufLeave",
    "WinLeave",
    "TextChanged",
    "TextChangedI",
    "VimResized",
    "WinScrolled",
  }
end

local function tag_spec(cfg, intent)
  return vim.tbl_extend("force", palette.spec(intent) or {}, (cfg.tags or {})[intent] or {})
end

local function highlight_group(cfg, intent)
  local spec = tag_spec(cfg, intent)
  local group = "CintHover_" .. palette.sanitize(intent)
  local bg = spec.bg or spec.color
  local fg = spec.sign or palette.fallback.sign
  if bg then
    vim.api.nvim_set_hl(0, group, { bg = bg, fg = fg })
  else
    vim.api.nvim_set_hl(0, group, { fg = fg })
  end
  return group
end

local function content_width(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return math.max(1, math.min(width, M.max_width))
end

local function target_window(buf)
  if buf == vim.api.nvim_get_current_buf() then
    return vim.api.nvim_get_current_win(), true
  end
  local tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == tab then
      return win, false
    end
  end
  return nil, false
end

local function open_window(buf, lines, current, anchor)
  local opts = {
    width = content_width(lines),
    height = math.min(#lines, M.max_height),
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
  }
  if current then
    opts.relative = "cursor"
    opts.row = 1
    opts.col = 0
  else
    opts.relative = "editor"
    opts.row = anchor.row
    opts.col = anchor.col - 1
  end
  local win = vim.api.nvim_open_win(buf, false, opts)
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  return win
end

function M.close()
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

function M.active()
  return active ~= nil and vim.api.nvim_win_is_valid(active.win)
end

function M.hover(buf)
  M.close()
  buf = buf or vim.api.nvim_get_current_buf()
  local cfg = config.config_for(buf)
  if (cfg.hover or {}).enabled == false then
    return false
  end

  local target, current = target_window(buf)
  if not target then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(target)
  local line, col = cursor[1] - 1, cursor[2]
  local anchor = nil
  if not current then
    anchor = vim.fn.screenpos(target, cursor[1], cursor[2] + 1)
    if not anchor or anchor.row == 0 or anchor.col == 0 then
      return false
    end
  end

  local intents = api.intents_at_position(buf, line, col)
  if #intents == 0 then
    return false
  end

  local lines = {}
  local groups = {}
  for _, intent in ipairs(intents) do
    lines[#lines + 1] = intent
    groups[#groups + 1] = highlight_group(cfg, intent)
  end

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].bufhidden = "wipe"
  vim.bo[scratch].swapfile = false
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
  vim.bo[scratch].modifiable = false
  for index, text in ipairs(lines) do
    vim.api.nvim_buf_set_extmark(scratch, M.ns, index - 1, 0, {
      end_col = #text,
      hl_group = groups[index],
    })
  end

  local win = open_window(scratch, lines, current, anchor)
  active = { win = win, buf = scratch }
  return true
end

function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("cint_hover", { clear = true })
  vim.api.nvim_create_autocmd(close_events(), {
    group = group,
    callback = function()
      M.close()
    end,
    desc = "Cint: close intent hover",
  })

  vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
    group = group,
    callback = function()
      local cfg = config.config_for(vim.api.nvim_get_current_buf())
      local hover = cfg.hover or {}
      if hover.enabled ~= false and hover.on_cursor_hold ~= false then
        M.hover()
      end
    end,
    desc = "Cint: show intent hover",
  })
end

return M
