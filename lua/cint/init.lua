local api = require("cint.api")
local config = require("cint.config")
local live_ops = require("cint.live_ops")
local profile_ops = require("cint.profile_ops")
local render_ops = require("cint.render_ops")
local setup = require("cint.setup")
local state = require("cint.state")

local M = {}
local owners = {}

local function expose(module, fields)
  for _, field in ipairs(fields) do
    owners[field] = { module = module, key = field }
  end
end

local function alias(module, field, key)
  owners[field] = { module = module, key = key }
end

expose(config, {
  "defaults",
  "config",
  "base_config",
  "setup_profiles",
  "setup_shards",
  "default_profile",
  "global_profile",
  "global_shards",
  "keymaps",
  "global_scope",
  "profiles_path",
  "buffer_root",
  "get_profiles",
  "get_shards",
  "shard_names",
  "shard_history",
  "profile_names",
  "active_profile",
  "resolve_profile",
  "config_for",
  "language_for",
})

alias(state, "_rendered", "rendered")
alias(state, "_active", "active")
alias(state, "_configs", "configs")
alias(state, "_live_tags", "live_tags")
alias(state, "_live_docs", "live_docs")
alias(state, "_live_timers", "live_timers")
alias(state, "_live_ready", "live_ready")
alias(state, "_live_root", "live_root")
alias(state, "_live_failed", "live_failed")

expose(render_ops, { "reveal_block", "discard", "clear" })
expose(live_ops, {
  "live_connect",
  "live_open",
  "live_change",
  "live_request_analysis",
  "live_close",
  "live_on_tags",
  "live_inspect",
  "live_shutdown",
  "live_stop_server",
  "live_restart",
  "live_status",
  "render_buf",
  "render",
  "render_all",
  "toggle",
  "refresh",
})
expose(profile_ops, {
  "apply_profile",
  "set_profile",
  "apply_shard",
  "undo_shard",
  "reset_shards",
  "pick_shard",
  "pick_profile",
  "edit_profiles",
  "reload_profiles",
  "profile",
  "info",
})
expose(api, { "annotations_at", "provenance_at" })
expose(setup, { "setup_keymaps" })

setmetatable(M, {
  __index = function(_, key)
    local owner = owners[key]
    if owner then
      return owner.module[owner.key]
    end
  end,
})

function M.setup(opts)
  setup.run(opts)
  return M
end

return M
