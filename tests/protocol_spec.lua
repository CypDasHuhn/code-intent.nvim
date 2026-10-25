local protocol = require("cint.protocol")

assert(protocol.version == 5, "renderer must pin engine protocol 5")
assert(type(protocol.fingerprint) == "string" and #protocol.fingerprint == 64, "fingerprint must be a sha256 hex string")
assert(protocol.supports(3), "legacy protocol 3 should be readable")
assert(protocol.supports(4), "legacy protocol 4 should be readable")
assert(protocol.supports(5), "pinned protocol should be supported")
assert(not protocol.supports(1), "protocol 1 must be rejected")
assert(not protocol.supports(2), "protocol 2 must be rejected")
assert(not protocol.supports(0), "protocol 0 must be rejected")
assert(not protocol.supports(6), "future protocol must be rejected")

local ok = protocol.check({ protocol = 5, fingerprint = protocol.fingerprint })
assert(ok, "pinned protocol and fingerprint should be compatible")

local stale, stale_error = protocol.check({ protocol = 5, fingerprint = "stale" })
assert(not stale, "stale fingerprint must be rejected")
assert(stale_error:find("fingerprint mismatch", 1, true), "stale failure must name the fingerprint mismatch")

local legacy = protocol.check({ protocol = 4 })
assert(legacy, "legacy protocol 4 should remain readable without a fingerprint")

local future, future_error = protocol.check({ protocol = 6, fingerprint = protocol.fingerprint })
assert(not future, "future protocol must be rejected")
assert(future_error:find("incompatible engine protocol 6", 1, true), "future failure must name the protocol")

print("PASS")
vim.cmd("qa!")
