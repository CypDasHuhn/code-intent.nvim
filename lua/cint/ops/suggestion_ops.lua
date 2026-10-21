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

local function suggestion_gate_error()
  local protocol = tonumber(state.live_config_protocol) or 0
  if protocol < 3 then
    if protocol > 0 then
      return string.format(
        "live server protocol %d does not support suggestions; restart/rebuild the live server (protocol 3 required)",
        protocol
      )
    end
    return "live server did not report a protocol; restart/rebuild the live server (protocol 3 required)"
  end
  if type(state.live_suggestions) ~= "table" then
    return "missing suggestions descriptor from the live server; restart/rebuild the live server (protocol 3 required)"
  end
  if state.live_suggestions.enabled == false then
    return "AI suggestions are disabled (enabled=false in .cint/suggestions.yml); set suggestions.enabled: true to enable them (they are not auto-enabled)"
  end
  return nil
end

function M.suggestions_supported()
  return suggestion_gate_error() == nil
end

function M.suggestions_descriptor()
  return state.live_suggestions
end

function M.candidates(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local record = state.live_candidates[buf]
  if not record then
    return {}
  end
  if record.candidates and #record.candidates > 0 then
    return record.candidates
  end
  if record.groups and #record.groups > 0 then
    local candidates = {}
    for _, group in ipairs(record.groups) do
      for _, candidate in ipairs(group.candidates or {}) do
        candidates[#candidates + 1] = candidate
      end
    end
    return candidates
  end
  return record.candidates or {}
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
  local by_span = {}
  for _, candidate in ipairs(record.candidates or {}) do
    local key = table.concat({
      tostring(candidate.path or ""),
      tostring(candidate.contentHash or ""),
      tostring(candidate.startLine or 0),
      tostring(candidate.startCol or 0),
      tostring(candidate.endLine or 0),
      tostring(candidate.endCol or 0),
    }, ":")
    local group = by_span[key]
    if not group then
      group = {
        anchorId = candidate.candidateId,
        path = candidate.path,
        contentHash = candidate.contentHash,
        startLine = candidate.startLine,
        startCol = candidate.startCol,
        endLine = candidate.endLine,
        endCol = candidate.endCol,
        candidates = {},
      }
      by_span[key] = group
      groups[#groups + 1] = group
    end
    group.candidates[#group.candidates + 1] = candidate
  end
  return groups
end

function M.review_active(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return state.review_buffers[buf] == true
end

function M.render(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return candidate_render.render(buf, M.candidates(buf), M.review_active(buf))
end

function M.suggest(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not config.language_for(buf) then
    return false, "no language for this buffer"
  end
  local gate_error = suggestion_gate_error()
  if gate_error then
    return false, gate_error
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

function M.review_toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if M.review_active(buf) then
    state.review_buffers[buf] = nil
    local rendered = M.render(buf)
    notify(string.format("review mode off; %d unsure candidate(s)", rendered))
    return false
  end
  state.review_buffers[buf] = true
  local rendered = M.render(buf)
  if rendered == 0 then
    notify("review mode on; no unsure candidates")
  else
    notify(string.format("review mode on; %d unsure candidate(s)", rendered))
  end
  return true
end

M.review = M.review_toggle

local function cursor_position(buf)
  local win
  if buf == vim.api.nvim_get_current_buf() then
    win = vim.api.nvim_get_current_win()
  else
    win = vim.fn.win_findbuf(buf)[1]
  end
  if not win then
    return nil
  end
  local position = vim.api.nvim_win_get_cursor(win)
  return position[1] - 1, position[2]
end

local function candidate_covers(candidate, row, col)
  local start_row = tonumber(candidate.startLine) or 0
  local end_row = tonumber(candidate.endLine) or start_row
  if row < start_row or row > end_row then
    return false
  end
  local start_col = tonumber(candidate.startCol) or 0
  local end_col = tonumber(candidate.endCol) or start_col
  if row == start_row and col < start_col then
    return false
  end
  if row == end_row and col > end_col then
    return false
  end
  return true
end

local function matches_under_cursor(buf)
  local row, col = cursor_position(buf)
  if row == nil then
    return {}
  end
  local matches = {}
  for _, group in ipairs(M.groups(buf)) do
    for _, candidate in ipairs(group.candidates or {}) do
      if candidate_covers(candidate, row, col) then
        matches[#matches + 1] = { group = group, candidate = candidate }
      end
    end
  end
  return matches
end

local function is_better(candidate, current)
  return current == nil
    or (tonumber(candidate.confidence) or 0) > (tonumber(current.confidence) or 0)
end

local function best_match(matches)
  local best = matches[1]
  for index = 2, #matches do
    if is_better(matches[index].candidate, best.candidate) then
      best = matches[index]
    end
  end
  return best
end

local function candidate_intents(candidate)
  local intents = {}
  for _, intent in ipairs(candidate.intents or {}) do
    intents[#intents + 1] = tostring(intent)
  end
  return #intents > 0 and table.concat(intents, ",") or "candidate"
end

local function review_arguments(first, second)
  local buf
  local intent
  if type(first) == "number" then
    buf = first
    intent = second
  elseif type(first) == "string" then
    intent = first
    buf = second
  else
    buf = second
  end
  if type(intent) == "string" then
    intent = vim.trim(intent)
    if intent == "" then
      intent = nil
    end
  else
    intent = nil
  end
  return buf or vim.api.nvim_get_current_buf(), intent
end

local function unique_matches(matches)
  local seen, result = {}, {}
  for _, match in ipairs(matches) do
    local id = match.candidate.candidateId
    if not id or not seen[id] then
      if id then
        seen[id] = true
      end
      result[#result + 1] = match
    end
  end
  return result
end

local function match_label(match)
  local candidate = match.candidate
  local parts = {
    candidate_intents(candidate),
    string.format("%.2f", tonumber(candidate.confidence) or 0),
    tostring(candidate.source or "candidate"),
  }
  if candidate.reason and candidate.reason ~= "" then
    parts[#parts + 1] = tostring(candidate.reason)
  end
  local rationale = candidate.rationale and vim.trim(tostring(candidate.rationale)) or ""
  if rationale ~= "" then
    if #rationale > 64 then
      rationale = rationale:sub(1, 61) .. "..."
    end
    parts[#parts + 1] = rationale
  end
  return table.concat(parts, " · ")
end

local function accept_match(match, buf)
  local candidate = match.candidate
  local candidate_id = candidate.candidateId
  if not candidate_id then
    local message = "candidate has no id; wait for the next publish"
    notify(message, vim.log.levels.WARN)
    return false, message
  end
  local ok, err = M.decide(candidate_id, "confirm", buf)
  if not ok then
    notify(err, vim.log.levels.WARN)
    return false, err
  end
  notify(string.format("accepted %s", candidate_intents(candidate)))
  return true
end

function M.review_accept(first, second)
  local buf, intent = review_arguments(first, second)
  local matches = unique_matches(matches_under_cursor(buf))
  if #matches == 0 then
    local message = "no candidate under the cursor"
    notify(message, vim.log.levels.WARN)
    return false, message
  end
  if intent then
    local wanted = intent:upper()
    local filtered = {}
    for _, match in ipairs(matches) do
      for _, value in ipairs(match.candidate.intents or {}) do
        if tostring(value):upper() == wanted then
          filtered[#filtered + 1] = match
          break
        end
      end
    end
    if #filtered == 0 then
      local message = string.format("no candidate with intent %s under the cursor", intent)
      notify(message, vim.log.levels.WARN)
      return false, message
    end
    matches = filtered
  end

  if #matches == 1 then
    return accept_match(matches[1], buf)
  end

  table.sort(matches, function(left, right)
    local left_confidence = tonumber(left.candidate.confidence) or 0
    local right_confidence = tonumber(right.candidate.confidence) or 0
    if left_confidence == right_confidence then
      return candidate_intents(left.candidate) < candidate_intents(right.candidate)
    end
    return left_confidence > right_confidence
  end)
  local labels = {}
  for index, match in ipairs(matches) do
    labels[index] = match_label(match)
  end
  vim.ui.select(labels, { prompt = "Accept candidate" }, function(_, index)
    if index then
      accept_match(matches[index], buf)
    end
  end)
  return true
end

function M.review_deny(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local matches = matches_under_cursor(buf)
  if #matches == 0 then
    local message = "no candidate under the cursor"
    notify(message, vim.log.levels.WARN)
    return false, message
  end
  local chosen = best_match(matches)
  local candidates = chosen.group.candidates or { chosen.candidate }
  local seen = {}
  local rejected = 0
  local last_error
  for _, candidate in ipairs(candidates) do
    local candidate_id = candidate.candidateId
    if candidate_id and not seen[candidate_id] then
      seen[candidate_id] = true
      local ok, err = M.decide(candidate_id, "reject", buf)
      if ok then
        rejected = rejected + 1
      else
        last_error = err
      end
    end
  end
  if rejected == 0 then
    local message = last_error or "candidate has no id; wait for the next publish"
    notify(message, vim.log.levels.WARN)
    return false, message
  end
  notify(string.format("rejected %d alternative(s)", rejected))
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
