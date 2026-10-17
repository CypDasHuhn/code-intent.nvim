local artifact = require("semantic_code_painter.artifact")
local render = require("semantic_code_painter.render")
local profiles = require("semantic_code_painter.profiles")
local live = require("semantic_code_painter.live")

local M = {}

M.defaults = {
  artifact = "tags.json",
  root_markers = { ".git" },
  root = nil,
  auto_render = false,
  live = false,
  live_lsp = true,
  server_cmd = { "semantic-code-painter-server" },
  debounce_ms = 150,
  expand_on_cursor = true,
  handlers = { "color" },
  resolve = {
    precedence = { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" },
    default = "SHOW",
  },
  rules = {
    CONCEAL = { conceal = { lines = true } },
    HIGHLIGHT = { highlight = true },
    SHOW = { highlight = true },
    IGNORE = { ignore = true },
  },
  tags = {
    Logging = { meaning = "CONCEAL" },
    ErrorHandling = { meaning = "SHOW" },
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

M._artifacts = {}
M._rendered = {}
M._active = {}
M._configs = {}
M._live_tags = {}
M._live_docs = {}
M._live_timers = {}
M._live_ready = false
M._live_root = nil
M._live_failed = false

function M.setup(opts)
  opts = opts or {}

  local base = profiles.merge(M.defaults, opts)
  M.setup_profiles = vim.deepcopy(opts.profiles or {})
  M.setup_shards = vim.deepcopy(opts.shards or {})
  M.default_profile = opts.profile or "base"
  M.global_profile = opts.profile
  M.global_shards = {}
  M.keymaps = opts.keymaps or {}

  base.profiles = nil
  base.shards = nil
  base.profile = nil
  base.keymaps = nil
  base.profile_by = nil

  M.base_config = base
  M.config = vim.deepcopy(base)
  M._artifacts = {}
  M._rendered = {}
  M._active = {}
  M._configs = {}
  M._live_tags = {}
  M._live_docs = {}
  M._live_ready = false
  M._live_root = nil
  M._live_failed = false
  for _, timer in pairs(M._live_timers) do
    pcall(function()
      timer:stop()
      timer:close()
    end)
  end
  M._live_timers = {}
  live.disconnect()

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.b[buf].scp_profile = nil
      vim.b[buf].scp_shards = nil
    end
  end

  profiles.invalidate()
  render.reset()
  M.setup_keymaps()
  return M
end

local function file_root(path)
  if M.base_config.root then
    return vim.fs.normalize(M.base_config.root)
  end
  return artifact.find_root(path, M.base_config.root_markers) or vim.fs.normalize(vim.fn.getcwd())
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
  local project = profiles.load(root)
  local merged = profiles.merge(M.setup_profiles, project.profiles or {})
  return {
    default = project.default or M.default_profile,
    profiles = merged,
  }
end

function M.get_shards(root)
  root = root or M.buffer_root()
  local project = profiles.load(root)
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
  for _, name in ipairs(vim.b[buf].scp_shards or {}) do
    history[#history + 1] = name
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

  local buffer_profile = vim.b[buf].scp_profile
  if buffer_profile and exists(buffer_profile) then
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
  local root = M.buffer_root(buf)
  local config = M.resolve_profile(root, M.active_profile(root, buf), buf)
  M._configs[buf] = config
  M.config = config
  return config
end

local function live_supported(buf)
  if not M.base_config.live then
    return false
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return false
  end
  local filetype = vim.bo[buf].filetype
  return filetype == "kotlin" or path:match("%.kts?$") ~= nil
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function buf_for_path(path)
  path = vim.fs.normalize(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fs.normalize(name) == path then
        return buf
      end
    end
  end
  return nil
end

function M.live_connect(root)
  if not M.base_config.live or M._live_failed then
    return false
  end
  if live.is_connected() and M._live_root == root then
    M._live_ready = true
    return true
  end

  local ok, err = live.connect(root, M.base_config, {
    on_ready = function()
      M._live_ready = true
      M._live_root = root
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and live_supported(buf) and M.buffer_root(buf) == root then
          M.live_open(buf)
        end
      end
    end,
    on_tags = function(params)
      M.live_on_tags(params)
    end,
    on_error = function(message)
      M._live_ready = false
      M._live_docs = {}
      M._live_tags = {}
      vim.notify("semantic-code-painter live: " .. tostring(message), vim.log.levels.WARN)
    end,
  })

  if not ok then
    M._live_ready = false
    M._live_failed = true
    vim.notify("semantic-code-painter live: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

function M.live_open(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not live_supported(buf) then
    return false
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return false
  end
  local root = M.buffer_root(buf)
  if not M.live_connect(root) then
    return false
  end
  if not live.is_connected() then
    return true
  end

  local version = vim.b[buf].changedtick
  local doc = M._live_docs[buf]
  if doc and doc.path == path and doc.version == version then
    return true
  end

  local text = buffer_text(buf)
  M._live_docs[buf] = { path = path, version = version, text = text }
  M._live_tags[buf] = nil
  live.open(path, text, version, "kotlin")
  return true
end

function M.live_change(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not live_supported(buf) then
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return
  end

  local root = M.buffer_root(buf)
  if not M.live_connect(root) then
    return
  end
  if not live.is_connected() then
    return
  end

  local timer = M._live_timers[buf]
  if timer then
    timer:stop()
  else
    timer = vim.uv.new_timer()
    M._live_timers[buf] = timer
  end

  timer:start(M.base_config.debounce_ms or 150, 0, function()
    vim.schedule(function()
      if not vim.api.nvim_buf_is_loaded(buf) then
        return
      end
      if not live_supported(buf) then
        return
      end
      local current_path = vim.api.nvim_buf_get_name(buf)
      local current_root = M.buffer_root(buf)
      if not M.live_connect(current_root) then
        return
      end
      if not live.is_connected() then
        return
      end

      local version = vim.b[buf].changedtick
      local text = buffer_text(buf)
      M._live_docs[buf] = { path = current_path, version = version, text = text }
      live.change(current_path, text, version, "kotlin")
    end)
  end)
end

function M.live_request_analysis(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not live_supported(buf) then
    return false
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return false
  end
  local root = M.buffer_root(buf)
  if not M.live_connect(root) then
    return false
  end
  if not live.is_connected() then
    return false
  end

  local timer = M._live_timers[buf]
  if timer then
    timer:stop()
  end

  local version = vim.b[buf].changedtick
  local text = buffer_text(buf)
  M._live_docs[buf] = { path = path, version = version, text = text }
  live.change(path, text, version, "kotlin")
  return true
end

function M.live_close(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local timer = M._live_timers[buf]
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    M._live_timers[buf] = nil
  end

  local doc = M._live_docs[buf]
  if doc and live.is_connected() then
    live.close(doc.path)
  end
  M._live_docs[buf] = nil
  M._live_tags[buf] = nil
end

function M.live_on_tags(params)
  local buf = buf_for_path(params.uri)
  if not buf then
    return
  end
  local doc = M._live_docs[buf]
  if not doc or params.version ~= doc.version then
    return
  end

  local previous = M._live_tags[buf]
  M._live_tags[buf] = {
    version = params.version,
    hash = params.hash,
    annotations = params.annotations or {},
  }

  if previous and previous.hash == params.hash and M._rendered[buf] ~= nil then
    return
  end

  if
    buf == vim.api.nvim_get_current_buf()
    or M._rendered[buf] ~= nil
    or #vim.fn.win_findbuf(buf) > 0
  then
    local config = M.config_for(buf)
    M._rendered[buf] = params.annotations or {}
    render.render_buffer(buf, params.annotations or {}, config)
    M.reveal_block(buf)
  end
end

function M.live_inspect(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local tags = M._live_tags[buf]
  local doc = M._live_docs[buf]
  local root = M.buffer_root(buf)
  return {
    connected = live.is_connected(),
    failed = M._live_failed,
    liveRoot = M._live_root,
    root = root,
    path = vim.api.nvim_buf_get_name(buf),
    profile = M.active_profile(root, buf),
    shards = M.shard_history(buf),
    bufferVersion = vim.b[buf].changedtick,
    docVersion = doc and doc.version or nil,
    tagVersion = tags and tags.version or nil,
    pending = doc ~= nil and (tags == nil or tags.version ~= doc.version),
    hash = tags and tags.hash or nil,
    annotations = tags and tags.annotations or {},
    rendered = M._rendered[buf] ~= nil,
    extmarks = #vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {}),
  }
end

function M.live_shutdown()
  local bufs = {}
  for buf in pairs(M._live_docs) do
    bufs[#bufs + 1] = buf
  end
  for _, buf in ipairs(bufs) do
    M.live_close(buf)
  end
  live.shutdown()
  M._live_docs = {}
  M._live_tags = {}
  M._live_ready = false
  M._live_root = nil
end

function M.live_status()
  return {
    enabled = M.base_config.live,
    connected = live.is_connected(),
    root = M._live_root,
  }
end

local function load_artifact(root)
  local file = root .. "/" .. M.base_config.artifact
  local cached = M._artifacts[root]
  local art, stat = artifact.load(file)
  if not art then
    return nil
  end
  if cached and cached.mtime == stat.mtime.sec then
    return cached.art
  end
  M._artifacts[root] = { mtime = stat.mtime.sec, art = art }
  return art
end

local function buffer_hash(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

function M.render_buf(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return
  end

  if live_supported(buf) then
    local tags = M._live_tags[buf]
    local version = vim.b[buf].changedtick
    if tags and tags.version == version then
      local config = M.config_for(buf)
      M._rendered[buf] = tags.annotations
      M._active[buf] = nil
      render.render_buffer(buf, tags.annotations, config)
      M.reveal_block(buf)
      return #tags.annotations
    end

    if tags then
      local config = M.config_for(buf)
      M._rendered[buf] = tags.annotations
      render.render_buffer(buf, tags.annotations, config)
      return #tags.annotations
    end

    local root = M.buffer_root(buf)
    if M.live_connect(root) then
      M._rendered[buf] = nil
      render.clear(buf)
      M.live_open(buf)
      M.live_request_analysis(buf)
      return 0
    end
  end

  local root = M.buffer_root(buf)
  local art = load_artifact(root)
  if not art then
    vim.notify(
      "semantic-code-painter: no " .. M.base_config.artifact .. " under " .. root,
      vim.log.levels.WARN
    )
    return
  end

  local rel = artifact.relpath(root, path)
  local expected = art.hashes[rel]
  if expected and expected ~= buffer_hash(buf) then
    render.clear(buf)
    M.discard(buf)
    vim.notify(
      "semantic-code-painter: " .. rel .. " changed since tagging; regenerate tags.json",
      vim.log.levels.WARN
    )
    return 0
  end

  local spans = art.index[rel] or {}
  local config = M.config_for(buf)
  M._rendered[buf] = spans
  M._active[buf] = nil
  render.render_buffer(buf, spans, config)
  M.reveal_block(buf)
  return #spans
end

function M.render()
  return M.render_buf(vim.api.nvim_get_current_buf())
end

function M.render_all()
  for buf in pairs(M._rendered) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.render_buf(buf)
    end
  end
end

function M.reveal_block(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if buf ~= vim.api.nvim_get_current_buf() then
    return
  end
  local spans = M._rendered[buf]
  if not spans then
    return
  end
  local config = M._configs[buf] or M.config_for(buf)
  if not config.expand_on_cursor then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local active
  for i, s in ipairs(spans) do
    if render.is_vertical(s, config) and row >= s.startLine and row <= s.endLine then
      active = i
      break
    end
  end
  if active == M._active[buf] then
    return
  end
  M._active[buf] = active
  render.render_buffer(buf, spans, config, {
    reveal = function(s)
      return row >= s.startLine and row <= s.endLine
    end,
  })
end

function M.discard(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  M._rendered[buf] = nil
  M._active[buf] = nil
  M._configs[buf] = nil
end

function M.clear()
  local buf = vim.api.nvim_get_current_buf()
  render.clear(buf)
  M.discard(buf)
end

function M.toggle()
  local buf = vim.api.nvim_get_current_buf()
  if render.is_rendered(buf) then
    M.clear()
  else
    M.render()
  end
end

function M.apply_profile()
  M._configs = {}
  render.reset()
  local any = false
  for buf in pairs(M._rendered) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.render_buf(buf)
      any = true
    end
  end
  if not any then
    M.render()
  end
end

function M.set_profile(name, opts)
  opts = opts or {}
  if not name or name == "" then
    return false
  end

  local buf = vim.api.nvim_get_current_buf()
  local root = M.buffer_root(buf)
  local data = M.get_profiles(root)
  if name ~= "base" and not data.profiles[name] then
    vim.notify("semantic-code-painter: unknown profile " .. name, vim.log.levels.WARN)
    return false
  end

  M.global_shards = {}
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(other) then
      vim.b[other].scp_shards = nil
    end
  end

  local global = opts.global
  if global == nil then
    global = M._rendered[buf] == nil
  end

  if global then
    M.global_profile = name
    for _, other in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(other) then
        vim.b[other].scp_profile = nil
      end
    end
  else
    vim.b[buf].scp_profile = name
  end

  M.apply_profile()
  vim.notify("semantic-code-painter: profile " .. name, vim.log.levels.INFO)
  return true
end

function M.apply_shard(name, opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local root = M.buffer_root(buf)
  local shards = M.get_shards(root)
  if not shards[name] then
    vim.notify("semantic-code-painter: unknown shard " .. name, vim.log.levels.WARN)
    return false
  end

  if opts.global then
    table.insert(M.global_shards, name)
  else
    local history = vim.b[buf].scp_shards or {}
    table.insert(history, name)
    vim.b[buf].scp_shards = history
  end

  M.apply_profile()
  vim.notify("semantic-code-painter: shard " .. name, vim.log.levels.INFO)
  return true
end

function M.undo_shard(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()

  if opts.global then
    if #M.global_shards == 0 then
      return false
    end
    table.remove(M.global_shards)
  else
    local history = vim.b[buf].scp_shards or {}
    if #history > 0 then
      table.remove(history)
      vim.b[buf].scp_shards = history
    elseif #M.global_shards > 0 then
      table.remove(M.global_shards)
    else
      return false
    end
  end

  M.apply_profile()
  return true
end

function M.reset_shards()
  M.global_shards = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.b[buf].scp_shards = nil
    end
  end
  M.apply_profile()
end

function M.pick_shard()
  local root = M.buffer_root()
  local names = M.shard_names(root)
  if #names == 0 then
    vim.notify("semantic-code-painter: no shards defined", vim.log.levels.WARN)
    return
  end

  vim.ui.select(names, {
    prompt = "Apply SC painter shard",
  }, function(choice)
    if choice then
      M.apply_shard(choice)
    end
  end)
end

function M.pick_profile()
  local buf = vim.api.nvim_get_current_buf()
  local root = M.buffer_root(buf)
  local names = M.profile_names(root)
  local active = M.active_profile(root, buf)

  vim.ui.select(names, {
    prompt = "SCPainter profile",
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
  local root = M.buffer_root()
  local file = profiles.file_path(root)
  local dir = vim.fs.dirname(file)

  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end

  if vim.fn.filereadable(file) == 0 then
    local active = M.active_profile(root)
    local data = M.get_profiles(root)
    local config = profiles.resolve(M.base_config, data.profiles, name or active)
    local seed = {
      default = active,
      profiles = {},
      shards = vim.deepcopy(M.get_shards(root)),
    }
    if next(M.setup_profiles) ~= nil then
      seed.profiles = vim.deepcopy(M.setup_profiles)
    else
      seed.profiles.base = profiles.snapshot(config)
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
      profiles.invalidate(root)
      M._configs = {}
      M.apply_profile()
      vim.notify("semantic-code-painter: profiles reloaded", vim.log.levels.INFO)
    end,
  })

  return buf
end

function M.reload_profiles()
  profiles.invalidate()
  M._configs = {}
  render.reset()
  M.apply_profile()
end

function M.profile()
  local buf = vim.api.nvim_get_current_buf()
  return M.active_profile(M.buffer_root(buf), buf)
end

function M.info()
  local buf = vim.api.nvim_get_current_buf()
  local root = M.buffer_root(buf)
  local config = M._configs[buf] or M.resolve_profile(root, M.active_profile(root, buf))
  return {
    profile = config.profile,
    artifact = M.base_config.artifact,
    root = M.base_config.root or root,
    root_markers = M.base_config.root_markers,
    auto_render = M.base_config.auto_render,
    live = M.base_config.live,
    liveConnected = live.is_connected(),
    liveFailed = M._live_failed,
    liveAnnotations = M._live_tags[buf] and #M._live_tags[buf].annotations or 0,
    liveVersion = M._live_tags[buf] and M._live_tags[buf].version or nil,
    shards = M.shard_history(buf),
    tags = config.tags,
    resolve = config.resolve,
    rules = config.rules,
  }
end

function M.setup_keymaps()
  local keymaps = M.keymaps or {}
  if keymaps.pick then
    vim.keymap.set("n", keymaps.pick, function()
      M.pick_profile()
    end, { desc = "SCPainter: pick profile" })
  end
  if keymaps.edit then
    vim.keymap.set("n", keymaps.edit, function()
      M.edit_profiles()
    end, { desc = "SCPainter: edit profiles" })
  end
  if keymaps.shard then
    vim.keymap.set("n", keymaps.shard, function()
      M.pick_shard()
    end, { desc = "SCPainter: apply shard" })
  end
end

function M.refresh()
  M._artifacts = {}
  profiles.invalidate()
  M._configs = {}
  M._live_failed = false
  render.reset()
  if M.base_config.live and M.live_request_analysis(vim.api.nvim_get_current_buf()) then
    return 0
  end
  return M.render()
end

return M
