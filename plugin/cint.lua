if vim.g.loaded_cint == 1 then
  return
end
vim.g.loaded_cint = 1

local cint = require("cint")

local function complete_profiles(arglead)
  local names = cint.profile_names()
  local matches = {}
  for _, name in ipairs(names) do
    if name:sub(1, #arglead) == arglead then
      matches[#matches + 1] = name
    end
  end
  return matches
end

local function complete_shards(arglead)
  local names = cint.shard_names()
  local matches = {}
  for _, name in ipairs(names) do
    if name:sub(1, #arglead) == arglead then
      matches[#matches + 1] = name
    end
  end
  return matches
end

vim.api.nvim_create_user_command("CintRender", function()
  cint.render()
end, { desc = "Render intent tags for the current buffer" })

vim.api.nvim_create_user_command("CintClear", function()
  cint.clear()
end, { desc = "Clear intent tag decorations" })

vim.api.nvim_create_user_command("CintToggle", function()
  cint.toggle()
end, { desc = "Toggle intent tag decorations" })

vim.api.nvim_create_user_command("CintRefresh", function()
  cint.refresh()
end, { desc = "Reconnect and re-analyze the current buffer" })

vim.api.nvim_create_user_command("CintProfile", function(args)
  if args.args == "" then
    cint.pick_profile()
  else
    cint.set_profile(args.args, { global = args.bang or nil })
  end
end, {
  nargs = "?",
  bang = true,
  complete = function(arglead)
    return complete_profiles(arglead)
  end,
  desc = "Pick or set a CodeIntent profile",
})

vim.api.nvim_create_user_command("CintProfileEdit", function(args)
  cint.edit_profiles(args.args ~= "" and args.args or nil)
end, {
  nargs = "?",
  complete = function(arglead)
    return complete_profiles(arglead)
  end,
  desc = "Edit CodeIntent profiles",
})

vim.api.nvim_create_user_command("CintProfileReload", function()
  cint.reload_profiles()
end, { desc = "Reload profiles and re-render" })

vim.api.nvim_create_user_command("CintShard", function(args)
  if args.args == "" then
    cint.pick_shard()
  else
    cint.apply_shard(args.args, { global = args.bang })
  end
end, {
  nargs = "?",
  bang = true,
  complete = function(arglead)
    return complete_shards(arglead)
  end,
  desc = "Apply a CodeIntent shard",
})

vim.api.nvim_create_user_command("CintShardUndo", function(args)
  cint.undo_shard({ global = args.bang })
end, { bang = true, desc = "Undo the last applied shard" })

vim.api.nvim_create_user_command("CintShardReset", function()
  cint.reset_shards()
end, { desc = "Clear applied shard history" })

vim.api.nvim_create_user_command("CintShardHistory", function()
  print(vim.inspect(cint.shard_history()))
end, { desc = "Show applied shard history" })

vim.api.nvim_create_user_command("CintInfo", function()
  print(vim.inspect(cint.info()))
end, { desc = "Show cint configuration" })

vim.api.nvim_create_user_command("CintAnalyze", function()
  if not cint.live_request_analysis() then
    cint.render()
  end
end, { desc = "Request a fresh live analysis" })

vim.api.nvim_create_user_command("CintServerStatus", function()
  print(vim.inspect(cint.live_status()))
end, { desc = "Show live analysis server status" })

vim.api.nvim_create_user_command("CintLiveTags", function()
  local info = cint.live_inspect()
  print(
    string.format(
      "Cint live: connected=%s tags=%d bufferVersion=%s tagVersion=%s extmarks=%d",
      tostring(info.connected),
      #info.annotations,
      tostring(info.bufferVersion),
      tostring(info.tagVersion),
      info.extmarks
    )
  )

  vim.cmd("new")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(vim.inspect(info), "\n", { plain = true }))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "lua"
  vim.bo[buf].modifiable = false
end, { desc = "Inspect live tags for the current buffer" })

vim.api.nvim_create_user_command("CintServerDisconnect", function()
  cint.live_shutdown()
end, { desc = "Disconnect from the live analysis server" })

vim.api.nvim_create_user_command("CintServerStop", function()
  cint.live_stop_server()
  print("cint: stopped live analysis server")
end, { desc = "Stop the live analysis daemon" })

vim.api.nvim_create_user_command("CintServerRestart", function()
  cint.live_restart()
  print("cint: restarting live analysis server")
end, { desc = "Restart the live analysis daemon" })

vim.keymap.set("n", "<Plug>(CintProfilePick)", function()
  cint.pick_profile()
end, { desc = "Cint: pick profile" })

vim.keymap.set("n", "<Plug>(CintProfileEdit)", function()
  cint.edit_profiles()
end, { desc = "Cint: edit profiles" })

vim.keymap.set("n", "<Plug>(CintShardPick)", function()
  cint.pick_shard()
end, { desc = "Cint: apply shard" })

local group = vim.api.nvim_create_augroup("SemanticCodePainter", { clear = true })
vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  callback = function(args)
    if not cint.base_config.auto_render then
      return
    end
    cint.render()
  end,
})

vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
  group = group,
  callback = function(args)
    cint.live_change(args.buf)
  end,
})

vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  callback = function(args)
    cint.live_request_analysis(args.buf)
  end,
})

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  group = group,
  callback = function()
    cint.reveal_block()
  end,
})

vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
  group = group,
  callback = function(args)
    cint.live_close(args.buf)
    cint.discard(args.buf)
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    cint.live_shutdown()
  end,
})
