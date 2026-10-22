local config = require("cint.core.config")

local M = {}

local function root_for(buf)
  return config.buffer_root(buf)
end

local function annotations_path(root)
  return root .. "/.cint/user-annotations.json"
end

local OWNER_FILE = "owner"
local STALE_MILLIS = 10000
local ACQUIRE_TIMEOUT_MS = 15000
local RETRY_MS = 10
local LOCK_NAME = "user-annotations.json.lock"
local CLAIM_NAME = LOCK_NAME .. ".steal"
local GUARD_NAME = LOCK_NAME .. ".guard"
local TOMBSTONE_MARKER = ".stale-"
local lock_conflict_hook = nil
local lock_before_owner_write_hook = nil
local lock_after_claim_hook = nil
local lock_before_release_hook = nil
local lock_before_release_restore_hook = nil
local lock_acquire_timeout_ms = ACQUIRE_TIMEOUT_MS

math.randomseed(os.time() + math.floor(vim.uv.hrtime() / 1000))

local function annotations_lock_path(root)
  return root .. "/.cint/" .. LOCK_NAME
end

local function annotations_claim_path(root)
  return root .. "/.cint/" .. CLAIM_NAME
end

local function new_token()
  local pid = vim.uv.os_getpid and vim.uv.os_getpid() or 0
  return vim.fn.sha256(table.concat({
    tostring(pid),
    tostring(vim.uv.hrtime()),
    tostring(os.time()),
    tostring(math.random(1, 2147483647)),
    tostring({}),
  }, ":"))
end

local function owner_path(path)
  return path .. "/" .. OWNER_FILE
end

local function process_start_marker(pid)
  local file = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
  if not file then
    return ""
  end
  local text = file:read("*a")
  file:close()
  local close = nil
  local index = 1
  while true do
    local found = text:find(")", index, true)
    if not found then
      break
    end
    close = found
    index = found + 1
  end
  if not close then
    return ""
  end
  local fields = {}
  for token in text:sub(close + 1):gmatch("%S+") do
    fields[#fields + 1] = token
  end
  return fields[20] or ""
end

local function process_alive(pid, start)
  if type(pid) ~= "number" or pid <= 0 then
    return false
  end
  local ok, err = vim.uv.kill(pid, 0)
  if not ok then
    local message = tostring(err or "")
    if message:find("ESRCH", 1, true) then
      return false
    end
    if not message:find("EPERM", 1, true) then
      return false
    end
  end
  if start and start ~= "" then
    local current = process_start_marker(pid)
    if current ~= "" and current ~= start then
      return false
    end
  end
  return true
end

local function owner_text(token)
  local pid = vim.uv.os_getpid and vim.uv.os_getpid() or 0
  return table.concat({
    "token=" .. token,
    "pid=" .. tostring(pid),
    "start=" .. process_start_marker(pid),
  }, "\n") .. "\n"
end

local function read_owner_raw(path)
  local file = io.open(owner_path(path), "r")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

local function parse_owner(text)
  if type(text) ~= "string" then
    return nil
  end
  local fields = {}
  for line in text:gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
    if key then
      fields[key] = value
    end
  end
  local token = fields.token
  local pid = tonumber(fields.pid)
  if not token or #token ~= 64 or not token:match("^[0-9a-f]+$") or not pid then
    return nil
  end
  return { token = token, pid = pid, start = fields.start or "" }
end

local function read_owner(path)
  return parse_owner(read_owner_raw(path))
end

local function cleanup_failed_owner_publish(path, token)
  local raw = read_owner_raw(path)
  local parsed = parse_owner(raw)
  local safe = raw == nil or vim.trim(raw) == "" or (parsed and parsed.token == token)
  if not safe then
    return
  end
  pcall(vim.uv.fs_unlink, owner_path(path))
  pcall(vim.uv.fs_rmdir, path)
end

local function publish_owner(path, token)
  local fd, err = vim.uv.fs_open(owner_path(path), "wx", 420)
  if not fd then
    local message = tostring(err or "")
    if message:find("EEXIST", 1, true) or message:find("ENOENT", 1, true) then
      return false, nil
    end
    return false, message
  end
  local content = owner_text(token)
  local written, write_err = vim.uv.fs_write(fd, content, -1)
  if not written or written ~= #content then
    vim.uv.fs_close(fd)
    cleanup_failed_owner_publish(path, token)
    return false, tostring(write_err)
  end
  vim.uv.fs_close(fd)
  return true, nil
end

local function mtime_millis(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or type(stat.mtime) ~= "table" then
    return nil
  end
  local mtime = stat.mtime
  return (mtime.sec or 0) * 1000 + math.floor((mtime.nsec or 0) / 1000000)
end

local function is_stale(path)
  local owner = read_owner(path)
  if owner then
    return not process_alive(owner.pid, owner.start)
  end
  local directory = mtime_millis(path)
  if not directory then
    return false
  end
  local owner_file = mtime_millis(owner_path(path))
  local modified = owner_file and math.max(directory, owner_file) or directory
  return os.time() * 1000 - modified > STALE_MILLIS
end

local function delete_tree(path)
  local handle = vim.uv.fs_scandir(path)
  if handle then
    while true do
      local name = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local child = path .. "/" .. name
      local stat = vim.uv.fs_stat(child)
      if stat and stat.type == "directory" then
        delete_tree(child)
      else
        pcall(vim.uv.fs_unlink, child)
      end
    end
  end
  pcall(vim.uv.fs_rmdir, path)
end

local function reap_inert(root)
  local directory = root .. "/.cint"
  local handle = vim.uv.fs_scandir(directory)
  if not handle then
    return
  end
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local auxiliary = name ~= LOCK_NAME
      and name ~= CLAIM_NAME
      and (
        name:sub(1, #LOCK_NAME + #TOMBSTONE_MARKER) == LOCK_NAME .. TOMBSTONE_MARKER
        or name:sub(1, #CLAIM_NAME + #TOMBSTONE_MARKER) == CLAIM_NAME .. TOMBSTONE_MARKER
        or name == GUARD_NAME
        or name:sub(1, #GUARD_NAME + #TOMBSTONE_MARKER) == GUARD_NAME .. TOMBSTONE_MARKER
      )
    if auxiliary then
      local path = directory .. "/" .. name
      if is_stale(path) then
        delete_tree(path)
      end
    end
  end
end

local function reap_stale_aux(path, token)
  local observed = read_owner_raw(path)
  local tombstone = path .. TOMBSTONE_MARKER .. token
  local moved = vim.uv.fs_rename(path, tombstone)
  if not moved then
    return true, nil
  end
  if read_owner_raw(tombstone) == observed and is_stale(tombstone) then
    delete_tree(tombstone)
    return true, nil
  end
  local restored = vim.uv.fs_rename(tombstone, path)
  if not restored then
    return nil, "failed to restore " .. path
  end
  return true, nil
end

local function steal_canonical(path, token)
  local tombstone = path .. TOMBSTONE_MARKER .. token
  local moved = vim.uv.fs_rename(path, tombstone)
  if not moved then
    return true, nil
  end
  if is_stale(tombstone) then
    delete_tree(tombstone)
    return true, nil
  end
  local restored = vim.uv.fs_rename(tombstone, path)
  if not restored then
    return nil, "failed to restore lock at " .. path
  end
  return nil, "lock became live during stale steal at " .. path
end

local function release_owned(path, token)
  local tombstone = path .. TOMBSTONE_MARKER .. token
  local observed = read_owner_raw(path)
  local owner = parse_owner(observed)
  if not owner or owner.token ~= token then
    local existing = read_owner(tombstone)
    if existing and existing.token == token then
      delete_tree(tombstone)
      return true, nil
    end
    return false, nil
  end
  if lock_before_release_hook then
    lock_before_release_hook()
  end
  local moved = vim.uv.fs_rename(path, tombstone)
  if not moved then
    local existing = read_owner(tombstone)
    if existing and existing.token == token then
      if not vim.uv.fs_stat(path) then
        delete_tree(tombstone)
        return true, nil
      end
      delete_tree(tombstone)
      moved = vim.uv.fs_rename(path, tombstone)
      if not moved then
        return nil, "failed to release " .. path
      end
    elseif not vim.uv.fs_stat(path) then
      return false, nil
    elseif existing then
      return nil, "tombstone already exists for " .. path
    else
      return nil, "failed to release " .. path
    end
  end
  local moved_owner = read_owner(tombstone)
  if moved_owner and moved_owner.token == token then
    delete_tree(tombstone)
    return true, nil
  end
  if lock_before_release_restore_hook then
    lock_before_release_restore_hook()
  end
  local restored = vim.uv.fs_rename(tombstone, path)
  if not restored then
    return nil, "failed to restore lock at " .. path
  end
  return false, nil
end

local function remove_if_ownerless(path)
  if vim.uv.fs_stat(owner_path(path)) then
    return false
  end
  local ok = vim.uv.fs_rmdir(path)
  return ok and true or false
end

local function try_acquire_claim(claim_path, token, deadline)
  while true do
    if vim.uv.now() > deadline then
      return false, nil
    end
    if vim.uv.fs_stat(claim_path) then
      if not is_stale(claim_path) then
        return false, nil
      end
      local ok, err = reap_stale_aux(claim_path, token)
      if err then
        return nil, err
      end
    else
      local created, mkdir_err = vim.uv.fs_mkdir(claim_path, 448)
      if created then
        local published, publish_err = publish_owner(claim_path, token)
        if published then
          if lock_after_claim_hook then
            lock_after_claim_hook(claim_path)
          end
          return true, nil
        end
        if publish_err then
          return nil, publish_err
        end
        return false, nil
      end
      local message = tostring(mkdir_err or "")
      if not message:find("EEXIST", 1, true) then
        return nil, message
      end
    end
    vim.wait(RETRY_MS)
  end
end

local function acquire_annotations_lock(root, token)
  local lock = annotations_lock_path(root)
  local claim = annotations_claim_path(root)
  local deadline = vim.uv.now() + lock_acquire_timeout_ms
  while true do
    if vim.uv.now() > deadline then
      return nil, "timed out waiting for " .. lock
    end
    if vim.uv.fs_stat(claim) then
      if is_stale(claim) then
        local ok, err = reap_stale_aux(claim, token)
        if err then
          return nil, err
        end
      end
      vim.wait(RETRY_MS)
    else
      local created, mkdir_err = vim.uv.fs_mkdir(lock, 448)
      if created then
        if vim.uv.fs_stat(claim) then
          remove_if_ownerless(lock)
          vim.wait(RETRY_MS)
        else
          if lock_before_owner_write_hook then
            lock_before_owner_write_hook(lock)
          end
          local published, publish_err = publish_owner(lock, token)
          if published then
            return lock
          end
          if publish_err then
            return nil, publish_err
          end
          vim.wait(RETRY_MS)
        end
      else
        local message = tostring(mkdir_err or "")
        if not message:find("EEXIST", 1, true) then
          return nil, message
        end
        if lock_conflict_hook then
          lock_conflict_hook(lock)
        end
        if is_stale(lock) then
          local claimed, claim_err = try_acquire_claim(claim, token, deadline)
          if claim_err then
            return nil, claim_err
          end
          if claimed then
            local failure = nil
            if vim.uv.fs_stat(lock) and is_stale(lock) then
              local stolen, steal_err = steal_canonical(lock, token)
              if not stolen then
                failure = steal_err
              end
            end
            local released, release_err = release_owned(claim, token)
            if not released and release_err and not failure then
              failure = release_err
            end
            if failure then
              return nil, failure
            end
          end
        end
        vim.wait(RETRY_MS)
      end
    end
  end
end

local function with_annotations_lock(root, callback)
  vim.fn.mkdir(root .. "/.cint", "p")
  reap_inert(root)
  local token = new_token()
  local lock, err = acquire_annotations_lock(root, token)
  if not lock then
    return false, err
  end
  reap_inert(root)
  local owner = read_owner(lock)
  if not owner or owner.token ~= token then
    local released, release_err = release_owned(lock, token)
    if not released and release_err then
      return false, release_err
    end
    return false, "lost annotation lock"
  end
  local ok, first, second = pcall(callback, token)
  local released, release_err = release_owned(lock, token)
  if not released and release_err then
    if ok then
      error(release_err)
    end
    pcall(
      vim.notify,
      "cint: failed to release annotation lock: " .. tostring(release_err),
      vim.log.levels.WARN
    )
  end
  if not ok then
    error(first)
  end
  return first, second
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

local function save(root, records, token)
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
  local lock = annotations_lock_path(root)
  local owner = read_owner(lock)
  if not owner or owner.token ~= token then
    os.remove(temporary)
    return false, "lost annotation lock"
  end
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
  local root = root_for(buf)
  return with_annotations_lock(root, function(token)
    local anchor = symbol_at_cursor(buf)
    if not anchor then
      return false, "no symbol under cursor"
    end
    local record, err = record_for(buf, intent, note, anchor)
    if not record then
      return false, err
    end
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
    local ok, save_err = save(root, kept, token)
    if not ok then
      return false, save_err
    end
    return true, record
  end)
end

function M.annotate_range(intent, note, line1, line2, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local first = math.min(line1, line2)
  local last = math.max(line1, line2)
  line1, line2 = first, last
  local root = root_for(buf)
  return with_annotations_lock(root, function(token)
    local anchor = range_anchor(buf, line1, line2)
    local record, err = record_for(buf, intent, note, anchor)
    if not record then
      return false, err
    end
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
    local ok, save_err = save(root, kept, token)
    if not ok then
      return false, save_err
    end
    return true, record
  end)
end

function M.unannotate(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local root = root_for(buf)
  return with_annotations_lock(root, function(token)
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
      local ok, err = save(root, kept, token)
      if not ok then
        return false, err
      end
    end
    return removed > 0, removed
  end)
end

function M.unannotate_range(line1, line2, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local first = math.min(line1, line2)
  local last = math.max(line1, line2)
  line1, line2 = first, last
  local root = root_for(buf)
  return with_annotations_lock(root, function(token)
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
      local ok, err = save(root, kept, token)
      if not ok then
        return false, err
      end
    end
    return removed > 0, removed
  end)
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

function M._release_annotations_lock(root, token)
  vim.fn.mkdir(root .. "/.cint", "p")
  local lock = annotations_lock_path(root)
  return release_owned(lock, token)
end

function M._acquire_lock_for_test(root)
  vim.fn.mkdir(root .. "/.cint", "p")
  reap_inert(root)
  local token = new_token()
  local lock, err = acquire_annotations_lock(root, token)
  if not lock then
    return nil, err
  end
  return token
end

function M._is_lock_stale(root)
  return is_stale(annotations_lock_path(root))
end

function M._process_start_marker(pid)
  return process_start_marker(pid)
end

function M._set_lock_timeout(milliseconds)
  lock_acquire_timeout_ms = milliseconds or ACQUIRE_TIMEOUT_MS
end

function M._set_lock_hooks(hooks)
  hooks = hooks or {}
  lock_conflict_hook = hooks.before_conflict
  lock_before_owner_write_hook = hooks.before_owner_write
  lock_after_claim_hook = hooks.after_claim
  lock_before_release_hook = hooks.before_release
  lock_before_release_restore_hook = hooks.before_release_restore
end

function M._set_lock_conflict_hook(hook)
  lock_conflict_hook = hook
end

return M
