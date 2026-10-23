local config = require("cint.core.config")
local capabilities = require("cint.core.capabilities")
local live = require("cint.transport.live")
local live_ops = require("cint.ops.live_ops")
local candidate_render = require("cint.render.candidates")
local state = require("cint.core.state")

local M = {}

local function notify(message, level)
  vim.notify("cint: " .. tostring(message), level or vim.log.levels.INFO)
end

local function nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

local function buffer_uri(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return nil
  end
  return path
end

local function analysis_current(buf, uri)
  local doc = state.live_docs[buf]
  local tags = state.live_tags[buf]
  local version = vim.b[buf].changedtick
  return doc ~= nil
    and tags ~= nil
    and doc.path == uri
    and doc.version == version
    and tags.version == version
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

function M.proposal_groups(buf)
  if not capabilities.restrictions() then
    return {}
  end
  local groups = {}
  for _, group in ipairs(M.groups(buf)) do
    if candidate_render.is_proposal_group(group) then
      groups[#groups + 1] = group
    end
  end
  return groups
end

function M.proposal_group_count(buf)
  return #M.proposal_groups(buf)
end

function M.ai_candidate_count(buf)
  local count = candidate_render.ai_count(M.candidates(buf))
  for _, group in ipairs(M.proposal_groups(buf)) do
    for _, operation in ipairs(group.operations or {}) do
      if tostring(operation.kind or ""):upper() == "ADD" then
        count = count + 1
      end
    end
  end
  return count
end

function M.restriction_count(buf)
  return M.proposal_group_count(buf or vim.api.nvim_get_current_buf())
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
  local record = state.live_candidates[buf]
  return candidate_render.render(buf, M.candidates(buf), M.review_active(buf), {
    groups = record and record.groups or {},
    ai_passive = capabilities.ai_passive(),
    operations = capabilities.operations(),
  })
end

local function completion_message(result, buf)
  if not capabilities.discovery() then
    if not state.live_suggest_ai_seen[buf] then
      return "AI suggestions found no new candidates"
    end
    return nil
  end
  local additions = tonumber(result.additions) or 0
  local restrictions = tonumber(result.restrictions) or 0
  local reused = tonumber(result.reused) or 0
  local graded = tonumber(result.graded) or 0
  local total = tonumber(result.total) or 0
  if graded == 0 and reused > 0 and additions == 0 and restrictions == 0 then
    return string.format("AI: no changes since last pass (%d reused)", reused)
  end
  local parts = {
    string.format("graded %d/%d", graded, total),
    string.format("%d additions", additions),
  }
  if capabilities.restrictions() then
    parts[#parts + 1] = string.format("%d restrictions", restrictions)
  end
  if capabilities.cache() then
    parts[#parts + 1] = string.format("%d reused", reused)
  end
  if tonumber(result.toolCalls) and tonumber(result.toolCalls) > 0 then
    parts[#parts + 1] = string.format("%d tool calls", tonumber(result.toolCalls))
  end
  if result.budgetExhausted then
    parts[#parts + 1] = "budget exhausted"
  elseif result.incomplete then
    parts[#parts + 1] = "incomplete"
  end
  return "AI: " .. table.concat(parts, " · ")
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
  if not analysis_current(buf, uri) then
    if not live_ops.live_request_analysis(buf) then
      return false, "live server is not connected"
    end
  elseif not live.is_connected() then
    return false, "live server is not connected"
  end
  local version = vim.b[buf].changedtick
  local request_id = tostring(vim.uv.hrtime())
  state.live_suggest_request[buf] = request_id
  state.live_suggest_ai_seen[buf] = false
  if capabilities.discovery() then
    state.live_suggest_progress[buf] = {
      version = version,
      graded = 0,
      reused = 0,
      total = 0,
      activity = "starting",
    }
  end
  notify("requesting AI suggestions")
  local sent = live.request("cint/suggest", {
    uri = uri,
    version = version,
    requestId = request_id,
  }, function(request_err, result)
    if state.live_suggest_request[buf] ~= request_id then
      return
    end
    state.live_suggest_progress[buf] = nil
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
      if capabilities.discovery() then
        if result.timeout then
          notify("AI suggestion pass timed out", vim.log.levels.INFO)
        else
          notify("AI suggestion pass cancelled", vim.log.levels.INFO)
        end
      end
      return
    end
    if result.busy then
      notify("AI suggestion pass already running", vim.log.levels.INFO)
      return
    end
    if result.disabled then
      notify("AI suggestions are disabled", vim.log.levels.INFO)
      return
    end
    if result.accepted ~= true then
      notify("AI suggestion pass was not accepted", vim.log.levels.INFO)
      return
    end
    state.live_suggest_results[buf] = result
    local message = completion_message(result, buf)
    if message then
      notify(message)
    end
  end)
  if not sent then
    state.live_suggest_progress[buf] = nil
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
  local sent = live.request("cint/suggest/cancel", {
    uri = uri,
    requestId = state.live_suggest_request[buf],
  })
  if sent and capabilities.discovery() then
    notify("cancelling AI suggestions", vim.log.levels.INFO)
  end
  return sent
end

function M.decide(candidate_id, decision, buf, proposal, callback)
  buf = buf or vim.api.nvim_get_current_buf()
  local uri = buffer_uri(buf)
  if not uri then
    return false, "the buffer has no file path"
  end
  if not live.is_connected() then
    return false, "live server is not connected"
  end
  local params = {
    uri = uri,
    version = vim.b[buf].changedtick,
    candidateId = candidate_id,
    decision = decision,
  }
  if proposal then
    params.proposalId = candidate_id
  end
  local target = proposal and "proposal" or "candidate"
  local key = table.concat({ tostring(buf), tostring(params.version), target, tostring(candidate_id) }, ":")
  if state.live_decisions[key] then
    return false, "decision already in progress"
  end
  state.live_decisions[key] = true
  local function finish(error, result)
    state.live_decisions[key] = nil
    if callback then
      callback(error, result)
    end
  end
  local sent = live.request("cint/candidates/decide", params, function(request_err, result)
    if request_err then
      notify(request_err, vim.log.levels.WARN)
      finish(request_err, nil)
      return
    end
    if type(result) ~= "table" then
      local message = "decision was not accepted"
      notify(message, vim.log.levels.WARN)
      finish(message, result)
      return
    end
    if result.accepted == true then
      finish(nil, result)
      return
    end
    local message
    if result.missing then
      message = target .. " is no longer available"
    elseif result.disabled then
      message = "AI restrictions are disabled"
    elseif result.stale then
      message = target .. " is stale"
    else
      message = "decision was not accepted"
    end
    notify(message, result.stale and vim.log.levels.INFO or vim.log.levels.WARN)
    finish(message, result)
  end)
  if not sent then
    state.live_decisions[key] = nil
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

local REVIEW_CONTEXT_KEY = "cint_review"
local REVIEW_TITLE = "cint review"

local function quickfix_entry(buf)
  if vim.bo[buf].buftype ~= "quickfix" then
    return nil
  end
  local location = vim.fn.getloclist(0, { winid = 0 })
  if (tonumber(location.winid) or 0) ~= 0 then
    return nil
  end
  local meta = vim.fn.getqflist({ context = 0, title = 0, winid = 0 })
  local context = meta.context
  if meta.title ~= REVIEW_TITLE or type(context) ~= "table" or context[REVIEW_CONTEXT_KEY] ~= true then
    return nil
  end
  local win = vim.fn.win_findbuf(buf)[1]
  if not win or (tonumber(meta.winid) or 0) ~= win then
    return nil
  end
  local items = vim.fn.getqflist()
  if #items == 0 then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local index = math.max(1, math.min(row, #items))
  local item = items[index]
  if not item or (tonumber(item.bufnr) or 0) == 0 then
    return nil
  end
  return item, items, index
end

local function review_target(buf)
  local item = quickfix_entry(buf)
  if item then
    return item.bufnr, (tonumber(item.lnum) or 1) - 1, math.max(0, (tonumber(item.col) or 1) - 1)
  end
  local row, col = cursor_position(buf)
  return buf, row, col
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

local function group_covers(group, row, col)
  local start_row = tonumber(group.startLine) or 0
  local end_row = tonumber(group.endLine) or start_row
  if row < start_row or row > end_row then
    return false
  end
  local start_col = tonumber(group.startCol) or 0
  local end_col = tonumber(group.endCol) or start_col
  if row == start_row and col < start_col then
    return false
  end
  if row == end_row and col > end_col then
    return false
  end
  return true
end

local function operation_covers(operation, row, col)
  return group_covers({
    startLine = operation.startLine,
    startCol = operation.startCol,
    endLine = operation.endLine,
    endCol = operation.endCol,
  }, row, col)
end

local function proposal_covers(group, row, col)
  if group_covers(group, row, col) then
    return true
  end
  for _, operation in ipairs(group.operations or {}) do
    if operation_covers(operation, row, col) then
      return true
    end
  end
  return false
end

local function group_key(group)
  return tostring(group.proposalId or group.groupId or group.anchorId or "")
    .. ":"
    .. tostring(group.path or "")
    .. ":"
    .. tostring(group.startLine or 0)
    .. ":"
    .. tostring(group.startCol or 0)
end

local function matches_under_cursor(buf, row, col)
  if row == nil then
    return {}
  end
  local matches = {}
  for _, group in ipairs(M.groups(buf)) do
    if candidate_render.is_proposal_group(group) and proposal_covers(group, row, col) then
      matches[#matches + 1] = { group = group, proposal = true }
    end
    for _, candidate in ipairs(group.candidates or {}) do
      if candidate_covers(candidate, row, col) then
        matches[#matches + 1] = { group = group, candidate = candidate }
      end
    end
  end
  return matches
end

local function match_confidence(match)
  if match.proposal then
    return candidate_render.group_confidence(match.group)
  end
  return tonumber(match.candidate.confidence) or 0
end

local function unique_groups(matches)
  local seen, result = {}, {}
  for _, match in ipairs(matches) do
    local key = group_key(match.group)
    local entry = seen[key]
    if not entry then
      entry = { group = match.group, matches = {}, proposal = false }
      seen[key] = entry
      result[#result + 1] = entry
    end
    entry.matches[#entry.matches + 1] = match
    if match.proposal then
      entry.proposal = true
    end
  end
  return result
end

local function candidate_intents(candidate)
  local intents = {}
  for _, intent in ipairs(candidate.intents or {}) do
    intents[#intents + 1] = tostring(intent)
  end
  return #intents > 0 and table.concat(intents, ",") or "candidate"
end

local function group_intents(group)
  local intents = {}
  for _, candidate in ipairs(group.candidates or {}) do
    for _, intent in ipairs(candidate.intents or {}) do
      intents[#intents + 1] = tostring(intent)
    end
  end
  for _, operation in ipairs(group.operations or {}) do
    if operation.intent then
      intents[#intents + 1] = tostring(operation.intent)
    end
  end
  return intents
end

local function group_has_intent(group, wanted)
  for _, intent in ipairs(group_intents(group)) do
    if intent:upper() == wanted then
      return true
    end
  end
  return false
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
    local id = match.proposal and group_key(match.group) or match.candidate and match.candidate.candidateId
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
  if match.proposal then
    return candidate_render.group_label(match.group)
  end
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

local function proposal_id(group)
  return group.proposalId or group.groupId
end

local function proposal_message(group)
  local removed, added = {}, {}
  for _, operation in ipairs(group.operations or {}) do
    local intent = tostring(operation.intent or "?")
    if tostring(operation.kind or ""):upper() == "REMOVE" then
      removed[#removed + 1] = intent
    else
      added[#added + 1] = intent
    end
  end
  local parts = {}
  if #removed > 0 then
    parts[#parts + 1] = "removed " .. table.concat(removed, ",")
  end
  if #added > 0 then
    parts[#parts + 1] = "added " .. table.concat(added, ",")
  end
  if #parts == 0 then
    parts[#parts + 1] = "applied proposal"
  end
  return table.concat(parts, ", ") .. " (AI)"
end

local function accept_proposal(group, buf)
  local id = proposal_id(group)
  if not id then
    local message = "proposal has no id; wait for the next publish"
    notify(message, vim.log.levels.WARN)
    return false, message
  end
  local sent, err = M.decide(id, "confirm", buf, true, function(_, result)
    if type(result) == "table" and result.accepted == true then
      notify(proposal_message(group))
    end
  end)
  if not sent then
    notify(err, vim.log.levels.WARN)
    return false, err
  end
  return true
end

local function accept_match(match, buf)
  if match.proposal then
    return accept_proposal(match.group, buf)
  end
  local candidate = match.candidate
  local candidate_id = candidate.candidateId
  if not candidate_id then
    local message = "candidate has no id; wait for the next publish"
    notify(message, vim.log.levels.WARN)
    return false, message
  end
  local sent, err = M.decide(candidate_id, "confirm", buf, false, function(_, result)
    if type(result) == "table" and result.accepted == true then
      notify(string.format("accepted %s", candidate_intents(candidate)))
    end
  end)
  if not sent then
    notify(err, vim.log.levels.WARN)
    return false, err
  end
  return true
end

local function sort_matches(matches)
  table.sort(matches, function(left, right)
    local left_confidence = match_confidence(left)
    local right_confidence = match_confidence(right)
    if left_confidence == right_confidence then
      return match_label(left) < match_label(right)
    end
    return left_confidence > right_confidence
  end)
  return matches
end

local function pick_group(matches, prompt, callback)
  sort_matches(matches)
  local ordered = unique_groups(matches)
  local labels = {}
  for index, entry in ipairs(ordered) do
    labels[index] = candidate_render.group_label(entry.group)
  end
  vim.ui.select(labels, { prompt = prompt }, function(_, index)
    if index then
      callback(ordered[index])
    end
  end)
  return true
end

local function pick_alternatives(matches, buf)
  sort_matches(matches)
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

local function accept_group(entry, buf)
  if entry.proposal then
    local proposal = nil
    for _, match in ipairs(entry.matches) do
      if match.proposal then
        proposal = match
        break
      end
    end
    return accept_match(proposal, buf)
  end
  local candidates = {}
  for _, match in ipairs(entry.matches) do
    if match.candidate then
      candidates[#candidates + 1] = match
    end
  end
  if #candidates == 1 then
    return accept_match(candidates[1], buf)
  end
  return pick_alternatives(candidates, buf)
end

function M.review_accept(first, second)
  local requested_buf, intent = review_arguments(first, second)
  local buf, row, col = review_target(requested_buf)
  local matches = unique_matches(matches_under_cursor(buf, row, col))
  if #matches == 0 then
    local message = "no candidate under the cursor"
    notify(message, vim.log.levels.WARN)
    return false, message
  end
  if intent then
    local wanted = intent:upper()
    local filtered = {}
    for _, match in ipairs(matches) do
      if group_has_intent(match.group, wanted) then
        filtered[#filtered + 1] = match
      end
    end
    if #filtered == 0 then
      local message = string.format("no candidate with intent %s under the cursor", intent)
      notify(message, vim.log.levels.WARN)
      return false, message
    end
    matches = filtered
  end

  local entries = unique_groups(matches)
  if #entries > 1 then
    return pick_group(matches, "Accept review group", function(entry)
      accept_group(entry, buf)
    end)
  end
  return accept_group(entries[1], buf)
end

local function deny_group(entry, buf)
  if entry.proposal then
    local proposal = nil
    for _, match in ipairs(entry.matches) do
      if match.proposal then
        proposal = match
        break
      end
    end
    local group = proposal.group
    local id = proposal_id(group)
    if not id then
      local message = "proposal has no id; wait for the next publish"
      notify(message, vim.log.levels.WARN)
      return false, message
    end
    local sent, err = M.decide(id, "reject", buf, true, function(_, result)
      if type(result) == "table" and result.accepted == true then
        notify("rejected proposal " .. candidate_render.group_signature(group))
      end
    end)
    if not sent then
      notify(err, vim.log.levels.WARN)
      return false, err
    end
    return true
  end
  local ids = {}
  local seen = {}
  for _, candidate in ipairs(entry.group.candidates or {}) do
    local id = candidate.candidateId
    if id and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  if #ids == 0 then
    local message = "candidate has no id; wait for the next publish"
    notify(message, vim.log.levels.WARN)
    return false, message
  end
  local remaining = #ids
  local accepted = 0
  local last_error
  local sent_any = false
  local function finish()
    remaining = remaining - 1
    if remaining == 0 then
      if accepted > 0 then
        notify(string.format("rejected %d alternative(s)", accepted))
      elseif last_error and not sent_any then
        notify(last_error, vim.log.levels.WARN)
      end
    end
  end
  for _, id in ipairs(ids) do
    local sent, err = M.decide(id, "reject", buf, false, function(error, result)
      if not error and type(result) == "table" and result.accepted == true then
        accepted = accepted + 1
      end
      finish()
    end)
    if sent then
      sent_any = true
    else
      last_error = err
      finish()
    end
  end
  if not sent_any then
    return false, last_error
  end
  return true
end

function M.review_deny(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local target_buf, row, col = review_target(buf)
  local matches = unique_matches(matches_under_cursor(target_buf, row, col))
  if #matches == 0 then
    local message = "no candidate under the cursor"
    notify(message, vim.log.levels.WARN)
    return false, message
  end
  local entries = unique_groups(matches)
  if #entries > 1 then
    return pick_group(matches, "Deny review group", function(entry)
      deny_group(entry, target_buf)
    end)
  end
  return deny_group(entries[1], target_buf)
end

function M.review_entries(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local entries = {}
  for _, group in ipairs(M.groups(buf)) do
    entries[#entries + 1] = {
      bufnr = buf,
      lnum = (tonumber(group.startLine) or 0) + 1,
      col = (tonumber(group.startCol) or 0) + 1,
      text = candidate_render.group_label(group),
      group = group,
      path = group.path,
    }
  end
  table.sort(entries, function(left, right)
    local left_path = tostring(left.path or "")
    local right_path = tostring(right.path or "")
    if left_path ~= right_path then
      return left_path < right_path
    end
    if left.lnum ~= right.lnum then
      return left.lnum < right.lnum
    end
    return left.col < right.col
  end)
  return entries
end

function M.review_list(buf, opts)
  buf = buf or vim.api.nvim_get_current_buf()
  local target_buf = review_target(buf)
  if target_buf then
    buf = target_buf
  end
  opts = opts or {}
  local entries = M.review_entries(buf)
  if #entries == 0 then
    notify("no review groups for this buffer", vim.log.levels.INFO)
    return false
  end
  if opts.open ~= false then
    local quickfix = {}
    for _, entry in ipairs(entries) do
      quickfix[#quickfix + 1] = {
        bufnr = entry.bufnr,
        lnum = entry.lnum,
        col = entry.col,
        text = entry.text,
      }
    end
    vim.fn.setqflist(quickfix, "r")
    vim.fn.setqflist({}, "a", {
      title = REVIEW_TITLE,
      context = { [REVIEW_CONTEXT_KEY] = true },
    })
    vim.cmd("copen")
  end
  return entries
end

function M.review_navigate(direction, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype == "quickfix" then
    local item, items, index = quickfix_entry(buf)
    if not item then
      notify("not a cint review list", vim.log.levels.INFO)
      return false
    end
    if direction == "prev" then
      index = index <= 1 and #items or index - 1
    else
      index = index >= #items and 1 or index + 1
    end
    vim.cmd("cc " .. index)
    item = items[index]
    return {
      bufnr = item.bufnr,
      lnum = item.lnum,
      col = item.col,
      text = item.text,
      path = vim.api.nvim_buf_get_name(item.bufnr),
    }
  end
  local entries = M.review_entries(buf)
  if #entries == 0 then
    notify("no review groups for this buffer", vim.log.levels.INFO)
    return false
  end
  local row, col = cursor_position(buf)
  if row == nil then
    return false
  end
  local target
  if direction == "prev" then
    for index = #entries, 1, -1 do
      local entry = entries[index]
      if entry.lnum - 1 < row or (entry.lnum - 1 == row and entry.col - 1 < col) then
        target = entry
        break
      end
    end
    target = target or entries[#entries]
  else
    for _, entry in ipairs(entries) do
      if entry.lnum - 1 > row or (entry.lnum - 1 == row and entry.col - 1 > col) then
        target = entry
        break
      end
    end
    target = target or entries[1]
  end
  local win = vim.fn.win_findbuf(buf)[1] or vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_win_set_cursor, win, { target.lnum, math.max(0, target.col - 1) })
  return target
end

local function restriction_label(record)
  local parts = {
    string.format("%s · %s:%d", tostring(record.status or "unknown"), tostring(record.path or "?"), (tonumber(record.startLine) or 0) + 1),
  }
  if nonempty_string(record.symbol) then
    parts[#parts + 1] = record.symbol
  end
  local operations = {}
  for _, operation in ipairs(record.remove or {}) do
    operations[#operations + 1] = "− " .. tostring(operation.intent)
  end
  for _, operation in ipairs(record.add or {}) do
    operations[#operations + 1] = "+ " .. tostring(operation.intent)
  end
  if #operations > 0 then
    parts[#parts + 1] = table.concat(operations, " ")
  end
  if nonempty_string(record.provider) then
    parts[#parts + 1] = "ai:" .. record.provider
  end
  return table.concat(parts, " · ")
end

function M.restriction_remove(id, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not capabilities.restrictions() then
    return false, "live server does not support AI restrictions (protocol 4 with restrictions enabled required)"
  end
  if not live.is_connected() then
    return false, "live server is not connected"
  end
  local sent = live.request("cint/restrictions/remove", { id = id }, function(request_err, result)
    if request_err then
      notify(request_err, vim.log.levels.WARN)
      return
    end
    if type(result) == "table" and result.removed == true then
      notify("removed AI restriction; re-analyzing")
      state.live_restrictions[buf] = nil
      live_ops.live_request_analysis(buf)
    else
      notify("restriction was not removed", vim.log.levels.WARN)
    end
  end)
  if not sent then
    return false, "live server is not connected"
  end
  return true
end

function M.restrictions(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not capabilities.restrictions() then
    return false,
      "AI restrictions are not supported; restart/rebuild the live server (protocol 4 with restrictions enabled required)"
  end
  local uri = buffer_uri(buf)
  local sent = live.request("cint/restrictions/list", { uri = uri }, function(request_err, result)
    if request_err then
      notify(request_err, vim.log.levels.WARN)
      return
    end
    local records = type(result) == "table" and result.restrictions or {}
    state.live_restrictions[buf] = records
    if #records == 0 then
      notify("no AI restrictions", vim.log.levels.INFO)
      return
    end
    local labels = {}
    for index, record in ipairs(records) do
      labels[index] = restriction_label(record)
    end
    vim.ui.select(labels, { prompt = "AI restrictions" }, function(_, index)
      if index then
        M.restriction_remove(records[index].id, buf)
      end
    end)
  end)
  if not sent then
    return false, "live server is not connected"
  end
  return true
end

local function event_line(event)
  local parts = { tostring(event.type or "event") }
  if nonempty_string(event.tool) then
    parts[#parts + 1] = event.tool
  end
  if nonempty_string(event.unitId) then
    parts[#parts + 1] = event.unitId
  end
  local prefix = table.concat(parts, " · ")
  if nonempty_string(event.message) then
    return prefix .. ": " .. event.message
  end
  return prefix
end

function M.ai_log_lines(result)
  local lines = {}
  if type(result) ~= "table" then
    return { "cint AI log: no session recorded" }
  end
  lines[#lines + 1] = string.format(
    "cint AI log · %s",
    tostring(result.uri or "current buffer")
  )
  lines[#lines + 1] = string.format(
    "coverage graded %d/%d · reused %d · additions %d · tool calls %d · turns %d",
    tonumber(result.graded) or 0,
    tonumber(result.total) or 0,
    tonumber(result.reused) or 0,
    tonumber(result.additions) or 0,
    tonumber(result.toolCalls) or 0,
    tonumber(result.turns) or 0
  )
  lines[#lines + 1] = string.format(
    "overhead %d ms · incomplete %s · budget exhausted %s",
    tonumber(result.overhead) or 0,
    tostring(result.incomplete == true),
    tostring(result.budgetExhausted == true)
  )
  local uncovered = result.uncovered or {}
  if #uncovered > 0 then
    lines[#lines + 1] = "uncovered " .. table.concat(uncovered, ", ")
  end
  local events = result.events or {}
  lines[#lines + 1] = string.format("events %d", #events)
  for _, event in ipairs(events) do
    lines[#lines + 1] = "  " .. event_line(event)
  end
  return lines
end

function M.ai_log(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if capabilities.protocol() < 4 then
    return false, "cint/suggest/log requires protocol 4; restart/rebuild the live server"
  end
  local uri = buffer_uri(buf)
  if not uri then
    return false, "the buffer has no file path"
  end
  local sent = live.request("cint/suggest/log", { uri = uri }, function(request_err, result)
    if request_err then
      notify(request_err, vim.log.levels.WARN)
      return
    end
    state.live_suggest_log[buf] = result
    local lines = M.ai_log_lines(result)
    vim.cmd("new")
    local log_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(log_buf, 0, -1, false, lines)
    vim.bo[log_buf].buftype = "nofile"
    vim.bo[log_buf].bufhidden = "wipe"
    vim.bo[log_buf].filetype = "text"
    vim.bo[log_buf].modifiable = false
  end)
  if not sent then
    return false, "live server is not connected"
  end
  return true
end

function M.progress(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return state.live_suggest_progress[buf]
end

function M.status(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return M.candidate_count(buf) + M.proposal_group_count(buf)
end

function M.status_text(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local enhanced = capabilities.protocol() >= 4
    and (capabilities.discovery() or capabilities.restrictions() or capabilities.cache())
  if enhanced then
    local progress = state.live_suggest_progress[buf]
    if progress and capabilities.discovery() then
      local parts = {
        string.format("CodeIntent: grading %d/%d", tonumber(progress.graded) or 0, tonumber(progress.total) or 0),
      }
      if capabilities.cache() then
        parts[#parts + 1] = string.format("reused %d", tonumber(progress.reused) or 0)
      end
      if progress.activity and progress.activity ~= "" then
        parts[#parts + 1] = tostring(progress.activity)
      end
      return table.concat(parts, " · ")
    end
    local ai = M.ai_candidate_count(buf)
    local text = string.format("CodeIntent: %d unsure", M.status(buf))
    if ai > 0 then
      text = text .. string.format(" (%d AI)", ai)
    end
    if capabilities.restrictions() then
      local restrictions = M.restriction_count(buf)
      if restrictions > 0 then
        text = text .. string.format(" · %d restrictions", restrictions)
      end
    end
    local result = state.live_suggest_results[buf]
    if result then
      if capabilities.cache() then
        text = text .. string.format(" · reused %d", tonumber(result.reused) or 0)
      end
      if capabilities.discovery() then
        text = text
          .. string.format(
            " · coverage %d/%d",
            tonumber(result.graded) or 0,
            tonumber(result.total) or 0
          )
      end
    end
    return text
  end
  local ai = M.ai_candidate_count(buf)
  if ai > 0 then
    return string.format("CodeIntent: %d unsure (%d AI)", M.candidate_count(buf), ai)
  end
  return string.format("CodeIntent: %d unsure", M.candidate_count(buf))
end

return M
