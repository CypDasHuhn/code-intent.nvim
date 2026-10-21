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
  live_config_packs = {},
  live_config_overlay = {},
  live_config_protocol = nil,
  live_candidates = {},
  live_suggestions = nil,
  live_suggest_request = {},
  review_buffers = {},
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
  M.live_config_packs = {}
  M.live_config_overlay = {}
  M.live_config_protocol = nil
  M.live_candidates = {}
  M.live_suggestions = nil
  M.live_suggest_request = {}
  M.review_buffers = {}
end

return M
