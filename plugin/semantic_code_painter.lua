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

vim.api.nvim_create_user_command("SCPainterInfo", function()
  print(vim.inspect(scp.info()))
end, { desc = "Show semantic-code-painter configuration" })

vim.keymap.set("n", "<Plug>(SCPainterProfilePick)", function()
  scp.pick_profile()
end, { desc = "SCPainter: pick profile" })

vim.keymap.set("n", "<Plug>(SCPainterProfileEdit)", function()
  scp.edit_profiles()
end, { desc = "SCPainter: edit profiles" })

local group = vim.api.nvim_create_augroup("SemanticCodePainter", { clear = true })
vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  callback = function()
    if scp.base_config.auto_render then
      scp.render()
    end
  end,
})

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  group = group,
  callback = function()
    scp.reveal_block()
  end,
})

vim.api.nvim_create_autocmd("BufWipeout", {
  group = group,
  callback = function(args)
    scp.discard(args.buf)
  end,
})
