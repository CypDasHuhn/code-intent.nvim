local M = {
  rendered = {},
  active = {},
  configs = {},
  live_tags = {},
  live_docs = {},
  live_timers = {},
  live_ready = false,
  live_root = nil,
  live_failed = false,
}

function M.reset()
  for _, timer in pairs(M.live_timers) do
    pcall(function()
      timer:stop()
      timer:close()
    end)
  end
  M.rendered = {}
  M.active = {}
  M.configs = {}
  M.live_tags = {}
  M.live_docs = {}
  M.live_timers = {}
  M.live_ready = false
  M.live_root = nil
  M.live_failed = false
end

return M
