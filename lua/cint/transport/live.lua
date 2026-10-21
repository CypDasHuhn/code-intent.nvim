local M = {}

local state = {
  pipe = nil,
  connected = false,
  connecting = false,
  root = nil,
  buffer = "",
  next_id = 1,
  job = nil,
  callbacks = {},
  pending = {},
}

local function socket_path(root)
  local base = vim.env.XDG_RUNTIME_DIR or "/tmp"
  local ok, uid = pcall(vim.uv.getuid)
  if not ok or not uid then
    uid = (vim.fn.system("id -u"):gsub("%s+$", ""))
  end
  local dir = base .. "/cint-" .. uid
  vim.fn.mkdir(dir, "p")
  pcall(vim.uv.fs_chmod, dir, 448)
  return dir .. "/" .. vim.fn.sha256(root):sub(1, 16) .. ".sock"
end

local function socket_alive(path)
  local ok, chan = pcall(vim.fn.sockconnect, "pipe", path, { rpc = false })
  if ok and chan and chan ~= 0 then
    pcall(vim.fn.chanclose, chan)
    return true
  end
  return false
end

function M.socket_path(root)
  return socket_path(root)
end

local function ensure_server(root, opts)
  local path = socket_path(root)
  if socket_alive(path) then
    return path
  end
  if vim.uv.fs_stat(path) then
    pcall(vim.uv.fs_unlink, path)
  end

  local cmd = opts.server_cmd or { "cint-server" }
  if type(cmd) == "string" then
    cmd = vim.split(cmd, "%s+", { trimempty = true })
  end
  cmd = vim.deepcopy(cmd)
  vim.list_extend(cmd, { "--socket", path, "--root", root })
  if opts.live_lsp == false then
    table.insert(cmd, "--no-lsp")
  end
  if opts.config then
    table.insert(cmd, "--config")
    table.insert(cmd, opts.config)
  end

  local job
  if opts.server_log ~= false then
    local log = opts.server_log
      or (vim.fn.stdpath("log") .. "/cint-live.log")
    vim.fn.mkdir(vim.fn.fnamemodify(log, ":h"), "p")
    local quoted = {}
    for _, part in ipairs(cmd) do
      quoted[#quoted + 1] = vim.fn.shellescape(part)
    end
    job = vim.fn.jobstart({
      "/bin/sh",
      "-c",
      "exec " .. table.concat(quoted, " ") .. " >> " .. vim.fn.shellescape(log) .. " 2>&1",
    }, { detach = true, cwd = root })
  else
    job = vim.fn.jobstart(cmd, { detach = true, cwd = root })
  end
  if job <= 0 then
    return nil, "could not start " .. cmd[1]
  end
  state.job = job

  local started = vim.wait(5000, function()
    return socket_alive(path)
  end, 50)
  if not started then
    return nil, "server did not start"
  end
  return path
end

local function error_text(error)
  if type(error) == "table" then
    return error.message or vim.inspect(error)
  end
  return tostring(error)
end

local function dispatch(message)
  local callbacks = state.callbacks
  if message.id ~= nil then
    local pending = state.pending[message.id]
    if pending then
      state.pending[message.id] = nil
      if message.error then
        pending(error_text(message.error), nil)
      else
        pending(nil, message.result)
      end
    end
    if message.method == nil then
      return
    end
  end
  if message.method == "cint/publishTags" then
    if callbacks.on_tags then
      callbacks.on_tags(message.params)
    end
  elseif message.method == "cint/publishCandidates" then
    if callbacks.on_candidates then
      callbacks.on_candidates(message.params)
    end
  elseif message.method == "cint/error" then
    if callbacks.on_error then
      local text = message.params and message.params.message or "live error"
      callbacks.on_error(text)
    end
  end
end

function M.send(message)
  if not state.connected or not state.pipe then
    return false
  end
  state.pipe:write(vim.json.encode(message) .. "\n")
  return true
end

function M.request(method, params, callback)
  if not state.connected or not state.pipe then
    return false
  end
  local id = state.next_id
  state.next_id = state.next_id + 1
  if callback then
    state.pending[id] = callback
  end
  local sent = M.send({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or vim.empty_dict(),
  })
  if not sent then
    state.pending[id] = nil
  end
  return sent
end

function M.is_connected()
  return state.connected
end

function M.root()
  return state.root
end

function M.disconnect()
  if state.pipe then
    pcall(function()
      state.pipe:read_stop()
      state.pipe:close()
    end)
  end
  state.pipe = nil
  state.connected = false
  state.connecting = false
  state.root = nil
  state.buffer = ""
  state.pending = {}
end

function M.connect(root, opts, callbacks)
  if state.connected and state.root == root then
    state.callbacks = callbacks or state.callbacks
    return true
  end
  if state.connecting and state.root == root then
    state.callbacks = callbacks or state.callbacks
    return true
  end
  if state.pipe then
    M.disconnect()
  end

  state.callbacks = callbacks or {}
  local path, err = ensure_server(root, opts)
  if not path then
    return false, err
  end

  local pipe = vim.uv.new_pipe(false)
  state.pipe = pipe
  state.root = root
  state.buffer = ""
  state.connecting = true

  pipe:connect(path, function(connect_err)
    if connect_err then
      state.connecting = false
      vim.schedule(function()
        if state.callbacks.on_error then
          state.callbacks.on_error(connect_err)
        end
      end)
      M.disconnect()
      return
    end

    state.connected = true
    state.connecting = false
    pipe:read_start(function(read_err, data)
      if read_err then
        vim.schedule(function()
          if state.callbacks.on_error then
            state.callbacks.on_error(read_err)
          end
        end)
        return
      end
      if not data then
        vim.schedule(function()
          if state.pipe ~= pipe then
            return
          end
          if state.callbacks.on_error then
            state.callbacks.on_error("live server disconnected")
          end
          M.disconnect()
        end)
        return
      end
      state.buffer = state.buffer .. data
      while true do
        local newline = state.buffer:find("\n", 1, true)
        if not newline then
          break
        end
        local line = state.buffer:sub(1, newline - 1)
        state.buffer = state.buffer:sub(newline + 1)
        if line ~= "" then
          local ok, message = pcall(vim.json.decode, line)
          if ok then
            vim.schedule(function()
              dispatch(message)
            end)
          end
        end
      end
    end)

    M.request("initialize", { protocol = 3, root = root, client = "nvim" }, function(request_err, result)
      if request_err then
        if state.callbacks.on_error then
          state.callbacks.on_error(request_err)
        end
        return
      end
      if state.callbacks.on_initialize then
        state.callbacks.on_initialize(result)
      end
      vim.schedule(function()
        if state.callbacks.on_ready then
          state.callbacks.on_ready()
        end
      end)
    end)
  end)

  return true
end

function M.open(uri, text, version, language)
  return M.send({
    method = "textDocument/didOpen",
    params = { uri = uri, text = text, version = version, languageId = language },
  })
end

function M.change(uri, text, version, language)
  return M.send({
    method = "textDocument/didChange",
    params = { uri = uri, text = text, version = version, languageId = language },
  })
end

function M.close(uri)
  return M.send({
    method = "textDocument/didClose",
    params = { uri = uri },
  })
end

function M.analyze(uri, version)
  return M.send({
    method = "cint/analyze",
    params = { uri = uri, version = version },
  })
end

function M.shutdown()
  M.send({ jsonrpc = "2.0", id = state.next_id, method = "shutdown" })
  state.next_id = state.next_id + 1
  M.disconnect()
end

function M.stop_server()
  if state.job then
    pcall(vim.fn.jobstop, state.job)
    state.job = nil
  end
  M.disconnect()
end

return M
