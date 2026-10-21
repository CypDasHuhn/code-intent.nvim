local api = require("cint.core.api")
local annotations = require("cint.ops.annotations")
local config = require("cint.core.config")
local config_ops = require("cint.ops.config_ops")
local live_ops = require("cint.ops.live_ops")
local profile_ops = require("cint.ops.profile_ops")
local render_ops = require("cint.ops.render_ops")
local setup = require("cint.ops.setup")
local suggestion_ops = require("cint.ops.suggestion_ops")
local state = require("cint.core.state")

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
alias(state, "_live_config_packs", "live_config_packs")
alias(state, "_live_config_overlay", "live_config_overlay")

expose(render_ops, { "reveal_block", "discard", "clear" })
expose(config_ops, {
  "config_read",
  "config_add",
  "config_remove",
  "config_append",
  "config_remove_value",
  "config_choices",
  "config_remove_choices",
  "config_cache",
  "config_on_initialize",
  "config_supported",
})
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
expose(suggestion_ops, {
  "suggestions_supported",
  "suggestions_descriptor",
  "candidates",
  "candidate_count",
  "groups",
  "suggest",
  "cancel",
  "decide",
  "review",
  "status",
  "status_text",
})
expose(api, { "annotations_at", "provenance_at" })
expose(annotations, {
  "annotate",
  "annotate_range",
  "unannotate",
  "unannotate_range",
  "annotations",
  "file_path",
})
alias(annotations, "annotations_reload", "reload")
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
