local config = require("cint.config")
local render = require("cint.render")
local state = require("cint.state")

local M = {}

function M.render_spans(buf, spans, cfg)
  local plan = render.plan(buf, spans, cfg)
  local active = nil
  if buf == vim.api.nvim_get_current_buf() and cfg.expand_on_cursor then
    active = render.active_span(plan, vim.api.nvim_win_get_cursor(0)[1] - 1)
  end
  state.active[buf] = active and active.index or nil
  render.render_buffer(buf, spans, cfg, {
    plan = plan,
    reveal = active and function(s)
      return render.contains(active.span, s)
    end or nil,
  })
end

function M.reveal_block(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if buf ~= vim.api.nvim_get_current_buf() then
    return
  end
  local spans = state.rendered[buf]
  if not spans then
    return
  end
  local cfg = state.configs[buf] or config.config_for(buf)
  if not cfg.expand_on_cursor then
    return
  end
  local plan = render.plan(buf, spans, cfg)
  local active = render.active_span(plan, vim.api.nvim_win_get_cursor(0)[1] - 1)
  local index = active and active.index or nil
  if index == state.active[buf] then
    return
  end
  state.active[buf] = index
  render.update_reveal(buf, plan, active)
end

function M.discard(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  state.rendered[buf] = nil
  state.active[buf] = nil
  state.configs[buf] = nil
end

function M.clear()
  local buf = vim.api.nvim_get_current_buf()
  render.clear(buf)
  M.discard(buf)
end

return M
