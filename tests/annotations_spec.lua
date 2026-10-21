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
assert(vim.trim(marks[1][4].sign_text or "") == "U", "user-authored annotations should be marked")

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
assert(cint.render() == 1, "user annotation should render under the shipped default policy")
local default_marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
assert(#default_marks == 1, "default-policy user annotation should create one extmark")
assert(vim.trim(default_marks[1][4].sign_text or "") == "U", "default-policy user annotations should be marked")

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

print("PASS")
vim.cmd("qa!")
