local config = require("cint.core.config")
local live = require("cint.transport.live")
local state = require("cint.core.state")

local M = {}

local APPENDABLE = {
  STRINGS = true,
  STRING_LIST = true,
}

local function lower(value)
  return tostring(value or ""):lower()
end

local function notify(message, level)
  vim.notify("cint: " .. tostring(message), level or vim.log.levels.INFO)
end

local function language_matches(left, right)
  return lower(left) == lower(right)
end

local function pack_supports(pack, language)
  local languages = pack.languages or {}
  if #languages == 0 then
    return true
  end
  for _, candidate in ipairs(languages) do
    if language_matches(candidate, language) then
      return true
    end
  end
  return false
end

local function field_applies(field, language)
  if field.scope == "LANGUAGE" then
    local languages = field.languages or {}
    if #languages == 0 then
      return true
    end
    for _, candidate in ipairs(languages) do
      if language_matches(candidate, language) then
        return true
      end
    end
    return false
  end
  return field.scope == nil or field.scope == "PACK"
end

local function rule_label(pack)
  local labels = {}
  for _, rule in ipairs(pack.rules or {}) do
    labels[#labels + 1] = string.format("%s (%s)", tostring(rule.id), tostring(rule.owns))
  end
  if #labels == 0 then
    return tostring(pack.packId)
  end
  return table.concat(labels, ", ")
end

local function field_label(pack, field)
  return string.format("%s · %s · %s", tostring(pack.packId), rule_label(pack), tostring(field.key))
end

local function sorted_choices(choices)
  table.sort(choices, function(left, right)
    return left.label < right.label
  end)
  return choices
end

local function cache(result)
  if type(result) ~= "table" then
    return
  end
  if type(result.packs) == "table" then
    state.live_config_packs = result.packs
  end
  if type(result.overlay) == "table" then
    state.live_config_overlay = result.overlay
  end
end

local function refresh(buf)
  local live_ops = require("cint.ops.live_ops")
  if not live_ops.live_request_analysis(buf) then
    live_ops.render_buf(buf)
  end
end

local function overlay_language_values(overlay, pack_id, language)
  local pack = overlay[pack_id]
  if type(pack) ~= "table" then
    return nil
  end
  for key, value in pairs(pack) do
    if type(key) == "string" and language_matches(key, language) and type(value) == "table" then
      return value
    end
  end
  return nil
end

local function values(raw)
  if type(raw) == "string" then
    return { raw }
  end
  if type(raw) == "table" then
    local result = {}
    for _, value in ipairs(raw) do
      result[#result + 1] = tostring(value)
    end
    return result
  end
  return {}
end

function M.config_cache(result)
  cache(result)
end

function M.config_supported()
  return (state.live_config_protocol or 0) >= 2
end

function M.config_on_initialize(result)
  local protocol = tonumber(type(result) == "table" and result.protocol) or 0
  state.live_config_protocol = protocol
  if protocol < 2 then
    state.live_config_packs = {}
    state.live_config_overlay = {}
    return
  end
  local data = type(result.config) == "table" and result.config or nil
  if type(data) == "table" then
    cache(data)
    if type(data.overlayError) == "string" then
      notify(data.overlayError, vim.log.levels.WARN)
    end
  end
  if type(data) ~= "table" or type(data.overlay) ~= "table" then
    M.config_read()
  end
end

function M.config_read()
  if not M.config_supported() then
    return false
  end
  return live.request("cint/config/read", {}, function(request_err, result)
    if request_err then
      notify(request_err, vim.log.levels.WARN)
      return
    end
    cache(result)
  end)
end

function M.config_choices(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local language = config.language_for(buf)
  if not language then
    return {}
  end
  local choices = {}
  for _, pack in ipairs(state.live_config_packs or {}) do
    if pack_supports(pack, language) then
      for _, field in ipairs(pack.fields or {}) do
        if APPENDABLE[field.kind] and field_applies(field, language) then
          choices[#choices + 1] = {
            packId = pack.packId,
            language = language,
            field = field.key,
            kind = field.kind,
            scope = field.scope,
            label = field_label(pack, field),
          }
        end
      end
    end
  end
  return sorted_choices(choices)
end

function M.config_remove_choices(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local language = config.language_for(buf)
  if not language then
    return {}
  end
  local overlay = state.live_config_overlay or {}
  local choices = {}
  for _, pack in ipairs(state.live_config_packs or {}) do
    if pack_supports(pack, language) then
      for _, field in ipairs(pack.fields or {}) do
        if APPENDABLE[field.kind] and field_applies(field, language) then
          local raw
          if field.scope == "LANGUAGE" then
            local language_values = overlay_language_values(overlay, pack.packId, language)
            raw = language_values and language_values[field.key] or nil
          else
            local pack_values = overlay[pack.packId]
            raw = type(pack_values) == "table" and pack_values[field.key] or nil
          end
          for _, value in ipairs(values(raw)) do
            choices[#choices + 1] = {
              packId = pack.packId,
              language = language,
              field = field.key,
              value = value,
              label = string.format(
                "%s · %s · %s = %s",
                tostring(pack.packId),
                rule_label(pack),
                tostring(field.key),
                value
              ),
            }
          end
        end
      end
    end
  end
  return sorted_choices(choices)
end

function M.config_append(pack_id, language, field, value, buf)
  if not M.config_supported() then
    notify("live server does not support config mutations", vim.log.levels.WARN)
    return false
  end
  local ok = live.request("cint/config/append", {
    packId = pack_id,
    language = language,
    field = field,
    value = value,
  }, function(request_err, result)
    if request_err then
      notify(request_err, vim.log.levels.WARN)
      return
    end
    cache(result)
    notify(string.format("added %s to %s.%s", value, pack_id, field))
    refresh(buf)
  end)
  if not ok then
    notify("live server is not connected", vim.log.levels.WARN)
    return false
  end
  return true
end

function M.config_remove_value(pack_id, language, field, value, buf)
  if not M.config_supported() then
    notify("live server does not support config mutations", vim.log.levels.WARN)
    return false
  end
  local ok = live.request("cint/config/remove", {
    packId = pack_id,
    language = language,
    field = field,
    value = value,
  }, function(request_err, result)
    if request_err then
      notify(request_err, vim.log.levels.WARN)
      return
    end
    cache(result)
    notify(string.format("removed %s from %s.%s", value, pack_id, field))
    refresh(buf)
  end)
  if not ok then
    notify("live server is not connected", vim.log.levels.WARN)
    return false
  end
  return true
end

function M.config_add(value, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not M.config_supported() then
    return false, "live server does not support config mutations"
  end
  value = vim.trim(value or "")
  if value == "" then
    return false, "no word under cursor"
  end
  local choices = M.config_choices(buf)
  if #choices == 0 then
    return false, "no string config fields for this language"
  end
  local labels = {}
  for index, choice in ipairs(choices) do
    labels[index] = choice.label
  end
  vim.ui.select(labels, { prompt = "cint config add: " .. value }, function(_, index)
    if not index then
      return
    end
    local choice = choices[index]
    M.config_append(choice.packId, choice.language, choice.field, value, buf)
  end)
  return true
end

function M.config_remove(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not M.config_supported() then
    return false, "live server does not support config mutations"
  end
  local choices = M.config_remove_choices(buf)
  if #choices == 0 then
    return false, "no user config overlay values for this language"
  end
  local labels = {}
  for index, choice in ipairs(choices) do
    labels[index] = choice.label
  end
  vim.ui.select(labels, { prompt = "cint config remove" }, function(_, index)
    if not index then
      return
    end
    local choice = choices[index]
    M.config_remove_value(choice.packId, choice.language, choice.field, choice.value, buf)
  end)
  return true
end

return M
