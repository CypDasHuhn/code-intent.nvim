local config = require("cint.core.config")
local live = require("cint.transport.live")
local live_ops = require("cint.ops.live_ops")
local candidate_render = require("cint.render.candidates")
local state = require("cint.core.state")

local M = {}

local function notify(message, level)
  vim.notify("cint: " .. tostring(message), level or vim.log.levels.INFO)
end

local function buffer_uri(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return nil
  end
  return path
end

function M.suggestions_supported()
  return (tonumber(state.live_config_protocol) or 0) >= 3
    and type(state.live_suggestions) == "table"
    and state.live_suggestions.enabled ~= false
end

function M.suggestions_descriptor()
  return state.live_suggestions
end

function M.candidates(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local record = state.live_candidates[buf]
  return record and record.candidates or {}
end

function M.candidate_count(buf)
  return #M.candidates(buf)
end

function M.groups(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local record = state.live_candidates[buf]
  if not record then
    return {}
  end
  if record.groups and #record.groups > 0 then
    return record.groups
  end
  local groups = {}
  for _, candidate in ipairs(record.candidates or {}) do
    groups[#groups + 1] = {
      anchorId = candidate.candidateId,
      candidates = { candidate },
    }
  end
  return groups
end

function M.render(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return candidate_render.render(buf, M.candidates(buf))
end

function M.suggest(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not config.language_for(buf) then
    return false, "no language for this buffer"
  end
  if not M.suggestions_supported() then
    return false, "live server does not support suggestions"
  end
  local uri = buffer_uri(buf)
  if not uri then
    return false, "the buffer has no file path"
  end
  if not live_ops.live_request_analysis(buf) then
    return false, "live server is not connected"
  end
  local version = vim.b[buf].changedtick
  local request_id = tostring(vim.uv.hrtime())
  state.live_suggest_request[buf] = request_id
  local sent = live.request("cint/suggest", {
    uri = uri,
    version = version,
    requestId = request_id,
  }, function(request_err, result)
    if request_err then
      notify(request_err, vim.log.levels.WARN)
      return
    end
    if type(result) ~= "table" then
      return
    end
    if result.stale then
      notify("suggestion request was stale", vim.log.levels.INFO)
      return
    end
    if result.cancelled then
      return
    end
    notify(string.format("%d unsure candidate(s)", tonumber(result.count) or 0))
  end)
  if not sent then
    return false, "live server is not connected"
  end
  return true
end

function M.cancel(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local uri = buffer_uri(buf)
  if not uri or not live.is_connected() then
    return false
  end
  return live.request("cint/suggest/cancel", {
    uri = uri,
    requestId = state.live_suggest_request[buf],
  })
end

function M.decide(candidate_id, decision, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local uri = buffer_uri(buf)
  if not uri then
    return false, "the buffer has no file path"
  end
  if not live.is_connected() then
    return false, "live server is not connected"
  end
  local sent = live.request("cint/candidates/decide", {
    uri = uri,
    version = vim.b[buf].changedtick,
    candidateId = candidate_id,
    decision = decision,
  }, function(request_err, result)
    if request_err then
      notify(request_err, vim.log.levels.WARN)
      return
    end
    if type(result) == "table" and result.stale then
      notify("candidate is stale", vim.log.levels.INFO)
    end
  end)
  if not sent then
    return false, "live server is not connected"
  end
  return true
end

local function candidate_label(candidate)
  local intents = table.concat(candidate.intents or {}, ",")
  local rationale = candidate.rationale and (" · " .. tostring(candidate.rationale)) or ""
  return string.format(
    "%s · %s · %s · %.2f · %s:%d%s",
    tostring(candidate.reason),
    intents,
    tostring(candidate.source),
    tonumber(candidate.confidence) or 0,
    tostring(candidate.path or ""),
    (tonumber(candidate.startLine) or 0) + 1,
    rationale
  )
end

local function group_label(group)
  local candidates = group.candidates or {}
  local first = candidates[1] or {}
  local intents = {}
  for _, candidate in ipairs(candidates) do
    intents[#intents + 1] = table.concat(candidate.intents or {}, ",")
  end
  return string.format(
    "%s:%d · %s · %d alternative(s)",
    tostring(first.path or ""),
    (tonumber(first.startLine) or 0) + 1,
    table.concat(intents, " / "),
    #candidates
  )
end

function M.review(buf, select)
  buf = buf or vim.api.nvim_get_current_buf()
  local groups = M.groups(buf)
  if #groups == 0 then
    notify("no unsure candidates", vim.log.levels.INFO)
    return false
  end
  local picker = select or vim.ui.select
  local labels = {}
  for index, group in ipairs(groups) do
    labels[index] = group_label(group)
  end
  picker(labels, { prompt = "Cint review candidate" }, function(_, group_index)
    if not group_index then
      return
    end
    local group = groups[group_index]
    local candidates = group.candidates or {}
    local function choose_action(candidate)
      picker({ "Confirm", "Reject", "Skip" }, { prompt = "Cint candidate action" }, function(action)
        if not action then
          return
        end
        M.decide(candidate.candidateId, action:lower(), buf)
      end)
    end
    if #candidates <= 1 then
      choose_action(candidates[1])
      return
    end
    local alternatives = {}
    for index, candidate in ipairs(candidates) do
      alternatives[index] = candidate_label(candidate)
    end
    picker(alternatives, { prompt = "Cint choose alternative" }, function(_, index)
      if index then
        choose_action(candidates[index])
      end
    end)
  end)
  return true
end

function M.status(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return M.candidate_count(buf)
end

function M.status_text(buf)
  return string.format("CodeIntent: %d unsure", M.status(buf))
end

return M
