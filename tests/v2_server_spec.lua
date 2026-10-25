local live = require("cint.transport.live")
local protocol = require("cint.protocol")

local engine_root = vim.env.CINT_ENGINE_ROOT or vim.fn.getcwd() .. "/../code-intent"
local server_bin = vim.env.CINT_SERVER_BIN
  or vim.fn.fnamemodify(
    engine_root .. "/analysis-engine/apps/server/build/install/cint-server/bin/cint-server",
    ":p"
  )

if vim.fn.executable(server_bin) ~= 1 then
  if vim.env.CINT_REQUIRE_SERVER == "1" then
    error(
      "engine protocol check failed: cint-server not installed at "
        .. server_bin
        .. "; run: cd "
        .. engine_root
        .. " && just install"
    )
  end
  print("SKIP V2 cint-server not installed")
  vim.cmd("qa!")
  return
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local initialized = nil
local ready = false
local failure = nil

local connected, connect_error = live.connect(root, {
  server_cmd = { server_bin },
  server_log = false,
}, {
  on_initialize = function(result)
    initialized = result
  end,
  on_ready = function()
    ready = true
  end,
  on_error = function(message)
    failure = message
  end,
})

assert(connected, connect_error or "live.connect should start the V2 server")
assert(vim.wait(15000, function()
  return ready or failure ~= nil
end, 50), "V2 server did not become ready")
assert(failure == nil, failure)
assert(ready, "V2 server never became ready")
assert(initialized ~= nil, "V2 server should return initialize data")
assert(initialized.root == root, "V2 server should report the requested root")
assert(
  initialized.protocol == protocol.version,
  string.format(
    "engine protocol mismatch: expected %d, got %s; regenerate lua/cint/protocol.lua from ../code-intent/analysis-engine/ipc/protocol.schema.json",
    protocol.version,
    tostring(initialized.protocol)
  )
)
assert(
  initialized.fingerprint == protocol.fingerprint,
  string.format(
    "engine schema fingerprint mismatch: expected %s, got %s; refresh the renderer protocol pin",
    protocol.fingerprint,
    tostring(initialized.fingerprint)
  )
)

live.stop_server()
print("PASS")
vim.cmd("qa!")
