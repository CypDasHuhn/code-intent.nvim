local hover = require("cint.hover")

local M = {}

local function complete_profiles(cint, arglead)
  local names = cint.profile_names()
  local matches = {}
  for _, name in ipairs(names) do
    if name:sub(1, #arglead) == arglead then
      matches[#matches + 1] = name
    end
  end
  return matches
end

local function complete_shards(cint, arglead)
  local names = cint.shard_names()
  local matches = {}
  for _, name in ipairs(names) do
    if name:sub(1, #arglead) == arglead then
      matches[#matches + 1] = name
    end
  end
  return matches
end

local USER_INTENTS = { "PURE", "READONLY" }

local function complete_user_intents(arglead)
  local prefix = vim.trim(arglead or ""):upper()
  local matches = {}
  for _, intent in ipairs(USER_INTENTS) do
    if prefix == "" or intent:sub(1, #prefix) == prefix then
      matches[#matches + 1] = intent
    end
  end
  return matches
end

local function refresh_after_annotation(cint)
  if not cint.live_request_analysis() then
    cint.render()
  end
end

local function annotation_note(args)
  if #args.fargs <= 1 then
    return nil
  end
  return table.concat(args.fargs, " ", 2)
end

function M.register(cint)
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
      return complete_profiles(cint, arglead)
    end,
    desc = "Pick or set a CodeIntent profile",
  })

  vim.api.nvim_create_user_command("CintProfileEdit", function(args)
    cint.edit_profiles(args.args ~= "" and args.args or nil)
  end, {
    nargs = "?",
    complete = function(arglead)
      return complete_profiles(cint, arglead)
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
      return complete_shards(cint, arglead)
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

  vim.api.nvim_create_user_command("CintSuggest", function()
    local ok, err = cint.suggest()
    if not ok and err then
      vim.notify("cint: " .. tostring(err), vim.log.levels.WARN)
    end
  end, { desc = "Request AI intent candidates for the current buffer" })

  vim.api.nvim_create_user_command("CintReview", function()
    cint.review_toggle()
  end, { desc = "Toggle candidate review mode" })

  vim.api.nvim_create_user_command("CintReviewAccept", function(args)
    local ok, err = cint.review_accept(args.args ~= "" and args.args or nil)
    if not ok and err then
      vim.notify("cint: " .. tostring(err), vim.log.levels.WARN)
    end
  end, {
    nargs = "?",
    desc = "Accept the candidate under the cursor, optionally matching an intent",
  })

  vim.api.nvim_create_user_command("CintReviewDeny", function()
    local ok, err = cint.review_deny()
    if not ok and err then
      vim.notify("cint: " .. tostring(err), vim.log.levels.WARN)
    end
  end, { desc = "Reject all candidate alternatives under the cursor" })

  vim.api.nvim_create_user_command("CintReviewList", function()
    cint.review_list()
  end, { desc = "List AI review groups in the quickfix list" })

  vim.api.nvim_create_user_command("CintSuggestCancel", function()
    if not cint.cancel() then
      vim.notify("cint: no AI suggestion pass to cancel", vim.log.levels.INFO)
    end
  end, { desc = "Cancel the running AI suggestion pass" })

  vim.api.nvim_create_user_command("CintRestrictions", function()
    local ok, err = cint.restrictions()
    if not ok and err then
      vim.notify("cint: " .. tostring(err), vim.log.levels.WARN)
    end
  end, { desc = "Inspect and remove active AI restrictions" })

  vim.api.nvim_create_user_command("CintAiLog", function()
    local ok, err = cint.ai_log()
    if not ok and err then
      vim.notify("cint: " .. tostring(err), vim.log.levels.WARN)
    end
  end, { desc = "Show the last AI session log" })

  vim.api.nvim_create_user_command("CintStripes", function()
    local enabled = cint.toggle_stripes()
    vim.notify("cint: mixed-intent stripes " .. (enabled and "on" or "off"), vim.log.levels.INFO)
  end, { desc = "Toggle active-span mixed-intent striping" })

  vim.api.nvim_create_user_command("CintIntentLabels", function()
    local enabled = cint.intent_labels_toggle()
    vim.notify("cint: intent labels " .. (enabled and "on" or "off"), vim.log.levels.INFO)
  end, { desc = "Toggle virtual intent labels above annotations" })

  vim.api.nvim_create_user_command("CintHover", function()
    cint.hover()
  end, { desc = "Show the intents under the cursor in a floating window" })

  vim.api.nvim_create_user_command("CintAnalyze", function()
    if not cint.live_request_analysis() then
      cint.render()
    end
  end, { desc = "Request a fresh live analysis" })

  vim.api.nvim_create_user_command("CintConfigAdd", function()
    local word = vim.fn.expand("<cword>")
    local ok, err = cint.config_add(word)
    if not ok and err then
      vim.notify("cint: " .. tostring(err), vim.log.levels.WARN)
    end
  end, { desc = "Append the word under the cursor to a rulepack config field" })

  vim.api.nvim_create_user_command("CintConfigRemove", function()
    local ok, err = cint.config_remove()
    if not ok and err then
      vim.notify("cint: " .. tostring(err), vim.log.levels.INFO)
    end
  end, { desc = "Remove a user value from a rulepack config overlay" })

  vim.api.nvim_create_user_command("CintServerStatus", function()
    print(vim.inspect(cint.live_status()))
  end, { desc = "Show live analysis server status" })

  vim.api.nvim_create_user_command("CintLiveTags", function()
    local info = cint.live_inspect()
    print(
      string.format(
        "Cint live: connected=%s tags=%d candidates=%d bufferVersion=%s tagVersion=%s extmarks=%d",
        tostring(info.connected),
        #info.annotations,
        info.candidateCount or 0,
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

  vim.api.nvim_create_user_command("CintAnnotate", function(args)
    local intent = args.fargs[1]
    local note = annotation_note(args)
    local ok
    local result
    if args.range > 0 then
      ok, result = cint.annotate_range(intent, note, args.line1 - 1, args.line2 - 1)
    else
      ok, result = cint.annotate(intent, note)
    end
    if not ok then
      vim.notify("cint: " .. tostring(result), vim.log.levels.WARN)
      return
    end
    vim.notify("cint: annotated " .. table.concat(result.intents, ","), vim.log.levels.INFO)
    refresh_after_annotation(cint)
  end, {
    nargs = "+",
    range = true,
    complete = complete_user_intents,
    desc = "Annotate the current symbol or visual range with a user intent",
  })

  vim.api.nvim_create_user_command("CintUnannotate", function(args)
    local ok
    local result
    if args.range > 0 then
      ok, result = cint.unannotate_range(args.line1 - 1, args.line2 - 1)
    else
      ok, result = cint.unannotate()
    end
    if not ok then
      vim.notify("cint: no user annotation removed", vim.log.levels.INFO)
      return
    end
    vim.notify("cint: removed " .. tostring(result) .. " user annotation(s)", vim.log.levels.INFO)
    refresh_after_annotation(cint)
  end, {
    range = true,
    desc = "Remove user annotations at the cursor or visual range",
  })

  vim.api.nvim_create_user_command("CintAnnotations", function()
    local annotations = cint.annotations()
    if #annotations == 0 then
      vim.notify("cint: no user annotations for this buffer", vim.log.levels.INFO)
      return
    end
    local lines = {}
    for _, annotation in ipairs(annotations) do
      lines[#lines + 1] = string.format(
        "%s:%d intents=%s%s",
        annotation.path,
        annotation.startLine + 1,
        table.concat(annotation.intents or {}, ","),
        annotation.note and (" note=" .. annotation.note) or ""
      )
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "List user annotations for this buffer" })

  vim.api.nvim_create_user_command("CintAnnotationsReload", function()
    cint.annotations_reload()
    refresh_after_annotation(cint)
  end, { desc = "Reload user annotations and request a fresh analysis" })

  vim.keymap.set("n", "<Plug>(CintProfilePick)", function()
    cint.pick_profile()
  end, { desc = "Cint: pick profile" })

  vim.keymap.set("n", "<Plug>(CintProfileEdit)", function()
    cint.edit_profiles()
  end, { desc = "Cint: edit profiles" })

  vim.keymap.set("n", "<Plug>(CintShardPick)", function()
    cint.pick_shard()
  end, { desc = "Cint: apply shard" })

  vim.keymap.set("n", "<Plug>(CintHover)", function()
    cint.hover()
  end, { desc = "Cint: show intent hover" })

  vim.keymap.set("n", "<Plug>(CintReviewNext)", function()
    cint.review_navigate("next")
  end, { desc = "Cint: next review group" })

  vim.keymap.set("n", "<Plug>(CintReviewPrev)", function()
    cint.review_navigate("prev")
  end, { desc = "Cint: previous review group" })

  vim.keymap.set("n", "<Plug>(CintReviewAccept)", function()
    local ok, err = cint.review_accept()
    if not ok and err then
      vim.notify("cint: " .. tostring(err), vim.log.levels.WARN)
    end
  end, { desc = "Cint: accept review group" })

  vim.keymap.set("n", "<Plug>(CintReviewDeny)", function()
    local ok, err = cint.review_deny()
    if not ok and err then
      vim.notify("cint: " .. tostring(err), vim.log.levels.WARN)
    end
  end, { desc = "Cint: deny review group" })

  vim.keymap.set("n", "<Plug>(CintReviewList)", function()
    cint.review_list()
  end, { desc = "Cint: list review groups" })

  vim.keymap.set("n", "]c", "<Plug>(CintReviewNext)", { remap = true, desc = "Cint: next review group" })
  vim.keymap.set("n", "[c", "<Plug>(CintReviewPrev)", { remap = true, desc = "Cint: previous review group" })

  local group = vim.api.nvim_create_augroup("cint", { clear = true })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function()
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

  hover.setup_autocmds()
end

return M
