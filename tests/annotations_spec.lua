local cint = require("cint")
local annotations = require("cint.ops.annotations")
local render = require("cint.render")

local function write(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local function read(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return text
end

local function write_lock(lock_path, token, pid, start)
  vim.fn.mkdir(lock_path, "p")
  write(lock_path .. "/owner", "token=" .. token .. "\npid=" .. tostring(pid) .. "\nstart=" .. tostring(start or "") .. "\n")
end

local function set_old(path, seconds)
  local stamp = os.time() - (seconds or 30)
  vim.uv.fs_utime(path, stamp, stamp)
  local owner = path .. "/owner"
  if vim.uv.fs_stat(owner) then
    vim.uv.fs_utime(owner, stamp, stamp)
  end
end

local function read_token(path)
  local file = io.open(path .. "/owner", "r")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text:match("token=([^\r\n]+)")
end

local function signal(flag, pid)
  vim.fn.system({ "/bin/kill", flag, tostring(pid) })
  assert(vim.v.shell_error == 0, "could not signal " .. tostring(pid))
end

local function wait_dead(pid)
  return vim.wait(5000, function()
    return not vim.uv.kill(pid, 0)
  end, 10)
end

local function spawn_sleep()
  local handle, pid = vim.uv.spawn("sleep", { args = { "60" } }, function() end)
  assert(handle and pid, "could not spawn sleep helper")
  local start = nil
  local found = vim.wait(5000, function()
    start = annotations._process_start_marker(pid)
    return start ~= ""
  end, 10)
  assert(found and start ~= "", "could not read the helper process start marker")
  return handle, pid, start
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local source = root .. "/Sample.kt"
write(source, 'fun make(): String = "x"\nval other = 1\nval third = 2\n\n')

cint.setup({ root = root })
vim.cmd.edit(vim.fn.fnameescape(source))
local buf = vim.api.nvim_get_current_buf()

vim.api.nvim_win_set_cursor(0, { 1, 5 })
local ok, record = cint.annotate("PURE", "generated helper")
assert(ok, tostring(record))
assert(record.path == "Sample.kt", "annotations should store a project-relative path")
assert(record.symbol == "make", "current-symbol annotation should capture the word under cursor")
assert(record.contentHash and #record.contentHash == 64, "annotations should store a content hash")
assert(record.note == "generated helper", "notes should be persisted")

local persisted = vim.json.decode(read(annotations.file_path(buf)))
assert(#persisted.annotations == 1, "the annotation file should contain the new record")
assert(persisted.annotations[1].intents[1] == "PURE", "the intent should round-trip through disk")

local listed = cint.annotations()
assert(#listed == 1, "listing should load annotations from disk")
assert(listed[1].symbol == "make", "listing should expose the stable symbol anchor")

vim.api.nvim_win_set_cursor(0, { 1, 5 })
local range_ok, range_record = cint.annotate_range("TEAM_CUSTOM_INTENT", "range note", 0, 0)
assert(range_ok, tostring(range_record))
assert(range_record.symbol == nil, "visual-range annotations should use the range fallback")
assert(range_record.contentHash == vim.fn.sha256(vim.api.nvim_get_current_line()), "range anchors should hash the selected text")
assert(#cint.annotations() == 2, "range annotations should be added to the same file")

local removed, count = cint.unannotate()
assert(removed and count == 1, "unannotating the current symbol should remove only that record")
local remaining = cint.annotations_reload()
assert(#remaining == 1, "another annotation on the same line should survive symbol removal")
assert(remaining[1].intents[1] == "TEAM_CUSTOM_INTENT", "unknown intent names should be preserved")
assert(remaining[1].symbol == nil, "the surviving record should still be the range annotation")

local range_removed, range_count = cint.unannotate_range(0, 0)
assert(range_removed and range_count == 1, "range removal should remove the contained range annotation")
assert(#cint.annotations() == 0, "all annotations should be gone before the malformed-file test")

local blank_hash_ok, blank_hash_record = cint.annotate_range("TEAM_CUSTOM_INTENT", "blank line", 2, 3)
assert(blank_hash_ok, tostring(blank_hash_record))
assert(
  blank_hash_record.contentHash == vim.fn.sha256("val third = 2"),
  "a linewise range ending on an empty line should store the canonical hash"
)
assert(
  blank_hash_record.contentHash ~= vim.fn.sha256("val third = 2\n"),
  "the empty-line range should not store the raw joined text hash"
)
local blank_hash_removed = cint.unannotate_range(2, 3)
assert(blank_hash_removed, "the empty-line range should be removable")
assert(#cint.annotations() == 0, "the empty-line annotation should be removed")

local annotation_file = annotations.file_path(buf)
write(annotation_file, "{not valid json")
local malformed_original = read(annotation_file)
local malformed_ok, malformed_err = cint.annotate("PURE")
assert(not malformed_ok, "annotating should fail when the annotation file is malformed")
assert(tostring(malformed_err):find("could not read", 1, true) ~= nil, "malformed reads should report an error")
assert(read(annotation_file) == malformed_original, "a malformed annotation file must not be overwritten")
assert(#vim.fn.glob(annotation_file .. ".bak-*", false, true) == 1, "malformed annotation files should be backed up")

assert(vim.fn.exists(":CintAnnotate") == 2, "CintAnnotate command should exist")
local intent_completions = vim.fn.getcompletion("CintAnnotate R", "cmdline")
assert(vim.tbl_contains(intent_completions, "READONLY"), "CintAnnotate should complete READONLY")
local pure_completions = vim.fn.getcompletion("CintAnnotate P", "cmdline")
assert(vim.tbl_contains(pure_completions, "PURE"), "CintAnnotate should complete PURE")
assert(vim.fn.exists(":CintUnannotate") == 2, "CintUnannotate command should exist")
assert(vim.fn.exists(":CintAnnotations") == 2, "CintAnnotations command should exist")
assert(vim.fn.exists(":CintAnnotationsReload") == 2, "CintAnnotationsReload command should exist")

cint.setup({
  root = root,
  resolve = { precedence = { "HIGHLIGHT" }, default = "HIGHLIGHT" },
  rules = { HIGHLIGHT = { highlight = true } },
  tags = { PURE = { meaning = "HIGHLIGHT", bg = "#101010" } },
})
cint._live_tags[buf] = {
  version = vim.b[buf].changedtick,
  hash = "annotations-test",
  annotations = {
    {
      role = "source-intent",
      intents = { "PURE" },
      startLine = 0,
      startCol = 0,
      endLine = 0,
      endCol = 8,
      provenance = {
        {
          rule = "ordinary:contributor",
          role = "source-intent",
          intents = { "PURE" },
          source = "user",
          confidence = 1.0,
        },
      },
    },
  },
}
assert(cint.render() == 1, "user annotation should render")
local marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
assert(#marks == 1, "user annotation should create one extmark")
assert(marks[1][4].sign_text == nil, "user source should not add a U marker")

render.clear(buf)
render.reset()
cint.setup({ root = root })
cint._live_tags[buf] = {
  version = vim.b[buf].changedtick,
  hash = "annotations-default-test",
  annotations = {
    {
      role = "source-intent",
      intents = { "PURE", "TEAM_CUSTOM_INTENT" },
      startLine = 0,
      startCol = 0,
      endLine = 0,
      endCol = 8,
      provenance = {
        {
          rule = "ordinary:contributor",
          role = "source-intent",
          intents = { "TEAM_CUSTOM_INTENT" },
          source = "pack",
          confidence = 1.0,
        },
        {
          rule = "ordinary:contributor",
          role = "source-intent",
          intents = { "PURE" },
          source = "user",
          confidence = 1.0,
        },
      },
    },
  },
}
assert(cint.render() == 1, "user annotation should still be counted under the shipped default policy")
local default_marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
assert(#default_marks == 0, "default-policy SHOW should no longer force a U marker for user annotations")

local lock_root = vim.fn.tempname()
vim.fn.mkdir(lock_root, "p")
local lock_source = lock_root .. "/Locked.kt"
write(lock_source, 'fun locked(): String = "x"\n')
cint.setup({ root = lock_root })
vim.cmd.edit(vim.fn.fnameescape(lock_source))
local lock_buf = vim.api.nvim_get_current_buf()
local lock_path = lock_root .. "/.cint/user-annotations.json.lock"
vim.fn.mkdir(lock_path, "p")
local lock_released = false
local lock_timer = vim.uv.new_timer()
lock_timer:start(100, 0, function()
  vim.schedule(function()
    vim.uv.fs_rmdir(lock_path)
    lock_released = true
  end)
end)
local lock_ok, lock_record = cint.annotate("PURE")
assert(lock_ok, tostring(lock_record))
assert(lock_released, "annotation writer should wait for the shared lock file")
lock_timer:close()
assert(vim.uv.fs_stat(lock_path) == nil, "annotation writer should release the shared lock")
assert(#annotations.annotations(lock_buf) == 1, "locked annotation should persist")

local legacy_root = vim.fn.tempname()
vim.fn.mkdir(legacy_root .. "/.cint", "p")
local legacy_source = legacy_root .. "/Legacy.kt"
write(legacy_source, 'fun legacy(): String = "x"\n')
cint.setup({ root = legacy_root })
vim.cmd.edit(vim.fn.fnameescape(legacy_source))
local legacy_buf = vim.api.nvim_get_current_buf()
local legacy_lock = legacy_root .. "/.cint/user-annotations.json.lock"
local legacy_guard = legacy_lock .. ".guard"
local legacy_tombstone = legacy_lock .. ".stale-old"
vim.fn.mkdir(legacy_lock, "p")
vim.fn.mkdir(legacy_guard, "p")
vim.fn.mkdir(legacy_tombstone, "p")
set_old(legacy_lock)
set_old(legacy_guard)
set_old(legacy_tombstone)
local legacy_ok, legacy_record = cint.annotate("PURE")
assert(legacy_ok, tostring(legacy_record))
assert(vim.uv.fs_stat(legacy_lock) == nil, "an ownerless legacy lock should be recovered")
assert(vim.uv.fs_stat(legacy_guard) == nil, "an ownerless legacy guard should be reaped")
assert(vim.uv.fs_stat(legacy_tombstone) == nil, "an old tombstone should be reaped")
assert(#annotations.annotations(legacy_buf) == 1, "legacy recovery should still persist the annotation")

local dead_root = vim.fn.tempname()
vim.fn.mkdir(dead_root, "p")
local dead_source = dead_root .. "/Dead.kt"
write(dead_source, 'fun dead(): String = "x"\n')
cint.setup({ root = dead_root })
vim.cmd.edit(vim.fn.fnameescape(dead_source))
local dead_buf = vim.api.nvim_get_current_buf()
local dead_lock = dead_root .. "/.cint/user-annotations.json.lock"
local dead_handle, dead_pid, dead_start = spawn_sleep()
signal("-KILL", dead_pid)
assert(wait_dead(dead_pid), "the helper process should terminate")
pcall(dead_handle.close, dead_handle)
write_lock(dead_lock, string.rep("1", 64), dead_pid, dead_start)
local dead_ok, dead_record = cint.annotate("PURE")
assert(dead_ok, tostring(dead_record))
assert(vim.uv.fs_stat(dead_lock) == nil, "a dead-holder lock should be recovered")
assert(#annotations.annotations(dead_buf) == 1, "dead-holder recovery should persist the annotation")

local live_root = vim.fn.tempname()
vim.fn.mkdir(live_root .. "/.cint", "p")
local live_lock = live_root .. "/.cint/user-annotations.json.lock"
local live_pid = vim.uv.os_getpid()
local live_start = annotations._process_start_marker(live_pid)
write_lock(live_lock, string.rep("2", 64), live_pid, live_start)
set_old(live_lock)
assert(annotations._is_lock_stale(live_root) == false, "a live holder must not be stale even with an old mtime")
local suspended_handle, suspended_pid, suspended_start = spawn_sleep()
signal("-STOP", suspended_pid)
write_lock(live_lock, string.rep("3", 64), suspended_pid, suspended_start)
set_old(live_lock)
assert(annotations._is_lock_stale(live_root) == false, "a suspended live holder must not be stale")
signal("-CONT", suspended_pid)
signal("-KILL", suspended_pid)
assert(wait_dead(suspended_pid), "the suspended helper should terminate")
pcall(suspended_handle.close, suspended_handle)

local foreign_root = vim.fn.tempname()
vim.fn.mkdir(foreign_root .. "/.cint", "p")
local foreign_lock = foreign_root .. "/.cint/user-annotations.json.lock"
local foreign_token = string.rep("a", 64)
write_lock(foreign_lock, foreign_token, live_pid, live_start)
local wrong_release = annotations._release_annotations_lock(foreign_root, string.rep("b", 64))
assert(wrong_release == false, "a non-owner release must not delete a foreign-token lock")
assert(vim.uv.fs_stat(foreign_lock) ~= nil, "a non-owner release must leave the lock in place")
assert(read_token(foreign_lock) == foreign_token, "a non-owner release must not change the owner token")
local owner_release = annotations._release_annotations_lock(foreign_root, foreign_token)
assert(owner_release == true, "the owner release should remove its own lock")
assert(vim.uv.fs_stat(foreign_lock) == nil, "the owner release should delete the lock directory")

local release_root = vim.fn.tempname()
vim.fn.mkdir(release_root .. "/.cint", "p")
local release_lock = release_root .. "/.cint/user-annotations.json.lock"
local release_token = string.rep("c", 64)
local successor_token = string.rep("d", 64)
write_lock(release_lock, release_token, live_pid, live_start)
annotations._set_lock_hooks({
  before_release = function()
    vim.uv.fs_unlink(release_lock .. "/owner")
    vim.uv.fs_rmdir(release_lock)
    write_lock(release_lock, successor_token, live_pid, live_start)
  end,
})
local release_ok, release_err = annotations._release_annotations_lock(release_root, release_token)
annotations._set_lock_hooks(nil)
assert(release_ok == false, "a release that lost the lock must not report ownership")
assert(release_err == nil, "a restored successor lock is not a release failure")
assert(vim.uv.fs_stat(release_lock) ~= nil, "release must restore a successor lock it moved aside")
assert(read_token(release_lock) == successor_token, "release must not delete the successor lock")
assert(annotations._release_annotations_lock(release_root, successor_token) == true, "successor cleanup should release")

local creator_root = vim.fn.tempname()
vim.fn.mkdir(creator_root, "p")
local creator_source = creator_root .. "/Creator.kt"
write(creator_source, 'fun creator(): String = "x"\n')
cint.setup({ root = creator_root })
vim.cmd.edit(vim.fn.fnameescape(creator_source))
local creator_buf = vim.api.nvim_get_current_buf()
local creator_lock = creator_root .. "/.cint/user-annotations.json.lock"
local creator_successor_token = nil
local creator_hook_armed = true
annotations._set_lock_timeout(1000)
annotations._set_lock_hooks({
  before_owner_write = function(path)
    if not creator_hook_armed then
      return
    end
    creator_hook_armed = false
    set_old(path)
    local token, err = annotations._acquire_lock_for_test(creator_root)
    assert(token, tostring(err))
    creator_successor_token = token
  end,
})
local creator_ok, creator_err = cint.annotate("PURE")
annotations._set_lock_hooks(nil)
annotations._set_lock_timeout(nil)
assert(not creator_ok, "a creator that lost its ownerless lock must abort")
assert(tostring(creator_err):find("timed out", 1, true) ~= nil, "the creator should retry until its deadline")
assert(vim.uv.fs_stat(creator_lock) ~= nil, "the creator must not delete the successor lock")
assert(creator_successor_token ~= nil, "the competitor should have acquired the lock")
assert(read_token(creator_lock) == creator_successor_token, "the creator must not clobber the successor owner")
assert(#annotations.annotations(creator_buf) == 0, "the creator must not enter the critical section")
assert(annotations._release_annotations_lock(creator_root, creator_successor_token) == true, "creator successor cleanup should release")

local contention_root = vim.fn.tempname()
vim.fn.mkdir(contention_root, "p")
local contention_source = contention_root .. "/Contention.kt"
write(contention_source, 'fun contention(): String = "x"\n')
cint.setup({ root = contention_root })
vim.cmd.edit(vim.fn.fnameescape(contention_source))
local contention_buf = vim.api.nvim_get_current_buf()
local contention_lock = contention_root .. "/.cint/user-annotations.json.lock"
local contention_old_token = string.rep("a", 64)
write_lock(contention_lock, contention_old_token, dead_pid, dead_start)
local second_waiter_ok = nil
annotations._set_lock_timeout(2000)
annotations._set_lock_hooks({
  after_claim = function()
    local before = read_token(contention_lock)
    annotations._set_lock_timeout(100)
    local nested_ok = cint.annotate("PURE")
    annotations._set_lock_timeout(2000)
    second_waiter_ok = nested_ok
    assert(second_waiter_ok == false, "a second waiter must not acquire while the claim is held")
    assert(read_token(contention_lock) == before, "a second waiter must not move the canonical lock")
  end,
})
local contention_ok, contention_record = cint.annotate("PURE")
annotations._set_lock_hooks(nil)
annotations._set_lock_timeout(nil)
assert(contention_ok, tostring(contention_record))
assert(second_waiter_ok == false, "the nested waiter should have timed out")
assert(vim.uv.fs_stat(contention_lock) == nil, "the first waiter should have stolen and released the stale lock")
assert(#annotations.annotations(contention_buf) == 1, "the first waiter should persist its annotation")

local claim_live_root = vim.fn.tempname()
vim.fn.mkdir(claim_live_root, "p")
local claim_live_source = claim_live_root .. "/ClaimLive.kt"
write(claim_live_source, 'fun claimLive(): String = "x"\n')
cint.setup({ root = claim_live_root })
vim.cmd.edit(vim.fn.fnameescape(claim_live_source))
local claim_live_buf = vim.api.nvim_get_current_buf()
local claim_live_lock = claim_live_root .. "/.cint/user-annotations.json.lock"
local claim_live_old = string.rep("b", 64)
local claim_live_successor = string.rep("c", 64)
write_lock(claim_live_lock, claim_live_old, dead_pid, dead_start)
annotations._set_lock_timeout(300)
annotations._set_lock_hooks({
  after_claim = function()
    vim.uv.fs_unlink(claim_live_lock .. "/owner")
    vim.uv.fs_rmdir(claim_live_lock)
    write_lock(claim_live_lock, claim_live_successor, live_pid, live_start)
  end,
})
local claim_live_ok, claim_live_err = cint.annotate("PURE")
annotations._set_lock_hooks(nil)
annotations._set_lock_timeout(nil)
assert(not claim_live_ok, "a claim that sees a live lock must not steal it")
assert(tostring(claim_live_err):find("timed out", 1, true) ~= nil, "the claimant should wait for the live lock")
assert(read_token(claim_live_lock) == claim_live_successor, "the claimant must not move the live lock")
assert(#annotations.annotations(claim_live_buf) == 0, "the claimant must not enter the critical section")
assert(annotations._release_annotations_lock(claim_live_root, claim_live_successor) == true, "claim-live successor cleanup should release")

local claim_block_root = vim.fn.tempname()
vim.fn.mkdir(claim_block_root, "p")
local claim_block_source = claim_block_root .. "/ClaimBlock.kt"
write(claim_block_source, 'fun claimBlock(): String = "x"\n')
cint.setup({ root = claim_block_root })
vim.cmd.edit(vim.fn.fnameescape(claim_block_source))
local claim_block_lock = claim_block_root .. "/.cint/user-annotations.json.lock"
local claim_block_claim = claim_block_lock .. ".steal"
write_lock(claim_block_claim, string.rep("d", 64), live_pid, live_start)
annotations._set_lock_timeout(150)
local claim_block_ok, claim_block_err = cint.annotate("PURE")
annotations._set_lock_timeout(nil)
assert(not claim_block_ok, "a live claim must keep new writers out")
assert(tostring(claim_block_err):find("timed out", 1, true) ~= nil, "the writer should time out behind a live claim")
assert(vim.uv.fs_stat(claim_block_lock) == nil, "no canonical lock may be created while a claim is held")
assert(vim.uv.fs_stat(claim_block_claim) ~= nil, "the live claim must survive")

local hard_root = vim.fn.tempname()
vim.fn.mkdir(hard_root .. "/.cint", "p")
local hard_lock = hard_root .. "/.cint/user-annotations.json.lock"
local hard_token = string.rep("e", 64)
local hard_successor = string.rep("f", 64)
local hard_third = string.rep("0", 64)
write_lock(hard_lock, hard_token, live_pid, live_start)
annotations._set_lock_hooks({
  before_release = function()
    vim.uv.fs_unlink(hard_lock .. "/owner")
    vim.uv.fs_rmdir(hard_lock)
    write_lock(hard_lock, hard_successor, live_pid, live_start)
  end,
  before_release_restore = function()
    write_lock(hard_lock, hard_third, live_pid, live_start)
  end,
})
local hard_released, hard_err = annotations._release_annotations_lock(hard_root, hard_token)
annotations._set_lock_hooks(nil)
assert(hard_released == nil, "an unexpected restore failure must not look successful")
assert(tostring(hard_err):find("failed to restore lock", 1, true) ~= nil, "the restore failure should be surfaced")
assert(read_token(hard_lock) == hard_third, "the third lock should keep the canonical path")

local tombstone_root = vim.fn.tempname()
vim.fn.mkdir(tombstone_root .. "/.cint", "p")
local tombstone_lock = tombstone_root .. "/.cint/user-annotations.json.lock"
local tombstone_token = string.rep("9", 64)
local tombstone_path = tombstone_lock .. ".stale-" .. tombstone_token
write_lock(tombstone_path, tombstone_token, live_pid, live_start)
assert(annotations._release_annotations_lock(tombstone_root, tombstone_token) == true, "release should find its own tombstone")
assert(vim.uv.fs_stat(tombstone_path) == nil, "release should delete its own tombstone")

local vanish_root = vim.fn.tempname()
vim.fn.mkdir(vanish_root .. "/.cint/user-annotations.json.lock", "p")
local vanish_source = vanish_root .. "/Vanish.kt"
write(vanish_source, 'fun vanish(): String = "x"\n')
write(vanish_root .. "/.cint/user-annotations.json.lock/owner", "holder")
cint.setup({ root = vanish_root })
vim.cmd.edit(vim.fn.fnameescape(vanish_source))
local vanish_buf = vim.api.nvim_get_current_buf()
annotations._set_lock_conflict_hook(function(path)
  pcall(vim.uv.fs_unlink, path .. "/owner")
  pcall(vim.uv.fs_rmdir, path)
end)
local vanish_ok, vanish_record = cint.annotate("PURE")
annotations._set_lock_conflict_hook(nil)
assert(vanish_ok, tostring(vanish_record))
assert(#annotations.annotations(vanish_buf) == 1, "a vanished lock should be retried rather than raising")


local readonly_root = vim.fn.tempname()
vim.fn.mkdir(readonly_root, "p")
local readonly_source = readonly_root .. "/ReadOnly.kt"
write(readonly_source, 'fun readOnlyValue(): String = "x"\n')
cint.setup({ root = readonly_root })
vim.cmd.edit(vim.fn.fnameescape(readonly_source))
local readonly_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 1, 5 })
local readonly_ok, readonly_record = cint.annotate("READONLY")
assert(readonly_ok, tostring(readonly_record))
assert(vim.deep_equal(readonly_record.intents, { "READONLY" }), "READONLY should persist as a user intent")
assert(#annotations.annotations(readonly_buf) == 1, "READONLY should be readable back from disk")

print("PASS")
vim.cmd("qa!")
