local protocol = require("cint.protocol")

local engine_root = vim.env.CINT_ENGINE_ROOT or vim.fn.getcwd() .. "/../code-intent"
local schema_path = vim.env.CINT_PROTOCOL_SCHEMA
  or engine_root .. "/orchestration/ipc/protocol.schema.json"

if vim.fn.filereadable(schema_path) ~= 1 then
  error(
    "schema pin check failed: missing "
      .. schema_path
      .. "; set CINT_ENGINE_ROOT/CINT_PROTOCOL_SCHEMA or check out the engine repository"
  )
end

local ok, schema = pcall(vim.json.decode, table.concat(vim.fn.readfile(schema_path), "\n"))
assert(ok and type(schema) == "table", "schema pin check failed: invalid JSON at " .. schema_path)
assert(
  schema["x-protocol-version"] == protocol.version,
  string.format(
    "engine protocol mismatch: expected %d, schema says %s; refresh lua/cint/protocol.lua",
    protocol.version,
    tostring(schema["x-protocol-version"])
  )
)
assert(
  schema["x-schema-fingerprint"] == protocol.fingerprint,
  string.format(
    "engine schema fingerprint mismatch: expected %s, schema says %s; refresh lua/cint/protocol.lua",
    protocol.fingerprint,
    tostring(schema["x-schema-fingerprint"])
  )
)

local manifest_path = vim.env.CINT_ENGINE_RELEASE_MANIFEST
if manifest_path and manifest_path ~= "" then
  local manifest_ok, manifest = pcall(vim.json.decode, table.concat(vim.fn.readfile(manifest_path), "\n"))
  assert(manifest_ok and type(manifest) == "table", "release manifest is invalid: " .. manifest_path)
  assert(
    manifest.protocolVersion == protocol.version,
    string.format(
      "release manifest protocol mismatch: expected %d, manifest says %s",
      protocol.version,
      tostring(manifest.protocolVersion)
    )
  )
  assert(
    manifest.protocolFingerprint == protocol.fingerprint,
    string.format(
      "release manifest fingerprint mismatch: expected %s, manifest says %s",
      protocol.fingerprint,
      tostring(manifest.protocolFingerprint)
    )
  )
end

print("PASS")
vim.cmd("qa!")
