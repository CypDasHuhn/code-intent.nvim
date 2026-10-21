local profiles = require("cint.core.profiles")
local state = require("cint.core.state")

local M = {}

M.defaults = {
  root_markers = { ".git" },
  root = nil,
  auto_render = false,
  live_lsp = true,
  scope = "project",
  server_cmd = { "cint-server" },
  debounce_ms = 150,
  expand_on_cursor = true,
  handlers = { "color" },
  languages = {
    { language = "kotlin", filetypes = { "kotlin" }, extensions = { ".kt", ".kts" } },
    {
      language = "javascript",
      filetypes = { "javascript", "javascriptreact" },
      extensions = { ".js", ".jsx", ".mjs", ".cjs" },
    },
    { language = "typescript", filetypes = { "typescript" }, extensions = { ".ts", ".mts", ".cts" } },
    { language = "vue", filetypes = { "vue" }, extensions = { ".vue" } },
    { language = "csharp", filetypes = { "cs", "csharp" }, extensions = { ".cs" } },
  },
  resolve = {
    precedence = { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" },
    default = "SHOW",
  },
  rules = {
    CONCEAL = { conceal = { lines = true } },
    HIGHLIGHT = { highlight = true },
    SHOW = false,
    IGNORE = { ignore = true },
  },
  tags = {
    LOGGING = { meaning = "CONCEAL" },
    ERROR_HANDLING = { meaning = "SHOW" },
    BOOKKEEPING = { meaning = "SHOW" },
    DATA_MODIFY = { meaning = "SHOW" },
    LOCAL_VALUE_MODIFY = { meaning = "SHOW" },
    VALIDATION = { meaning = "SHOW" },
    UNTAGGED = { meaning = "SHOW" },
  },
}

M.config = vim.deepcopy(M.defaults)
M.base_config = vim.deepcopy(M.defaults)
M.setup_profiles = {}
M.setup_shards = {}
M.default_profile = "base"
M.global_profile = "base"
M.global_shards = {}
M.keymaps = {}

local function find_root(path, markers)
  local root = vim.fs.root(path, markers)
  if root then
    return vim.fs.normalize(root)
  end
  return nil
end

function M.global_scope()
  return M.base_config.scope == "global"
end

local function global_profiles_path()
  return vim.fs.normalize(vim.fn.stdpath("config") .. "/cint/profiles.lua")
end

local function profiles_path(root)
  return M.global_scope() and global_profiles_path() or profiles.file_path(root)
end

function M.profiles_path(root)
  root = root or M.buffer_root()
  return profiles_path(root)
end

local function file_root(path)
  if M.base_config.root then
    return vim.fs.normalize(M.base_config.root)
  end
  return find_root(path, M.base_config.root_markers) or vim.fs.normalize(vim.fn.getcwd())
end

function M.buffer_root(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return vim.fs.normalize(M.base_config.root or vim.fn.getcwd())
  end
  return file_root(path)
end

function M.get_profiles(root)
  root = root or M.buffer_root()
  local project = profiles.load(root, profiles_path(root))
  local merged = profiles.merge(M.setup_profiles, project.profiles or {})
  return {
    default = project.default or M.default_profile,
    profiles = merged,
  }
end

function M.get_shards(root)
  root = root or M.buffer_root()
  local project = profiles.load(root, profiles_path(root))
  return profiles.merge(M.setup_shards, project.shards or {})
end

function M.shard_names(root)
  local shards = M.get_shards(root)
  local names = {}
  for name in pairs(shards) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

function M.shard_history(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local history = {}
  for _, name in ipairs(M.global_shards or {}) do
    history[#history + 1] = name
  end
  if not M.global_scope() then
    for _, name in ipairs(vim.b[buf].cint_shards or {}) do
      history[#history + 1] = name
    end
  end
  return history
end

function M.profile_names(root)
  root = root or M.buffer_root()
  local data = M.get_profiles(root)
  local names = {}
  for name in pairs(data.profiles) do
    names[#names + 1] = name
  end
  if not data.profiles.base then
    names[#names + 1] = "base"
  end
  table.sort(names)
  return names
end

function M.active_profile(root, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  root = root or M.buffer_root(buf)
  local data = M.get_profiles(root)

  local function exists(name)
    return name == "base" or data.profiles[name] ~= nil
  end

  local buffer_profile = vim.b[buf].cint_profile
  if not M.global_scope() and buffer_profile and exists(buffer_profile) then
    return buffer_profile
  end

  if M.global_profile and exists(M.global_profile) then
    return M.global_profile
  end

  if data.default and exists(data.default) then
    return data.default
  end

  if exists(M.default_profile) then
    return M.default_profile
  end

  for name in pairs(data.profiles) do
    return name
  end
  return "base"
end

function M.resolve_profile(root, name, buf)
  root = root or M.buffer_root(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  name = name or M.active_profile(root, buf)
  local data = M.get_profiles(root)
  local merged = profiles.resolve(M.base_config, data.profiles, name)
  local shards = M.get_shards(root)
  for _, shard_name in ipairs(M.shard_history(buf)) do
    local shard = shards[shard_name]
    if shard then
      merged = profiles.merge(merged, shard)
    end
  end
  merged.profile = name
  return merged
end

function M.config_for(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local cached = state.configs[buf]
  if cached then
    return cached
  end
  local root = M.buffer_root(buf)
  local config = M.resolve_profile(root, M.active_profile(root, buf), buf)
  state.configs[buf] = config
  M.config = config
  return config
end

function M.language_for(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  local filetype = vim.bo[buf].filetype
  for _, entry in ipairs(M.base_config.languages or {}) do
    for _, candidate in ipairs(entry.filetypes or {}) do
      if filetype == candidate then
        return entry.language
      end
    end
  end
  for _, entry in ipairs(M.base_config.languages or {}) do
    for _, extension in ipairs(entry.extensions or {}) do
      if path ~= "" and path:sub(-#extension) == extension then
        return entry.language
      end
    end
  end
  return nil
end

return M
