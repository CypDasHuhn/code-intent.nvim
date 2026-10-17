if vim.g.loaded_semantic_code_painter == 1 then
  return
end
vim.g.loaded_semantic_code_painter = 1

local scp = require("semantic_code_painter")

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

vim.api.nvim_create_user_command("SCPainterInfo", function()
  print(vim.inspect({
    artifact = scp.config.artifact,
    root = scp.config.root,
    root_markers = scp.config.root_markers,
    auto_render = scp.config.auto_render,
    intentMeanings = scp.config.intentMeanings,
    resolve = scp.config.resolve,
    rules = scp.config.rules,
  }))
end, { desc = "Show semantic-code-painter configuration" })

local group = vim.api.nvim_create_augroup("SemanticCodePainter", { clear = true })
vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  callback = function()
    if scp.config.auto_render then
      scp.render()
    end
  end,
})

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  group = group,
  callback = function()
    if scp.config.expand_on_cursor then
      scp.reveal_block()
    end
  end,
})

vim.api.nvim_create_autocmd("BufWipeout", {
  group = group,
  callback = function(args)
    scp.discard(args.buf)
  end,
})
