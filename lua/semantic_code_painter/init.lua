local artifact = require("semantic_code_painter.artifact")
local render = require("semantic_code_painter.render")
local colors = require("semantic_code_painter.colors")

local M = {}

M.config = {
  artifact = "tags.json",
  root_markers = { ".git" },
  root = nil,
  auto_render = false,
  colors = {},
}

M._cache = {}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  M._cache = {}
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
  local spans = art.index[artifact.relpath(root, path)] or {}
  for _, span in ipairs(spans) do
    colors.define(span.tag, M.config.colors)
  end
  render.render_buffer(buf, spans)
  return #spans
end

function M.clear()
  render.clear(vim.api.nvim_get_current_buf())
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
