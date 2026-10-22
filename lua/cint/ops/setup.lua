local config = require("cint.core.config")
local hover = require("cint.hover")
local live = require("cint.transport.live")
local profile_ops = require("cint.ops.profile_ops")
local profiles = require("cint.core.profiles")
local render = require("cint.render")
local state = require("cint.core.state")

local M = {}

function M.setup_keymaps()
  local keymaps = config.keymaps or {}
  if keymaps.pick then
    vim.keymap.set("n", keymaps.pick, function()
      profile_ops.pick_profile()
    end, { desc = "Cint: pick profile" })
  end
  if keymaps.edit then
    vim.keymap.set("n", keymaps.edit, function()
      profile_ops.edit_profiles()
    end, { desc = "Cint: edit profiles" })
  end
  if keymaps.shard then
    vim.keymap.set("n", keymaps.shard, function()
      profile_ops.pick_shard()
    end, { desc = "Cint: apply shard" })
  end
end

function M.run(opts)
  opts = opts or {}

  local base = profiles.merge(config.defaults, opts)
  config.setup_profiles = vim.deepcopy(opts.profiles or {})
  config.setup_shards = vim.deepcopy(opts.shards or {})
  config.default_profile = opts.profile or "base"
  config.global_profile = opts.profile
  config.global_shards = {}
  config.keymaps = opts.keymaps or {}

  base.profiles = nil
  base.shards = nil
  base.profile = nil
  base.keymaps = nil

  config.base_config = base
  config.config = vim.deepcopy(base)
  state.reset()
  hover.close()
  live.disconnect()

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.b[buf].cint_profile = nil
      vim.b[buf].cint_shards = nil
    end
  end

  profiles.invalidate()
  render.reset()
  M.setup_keymaps()
  hover.setup_autocmds()
end

return M
