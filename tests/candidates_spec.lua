local cint = require("cint")
local candidate_render = require("cint.render.candidates")
local live = require("cint.transport.live")
local live_ops = require("cint.ops.live_ops")
local state = require("cint.core.state")
local suggestion_ops = require("cint.ops.suggestion_ops")

cint.setup({ auto_render = false, server_log = false })

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.mkdir(root .. "/.git", "p")
local socket = live.socket_path(root)
pcall(vim.uv.fs_unlink, socket)

local server = vim.uv.new_pipe(false)
assert(server:bind(socket))
local seen = {}
local decisions = {}
local last_candidates = nil
local client = nil

local function reply(message)
  client:write(vim.json.encode(message) .. "\n")
end

local function candidate(version, source, revision)
  return {
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
          knownIntents = { "VALIDATION" },
        },
      },
    })
  elseif message.method == "textDocument/didOpen" then
    publish_tags(message.params, 1)
    publish_candidates(message.params, "rule:validation:validation", 1)
  elseif message.method == "textDocument/didChange" then
    publish_tags(message.params, 2)
    publish_candidates(message.params, "rule:validation:validation", 2)
  elseif message.method == "cint/suggest" then
    publish_candidates(message.params, "ai:fake", 3)
    reply({ jsonrpc = "2.0", id = message.id, result = { accepted = true, count = 1 } })
  elseif message.method == "cint/suggest/cancel" then
    reply({ jsonrpc = "2.0", id = message.id, result = true })
  elseif message.method == "cint/candidates/decide" then
    decisions[#decisions + 1] = message.params
    if message.params.decision == "confirm" then
      publish_tags(message.params, 10, {
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
      publish_candidates(message.params, "rule:validation:validation", 10, {})
    end
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
local marks = vim.api.nvim_buf_get_extmarks(buf, candidate_render.ns, 0, -1, {})
assert(#marks >= 2, "candidates should render underline and sign extmarks")

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

assert(suggestion_ops.suggest(buf), "suggest should send a request")
assert(vim.wait(2000, function()
  return state.live_candidates[buf].candidates[1].source == "ai:fake"
end, 10), "fake provider should enrich the candidate")

local picks = { 1, 1 }
local function picker(items, _, callback)
  local index = table.remove(picks, 1)
  callback(items[index], index)
end
assert(suggestion_ops.review(buf, picker), "review should open")
assert(vim.wait(1000, function()
  return #decisions > 0
end, 10), "confirm should send a decision")
assert(decisions[1].decision == "confirm", "confirm action should be sent")
assert(decisions[1].candidateId == "cand-1", "decision should carry candidate identity")
assert(vim.wait(2000, function()
  return #suggestion_ops.candidates(buf) == 0
    and state.live_tags[buf] ~= nil
    and state.live_tags[buf].analysisRevision == 10
end, 10), "confirm should remove the candidate and republish tags")
local render_marks = vim.api.nvim_buf_get_extmarks(buf, require("cint.render").ns, 0, -1, { details = true })
assert(
  #render_marks > 0,
  "confirm should repaint the established annotation without a text change: "
    .. vim.inspect(render_marks)
    .. " tags="
    .. vim.inspect(state.live_tags[buf])
)
assert(#vim.api.nvim_buf_get_extmarks(buf, candidate_render.ns, 0, -1, {}) == 0, "candidate marks should be cleared")

local alternative_one = candidate(2, "ai:fake", 20)
alternative_one.candidateId = "cand-1"
local alternative_two = candidate(2, "ai:fake", 20)
alternative_two.candidateId = "cand-2"
alternative_two.intents = { "LOGGING" }
state.live_candidates[buf] = {
  version = 2,
  analysisRevision = 20,
  suggestionRevision = 20,
  root = state.live_root,
  candidates = { alternative_one, alternative_two },
  groups = {
    { anchorId = "anchor-1", candidates = { alternative_one, alternative_two } },
  },
}
local alternative_picks = { 1, 2, 1 }
local function alternative_picker(items, _, callback)
  local index = table.remove(alternative_picks, 1)
  callback(items[index], index)
end
assert(suggestion_ops.review(buf, alternative_picker), "alternative review should open")
assert(vim.wait(1000, function()
  return #decisions >= 2
end, 10), "alternative confirm should send a decision")
assert(decisions[#decisions].candidateId == "cand-2", "review should select one alternative per span")

local suggests_before = seen["cint/suggest"] or 0
state.live_config_protocol = 2
local gated, gated_err = suggestion_ops.suggest(buf)
assert(not gated, "protocol 2 should reject suggestions")
assert(tostring(gated_err):find("does not support") ~= nil, "protocol gating should explain")
assert((seen["cint/suggest"] or 0) == suggests_before, "protocol 2 must not send cint/suggest")

live.disconnect()
server:close()
pcall(vim.uv.fs_unlink, socket)
print("PASS")
vim.cmd("qa!")
