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
}

local function socket_path(root)
  local base = vim.env.XDG_RUNTIME_DIR or "/tmp"
  local ok, uid = pcall(vim.uv.getuid)
  if not ok or not uid then
    uid = (vim.fn.system("id -u"):gsub("%s+$", ""))
  end
  local dir = base .. "/semantic-code-painter-" .. uid
  vim.fn.mkdir(dir, "p")
  pcall(vim.uv.fs_chmod, dir, 448)
  return dir .. "/" .. vim.fn.sha256(root):sub(1, 16) .. ".sock"
end

local function ensure_server(root, opts)
  local path = socket_path(root)
  if vim.uv.fs_stat(path) then
    return path
  end

  local cmd = opts.server_cmd or { "semantic-code-painter-server" }
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

  local job = vim.fn.jobstart(cmd, { detach = true, cwd = root })
  if job <= 0 then
    return nil, "could not start " .. cmd[1]
  end
  state.job = job

  local started = vim.wait(5000, function()
    return vim.uv.fs_stat(path) ~= nil
  end, 50)
  if not started then
    return nil, "server did not start"
  end
  return path
end

local function dispatch(message)
  local callbacks = state.callbacks
  if message.method == "semanticPainter/publishTags" then
    if callbacks.on_tags then
      callbacks.on_tags(message.params)
    end
  elseif message.method == "semanticPainter/error" then
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

    M.send({
      jsonrpc = "2.0",
      id = state.next_id,
      method = "initialize",
      params = { protocol = 1, root = root, client = "nvim" },
    })
    state.next_id = state.next_id + 1

    vim.schedule(function()
      if state.callbacks.on_ready then
        state.callbacks.on_ready()
      end
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
    method = "semanticPainter/analyze",
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
