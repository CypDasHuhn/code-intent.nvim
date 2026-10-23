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
local decision_mode = "normal"
local pending_suggest = nil
local pending_restore = false
local restore_change_count = 0
local restored_after_analysis = false
local client = nil
local revision = 100
local groups = {}

local function next_revision()
  revision = revision + 1
  return revision
end

local function reply(message)
  client:write(vim.json.encode(message) .. "\n")
end

local function candidate(params, overrides)
  local value = {
    candidateId = "cand-1",
    path = root .. "/Sample.kt",
    contentHash = "hash",
    intents = { "VALIDATION" },
    source = "rule:validation:validation",
    confidence = 0.4,
    startLine = 1,
    startCol = 0,
    endLine = 1,
    endCol = 4,
    startByte = 20,
    endByte = 24,
    reason = "GAP",
    aiEligible = true,
    version = params.version,
    analysisRevision = revision,
    suggestionRevision = revision,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function operation(kind, intent, start_line, start_col, end_line, end_col, overrides)
  local value = {
    kind = kind,
    intent = intent,
    startLine = start_line,
    startCol = start_col,
    endLine = end_line,
    endCol = end_col,
    startByte = 20,
    endByte = 30,
    confidence = 0.68,
    rationale = "rationale for " .. intent,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function proposal(params, id, line, overrides)
  local value = {
    proposalId = id,
    groupId = id,
    anchorId = id,
    path = root .. "/Sample.kt",
    contentHash = "hash",
    unitId = id,
    startLine = line,
    startCol = 0,
    endLine = line,
    endCol = 4,
    startByte = 40,
    endByte = 44,
    provider = "fake",
    model = "fake-intent-v1",
    promptVersion = "deepseek-intent-v3",
    candidates = {},
    operations = {
      operation("REMOVE", "LOGGING", line, 0, line, 4, { source = "logging" }),
      operation("ADD", "SEARCH", line, 0, line, 4),
    },
    version = params.version,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function base_groups(params)
  return {
    {
      anchorId = "det-anchor",
      path = params.uri,
      contentHash = "hash",
      startLine = 1,
      startCol = 0,
      endLine = 1,
      endCol = 4,
      startByte = 20,
      endByte = 24,
      candidates = { candidate(params) },
    },
  }
end

local function publish_candidates(params, next_groups)
  groups = next_groups or groups
  local candidates = {}
  for _, group in ipairs(groups) do
    for _, item in ipairs(group.candidates or {}) do
      candidates[#candidates + 1] = item
    end
  end
  reply({
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
  })
end

local function publish_tags(params, annotations)
  reply({
    jsonrpc = "2.0",
    method = "cint/publishTags",
    params = {
      uri = params.uri,
      version = params.version,
      hash = "fake-" .. revision,
      revision = 0,
      analysisRevision = revision,
      annotations = annotations or {},
    },
  })
end

local function suggest_groups(params)
  local ai = candidate(params, {
    candidateId = "cand-ai",
    source = "ai:fake",
    confidence = 0.71,
    startLine = 1,
    startCol = 4,
    endLine = 1,
    endCol = 10,
    rationale = "regex find searches the text",
  })
  return {
    {
      anchorId = "det-anchor",
      path = params.uri,
      contentHash = "hash",
      startLine = 1,
      startCol = 0,
      endLine = 1,
      endCol = 4,
      startByte = 20,
      endByte = 24,
      candidates = { candidate(params) },
    },
    {
      anchorId = "ai-anchor",
      path = params.uri,
      contentHash = "hash",
      startLine = 1,
      startCol = 4,
      endLine = 1,
      endCol = 10,
      startByte = 24,
      endByte = 30,
      candidates = { ai },
      operations = {
        operation("ADD", "VALIDATION", 1, 4, 1, 10, { confidence = 0.71, rationale = "regex find searches the text", source = "ai:fake" }),
      },
    },
    proposal(params, "prop-1", 2),
    proposal(params, "prop-2", 3, {
      operations = {
        operation("REMOVE", "LOGGING", 3, 0, 3, 3, { source = "logging" }),
      },
    }),
  }
end

local function handle(message)
  seen[message.method] = (seen[message.method] or 0) + 1
  if message.method == "initialize" then
    reply({
      jsonrpc = "2.0",
      id = message.id,
      result = {
        protocol = 4,
        root = root,
        config = { packs = {}, overlay = {} },
        suggestions = {
          enabled = true,
          trigger = "manual",
          provider = "fake",
          model = "fake-intent-v1",
          knownIntents = { "VALIDATION", "LOGGING", "SEARCH" },
          discovery = true,
          restrictions = true,
          cache = true,
          maxUnitsPerRequest = 24,
        },
      },
    })
  elseif message.method == "textDocument/didOpen" or message.method == "textDocument/didChange" then
    next_revision()
    if pending_restore then
      restored_after_analysis = (seen["textDocument/didChange"] or 0) > restore_change_count
      pending_restore = false
      publish_tags(message.params, {
        {
          role = "source-intent",
          intents = { "LOGGING" },
          source = "logging",
          startLine = 2,
          startCol = 0,
          endLine = 2,
          endCol = 4,
          startByte = 40,
          endByte = 44,
          provenance = {},
        },
      })
      return
    end
    groups = base_groups(message.params)
    publish_tags(message.params)
    publish_candidates(message.params)
  elseif message.method == "cint/suggest" then
    if suggest_mode == "cancel" then
      pending_suggest = message
      reply({
        jsonrpc = "2.0",
        method = "cint/suggest/progress",
        params = {
          uri = message.params.uri,
          version = message.params.version,
          graded = 4,
          reused = 8,
          total = 12,
          activity = "reading Sample.kt:2",
        },
      })
      return
    end
    reply({
      jsonrpc = "2.0",
      method = "cint/suggest/progress",
      params = {
        uri = message.params.uri,
        version = message.params.version,
        graded = 5,
        reused = 7,
        total = 12,
        activity = "reading Sample.kt:2",
      },
    })
    local function finish()
      next_revision()
      groups = suggest_groups(message.params)
      publish_candidates(message.params)
      reply({
        jsonrpc = "2.0",
        id = message.id,
        result = {
          accepted = true,
          cancelled = false,
          count = 3,
          total = 12,
          graded = 5,
          reused = 7,
          additions = 2,
          restrictions = 2,
          toolCalls = 9,
          turns = 4,
          incomplete = false,
          budgetExhausted = false,
          overhead = 12,
          uncovered = {},
        },
      })
    end
    if suggest_mode == "progress" then
      vim.defer_fn(finish, 80)
    else
      finish()
    end
  elseif message.method == "cint/suggest/cancel" then
    reply({ jsonrpc = "2.0", id = message.id, result = true })
    if pending_suggest then
      reply({
        jsonrpc = "2.0",
        id = pending_suggest.id,
        result = { accepted = false, cancelled = true, count = 0 },
      })
      pending_suggest = nil
    end
  elseif message.method == "cint/suggest/log" then
    reply({
      jsonrpc = "2.0",
      id = message.id,
      result = {
        uri = message.params.uri,
        total = 12,
        graded = 5,
        reused = 7,
        additions = 2,
        toolCalls = 9,
        turns = 4,
        incomplete = false,
        budgetExhausted = false,
        overhead = 12,
        uncovered = { "u9" },
        events = {
          { type = "reuse", message = "reused u1", unitId = "u1", tool = vim.NIL },
          { type = "tool", message = "list_expression_units", tool = "list_expression_units", unitId = vim.NIL },
          { type = "verdict", message = "accepted 3, rejected 0", tool = vim.NIL, unitId = vim.NIL },
        },
      },
    })
  elseif message.method == "cint/restrictions/list" then
    reply({
      jsonrpc = "2.0",
      id = message.id,
      result = {
        restrictions = {
          {
            id = "restriction-1",
            path = root .. "/Sample.kt",
            symbol = vim.NIL,
            startLine = 2,
            startCol = 0,
            endLine = 2,
            endCol = 4,
            status = "active",
            provider = vim.NIL,
            remove = { { intent = "LOGGING", startOffset = 0, endOffset = 4 } },
            add = { { intent = "SEARCH", startOffset = 0, endOffset = 4 } },
          },
          {
            id = "restriction-2",
            path = root .. "/Sample.kt",
            symbol = "g",
            startLine = 3,
            startCol = 0,
            endLine = 3,
            endCol = 3,
            status = "dormant",
            provider = "fake",
            remove = { { intent = "LOGGING", startOffset = 0, endOffset = 3 } },
            add = {},
          },
        },
      },
    })
  elseif message.method == "cint/restrictions/remove" then
    decisions[#decisions + 1] = message.params
    pending_restore = true
    restore_change_count = seen["textDocument/didChange"] or 0
    reply({ jsonrpc = "2.0", id = message.id, result = { accepted = true, removed = true } })
  elseif message.method == "cint/candidates/decide" then
    decisions[#decisions + 1] = message.params
    local function complete()
      next_revision()
      local target = message.params.proposalId or message.params.candidateId
      local kept = {}
      for _, group in ipairs(groups) do
        local keep = group.proposalId ~= target and group.groupId ~= target
        if keep then
          local candidates = {}
          for _, item in ipairs(group.candidates or {}) do
            if item.candidateId ~= target then
              candidates[#candidates + 1] = item
            end
          end
          if #candidates > 0 or group.proposalId then
            group.candidates = candidates
            kept[#kept + 1] = group
          end
        end
      end
      groups = kept
      publish_tags(message.params, {
        {
          role = "source-intent",
          intents = { "SEARCH" },
          source = "ai-confirmed",
          startLine = 2,
          startCol = 0,
          endLine = 2,
          endCol = 4,
          startByte = 40,
          endByte = 44,
          provenance = {},
        },
      })
      publish_candidates(message.params)
      reply({ jsonrpc = "2.0", id = message.id, result = { accepted = true } })
    end
    if decision_mode == "disabled" then
      reply({ jsonrpc = "2.0", id = message.id, result = { accepted = false, disabled = true } })
    elseif decision_mode == "missing" then
      reply({ jsonrpc = "2.0", id = message.id, result = { accepted = false, missing = true } })
    elseif decision_mode == "delay" then
      vim.defer_fn(complete, 120)
    else
      complete()
    end
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
assert(suggestion_ops.suggestions_supported(), "protocol 4 should expose suggestions")
assert(suggestion_ops.suggestions_descriptor().discovery == true, "discovery capability should be exposed")
assert(suggestion_ops.suggestions_descriptor().restrictions == true, "restrictions capability should be exposed")
assert(suggestion_ops.suggestions_descriptor().cache == true, "cache capability should be exposed")

local path = root .. "/Sample.kt"
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, path)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fun f() {", "    check()", "    log()", "    save()", "}" })
vim.bo[buf].filetype = "kotlin"
vim.api.nvim_set_current_buf(buf)
assert(live_ops.live_open(buf), "opening the buffer should publish it")
assert(vim.wait(2000, function()
  return state.live_candidates[buf] ~= nil
end, 10), "candidate publish should reach the client")

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

local function sign_mark(marks, sign_text)
  for _, mark in ipairs(marks) do
    if vim.trim(mark[4].sign_text or "") == sign_text then
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

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level)
  notifications[#notifications + 1] = { text = tostring(message), level = level }
end

local function notification_count(messages, needle)
  local count = 0
  for _, message in ipairs(messages) do
    if message.text:find(needle, 1, true) then
      count = count + 1
    end
  end
  return count
end

assert(suggestion_ops.suggest(buf), "suggest should send a request")
assert(vim.wait(2000, function()
  return state.live_suggest_results[buf] ~= nil
end, 10), "suggest should complete")
assert(vim.wait(2000, function()
  return state.live_candidates[buf] and #suggestion_ops.groups(buf) == 4
end, 10), "suggest should publish operations and proposals")

local status = suggestion_ops.status_text(buf)
assert(status:find("CodeIntent: 4 unsure (2 AI)", 1, true), "status should count AI additions: " .. status)
assert(status:find("2 restrictions", 1, true), "status should count restrictions: " .. status)
assert(status:find("reused 7", 1, true), "status should show reuse: " .. status)
assert(status:find("coverage 5/12", 1, true), "status should show coverage: " .. status)

local passive = candidate_marks()
assert(mark_with_hl(passive, "CintCandidate"), "deterministic candidates should keep passive marks")
assert(not mark_with_hl(passive, "CintAiCandidate"), "passive mode should not add AI undercurl")
assert(sign_mark(passive, "AI") == nil, "passive mode should not add an AI sign")
assert(#virtual_marks(passive) == 0, "passive mode should not add AI virtual lines")
local ai_badges = 0
for _, mark in ipairs(passive) do
  if mark[4].virt_text then
    ai_badges = ai_badges + 1
  end
end
assert(ai_badges == 0, "passive mode should not add AI badges")

assert(notification_count(notifications, "AI added") == 0, "protocol 4 should not spam arrival notifications")
assert(notification_count(notifications, "graded 5/12") == 1, "completion should notify exactly once")
assert(notification_count(notifications, "2 additions") == 1, "completion should include additions")
assert(notification_count(notifications, "2 restrictions") == 1, "completion should include restrictions")

assert(suggestion_ops.review_toggle(buf) == true, "review should turn on")
local review = candidate_marks()
assert(mark_with_hl(review, "CintCandidateReview"), "review should use the review highlight")
local lines = virtual_marks(review)
assert(#lines == 4, "review should render every group, got " .. #lines)
local combined = {}
for _, mark in ipairs(lines) do
  combined[#combined + 1] = virtual_text(mark)
end
local function any_line(needle)
  for _, line in ipairs(combined) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end
assert(any_line("+ VALIDATION"), "review should render add operations")
assert(any_line("− LOGGING + SEARCH"), "review should render grouped reclassification")
assert(any_line("ai:fake"), "review should render the source")
assert(any_line("regex find searches the text"), "review should render the rationale")
assert(sign_mark(review, "−"), "review should render a remove sign")
assert(sign_mark(review, "+"), "review should render an add sign")

assert(vim.fn.exists(":CintReviewList") == 2, "CintReviewList command should exist")
assert(vim.fn.exists(":CintSuggestCancel") == 2, "CintSuggestCancel command should exist")
assert(vim.fn.exists(":CintRestrictions") == 2, "CintRestrictions command should exist")
assert(vim.fn.exists(":CintAiLog") == 2, "CintAiLog command should exist")
assert(vim.fn.maparg("]c", "n") ~= "", "]c should be mapped")
assert(vim.fn.maparg("[c", "n") ~= "", "[c should be mapped")
assert(vim.fn.maparg("<Plug>(CintReviewNext)", "n") ~= "", "<Plug> next mapping should exist")

local entries = suggestion_ops.review_entries(buf)
assert(#entries == 4, "review list should include every group")
assert(entries[1].text:find("VALIDATION", 1, true), "review list should label groups")
vim.cmd("CintReviewList")
local quickfix = vim.fn.getqflist()
assert(#quickfix == 4, "review list should populate the quickfix list")
assert(vim.fn.getqflist({ title = 0 }).title ~= nil, "quickfix list should be readable")
assert(vim.fn.getqflist({ context = 0 }).context.cint_review == true, "review list should be marked as cint-owned")
assert(vim.bo[vim.api.nvim_get_current_buf()].buftype == "quickfix", "review list should focus quickfix")

vim.cmd("normal! 3G")
assert(vim.api.nvim_win_get_cursor(0)[1] == 3, "quickfix cursor should move independently of the qf index")
assert(vim.fn.getqflist({ idx = 0 }).idx == 1, "qf index should still be stale after cursor movement")
local next_target = suggestion_ops.review_navigate("next")
assert(next_target ~= false, "quickfix navigation should find a group")
assert(vim.api.nvim_get_current_buf() == buf, "quickfix navigation should jump to the source buffer")
assert(next_target.lnum == 4, "quickfix navigation should use the cursor entry, got " .. next_target.lnum)

vim.cmd("CintReviewList")
assert(vim.bo[vim.api.nvim_get_current_buf()].buftype == "quickfix", "review list should focus quickfix again")
vim.cmd("normal! 3G")
notifications = {}
local before_qf_accept = #decisions
assert(cint.review_accept(), "accept should work from the quickfix window")
assert(vim.wait(2000, function()
  return #decisions == before_qf_accept + 1
end, 10), "quickfix accept should send a decision")
assert(decisions[#decisions].proposalId == "prop-1", "quickfix accept should use the entry under the cursor")
assert(vim.wait(2000, function()
  return notification_count(notifications, "removed LOGGING, added SEARCH (AI)") == 1
end, 10), "quickfix accept should notify only after acceptance")
assert(vim.wait(2000, function()
  return #suggestion_ops.review_entries(buf) == 3
end, 10), "quickfix accept should update the groups")

vim.cmd("CintReviewList")
assert(vim.bo[vim.api.nvim_get_current_buf()].buftype == "quickfix", "review list should focus quickfix for deny")
vim.cmd("normal! G")
notifications = {}
local before_qf_deny = #decisions
assert(cint.review_deny(), "deny should work from the quickfix window")
assert(vim.wait(2000, function()
  return #decisions == before_qf_deny + 1
end, 10), "quickfix deny should send a decision")
assert(decisions[#decisions].proposalId == "prop-2", "quickfix deny should use the entry under the cursor")
assert(decisions[#decisions].decision == "reject", "quickfix deny should reject")
assert(vim.wait(2000, function()
  return notification_count(notifications, "rejected proposal − LOGGING") == 1
end, 10), "quickfix deny should notify only after acceptance")

vim.fn.setqflist({
  { bufnr = buf, lnum = 2, col = 1, text = "unrelated grep hit one" },
  { bufnr = buf, lnum = 3, col = 1, text = "unrelated grep hit two" },
}, "r")
vim.cmd("copen")
assert(vim.bo[vim.api.nvim_get_current_buf()].buftype == "quickfix", "unrelated list should be focused")
vim.cmd("normal! G")
notifications = {}
local before_unrelated = #decisions
assert(not cint.review_accept(), "unrelated quickfix lists must not accept a cint group")
assert(#decisions == before_unrelated, "unrelated quickfix accept must not send a decision")
assert(not suggestion_ops.review_navigate("next"), "unrelated quickfix lists must not be navigated")
assert(vim.bo[vim.api.nvim_get_current_buf()].buftype == "quickfix", "unrelated quickfix navigation must not jump")
assert(notification_count(notifications, "not a cint review list") == 1, "unrelated lists should be rejected explicitly")
vim.cmd("cclose")
vim.api.nvim_set_current_buf(buf)

vim.fn.setloclist(0, {
  { bufnr = buf, lnum = 2, col = 1, text = "unrelated location hit" },
}, "r")
vim.cmd("lopen")
assert(vim.bo[vim.api.nvim_get_current_buf()].buftype == "quickfix", "unrelated location list should be focused")
notifications = {}
local before_location = #decisions
assert(not cint.review_accept(), "unrelated location lists must not accept a cint group")
assert(#decisions == before_location, "unrelated location accept must not send a decision")
assert(not suggestion_ops.review_navigate("next"), "unrelated location lists must not be navigated")
assert(notification_count(notifications, "not a cint review list") == 1, "unrelated location lists should be rejected explicitly")
vim.cmd("lclose")
vim.api.nvim_set_current_buf(buf)

local delay_proposal = proposal({ version = vim.b[buf].changedtick }, "delay-prop", 2)
state.live_candidates[buf] = {
  version = vim.b[buf].changedtick,
  analysisRevision = 55,
  suggestionRevision = 55,
  root = state.live_root,
  candidates = {},
  groups = { delay_proposal },
}
suggestion_ops.render(buf)
vim.api.nvim_win_set_cursor(0, { 3, 0 })
decision_mode = "delay"
notifications = {}
local before_accept = #decisions
assert(cint.review_accept(buf), "accept should apply the proposal under the caret")
local duplicate_ok, duplicate_err = cint.review_accept(buf)
assert(not duplicate_ok, "a second accept while the first is in flight should be rejected")
assert(tostring(duplicate_err):find("already in progress", 1, true), "duplicate accept should explain the in-flight decision")
assert(vim.wait(2000, function()
  return #decisions == before_accept + 1
end, 10), "double accept should send only one decision")
assert(decisions[#decisions].proposalId == "delay-prop", "accept should send the proposal id")
assert(decisions[#decisions].decision == "confirm", "accept should confirm the proposal")
assert(vim.wait(2000, function()
  return notification_count(notifications, "removed LOGGING, added SEARCH (AI)") == 1
end, 10), "accept should report success only after the server accepts")
assert(notification_count(notifications, "removed LOGGING, added SEARCH (AI)") == 1, "accept should not notify twice")
decision_mode = "normal"

local deny_proposal = proposal({ version = vim.b[buf].changedtick }, "deny-prop", 3, {
  operations = {
    operation("REMOVE", "LOGGING", 3, 0, 3, 3, { source = "logging" }),
  },
})
state.live_candidates[buf] = {
  version = vim.b[buf].changedtick,
  analysisRevision = 56,
  suggestionRevision = 56,
  root = state.live_root,
  candidates = {},
  groups = { deny_proposal },
}
suggestion_ops.render(buf)
vim.api.nvim_win_set_cursor(0, { 4, 0 })
notifications = {}
local before_deny = #decisions
assert(cint.review_deny(buf), "deny should reject the proposal under the caret")
assert(vim.wait(2000, function()
  return #decisions == before_deny + 1
end, 10), "deny should send a proposal decision")
assert(decisions[#decisions].proposalId == "deny-prop", "deny should send the proposal id")
assert(decisions[#decisions].decision == "reject", "deny should reject the proposal")
assert(vim.wait(2000, function()
  return notification_count(notifications, "rejected proposal − LOGGING") == 1
end, 10), "deny should report success after the server accepts")

local disabled_proposal = proposal({ version = vim.b[buf].changedtick }, "disabled-prop", 2)
state.live_candidates[buf] = {
  version = vim.b[buf].changedtick,
  analysisRevision = 60,
  suggestionRevision = 60,
  root = state.live_root,
  candidates = {},
  groups = { disabled_proposal },
}
suggestion_ops.render(buf)
vim.api.nvim_win_set_cursor(0, { 3, 0 })
decision_mode = "disabled"
notifications = {}
assert(cint.review_accept(buf), "disabled decision should still be sent")
assert(vim.wait(2000, function()
  return notification_count(notifications, "AI restrictions are disabled") == 1
end, 10), "disabled decision should be reported")
assert(notification_count(notifications, "removed LOGGING") == 0, "disabled decision must not report success")
decision_mode = "normal"

local missing_proposal = proposal({ version = vim.b[buf].changedtick }, "missing-prop", 2)
state.live_candidates[buf] = {
  version = vim.b[buf].changedtick,
  analysisRevision = 61,
  suggestionRevision = 61,
  root = state.live_root,
  candidates = {},
  groups = { missing_proposal },
}
suggestion_ops.render(buf)
vim.api.nvim_win_set_cursor(0, { 3, 0 })
decision_mode = "missing"
notifications = {}
assert(cint.review_accept(buf), "missing decision should still be sent")
assert(vim.wait(2000, function()
  return notification_count(notifications, "proposal is no longer available") == 1
end, 10), "missing decision should be reported")
assert(notification_count(notifications, "removed LOGGING") == 0, "missing decision must not report success")
decision_mode = "normal"

local wide = proposal({ version = vim.b[buf].changedtick }, "wide-prop", 1, {
  startCol = 4,
  endCol = 10,
  operations = {
    operation("REMOVE", "LOGGING", 0, 0, 2, 20, { source = "logging" }),
    operation("ADD", "SEARCH", 1, 4, 1, 10),
  },
})
state.live_candidates[buf] = {
  version = vim.b[buf].changedtick,
  analysisRevision = 62,
  suggestionRevision = 62,
  root = state.live_root,
  candidates = {},
  groups = { wide },
}
suggestion_ops.render(buf)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
notifications = {}
local before_wide = #decisions
assert(cint.review_accept(buf), "a removal span outside the anchor should be selectable")
assert(vim.wait(2000, function()
  return #decisions == before_wide + 1
end, 10), "wide removal span accept should send a decision")
assert(decisions[#decisions].proposalId == "wide-prop", "wide removal span should resolve the proposal")
assert(vim.wait(2000, function()
  return notification_count(notifications, "removed LOGGING, added SEARCH (AI)") == 1
end, 10), "wide removal span should report success")

local wide_deny = proposal({ version = vim.b[buf].changedtick }, "wide-deny", 1, {
  startCol = 4,
  endCol = 10,
  operations = {
    operation("REMOVE", "LOGGING", 0, 0, 2, 20, { source = "logging" }),
  },
})
state.live_candidates[buf] = {
  version = vim.b[buf].changedtick,
  analysisRevision = 63,
  suggestionRevision = 63,
  root = state.live_root,
  candidates = {},
  groups = { wide_deny },
}
suggestion_ops.render(buf)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
notifications = {}
local before_wide_deny = #decisions
assert(cint.review_deny(buf), "a removal span outside the anchor should be deniable")
assert(vim.wait(2000, function()
  return #decisions == before_wide_deny + 1
end, 10), "wide removal span deny should send a decision")
assert(decisions[#decisions].proposalId == "wide-deny", "wide removal span deny should resolve the proposal")
assert(decisions[#decisions].decision == "reject", "wide removal span deny should reject")

local overlap_one = proposal({ version = vim.b[buf].changedtick }, "overlap-1", 1)
local overlap_two = proposal({ version = vim.b[buf].changedtick }, "overlap-2", 1)
state.live_candidates[buf] = {
  version = vim.b[buf].changedtick,
  analysisRevision = 50,
  suggestionRevision = 50,
  root = state.live_root,
  candidates = {},
  groups = { overlap_one, overlap_two },
}
suggestion_ops.render(buf)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local picker_labels = nil
local original_select = vim.ui.select
vim.ui.select = function(items, _, callback)
  picker_labels = items
  callback(items[1], 1)
end
local before_overlap = #decisions
assert(cint.review_accept(buf), "overlapping groups should open a picker")
vim.ui.select = original_select
assert(picker_labels ~= nil and #picker_labels == 2, "picker should list both overlapping groups")
assert(vim.wait(2000, function()
  return #decisions == before_overlap + 1
end, 10), "overlap accept should send a decision")
assert(decisions[#decisions].proposalId == "overlap-1", "overlap picker should confirm the selected group")

local overlap_candidate = candidate({ version = vim.b[buf].changedtick }, {
  candidateId = "cand-overlap",
  source = "ai:fake",
  confidence = 0.9,
  startLine = 1,
  startCol = 0,
  endLine = 1,
  endCol = 10,
})
local overlap_proposal = proposal({ version = vim.b[buf].changedtick }, "prop-overlap", 1, {
  operations = {
    operation("REMOVE", "LOGGING", 1, 0, 1, 10, { source = "logging", confidence = 0.6 }),
    operation("ADD", "SEARCH", 1, 0, 1, 10, { confidence = 0.6 }),
  },
})
state.live_candidates[buf] = {
  version = vim.b[buf].changedtick,
  analysisRevision = 51,
  suggestionRevision = 51,
  root = state.live_root,
  candidates = { overlap_candidate },
  groups = {
    {
      anchorId = "overlap-cand-anchor",
      path = path,
      contentHash = "hash",
      startLine = 1,
      startCol = 0,
      endLine = 1,
      endCol = 10,
      candidates = { overlap_candidate },
    },
    overlap_proposal,
  },
}
suggestion_ops.render(buf)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local deny_labels = nil
vim.ui.select = function(items, _, callback)
  deny_labels = items
  local chosen = 1
  for index, label in ipairs(items) do
    if label:find("− LOGGING", 1, true) then
      chosen = index
      break
    end
  end
  callback(items[chosen], chosen)
end
notifications = {}
local before_overlap_deny = #decisions
assert(cint.review_deny(buf), "overlapping candidate and proposal should open a picker on deny")
vim.ui.select = original_select
assert(deny_labels ~= nil and #deny_labels == 2, "deny picker should list both overlapping groups")
assert(vim.wait(2000, function()
  return #decisions == before_overlap_deny + 1
end, 10), "overlap deny should send one decision")
assert(decisions[#decisions].proposalId == "prop-overlap", "deny picker should reject the selected proposal")
assert(decisions[#decisions].decision == "reject", "overlap deny should reject the proposal")

local restriction_labels = nil
vim.ui.select = function(items, _, callback)
  restriction_labels = items
  callback(items[1], 1)
end
local remove_before = seen["cint/restrictions/remove"] or 0
local change_before = seen["textDocument/didChange"] or 0
vim.cmd("CintRestrictions")
assert(vim.wait(2000, function()
  return (seen["cint/restrictions/remove"] or 0) == remove_before + 1
end, 10), "restriction inspector should send remove")
vim.ui.select = original_select
assert(restriction_labels and #restriction_labels == 2, "inspector should label every restriction")
assert(restriction_labels[1]:find("active", 1, true), "inspector should show restriction status")
assert(restriction_labels[1]:find("− LOGGING", 1, true), "inspector should show removed intents")
assert(not restriction_labels[1]:find("vim.NIL", 1, true), "inspector should not render null fields")
assert(decisions[#decisions].id == "restriction-1", "inspector should remove the selected restriction")
assert(vim.wait(2000, function()
  return restored_after_analysis and (seen["textDocument/didChange"] or 0) > change_before
end, 10), "restriction removal should require a client re-analysis")
assert(vim.wait(2000, function()
  local tags = state.live_tags[buf]
  return tags ~= nil
    and tags.annotations ~= nil
    and tags.annotations[1] ~= nil
    and tags.annotations[1].intents ~= nil
    and tags.annotations[1].intents[1] == "LOGGING"
end, 10), "re-analysis should restore the original annotation")

local before_log = vim.api.nvim_get_current_buf()
assert(cint.ai_log(buf), "ai log should send a request")
assert(vim.wait(2000, function()
  return vim.api.nvim_get_current_buf() ~= before_log
end, 10), "ai log should open a scratch buffer")
local log_buf = vim.api.nvim_get_current_buf()
local log_lines = table.concat(vim.api.nvim_buf_get_lines(log_buf, 0, -1, false), "\n")
assert(log_lines:find("coverage graded 5/12", 1, true), "ai log should show coverage")
assert(log_lines:find("reused 7", 1, true), "ai log should show reuse")
assert(log_lines:find("tool · list_expression_units", 1, true), "ai log should show tool calls")
assert(log_lines:find("verdict", 1, true), "ai log should show verdicts")
assert(not log_lines:find("vim.NIL", 1, true), "ai log should not render null fields")

local saved_protocol = state.live_config_protocol
local saved_suggestions = state.live_suggestions
local list_before = seen["cint/restrictions/list"] or 0
local remove_requests_before = seen["cint/restrictions/remove"] or 0

state.live_config_protocol = 3
local protocol_restrictions_ok, protocol_restrictions_err = cint.restrictions(buf)
assert(not protocol_restrictions_ok, "protocol 3 should reject the restrictions inspector")
assert(tostring(protocol_restrictions_err):find("protocol 4", 1, true), "protocol 3 should name the required protocol")
local protocol_remove_ok, protocol_remove_err = cint.restriction_remove("restriction-1", buf)
assert(not protocol_remove_ok, "protocol 3 should reject restriction removal")
assert(tostring(protocol_remove_err):find("protocol 4", 1, true), "protocol removal should name the required protocol")
assert((seen["cint/restrictions/list"] or 0) == list_before, "protocol 3 must not send restrictions/list")
assert((seen["cint/restrictions/remove"] or 0) == remove_requests_before, "protocol 3 must not send restrictions/remove")

state.live_candidates[buf] = {
  version = vim.b[buf].changedtick,
  analysisRevision = 70,
  suggestionRevision = 70,
  root = state.live_root,
  candidates = {
    candidate({ version = vim.b[buf].changedtick }, { candidateId = "cand-gated", source = "ai:fake" }),
  },
  groups = { proposal({ version = vim.b[buf].changedtick }, "gated-prop", 1) },
}
state.live_suggest_results[buf] = { reused = 7, graded = 5, total = 12 }
state.review_buffers[buf] = nil
assert(suggestion_ops.restriction_count(buf) == 0, "protocol 3 should not count proposal groups")
assert(suggestion_ops.status(buf) == 1, "protocol 3 status should not count proposal groups")
assert(not suggestion_ops.status_text(buf):find("restrictions", 1, true), "protocol 3 status should stay legacy")
suggestion_ops.render(buf)
local gated_marks = candidate_marks()
assert(mark_with_hl(gated_marks, "CintAiCandidate"), "protocol 3 should keep passive AI marks")
assert(sign_mark(gated_marks, "AI"), "protocol 3 should keep the AI sign")
assert(not mark_with_hl(gated_marks, "CintCandidateReview"), "protocol 3 should not render review operations")
state.review_buffers[buf] = true
suggestion_ops.render(buf)
for _, mark in ipairs(virtual_marks(candidate_marks())) do
  assert(not virtual_text(mark):find("− LOGGING", 1, true), "protocol 3 should not render proposal operations")
end
state.review_buffers[buf] = nil

state.live_config_protocol = 4
state.live_suggestions = {
  enabled = true,
  discovery = false,
  restrictions = true,
  cache = false,
}
suggestion_ops.render(buf)
local disabled_marks = candidate_marks()
assert(mark_with_hl(disabled_marks, "CintAiCandidate"), "discovery=false should keep passive AI marks")
assert(sign_mark(disabled_marks, "AI"), "discovery=false should keep the AI sign")
local restricted_status = suggestion_ops.status_text(buf)
assert(restricted_status:find("restrictions", 1, true), "restrictions=true should still count proposals")
assert(not restricted_status:find("reused", 1, true), "cache=false should not show reuse")
assert(not restricted_status:find("coverage", 1, true), "discovery=false should not show coverage")

state.live_suggestions = {
  enabled = true,
  discovery = true,
  restrictions = false,
  cache = false,
}
local no_restrictions_ok, no_restrictions_err = cint.restrictions(buf)
assert(not no_restrictions_ok, "restrictions=false should reject the inspector")
assert(tostring(no_restrictions_err):find("restrictions", 1, true), "disabled restrictions should be named")
local no_remove_ok, no_remove_err = cint.restriction_remove("restriction-1", buf)
assert(not no_remove_ok, "restrictions=false should reject removal")
assert(tostring(no_remove_err):find("restrictions", 1, true), "disabled removal should be named")
assert((seen["cint/restrictions/list"] or 0) == list_before, "disabled restrictions must not send restrictions/list")
assert((seen["cint/restrictions/remove"] or 0) == remove_requests_before, "disabled restrictions must not send remove")

local cache_off_status = suggestion_ops.status_text(buf)
assert(cache_off_status:find("coverage 5/12", 1, true), "discovery=true should show coverage")
assert(not cache_off_status:find("reused", 1, true), "cache=false should omit reuse")

state.live_config_protocol = saved_protocol
state.live_suggestions = saved_suggestions
local progress_params = { uri = path, version = vim.b[buf].changedtick }
local progress_groups = base_groups(progress_params)
state.live_candidates[buf] = {
  version = vim.b[buf].changedtick,
  analysisRevision = 71,
  suggestionRevision = 71,
  root = state.live_root,
  candidates = progress_groups[1].candidates,
  groups = progress_groups,
}
state.live_suggest_results[buf] = nil
suggestion_ops.render(buf)

suggest_mode = "progress"
notifications = {}
assert(suggestion_ops.suggest(buf), "progress suggest should send a request")
assert(vim.wait(1000, function()
  local text = suggestion_ops.status_text(buf)
  return text:find("grading 5/12", 1, true) ~= nil
end, 10), "progress should be visible in status text")
local progress_status = suggestion_ops.status_text(buf)
assert(progress_status:find("reused 7", 1, true), "progress should show reuse")
assert(progress_status:find("reading Sample.kt:2", 1, true), "progress should show activity")
assert(mark_with_hl(candidate_marks(), "CintCandidate"), "progress should not disturb deterministic tags")
assert(vim.wait(2000, function()
  return state.live_suggest_progress[buf] == nil and state.live_suggest_results[buf] ~= nil
end, 10), "progress suggest should complete")
assert(suggestion_ops.progress(buf) == nil, "progress should clear on completion")
local completion = table.concat(
  vim.tbl_map(function(message)
    return message.text
  end, notifications),
  "\n"
)
assert(completion:find("graded 5/12", 1, true), "completion should report graded coverage")
assert(completion:find("2 additions", 1, true), "completion should report additions")
assert(completion:find("2 restrictions", 1, true), "completion should report restrictions")
assert(completion:find("7 reused", 1, true), "completion should report reuse")

suggest_mode = "cancel"
notifications = {}
assert(suggestion_ops.suggest(buf), "cancel suggest should send a request")
assert(vim.wait(1000, function()
  return suggestion_ops.status_text(buf):find("grading 4/12", 1, true) ~= nil
end, 10), "cancel suggest should report progress")
assert(suggestion_ops.cancel(buf), "cancel should send a request")
assert(vim.wait(2000, function()
  return notification_count(notifications, "AI suggestion pass cancelled") > 0
end, 10), "cancellation should be visible")
assert(state.live_suggest_progress[buf] == nil, "cancellation should clear progress")

suggest_mode = "publish"
vim.notify = original_notify
live_ops.live_close(buf)
live.disconnect()
server:close()
pcall(vim.uv.fs_unlink, socket)
print("PASS")
vim.cmd("qa!")
