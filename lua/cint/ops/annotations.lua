local config = require("cint.core.config")

local M = {}

local function root_for(buf)
  return config.buffer_root(buf)
end

local function annotations_path(root)
  return root .. "/.cint/user-annotations.json"
end

local function relative_path(root, path)
  path = vim.fs.normalize(path)
  root = vim.fs.normalize(root)
  local relative = vim.fs.relpath(root, path)
  return relative and vim.fs.normalize(relative) or path
end

local function parse_intents(raw)
  local intents = {}
  for token in tostring(raw or ""):gmatch("[^,]+") do
    token = vim.trim(token)
    if token ~= "" then
      intents[#intents + 1] = token
    end
  end
  return intents
end

local function backup(path)
  local base = path .. ".bak-" .. tostring(os.time())
  local candidate = base
  local index = 1
  while vim.uv.fs_stat(candidate) do
    candidate = base .. "-" .. tostring(index)
    index = index + 1
  end
  local copied, result = pcall(vim.uv.fs_copyfile, path, candidate)
  if not copied or not result then
    local input = io.open(path, "rb")
    if input then
      local output = io.open(candidate, "wb")
      if output then
        output:write(input:read("*a"))
        output:close()
      end
      input:close()
    end
  end
  return candidate
end

local function malformed(path, reason)
  local backup_path = backup(path)
  local message = string.format(
    "cint: could not read user annotations (%s); kept the original and wrote a backup to %s",
    reason,
    backup_path
  )
  pcall(vim.notify, message, vim.log.levels.WARN)
  return nil, message
end

local function load(root)
  local path = annotations_path(root)
  local file = io.open(path, "r")
  if not file then
    return {}
  end
  local text = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    return malformed(path, "invalid JSON")
  end
  local entries
  if type(decoded.annotations) == "table" then
    entries = decoded.annotations
  elseif decoded[1] ~= nil or next(decoded) == nil then
    entries = decoded
  end
  if type(entries) ~= "table" then
    return malformed(path, "missing annotations list")
  end
  return entries
end

local function save(root, records)
  local directory = root .. "/.cint"
  vim.fn.mkdir(directory, "p")
  local path = annotations_path(root)
  local temporary = path .. ".tmp"
  local file, err = io.open(temporary, "w")
  if not file then
    return false, err
  end
  file:write(vim.json.encode({ version = 1, annotations = records }))
  file:write("\n")
  file:close()
  local ok, rename_err = os.rename(temporary, path)
  if not ok then
    os.remove(temporary)
    return false, rename_err
  end
  return true
end

local function line_text(buf, row)
  return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

local function symbol_at_cursor(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if buf ~= vim.api.nvim_get_current_buf() then
    return nil
  end
  local symbol = vim.fn.expand("<cword>")
  if symbol == nil or symbol == "" then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]
  local text = line_text(buf, row)
  local from = 1
  local start_col
  local end_col
  while true do
    local first, last = text:find(symbol, from, true)
    if not first then
      break
    end
    if col >= first - 1 and col <= last then
      start_col = first - 1
      end_col = last
      break
    end
    from = last + 1
  end
  if not start_col then
    return nil
  end
  return {
    symbol = symbol,
    text = symbol,
    startLine = row,
    startCol = start_col,
    endLine = row,
    endCol = end_col,
  }
end

local function range_anchor(buf, line1, line2)
  local last = line_text(buf, line2)
  return {
    text = table.concat(vim.api.nvim_buf_get_lines(buf, line1, line2 + 1, false), "\n"),
    startLine = line1,
    startCol = 0,
    endLine = line2,
    endCol = #last,
  }
end

local function content_hash(text)
  local canonical = text:gsub("\r\n", "\n")
  canonical = canonical:gsub("\n$", "")
  return vim.fn.sha256(canonical)
end

local function record_for(buf, intent, note, anchor)
  local root = root_for(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  local intents = parse_intents(intent)
  if #intents == 0 then
    return nil, "an intent name is required"
  end
  if path == "" then
    return nil, "the buffer has no file path"
  end
  local record = {
    path = relative_path(root, path),
    contentHash = content_hash(anchor.text),
    startLine = anchor.startLine,
    startCol = anchor.startCol,
    endLine = anchor.endLine,
    endCol = anchor.endCol,
    intents = intents,
    createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  if anchor.symbol then
    record.symbol = anchor.symbol
  end
  if note and vim.trim(note) ~= "" then
    record.note = vim.trim(note)
  end
  return record
end

local function same_position(record, anchor)
  return record.startLine == anchor.startLine
    and record.startCol == anchor.startCol
    and record.endLine == anchor.endLine
    and record.endCol == anchor.endCol
end

local function same_path(record, path)
  return vim.fs.normalize(record.path) == vim.fs.normalize(path)
end

function M.annotate(intent, note, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local anchor = symbol_at_cursor(buf)
  if not anchor then
    return false, "no symbol under cursor"
  end
  local record, err = record_for(buf, intent, note, anchor)
  if not record then
    return false, err
  end
  local root = root_for(buf)
  local records, load_err = load(root)
  if not records then
    return false, load_err
  end
  local kept = {}
  for _, existing in ipairs(records) do
    local same_symbol = existing.symbol == record.symbol and same_path(existing, record.path)
    if not same_symbol then
      kept[#kept + 1] = existing
    end
  end
  kept[#kept + 1] = record
  local ok, save_err = save(root, kept)
  if not ok then
    return false, save_err
  end
  return true, record
end

function M.annotate_range(intent, note, line1, line2, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local first = math.min(line1, line2)
  local last = math.max(line1, line2)
  line1, line2 = first, last
  local anchor = range_anchor(buf, line1, line2)
  local record, err = record_for(buf, intent, note, anchor)
  if not record then
    return false, err
  end
  local root = root_for(buf)
  local records, load_err = load(root)
  if not records then
    return false, load_err
  end
  local kept = {}
  for _, existing in ipairs(records) do
    if not (same_path(existing, record.path) and same_position(existing, anchor)) then
      kept[#kept + 1] = existing
    end
  end
  kept[#kept + 1] = record
  local ok, save_err = save(root, kept)
  if not ok then
    return false, save_err
  end
  return true, record
end

function M.unannotate(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local root = root_for(buf)
  local path = relative_path(root, vim.api.nvim_buf_get_name(buf))
  local anchor = symbol_at_cursor(buf)
  if not anchor then
    return false, "no symbol under cursor"
  end
  local records, load_err = load(root)
  if not records then
    return false, load_err
  end
  local kept = {}
  local removed = 0
  for _, record in ipairs(records) do
    local matches_path = same_path(record, path)
    local matches_symbol = record.symbol ~= nil and record.symbol == anchor.symbol
    if matches_path and (matches_symbol or same_position(record, anchor)) then
      removed = removed + 1
    else
      kept[#kept + 1] = record
    end
  end
  if removed > 0 then
    local ok, err = save(root, kept)
    if not ok then
      return false, err
    end
  end
  return removed > 0, removed
end

function M.unannotate_range(line1, line2, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local first = math.min(line1, line2)
  local last = math.max(line1, line2)
  line1, line2 = first, last
  local root = root_for(buf)
  local path = relative_path(root, vim.api.nvim_buf_get_name(buf))
  local records, load_err = load(root)
  if not records then
    return false, load_err
  end
  local kept = {}
  local removed = 0
  for _, record in ipairs(records) do
    local contained = record.startLine >= line1 and record.endLine <= line2
    if same_path(record, path) and contained then
      removed = removed + 1
    else
      kept[#kept + 1] = record
    end
  end
  if removed > 0 then
    local ok, err = save(root, kept)
    if not ok then
      return false, err
    end
  end
  return removed > 0, removed
end

function M.annotations(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local root = root_for(buf)
  local path = relative_path(root, vim.api.nvim_buf_get_name(buf))
  local records = load(root) or {}
  local result = {}
  for _, record in ipairs(records) do
    if same_path(record, path) then
      result[#result + 1] = record
    end
  end
  table.sort(result, function(left, right)
    if left.startLine == right.startLine then
      return left.startCol < right.startCol
    end
    return left.startLine < right.startLine
  end)
  return result
end

function M.reload(buf)
  return M.annotations(buf)
end

function M.file_path(buf)
  return annotations_path(root_for(buf or vim.api.nvim_get_current_buf()))
end

return M
