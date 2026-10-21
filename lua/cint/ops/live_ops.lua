local config = require("cint.core.config")
local config_ops = require("cint.ops.config_ops")
local live = require("cint.transport.live")
local profiles = require("cint.core.profiles")
local render = require("cint.render")
local render_ops = require("cint.ops.render_ops")
local state = require("cint.core.state")

local M = {}

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
  if state.live_root ~= root then
    state.live_config_packs = {}
    state.live_config_overlay = {}
    state.live_config_protocol = nil
    state.live_tags = {}
  end
  if state.live_failed then
    return false
  end
  if live.is_connected() and state.live_root == root then
    state.live_ready = true
    return true
  end

  local ok, err = live.connect(root, config.base_config, {
    on_ready = function()
      state.live_ready = true
      state.live_root = root
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if
          vim.api.nvim_buf_is_loaded(buf)
          and config.language_for(buf)
          and config.buffer_root(buf) == root
        then
          M.live_open(buf)
        end
      end
    end,
    on_initialize = function(result)
      config_ops.config_on_initialize(result)
    end,
    on_tags = function(params)
      M.live_on_tags(params)
    end,
    on_error = function(message)
      state.live_ready = false
      state.live_docs = {}
      state.live_tags = {}
      vim.notify("cint live: " .. tostring(message), vim.log.levels.WARN)
    end,
  })

  if not ok then
    state.live_ready = false
    state.live_failed = true
    vim.notify("cint live: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

function M.live_open(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local language = config.language_for(buf)
  if not language then
    return false
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return false
  end
  local root = config.buffer_root(buf)
  if not M.live_connect(root) then
    return false
  end
  if not live.is_connected() then
    return true
  end

  local version = vim.b[buf].changedtick
  local doc = state.live_docs[buf]
  if doc and doc.path == path and doc.version == version then
    return true
  end

  local text = buffer_text(buf)
  state.live_docs[buf] = { path = path, version = version, text = text }
  state.live_tags[buf] = nil
  live.open(path, text, version, language)
  return true
end

function M.live_change(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not config.language_for(buf) then
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return
  end

  local root = config.buffer_root(buf)
  if not M.live_connect(root) then
    return
  end
  if not live.is_connected() then
    return
  end

  local timer = state.live_timers[buf]
  if timer then
    timer:stop()
  else
    timer = vim.uv.new_timer()
    state.live_timers[buf] = timer
  end

  timer:start(config.base_config.debounce_ms or 150, 0, function()
    vim.schedule(function()
      if not vim.api.nvim_buf_is_loaded(buf) then
        return
      end
      local current_language = config.language_for(buf)
      if not current_language then
        return
      end
      local current_path = vim.api.nvim_buf_get_name(buf)
      local current_root = config.buffer_root(buf)
      if not M.live_connect(current_root) then
        return
      end
      if not live.is_connected() then
        return
      end

      local version = vim.b[buf].changedtick
      local text = buffer_text(buf)
      state.live_docs[buf] = { path = current_path, version = version, text = text }
      live.change(current_path, text, version, current_language)
    end)
  end)
end

function M.live_request_analysis(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local language = config.language_for(buf)
  if not language then
    return false
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return false
  end
  local root = config.buffer_root(buf)
  if not M.live_connect(root) then
    return false
  end
  if not live.is_connected() then
    return false
  end

  local timer = state.live_timers[buf]
  if timer then
    timer:stop()
  end

  local version = vim.b[buf].changedtick
  local text = buffer_text(buf)
  state.live_docs[buf] = { path = path, version = version, text = text }
  live.change(path, text, version, language)
  return true
end

function M.live_close(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local timer = state.live_timers[buf]
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    state.live_timers[buf] = nil
  end

  local doc = state.live_docs[buf]
  if doc and live.is_connected() then
    live.close(doc.path)
  end
  state.live_docs[buf] = nil
  state.live_tags[buf] = nil
end

function M.live_on_tags(params)
  local buf = buf_for_path(params.uri)
  if not buf then
    return
  end
  local doc = state.live_docs[buf]
  if not doc or params.version ~= doc.version then
    return
  end

  local annotations = params.annotations or {}
  for _, annotation in ipairs(annotations) do
    if annotation.nodeAnchor == vim.NIL then
      annotation.nodeAnchor = nil
    end
  end

  local revision = params.revision or 0
  local root = state.live_root
  local previous = state.live_tags[buf]
  if previous and previous.root and root and previous.root ~= root then
    previous = nil
  end
  -- A slow earlier publish can arrive after a config republish; revisions are
  -- monotonic per document/root, so discard the stale payload.
  if previous and revision < (previous.revision or 0) then
    return
  end
  state.live_tags[buf] = {
    version = params.version,
    hash = params.hash,
    revision = revision,
    root = root,
    annotations = annotations,
  }

  if
    previous
    and previous.hash == params.hash
    and (previous.revision or 0) == revision
    and state.rendered[buf] ~= nil
  then
    return
  end

  if
    buf == vim.api.nvim_get_current_buf()
    or state.rendered[buf] ~= nil
    or #vim.fn.win_findbuf(buf) > 0
  then
    local cfg = config.config_for(buf)
    state.rendered[buf] = annotations
    render_ops.render_spans(buf, annotations, cfg)
  end
end

function M.live_inspect(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local tags = state.live_tags[buf]
  local doc = state.live_docs[buf]
  local root = config.buffer_root(buf)
  return {
    connected = live.is_connected(),
    failed = state.live_failed,
    liveRoot = state.live_root,
    root = root,
    path = vim.api.nvim_buf_get_name(buf),
    profile = config.active_profile(root, buf),
    shards = config.shard_history(buf),
    bufferVersion = vim.b[buf].changedtick,
    docVersion = doc and doc.version or nil,
    tagVersion = tags and tags.version or nil,
    pending = doc ~= nil and (tags == nil or tags.version ~= doc.version),
    hash = tags and tags.hash or nil,
    annotations = tags and tags.annotations or {},
    rendered = state.rendered[buf] ~= nil,
    extmarks = #vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {}),
  }
end

function M.live_shutdown()
  local bufs = {}
  for buf in pairs(state.live_docs) do
    bufs[#bufs + 1] = buf
  end
  for _, buf in ipairs(bufs) do
    M.live_close(buf)
  end
  live.shutdown()
  state.live_docs = {}
  state.live_tags = {}
  state.live_ready = false
  state.live_root = nil
  state.live_config_packs = {}
  state.live_config_overlay = {}
  state.live_config_protocol = nil
end

function M.live_stop_server()
  local buf = vim.api.nvim_get_current_buf()
  local root = state.live_root or config.buffer_root(buf)
  local socket = live.socket_path(root)

  M.live_close(buf)
  live.stop_server()
  live.disconnect()

  local pids = vim.fn.systemlist({
    "pgrep",
    "-f",
    "dev.cint.server.MainKt.*" .. socket,
  })
  for _, pid in ipairs(pids) do
    local number = tonumber(pid)
    if number and number ~= vim.fn.getpid() then
      pcall(vim.uv.kill, number, "sigterm")
    end
  end

  vim.wait(1000, function()
    return vim.uv.fs_stat(socket) == nil
  end, 50)

  state.live_docs = {}
  state.live_tags = {}
  state.live_ready = false
  state.live_root = nil
  state.live_failed = false
  state.live_config_packs = {}
  state.live_config_overlay = {}
  state.live_config_protocol = nil
  return true
end

function M.live_restart()
  M.live_stop_server()
  state.live_failed = false
  return M.render()
end

function M.live_status()
  return {
    supported = config.language_for(vim.api.nvim_get_current_buf()) ~= nil,
    connected = live.is_connected(),
    root = state.live_root,
  }
end

function M.render_buf(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" or not config.language_for(buf) then
    return 0
  end

  local tags = state.live_tags[buf]
  if tags then
    local cfg = config.config_for(buf)
    state.rendered[buf] = tags.annotations
    render_ops.render_spans(buf, tags.annotations, cfg)
    return #tags.annotations
  end

  local root = config.buffer_root(buf)
  if M.live_connect(root) then
    state.rendered[buf] = nil
    render.clear(buf)
    M.live_open(buf)
    M.live_request_analysis(buf)
  end
  return 0
end

function M.render()
  return M.render_buf(vim.api.nvim_get_current_buf())
end

function M.render_all()
  for buf in pairs(state.rendered) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.render_buf(buf)
    end
  end
end

function M.toggle()
  local buf = vim.api.nvim_get_current_buf()
  if render.is_rendered(buf) then
    render_ops.clear()
  else
    M.render()
  end
end

function M.refresh()
  profiles.invalidate()
  state.configs = {}
  state.live_failed = false
  render.reset()
  if M.live_request_analysis(vim.api.nvim_get_current_buf()) then
    return 0
  end
  return M.render()
end

return M
