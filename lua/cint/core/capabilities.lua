local state = require("cint.core.state")

local M = {}

local function descriptor()
  if type(state.live_suggestions) == "table" then
    return state.live_suggestions
  end
  return nil
end

function M.protocol()
  return tonumber(state.live_config_protocol) or 0
end

function M.suggestions()
  return descriptor()
end

function M.suggestion_enabled()
  local value = descriptor()
  return M.protocol() >= 3 and value ~= nil and value.enabled ~= false
end

function M.discovery()
  local value = descriptor()
  return M.protocol() >= 4 and value ~= nil and value.discovery == true
end

function M.restrictions()
  local value = descriptor()
  return M.protocol() >= 4 and value ~= nil and value.restrictions == true
end

function M.cache()
  local value = descriptor()
  return M.protocol() >= 4 and value ~= nil and value.cache == true
end

function M.operations()
  return M.discovery() or M.restrictions()
end

function M.ai_passive()
  return not M.discovery()
end

return M
