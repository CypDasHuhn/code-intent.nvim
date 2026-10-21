local live = require("cint.transport.live")
local config_ops = require("cint.ops.config_ops")
local state = require("cint.core.state")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local socket = live.socket_path(root)
pcall(vim.uv.fs_unlink, socket)

local server = vim.uv.new_pipe(false)
assert(server:bind(socket))
local seen = {}
local tags = nil
local last_error = nil
local ready = false
local init_result = nil
local config_result = nil
local ready_saw_descriptors = false

local function reply(client, message)
  client:write(vim.json.encode(message) .. "\n")
end

local function publish(client, params, version)
  local message = {
    jsonrpc = "2.0",
    method = "cint/publishTags",
    params = {
      uri = params.uri,
      version = version,
      hash = "fake-" .. tostring(version),
      annotations = {
        {
          role = "source-intent",
          intents = { "LOGGING" },
          startLine = 0,
          startCol = 0,
          endLine = 0,
          endCol = 1,
        },
      },
    },
  }
  local encoded = vim.json.encode(message)
  client:write(encoded:sub(1, 12))
  client:write(encoded:sub(13) .. "\n")
end

local function handle(client, message)
  seen[message.method] = (seen[message.method] or 0) + 1
  if message.method == "initialize" then
    reply(client, {
      jsonrpc = "2.0",
      id = message.id,
      result = {
        protocol = 2,
        root = root,
        config = {
          packs = {
            {
              packId = "logging",
              languages = { "kotlin" },
              rules = { { id = "logging:logging", owns = "LOGGING", reads = {} } },
              fields = {
                { key = "methods", kind = "STRINGS", scope = "LANGUAGE", languages = { "kotlin" } },
              },
            },
          },
          overlay = {},
        },
      },
    })
  elseif message.method == "cint/config/read" then
    reply(client, {
      jsonrpc = "2.0",
      id = message.id,
      result = {
        packs = {},
        overlay = { logging = { kotlin = { methods = { "audit" } } } },
      },
    })
  elseif message.method == "textDocument/didOpen" then
    publish(client, message.params, message.params.version)
    reply(client, {
      jsonrpc = "2.0",
      method = "cint/error",
      params = { message = "fake warning" },
    })
  elseif message.method == "textDocument/didChange" then
    publish(client, message.params, message.params.version)
  elseif message.method == "cint/analyze" then
    publish(client, message.params, message.params.version)
  end
end

server:listen(16, function(listen_err)
  assert(not listen_err, tostring(listen_err))
  local client = vim.uv.new_pipe(false)
  local ok, err = server:accept(client)
  assert(ok, tostring(err))
  local buffered = ""
  client:read_start(function(read_err, data)
    if read_err then
      last_error = tostring(read_err)
      return
    end
    if not data then
      client:close()
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
        local decoded, message = pcall(vim.json.decode, line)
        if decoded and type(message) == "table" then
          handle(client, message)
        end
      end
    end
  end)
end)

local connected, connect_err = live.connect(root, { server_log = false }, {
  on_ready = function()
    ready = true
    ready_saw_descriptors = #state.live_config_packs == 1
  end,
  on_initialize = function(result)
    init_result = result
    config_ops.config_on_initialize(result)
  end,
  on_tags = function(params)
    tags = params
  end,
  on_error = function(message)
    last_error = message
  end,
})
assert(connected, tostring(connect_err))
assert(vim.wait(2000, function()
  return ready and live.is_connected()
end, 10), "live transport should connect")
assert(live.root() == root, "live transport should record the project root")
assert(vim.wait(2000, function()
  return init_result ~= nil and ready
end, 10), "initialize should correlate its response before ready")
assert(init_result.protocol == 2, "initialize should report the current protocol version")
assert(ready_saw_descriptors, "descriptors should be cached when on_ready fires")

local requested = live.request("cint/config/read", {}, function(request_err, result)
  assert(request_err == nil, tostring(request_err))
  config_result = result
end)
assert(requested, "request should write over the transport")
assert(vim.wait(2000, function()
  return config_result ~= nil
end, 10), "request should correlate its response by id")
assert(config_result.overlay.logging.kotlin.methods[1] == "audit", "request should decode its result")

local path = root .. "/Live.kt"
assert(live.open(path, "a\nb\n", 3, "kotlin"), "open should write over the transport")
assert(vim.wait(2000, function()
  return tags ~= nil
end, 10), "didOpen should be answered with publishTags")
assert(seen["textDocument/didOpen"] == 1, "didOpen should reach the server once")
assert(tags.version == 3, "publishTags should carry the analyzed version")
assert(tags.hash == "fake-3", "publishTags should carry the analyzed hash")
assert(#tags.annotations == 1, "publishTags should decode the annotation list")
assert(tags.annotations[1].intents[1] == "LOGGING", "publishTags should decode intents")
assert(vim.wait(1000, function()
  return last_error == "fake warning"
end, 10), "cint/error should be dispatched to on_error")

tags = nil
assert(live.change(path, "a\n", 4, "kotlin"), "change should write over the transport")
assert(vim.wait(2000, function()
  return tags and tags.version == 4
end, 10), "didChange should be answered with publishTags")

local analyzes = seen["cint/analyze"] or 0
assert(live.analyze(path, 4), "analyze should write over the transport")
assert(vim.wait(1000, function()
  return (seen["cint/analyze"] or 0) > analyzes
end, 10), "cint/analyze should reach the server")

local closes = seen["textDocument/didClose"] or 0
assert(live.close(path), "close should write over the transport")
assert(vim.wait(1000, function()
  return (seen["textDocument/didClose"] or 0) > closes
end, 10), "didClose should reach the server")

live.disconnect()
assert(not live.is_connected(), "disconnect should clear the connected state")
assert(live.send({ method = "ignored" }) == false, "send should fail while disconnected")

server:close()
pcall(vim.uv.fs_unlink, socket)
print("PASS")
vim.cmd("qa!")
