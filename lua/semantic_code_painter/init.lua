local artifact = require("semantic_code_painter.artifact")
local render = require("semantic_code_painter.render")
local profiles = require("semantic_code_painter.profiles")

local M = {}

M.defaults = {
  artifact = "tags.json",
  root_markers = { ".git" },
  root = nil,
  auto_render = false,
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
M.default_profile = "base"
M.global_profile = "base"
M.keymaps = {}

M._artifacts = {}
M._rendered = {}
M._active = {}
M._configs = {}

function M.setup(opts)
  opts = opts or {}

  local base = profiles.merge(M.defaults, opts)
  M.setup_profiles = vim.deepcopy(opts.profiles or {})
  M.default_profile = opts.profile or "base"
  M.global_profile = opts.profile
  M.keymaps = opts.keymaps or {}

  base.profiles = nil
  base.profile = nil
  base.keymaps = nil
  base.profile_by = nil

  M.base_config = base
  M.config = vim.deepcopy(base)
  M._artifacts = {}
  M._rendered = {}
  M._active = {}
  M._configs = {}

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

function M.resolve_profile(root, name)
  root = root or M.buffer_root()
  name = name or M.active_profile(root)
  local data = M.get_profiles(root)
  return profiles.resolve(M.base_config, data.profiles, name)
end

function M.config_for(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local root = M.buffer_root(buf)
  local config = M.resolve_profile(root, M.active_profile(root, buf))
  M._configs[buf] = config
  M.config = config
  return config
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
    local config = M.resolve_profile(root, name or active)
    local seed = {
      default = active,
      profiles = {},
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
end

function M.refresh()
  M._artifacts = {}
  profiles.invalidate()
  M._configs = {}
  render.reset()
  return M.render()
end

return M
