if vim.g.loaded_semantic_code_painter == 1 then
  return
end
vim.g.loaded_semantic_code_painter = 1

local scp = require("semantic_code_painter")

local function complete_profiles(arglead)
  local names = scp.profile_names()
  local matches = {}
  for _, name in ipairs(names) do
    if name:sub(1, #arglead) == arglead then
      matches[#matches + 1] = name
    end
  end
  return matches
end

local function complete_shards(arglead)
  local names = scp.shard_names()
  local matches = {}
  for _, name in ipairs(names) do
    if name:sub(1, #arglead) == arglead then
      matches[#matches + 1] = name
    end
  end
  return matches
end

vim.api.nvim_create_user_command("SCPainterRender", function()
  scp.render()
end, { desc = "Render intent tags for the current buffer" })

vim.api.nvim_create_user_command("SCPainterClear", function()
  scp.clear()
end, { desc = "Clear intent tag decorations" })

vim.api.nvim_create_user_command("SCPainterToggle", function()
  scp.toggle()
end, { desc = "Toggle intent tag decorations" })

vim.api.nvim_create_user_command("SCPainterRefresh", function()
  scp.refresh()
end, { desc = "Reload the tag artifact and re-render" })

vim.api.nvim_create_user_command("SCPainterProfile", function(args)
  if args.args == "" then
    scp.pick_profile()
  else
    scp.set_profile(args.args, { global = args.bang or nil })
  end
end, {
  nargs = "?",
  bang = true,
  complete = function(arglead)
    return complete_profiles(arglead)
  end,
  desc = "Pick or set a Semantic Code Painter profile",
})

vim.api.nvim_create_user_command("SCPainterProfileEdit", function(args)
  scp.edit_profiles(args.args ~= "" and args.args or nil)
end, {
  nargs = "?",
  complete = function(arglead)
    return complete_profiles(arglead)
  end,
  desc = "Edit Semantic Code Painter profiles",
})

vim.api.nvim_create_user_command("SCPainterProfileReload", function()
  scp.reload_profiles()
end, { desc = "Reload profiles and re-render" })

vim.api.nvim_create_user_command("SCPainterShard", function(args)
  if args.args == "" then
    scp.pick_shard()
  else
    scp.apply_shard(args.args, { global = args.bang })
  end
end, {
  nargs = "?",
  bang = true,
  complete = function(arglead)
    return complete_shards(arglead)
  end,
  desc = "Apply a Semantic Code Painter shard",
})

vim.api.nvim_create_user_command("SCPainterShardUndo", function(args)
  scp.undo_shard({ global = args.bang })
end, { bang = true, desc = "Undo the last applied shard" })

vim.api.nvim_create_user_command("SCPainterShardReset", function()
  scp.reset_shards()
end, { desc = "Clear applied shard history" })

vim.api.nvim_create_user_command("SCPainterShardHistory", function()
  print(vim.inspect(scp.shard_history()))
end, { desc = "Show applied shard history" })

vim.api.nvim_create_user_command("SCPainterInfo", function()
  print(vim.inspect(scp.info()))
end, { desc = "Show semantic-code-painter configuration" })

vim.api.nvim_create_user_command("SCPainterAnalyze", function()
  if not scp.live_request_analysis() then
    scp.render()
  end
end, { desc = "Request a fresh live analysis" })

vim.api.nvim_create_user_command("SCPainterServerStatus", function()
  print(vim.inspect(scp.live_status()))
end, { desc = "Show live analysis server status" })

vim.api.nvim_create_user_command("SCPainterServerDisconnect", function()
  scp.live_shutdown()
end, { desc = "Disconnect from the live analysis server" })

vim.keymap.set("n", "<Plug>(SCPainterProfilePick)", function()
  scp.pick_profile()
end, { desc = "SCPainter: pick profile" })

vim.keymap.set("n", "<Plug>(SCPainterProfileEdit)", function()
  scp.edit_profiles()
end, { desc = "SCPainter: edit profiles" })

vim.keymap.set("n", "<Plug>(SCPainterShardPick)", function()
  scp.pick_shard()
end, { desc = "SCPainter: apply shard" })

local group = vim.api.nvim_create_augroup("SemanticCodePainter", { clear = true })
vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  callback = function(args)
    if not scp.base_config.auto_render then
      return
    end
    if scp.base_config.live then
      if not scp.live_open(args.buf) then
        scp.render()
      end
    else
      scp.render()
    end
  end,
})

vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
  group = group,
  callback = function(args)
    if scp.base_config.live then
      scp.live_change(args.buf)
    end
  end,
})

vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  callback = function(args)
    if scp.base_config.live then
      scp.live_request_analysis(args.buf)
    end
  end,
})

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  group = group,
  callback = function()
    scp.reveal_block()
  end,
})

vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
  group = group,
  callback = function(args)
    scp.live_close(args.buf)
    scp.discard(args.buf)
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    scp.live_shutdown()
  end,
})
