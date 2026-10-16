local M = {}

function M.find_root(path, markers)
  local root = vim.fs.root(path, markers)
  if root then
    return vim.fs.normalize(root)
  end
  return nil
end

function M.relpath(root, path)
  path = vim.fs.normalize(path)
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return path
end

function M.load(file)
  local stat = vim.uv.fs_stat(file)
  if not stat then
    return nil, stat
  end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  end)
  if not ok or type(decoded) ~= "table" then
    return nil, stat
  end
  local index = {}
  for _, f in ipairs(decoded.files or {}) do
    index[f.path] = f.spans or {}
  end
  decoded.index = index
  return decoded, stat
end

return M
