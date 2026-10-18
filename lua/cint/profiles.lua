local M = {}

local cache = {}

function M.file_path(root)
  return root .. "/.cint/profiles.lua"
end

function M.load(root, file)
  local path = file or M.file_path(root)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    cache[root] = nil
    return { default = nil, profiles = {}, shards = {} }
  end

  local cached = cache[root]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.data
  end

  local chunk, err = loadfile(path)
  if not chunk then
    vim.notify("cint: " .. err, vim.log.levels.WARN)
    return { default = nil, profiles = {}, shards = {} }
  end

  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" then
    vim.notify("cint: invalid profiles file " .. path, vim.log.levels.WARN)
    return { default = nil, profiles = {}, shards = {} }
  end

  local profile_table = data.profiles
  if profile_table == nil then
    profile_table = vim.deepcopy(data)
    profile_table.default = nil
  end

  local result = {
    default = data.default,
    profiles = profile_table,
    shards = data.shards or {},
  }
  cache[root] = { mtime = stat.mtime.sec, data = result }
  return result
end

function M.invalidate(root)
  if root then
    cache[root] = nil
  else
    cache = {}
  end
end

local function is_list(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  if count == 0 then
    return false
  end
  return value[1] ~= nil and count == #value
end

function M.merge(base, override)
  if type(base) ~= "table" or type(override) ~= "table" then
    return vim.deepcopy(override)
  end
  if is_list(override) then
    return vim.deepcopy(override)
  end

  local result = vim.deepcopy(base)
  for key, value in pairs(override) do
    if type(value) == "table" and type(result[key]) == "table" and not is_list(value) then
      result[key] = M.merge(result[key], value)
    else
      result[key] = vim.deepcopy(value)
    end
  end
  return result
end

function M.resolve(base, profiles, name)
  local seen = {}

  local function resolve_one(profile_name)
    if not profile_name or seen[profile_name] then
      return {}
    end
    seen[profile_name] = true

    local profile = profiles[profile_name]
    if not profile then
      return {}
    end

    local parent = {}
    if profile.extends then
      parent = resolve_one(profile.extends)
    end

    local own = vim.deepcopy(profile)
    own.extends = nil
    return M.merge(parent, own)
  end

  local merged = M.merge(base, resolve_one(name))
  merged.profile = name
  return merged
end

function M.snapshot(config)
  local tags = vim.deepcopy(config.tags or {})
  if config.intentMeanings then
    for intent, meaning in pairs(config.intentMeanings) do
      tags[intent] = tags[intent] or {}
      if type(tags[intent]) == "table" and tags[intent].meaning == nil then
        tags[intent].meaning = meaning
      end
    end
  end
  for _, spec in pairs(tags) do
    if type(spec) == "table" then
      spec.conceal = nil
      spec.highlight = nil
      spec.ignore = nil
    end
  end
  return {
    resolve = vim.deepcopy(config.resolve),
    rules = vim.deepcopy(config.rules),
    tags = tags,
    handlers = vim.deepcopy(config.handlers),
    expand_on_cursor = config.expand_on_cursor,
  }
end

function M.serialize(value)
  return vim.inspect(value)
end

return M
