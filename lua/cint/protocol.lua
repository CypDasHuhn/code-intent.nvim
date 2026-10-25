local M = {
  version = 5,
  fingerprint = "ce1e3590ccbbd9e08784f09ec7c7f9e514e26ddd9488ef1216644b9d853d48b5",
  supported = { 3, 4, 5 },
}

function M.supports(value)
  local version = tonumber(value)
  if not version then
    return false
  end
  for _, candidate in ipairs(M.supported) do
    if candidate == version then
      return true
    end
  end
  return false
end

function M.check(result)
  local version = tonumber(type(result) == "table" and result.protocol) or 0
  if not M.supports(version) then
    return false,
      string.format(
        "incompatible engine protocol %s; code-intent-nvim supports %d..%d (pinned %d)",
        tostring(version),
        M.supported[1],
        M.supported[#M.supported],
        M.version
      )
  end
  if version == M.version and result.fingerprint ~= M.fingerprint then
    return false,
      string.format(
        "protocol %d fingerprint mismatch; expected %s, got %s",
        M.version,
        M.fingerprint,
        tostring(result.fingerprint)
      )
  end
  return true
end

return M
