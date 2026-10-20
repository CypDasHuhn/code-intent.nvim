local config = require("cint.core.config")
local live = require("cint.transport.live")
local live_ops = require("cint.ops.live_ops")
local profiles = require("cint.core.profiles")
local render = require("cint.render")
local state = require("cint.core.state")

local M = {}

function M.apply_profile()
  state.configs = {}
  render.reset()
  local any = false
  for buf in pairs(state.rendered) do
    if vim.api.nvim_buf_is_loaded(buf) then
      live_ops.render_buf(buf)
      any = true
    end
  end
  if not any then
    live_ops.render()
  end
end

function M.set_profile(name, opts)
  opts = opts or {}
  if not name or name == "" then
    return false
  end

  local buf = vim.api.nvim_get_current_buf()
  local root = config.buffer_root(buf)
  local data = config.get_profiles(root)
  if name ~= "base" and not data.profiles[name] then
    vim.notify("cint: unknown profile " .. name, vim.log.levels.WARN)
    return false
  end

  config.global_shards = {}
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(other) then
      vim.b[other].cint_shards = nil
    end
  end

  local global = opts.global
  if global == nil then
    global = state.rendered[buf] == nil
  end
  if config.global_scope() then
    global = true
  end

  if global then
    config.global_profile = name
    for _, other in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(other) then
        vim.b[other].cint_profile = nil
      end
    end
  else
    vim.b[buf].cint_profile = name
  end

  M.apply_profile()
  vim.notify("cint: profile " .. name, vim.log.levels.INFO)
  return true
end

function M.apply_shard(name, opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local root = config.buffer_root(buf)
  local shards = config.get_shards(root)
  if not shards[name] then
    vim.notify("cint: unknown shard " .. name, vim.log.levels.WARN)
    return false
  end

  if opts.global or config.global_scope() then
    table.insert(config.global_shards, name)
  else
    local history = vim.b[buf].cint_shards or {}
    table.insert(history, name)
    vim.b[buf].cint_shards = history
  end

  M.apply_profile()
  vim.notify("cint: shard " .. name, vim.log.levels.INFO)
  return true
end

function M.undo_shard(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()

  if opts.global or config.global_scope() then
    if #config.global_shards == 0 then
      return false
    end
    table.remove(config.global_shards)
  else
    local history = vim.b[buf].cint_shards or {}
    if #history > 0 then
      table.remove(history)
      vim.b[buf].cint_shards = history
    elseif #config.global_shards > 0 then
      table.remove(config.global_shards)
    else
      return false
    end
  end

  M.apply_profile()
  return true
end

function M.reset_shards()
  config.global_shards = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.b[buf].cint_shards = nil
    end
  end
  M.apply_profile()
end

function M.pick_shard()
  local root = config.buffer_root()
  local names = config.shard_names(root)
  if #names == 0 then
    vim.notify("cint: no shards defined", vim.log.levels.WARN)
    return
  end

  vim.ui.select(names, {
    prompt = "Apply Cint shard",
  }, function(choice)
    if choice then
      M.apply_shard(choice)
    end
  end)
end

function M.pick_profile()
  local buf = vim.api.nvim_get_current_buf()
  local root = config.buffer_root(buf)
  local names = config.profile_names(root)
  local active = config.active_profile(root, buf)

  vim.ui.select(names, {
    prompt = "Cint profile",
    format_item = function(item)
      if item == active then
        return "● " .. item
      end
      return item
    end,
  }, function(choice)
    if choice then
      M.set_profile(choice)
    end
  end)
end

function M.edit_profiles(name)
  local root = config.buffer_root()
  local file = config.profiles_path(root)
  local dir = vim.fs.dirname(file)

  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end

  if vim.fn.filereadable(file) == 0 then
    local active = config.active_profile(root)
    local data = config.get_profiles(root)
    local resolved = profiles.resolve(config.base_config, data.profiles, name or active)
    local seed = {
      default = active,
      profiles = {},
      shards = vim.deepcopy(config.get_shards(root)),
    }
    if next(config.setup_profiles) ~= nil then
      seed.profiles = vim.deepcopy(config.setup_profiles)
    else
      seed.profiles.base = profiles.snapshot(resolved)
    end
    local content = "return " .. profiles.serialize(seed) .. "\n"
    vim.fn.writefile(vim.split(content, "\n", { plain = true }), file)
  end

  vim.cmd.edit(vim.fn.fnameescape(file))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "lua"

  if name then
    vim.fn.search("^\\s*" .. vim.pesc(name) .. "\\s*=", "w")
  end

  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = buf,
    callback = function()
      profiles.invalidate()
      state.configs = {}
      M.apply_profile()
      vim.notify("cint: profiles reloaded", vim.log.levels.INFO)
    end,
  })

  return buf
end

function M.reload_profiles()
  profiles.invalidate()
  state.configs = {}
  render.reset()
  M.apply_profile()
end

function M.profile()
  local buf = vim.api.nvim_get_current_buf()
  return config.active_profile(config.buffer_root(buf), buf)
end

function M.info()
  local buf = vim.api.nvim_get_current_buf()
  local root = config.buffer_root(buf)
  local cfg = state.configs[buf] or config.resolve_profile(root, config.active_profile(root, buf))
  local tags = state.live_tags[buf]
  return {
    profile = cfg.profile,
    root = config.base_config.root or root,
    root_markers = config.base_config.root_markers,
    auto_render = config.base_config.auto_render,
    scope = config.base_config.scope,
    language = config.language_for(buf),
    languages = config.base_config.languages,
    liveConnected = live.is_connected(),
    liveFailed = state.live_failed,
    liveAnnotations = tags and #tags.annotations or 0,
    liveVersion = tags and tags.version or nil,
    shards = config.shard_history(buf),
    tags = cfg.tags,
    resolve = cfg.resolve,
    rules = cfg.rules,
  }
end

return M
