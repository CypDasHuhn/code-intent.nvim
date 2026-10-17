local artifact = require("semantic_code_painter.artifact")
local render = require("semantic_code_painter.render")

local M = {}

M.config = {
  artifact = "tags.json",
  root_markers = { ".git" },
  root = nil,
  auto_render = false,
  expand_on_cursor = true,
  handlers = { "color" },
  meanings = {
    CONCEAL = { conceal = { lines = true } },
    HIGHLIGHT = { highlight = true },
    SHOW = { highlight = true },
    IGNORE = { ignore = true },
  },
  tags = {},
}

M._cache = {}
M._rendered = {}
M._active = {}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  M._cache = {}
  render.reset()
  return M
end

local function file_root(path)
  if M.config.root then
    return vim.fs.normalize(M.config.root)
  end
  return artifact.find_root(path, M.config.root_markers) or vim.fs.normalize(vim.fn.getcwd())
end

local function load_artifact(root)
  local file = root .. "/" .. M.config.artifact
  local cached = M._cache[root]
  local art, stat = artifact.load(file)
  if not art then
    return nil
  end
  if cached and cached.mtime == stat.mtime.sec then
    return cached.art
  end
  M._cache[root] = { mtime = stat.mtime.sec, art = art }
  return art
end

local function buffer_hash(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

function M.render()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return
  end
  local root = file_root(path)
  local art = load_artifact(root)
  if not art then
    vim.notify(
      "semantic-code-painter: no " .. M.config.artifact .. " under " .. root,
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
  M._rendered[buf] = spans
  M._active[buf] = nil
  render.render_buffer(buf, spans, M.config)
  M.reveal_block(buf)
  return #spans
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
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local active
  for i, s in ipairs(spans) do
    if render.is_vertical(s, M.config) and row >= s.startLine and row <= s.endLine then
      active = i
      break
    end
  end
  if active == M._active[buf] then
    return
  end
  M._active[buf] = active
  render.render_buffer(buf, spans, M.config, {
    reveal = function(s)
      return row >= s.startLine and row <= s.endLine
    end,
  })
end

function M.discard(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  M._rendered[buf] = nil
  M._active[buf] = nil
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

function M.refresh()
  M._cache = {}
  return M.render()
end

return M
