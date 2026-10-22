local cint = require("cint")
local candidate_render = require("cint.render.candidates")
local live = require("cint.transport.live")
local live_ops = require("cint.ops.live_ops")
local state = require("cint.core.state")
local suggestion_ops = require("cint.ops.suggestion_ops")

cint.setup({
  auto_render = false,
  server_log = false,
  tags = { VALIDATION = { meaning = 'HIGHLIGHT', bg = '#101010' } },
})

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.mkdir(root .. "/.git", "p")
local socket = live.socket_path(root)
pcall(vim.uv.fs_unlink, socket)

local server = vim.uv.new_pipe(false)
assert(server:bind(socket))
local seen = {}
local decisions = {}
local suggest_mode = "publish"
local last_candidates = nil
local client = nil
local revision = 100

local function next_revision()
  revision = revision + 1
  return revision
end

local function reply(message)
  client:write(vim.json.encode(message) .. "\n")
end

local function candidate(version, source, revision, overrides)
  local value = {
    candidateId = "cand-1",
    path = root .. "/Sample.kt",
    contentHash = "hash",
    intents = { "VALIDATION" },
    source = source,
    confidence = 0.4,
    startLine = 1,
    startCol = 0,
    endLine = 1,
    endCol = 4,
    startByte = 20,
    endByte = 24,
    reason = "GAP",
    aiEligible = true,
    version = version,
    analysisRevision = revision,
    suggestionRevision = revision,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function publish_candidates(params, source, revision, candidates)
  candidates = candidates or { candidate(params.version, source, revision) }
  local groups = {}
  if #candidates > 0 then
    groups[1] = {
      anchorId = "anchor-1",
      path = params.uri,
      contentHash = "hash",
      startLine = 1,
      startCol = 0,
      endLine = 1,
      endCol = 4,
      startByte = 20,
      endByte = 24,
      candidates = candidates,
    }
  end
  last_candidates = {
    jsonrpc = "2.0",
    method = "cint/publishCandidates",
    params = {
      uri = params.uri,
      version = params.version,
      analysisRevision = revision,
      suggestionRevision = revision,
      groups = groups,
      candidates = candidates,
    },
  }
  reply(last_candidates)
end

local function publish_tags(params, revision, annotations)
  reply({
    jsonrpc = "2.0",
    method = "cint/publishTags",
    params = {
      uri = params.uri,
      version = params.version,
      hash = "fake",
      revision = 0,
      analysisRevision = revision or 1,
      annotations = annotations or {},
    },
  })
end

local function handle(message)
  seen[message.method] = (seen[message.method] or 0) + 1
  if message.method == "initialize" then
    reply({
      jsonrpc = "2.0",
      id = message.id,
      result = {
        protocol = 3,
        root = root,
        config = { packs = {}, overlay = {} },
        suggestions = {
          enabled = true,
          trigger = "manual",
          provider = "fake",
          model = "fake-intent-v1",
          knownIntents = { "VALIDATION", "LOGGING" },
        },
      },
    })
  elseif message.method == "textDocument/didOpen" then
    local current = next_revision()
    publish_tags(message.params, current)
    publish_candidates(message.params, "rule:validation:validation", current)
  elseif message.method == "textDocument/didChange" then
    local current = next_revision()
    publish_tags(message.params, current)
    publish_candidates(message.params, "rule:validation:validation", current)
  elseif message.method == "cint/suggest" then
    local current = next_revision()
    if suggest_mode == "publish" then
      publish_candidates(message.params, "ai:fake", current)
    end
    local result
    if suggest_mode == "busy" then
      result = { accepted = false, busy = true, count = 0 }
    elseif suggest_mode == "disabled" then
      result = { accepted = false, disabled = true, count = 0 }
    else
      result = { accepted = true, count = suggest_mode == "publish" and 1 or 0 }
    end
    reply({ jsonrpc = "2.0", id = message.id, result = result })
  elseif message.method == "cint/suggest/cancel" then
    reply({ jsonrpc = "2.0", id = message.id, result = true })
  elseif message.method == "cint/candidates/decide" then
    decisions[#decisions + 1] = message.params
    local current = next_revision()
    if message.params.decision == "confirm" then
      publish_tags(message.params, current, {
        {
          role = "source-intent",
          intents = { "VALIDATION" },
          source = "user",
          startLine = 1,
          startCol = 0,
          endLine = 1,
          endCol = 4,
          startByte = 20,
          endByte = 24,
          provenance = {
            { rule = "core:user-annotations", role = "source-intent", intents = { "VALIDATION" }, source = "user", confidence = 1.0, startLine = 1, startCol = 0, endLine = 1, endCol = 4, startByte = 20, endByte = 24 },
          },
        },
      })
    end
    publish_candidates(message.params, "rule:validation:validation", current, {})
    reply({ jsonrpc = "2.0", id = message.id, result = { accepted = true } })
  end
end

server:listen(16, function(listen_err)
  assert(not listen_err, tostring(listen_err))
  client = vim.uv.new_pipe(false)
  local ok, err = server:accept(client)
  assert(ok, tostring(err))
  local buffered = ""
  client:read_start(function(read_err, data)
    assert(not read_err, tostring(read_err))
    if not data then
      return
    end
    buffered = buffered .. data
    while true do
      local newline = buffered:find("\n", 1, true)
      if not newline then
        break
      end
      local line = buffered:sub(1, newline - 1)
      buffered = buffered:sub(newline + 1)
      if line ~= "" then
        local ok_decode, message = pcall(vim.json.decode, line)
        if ok_decode and type(message) == "table" then
          handle(message)
        end
      end
    end
  end)
end)

assert(live_ops.live_connect(root), "live connection should start")
assert(vim.wait(2000, function()
  return state.live_ready and live.is_connected()
end, 10), "live connection should become ready")
assert(suggestion_ops.suggestions_supported(), "protocol 3 should expose suggestions")
assert(suggestion_ops.suggestions_descriptor().provider == "fake")

local path = root .. "/Sample.kt"
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, path)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fun f() {", "    check()", "}" })
vim.bo[buf].filetype = "kotlin"
vim.api.nvim_set_current_buf(buf)
assert(live_ops.live_open(buf), "opening the buffer should publish it")
assert(vim.wait(2000, function()
  return state.live_candidates[buf] ~= nil
end, 10), "candidate publish should reach the client")
assert(#suggestion_ops.candidates(buf) == 1, "one candidate should be published")
assert(state.live_candidates[buf].candidates[1].source == "rule:validation:validation")
assert(suggestion_ops.status_text(buf) == "CodeIntent: 1 unsure", "status should count candidates")

local function candidate_marks()
  return vim.api.nvim_buf_get_extmarks(buf, candidate_render.ns, 0, -1, { details = true })
end

local function mark_with_hl(marks, needle)
  for _, mark in ipairs(marks) do
    local group = mark[4].hl_group
    if group and group:find(needle, 1, true) then
      return mark
    end
  end
end

local function virtual_marks(marks)
  local result = {}
  for _, mark in ipairs(marks) do
    if mark[4].virt_lines then
      result[#result + 1] = mark
    end
  end
  return result
end

local function virtual_text(mark)
  local chunks = mark[4].virt_lines[1] or {}
  local text = {}
  for _, chunk in ipairs(chunks) do
    text[#text + 1] = chunk[1]
  end
  return table.concat(text)
end

local function sign_mark(marks, sign_text)
  for _, mark in ipairs(marks) do
    if vim.trim(mark[4].sign_text or "") == sign_text then
      return mark
    end
  end
end

local function badges(marks)
  local result = {}
  for _, mark in ipairs(marks) do
    local chunks = mark[4].virt_text
    if chunks then
      local text = {}
      for _, chunk in ipairs(chunks) do
        text[#text + 1] = chunk[1]
      end
      result[#result + 1] = { text = table.concat(text), mark = mark }
    end
  end
  return result
end

local initial_marks = candidate_marks()
assert(#initial_marks >= 2, "candidates should render underline and sign extmarks")
assert(mark_with_hl(initial_marks, "CintCandidate"), "passive candidates should use the passive highlight")
assert(not mark_with_hl(initial_marks, "CintAiCandidate"), "deterministic candidates should not use the AI highlight")
assert(#virtual_marks(initial_marks) == 0, "passive candidates should not add virtual lines")
local deterministic_sign = sign_mark(initial_marks, "?")
assert(deterministic_sign, "deterministic candidates should keep the muted ? sign")
assert(deterministic_sign[4].sign_hl_group == "CintCandidateSign", "deterministic sign should use the passive sign highlight")
assert(#badges(initial_marks) == 0, "deterministic candidates should not add an AI badge")

local before = state.live_candidates[buf]
live_ops.live_on_candidates({
  uri = path,
  version = before.version,
  analysisRevision = 0,
  suggestionRevision = 0,
  candidates = {},
})
assert(#suggestion_ops.candidates(buf) == 1, "stale candidate revisions should be discarded")
live_ops.live_on_candidates({
  uri = path,
  version = before.version + 1,
  analysisRevision = 99,
  suggestionRevision = 99,
  candidates = {},
})
assert(#suggestion_ops.candidates(buf) == 1, "stale document versions should be discarded")

local suggest_notifications = {}
local suggest_notify = vim.notify
vim.notify = function(message, level)
  suggest_notifications[#suggest_notifications + 1] = { text = tostring(message), level = level }
end
assert(suggestion_ops.suggest(buf), "suggest should send a request")
assert(vim.wait(2000, function()
  return state.live_candidates[buf].candidates[1].source == "ai:fake"
end, 10), "fake provider should enrich the candidate")
vim.notify = suggest_notify

local function notification_count(messages, needle)
  local count = 0
  for _, message in ipairs(messages) do
    if message.text:find(needle, 1, true) then
      count = count + 1
    end
  end
  return count
end

assert(notification_count(suggest_notifications, "requesting AI suggestions") == 1, "suggest should announce start")
assert(
  notification_count(suggest_notifications, "AI added 1 candidate(s); :CintReview to inspect") == 1,
  "AI arrival should notify exactly once"
)
assert(
  notification_count(suggest_notifications, "AI suggestions found no new candidates") == 0,
  "a successful arrival should not also report no result"
)
for _, message in ipairs(suggest_notifications) do
  if message.text:find("AI added", 1, true) then
    assert(message.level == vim.log.levels.INFO, "AI arrival notification should be INFO")
  end
end

assert(suggestion_ops.status_text(buf) == "CodeIntent: 1 unsure (1 AI)", "status should include the AI count")
local ai_marks = candidate_marks()
assert(mark_with_hl(ai_marks, "CintAiCandidate"), "passive AI candidates should use the AI highlight")
local ai_sign = sign_mark(ai_marks, "AI")
assert(ai_sign, "passive AI candidates should use the AI sign")
assert(ai_sign[4].sign_hl_group == "CintAiCandidateSign", "AI sign should use the AI sign highlight")
local ai_badges = badges(ai_marks)
assert(#ai_badges == 1, "passive AI candidates should add one AI badge, got " .. #ai_badges)
assert(ai_badges[1].text == " AI", "AI badge should read ' AI'")
assert(ai_badges[1].mark[4].virt_text_pos == "eol", "AI badge should be placed at end of line")
assert(
  ai_badges[1].mark[4].virt_text[1][2] == "CintAiCandidateSign",
  "AI badge should use the AI sign highlight"
)

vim.wait(200, function()
  return false
end, 10)

local changes_before = seen["textDocument/didChange"] or 0
local repeat_notifications = {}
local repeat_notify = vim.notify
vim.notify = function(message, level)
  repeat_notifications[#repeat_notifications + 1] = { text = tostring(message), level = level }
end
assert(suggestion_ops.suggest(buf), "a repeat suggest should send a request")
assert(vim.wait(2000, function()
  return notification_count(repeat_notifications, "AI suggestions found no new candidates") > 0
end, 10), "a repeat suggest with AI already present should report no new candidates")
vim.notify = repeat_notify
assert(notification_count(repeat_notifications, "requesting AI suggestions") == 1, "repeat suggest should announce start")
assert(
  notification_count(repeat_notifications, "AI suggestions found no new candidates") == 1,
  "repeat suggest should report exactly one no-result outcome"
)
assert(notification_count(repeat_notifications, "AI added") == 0, "repeat suggest should not report a duplicate arrival")
assert(
  (seen["textDocument/didChange"] or 0) == changes_before,
  "a repeat suggest should reuse current analysis instead of republishing"
)

local ai_record = state.live_candidates[buf]
local republish_notifications = {}
local republish_notify = vim.notify
vim.notify = function(message, level)
  republish_notifications[#republish_notifications + 1] = { text = tostring(message), level = level }
end
live_ops.live_on_candidates({
  uri = path,
  version = ai_record.version,
  analysisRevision = ai_record.analysisRevision + 1,
  suggestionRevision = ai_record.suggestionRevision + 1,
  candidates = vim.deepcopy(ai_record.candidates),
})
vim.notify = republish_notify
assert(
  notification_count(republish_notifications, "AI added") == 0,
  "a repeated republish at the same AI count should not notify again"
)

suggest_mode = "busy"
local busy_notifications = {}
local busy_notify = vim.notify
vim.notify = function(message, level)
  busy_notifications[#busy_notifications + 1] = { text = tostring(message), level = level }
end
assert(suggestion_ops.suggest(buf), "a busy suggest should still send a request")
assert(vim.wait(2000, function()
  return notification_count(busy_notifications, "AI suggestion pass already running") > 0
end, 10), "a busy suggestion reply should be reported as busy")
vim.notify = busy_notify
suggest_mode = "publish"
assert(notification_count(busy_notifications, "requesting AI suggestions") == 1, "busy suggest should announce start")
assert(
  notification_count(busy_notifications, "AI suggestions found no new candidates") == 0,
  "a busy suggestion reply should not be reported as no-result"
)
assert(notification_count(busy_notifications, "AI added") == 0, "a busy suggestion reply should not report an arrival")

suggest_mode = "disabled"
local disabled_notifications = {}
local disabled_notify = vim.notify
vim.notify = function(message, level)
  disabled_notifications[#disabled_notifications + 1] = { text = tostring(message), level = level }
end
assert(suggestion_ops.suggest(buf), "a disabled suggest should still send a request")
assert(vim.wait(2000, function()
  return notification_count(disabled_notifications, "AI suggestions are disabled") > 0
end, 10), "a disabled suggestion reply should be explained")
vim.notify = disabled_notify
suggest_mode = "publish"
assert(notification_count(disabled_notifications, "requesting AI suggestions") == 1, "disabled suggest should announce start")
assert(
  notification_count(disabled_notifications, "AI suggestions found no new candidates") == 0,
  "a disabled suggestion reply should not be reported as no-result"
)
assert(notification_count(disabled_notifications, "AI added") == 0, "a disabled suggestion reply should not report an arrival")

assert(vim.fn.exists(":CintReview") == 2, "CintReview command should exist")
assert(vim.fn.exists(":CintReviewAccept") == 2, "CintReviewAccept command should exist")
assert(vim.fn.exists(":CintReviewDeny") == 2, "CintReviewDeny command should exist")

assert(suggestion_ops.review_toggle(buf) == true, "review toggle should enter review mode")
assert(suggestion_ops.review_active(buf), "review mode should be active for the buffer")
assert(state.review_buffers[buf] == true, "review state should be stored per buffer")
local review_marks = candidate_marks()
assert(mark_with_hl(review_marks, "CintCandidateReview"), "review should use the review highlight")
local review_virtual = virtual_marks(review_marks)
assert(#review_virtual == 1, "review should add one virtual line per candidate, got " .. #review_virtual)
assert(review_virtual[1][4].virt_lines_above == true, "candidate evidence should be above the line")
local evidence = virtual_text(review_virtual[1])
assert(evidence:find("VALIDATION", 1, true), "virtual line should show the intent")
assert(evidence:find("0.40", 1, true), "virtual line should show the confidence")
assert(evidence:find("ai:fake", 1, true), "virtual line should show the source")

vim.api.nvim_win_set_cursor(0, { 2, 2 })
local confirms_before = #decisions
assert(cint.review_accept(buf), "accept should confirm the candidate under the cursor")
assert(vim.wait(1000, function()
  return #decisions == confirms_before + 1
end, 10), "accept should send a confirm decision")
assert(decisions[#decisions].decision == "confirm", "accept should confirm")
assert(decisions[#decisions].candidateId == "cand-1", "decision should carry candidate identity")
assert(vim.wait(2000, function()
  return #suggestion_ops.candidates(buf) == 0
    and state.live_tags[buf] ~= nil
    and (state.live_tags[buf].analysisRevision or 0) >= 100
end, 10), "accept should remove the candidate and republish tags")
assert(suggestion_ops.review_active(buf), "accept should keep review mode active")
local render_marks = vim.api.nvim_buf_get_extmarks(buf, require("cint.render").ns, 0, -1, { details = true })
assert(
  #render_marks > 0,
  "accept should repaint the established annotation without a text change: "
    .. vim.inspect(render_marks)
    .. " tags="
    .. vim.inspect(state.live_tags[buf])
)
assert(#candidate_marks() == 0, "candidate marks should be cleared after the republish")

vim.api.nvim_win_set_cursor(0, { 3, 0 })
local missing_ok, missing_err = cint.review_accept(buf)
assert(not missing_ok, "accept without a candidate should fail")
assert(tostring(missing_err):find("no candidate under the cursor", 1, true), "accept should explain a missing candidate")
local deny_missing_ok, deny_missing_err = cint.review_deny(buf)
assert(not deny_missing_ok, "deny without a candidate should fail")
assert(tostring(deny_missing_err):find("no candidate under the cursor", 1, true), "deny should explain a missing candidate")

local function seed(candidates)
  local version = vim.b[buf].changedtick
  state.live_candidates[buf] = {
    version = version,
    analysisRevision = 20,
    suggestionRevision = 20,
    root = state.live_root,
    candidates = candidates,
    groups = {
      { anchorId = "anchor-1", candidates = candidates },
    },
  }
  suggestion_ops.render(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 2 })
end

local intent_choice = candidate(vim.b[buf].changedtick, "ai:fake", 20, {
  candidateId = "cand-1",
  intents = { "VALIDATION" },
  confidence = 0.8,
})
local intent_alternative = candidate(vim.b[buf].changedtick, "ai:fake", 20, {
  candidateId = "cand-2",
  intents = { "LOGGING" },
  confidence = 0.4,
})
seed({ intent_choice, intent_alternative })
local intent_before = #decisions
assert(cint.review_accept("LOGGING", buf), "intent argument should choose an alternative")
assert(vim.wait(1000, function()
  return #decisions == intent_before + 1
end, 10), "intent accept should send a decision")
assert(decisions[#decisions].candidateId == "cand-2", "intent accept should match the requested intent")
assert(vim.wait(2000, function()
  return #suggestion_ops.candidates(buf) == 0
end, 10), "intent accept should clear the group")

local low_confidence = candidate(vim.b[buf].changedtick, "ai:fake", 20, {
  candidateId = "cand-1",
  intents = { "VALIDATION" },
  confidence = 0.3,
})
local high_confidence = candidate(vim.b[buf].changedtick, "ai:fake", 20, {
  candidateId = "cand-2",
  intents = { "LOGGING" },
  confidence = 0.9,
})
seed({ low_confidence, high_confidence })
local picker_shown = false
local original_select = vim.ui.select
vim.ui.select = function(items, _, callback)
  picker_shown = true
  assert(#items == 2, "accept should offer every alternative under the caret")
  callback(items[1], 1)
end
local highest_before = #decisions
assert(cint.review_accept(buf), "accept without an intent should open the alternative picker")
vim.ui.select = original_select
assert(picker_shown, "multiple alternatives should open the picker")
assert(vim.wait(1000, function()
  return #decisions == highest_before + 1
end, 10), "picker accept should send a decision")
assert(decisions[#decisions].candidateId == "cand-2", "picker should select the highest-confidence alternative")
assert(vim.wait(2000, function()
  return #suggestion_ops.candidates(buf) == 0
end, 10), "picker accept should clear the group")

local deny_one = candidate(vim.b[buf].changedtick, "ai:fake", 20, {
  candidateId = "cand-1",
  intents = { "VALIDATION" },
  confidence = 0.9,
})
local deny_two = candidate(vim.b[buf].changedtick, "ai:fake", 20, {
  candidateId = "cand-2",
  intents = { "LOGGING" },
  confidence = 0.5,
})
seed({ deny_one, deny_two })
local deny_before = #decisions
assert(cint.review_deny(buf), "deny should reject the group under the cursor")
assert(vim.wait(1000, function()
  return #decisions >= deny_before + 2
end, 10), "deny should reject every alternative")
local rejected = {}
for index = deny_before + 1, #decisions do
  assert(decisions[index].decision == "reject", "deny should send reject decisions")
  rejected[decisions[index].candidateId] = true
end
assert(rejected["cand-1"] and rejected["cand-2"], "deny should reject all alternatives in the group")
assert(vim.wait(2000, function()
  return #suggestion_ops.candidates(buf) == 0
end, 10), "deny should clear the group")
assert(suggestion_ops.review_active(buf), "deny should keep review mode active")

local evidence_candidate = candidate(vim.b[buf].changedtick, "ai:fake", 20, {
  candidateId = "cand-1",
  intents = { "VALIDATION" },
  confidence = 0.55,
  rationale = "looks like validation",
})
seed({ evidence_candidate })
local intent_missing_before = #decisions
local intent_missing_ok, intent_missing_err = cint.review_accept("LOGGING", buf)
assert(not intent_missing_ok, "accept should reject an intent that is not present")
assert(tostring(intent_missing_err):find("no candidate with intent LOGGING", 1, true), "missing intent should be explained")
assert(#decisions == intent_missing_before, "a missing intent should not send a decision")
local evidence_text = virtual_text(virtual_marks(candidate_marks())[1])
assert(evidence_text:find("ai:fake", 1, true), "review evidence should include the source")
assert(evidence_text:find("looks like validation", 1, true), "review evidence should include a concise rationale")

assert(suggestion_ops.review_toggle(buf) == false, "review toggle should exit review mode")
assert(not suggestion_ops.review_active(buf), "review mode should be off for the buffer")
local passive_restored = candidate_marks()
assert(mark_with_hl(passive_restored, "CintAiCandidate"), "exiting review should restore passive AI rendering")
assert(not mark_with_hl(passive_restored, "CintCandidateReview"), "exiting review should remove the review highlight")
assert(#virtual_marks(passive_restored) == 0, "exiting review should remove virtual lines")

suggest_mode = "none"
local no_result_notifications = {}
local no_result_notify = vim.notify
vim.notify = function(message, level)
  no_result_notifications[#no_result_notifications + 1] = { text = tostring(message), level = level }
end
assert(suggestion_ops.suggest(buf), "a no-result suggest should still send a request")
assert(vim.wait(2000, function()
  return notification_count(no_result_notifications, "AI suggestions found no new candidates") > 0
end, 10), "a suggest pass without new candidates should report no result")
vim.notify = no_result_notify
assert(notification_count(no_result_notifications, "requesting AI suggestions") == 1, "no-result suggest should announce start")
assert(notification_count(no_result_notifications, "AI added") == 0, "no-result suggest should not report an arrival")
suggest_mode = "publish"

local saved_protocol = state.live_config_protocol
local saved_suggestions = state.live_suggestions
local suggests_before = seen["cint/suggest"] or 0

state.live_config_protocol = 2
local protocol_ok, protocol_err = suggestion_ops.suggest(buf)
assert(not protocol_ok, "protocol 2 should reject suggestions")
assert(tostring(protocol_err):find("protocol 2", 1, true), "protocol gating should name the protocol")
assert(tostring(protocol_err):find("restart/rebuild the live server", 1, true), "protocol gating should suggest a restart")
assert((seen["cint/suggest"] or 0) == suggests_before, "protocol 2 must not send cint/suggest")

state.live_config_protocol = 3
state.live_suggestions = nil
local descriptor_ok, descriptor_err = suggestion_ops.suggest(buf)
assert(not descriptor_ok, "a missing suggestions descriptor should reject suggestions")
assert(tostring(descriptor_err):find("descriptor", 1, true), "missing descriptors should be named")
assert(tostring(descriptor_err):find("restart/rebuild the live server", 1, true), "missing descriptors should suggest a restart")
assert((seen["cint/suggest"] or 0) == suggests_before, "missing descriptors must not send cint/suggest")

state.live_suggestions = { enabled = false }
local disabled_ok, disabled_err = suggestion_ops.suggest(buf)
assert(not disabled_ok, "a disabled descriptor should reject suggestions")
assert(tostring(disabled_err):find(".cint/suggestions.yml", 1, true), "disabled suggestions should name the config file")
assert(tostring(disabled_err):find("enabled=false", 1, true), "disabled suggestions should name the setting")
assert((seen["cint/suggest"] or 0) == suggests_before, "disabled suggestions must not send cint/suggest")

state.live_config_protocol = 2
state.live_suggestions = saved_suggestions
local notifications = {}
local original_notify = vim.notify
vim.notify = function(message)
  notifications[#notifications + 1] = tostring(message)
end
assert(pcall(vim.cmd, "CintSuggest"), "CintSuggest should not error")
vim.notify = original_notify
local command_explained = false
for _, message in ipairs(notifications) do
  if message:find("restart/rebuild the live server", 1, true) then
    command_explained = true
  end
end
assert(command_explained, "CintSuggest should surface the protocol restart hint")
state.live_config_protocol = saved_protocol
state.live_suggestions = saved_suggestions

assert(suggestion_ops.review_toggle(buf) == true, "review should be re-enabled before closing")
assert(suggestion_ops.review_active(buf), "review mode should be active before closing")
live_ops.live_close(buf)
assert(not suggestion_ops.review_active(buf), "closing the buffer should clear review state")
assert(#candidate_marks() == 0, "closing the buffer should clear candidate marks")

live.disconnect()
server:close()
pcall(vim.uv.fs_unlink, socket)
print("PASS")
vim.cmd("qa!")
