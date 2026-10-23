local M = {}

M.ns = vim.api.nvim_create_namespace("cint-candidates")

local function define_highlights()
  vim.api.nvim_set_hl(0, "CintCandidate", { undercurl = true, underdouble = true })
  vim.api.nvim_set_hl(0, "CintCandidateSign", { fg = "#8a8a8a", italic = true })
  vim.api.nvim_set_hl(0, "CintAiCandidate", { undercurl = true, sp = "#c678dd" })
  vim.api.nvim_set_hl(0, "CintAiCandidateSign", { fg = "#c678dd", bold = true })
  vim.api.nvim_set_hl(0, "CintCandidateReview", { bg = "#3a3320", underline = true, bold = true })
  vim.api.nvim_set_hl(0, "CintCandidateReviewSign", { fg = "#e5c07b", bold = true })
  vim.api.nvim_set_hl(0, "CintCandidateReviewLine", { fg = "#e5c07b", italic = true })
end

function M.is_ai(candidate)
  local source = candidate and candidate.source
  return type(source) == "string" and source:sub(1, 3) == "ai:"
end

function M.ai_count(candidates)
  local count = 0
  for _, candidate in ipairs(candidates or {}) do
    if M.is_ai(candidate) then
      count = count + 1
    end
  end
  return count
end

local function operations(group)
  return group and group.operations or {}
end

function M.is_proposal_group(group)
  if not group then
    return false
  end
  if group.proposalId ~= nil or group.groupId ~= nil then
    return true
  end
  for _, operation in ipairs(operations(group)) do
    if tostring(operation.kind or ""):upper() == "REMOVE" then
      return true
    end
  end
  return false
end

local function operation_labels(group)
  local labels = {}
  for _, operation in ipairs(operations(group)) do
    local kind = tostring(operation.kind or "ADD"):upper()
    local prefix = kind == "REMOVE" and "− " or "+ "
    labels[#labels + 1] = prefix .. tostring(operation.intent or "?")
  end
  return labels
end

function M.group_signature(group)
  local labels = operation_labels(group)
  if #labels > 0 then
    return table.concat(labels, " ")
  end
  local intents = {}
  for _, candidate in ipairs(group and group.candidates or {}) do
    for _, intent in ipairs(candidate.intents or {}) do
      intents[#intents + 1] = "+ " .. tostring(intent)
    end
  end
  return #intents > 0 and table.concat(intents, " ") or "+ ?"
end

function M.group_confidence(group)
  local best = 0
  for _, operation in ipairs(operations(group)) do
    best = math.max(best, tonumber(operation.confidence) or 0)
  end
  for _, candidate in ipairs(group and group.candidates or {}) do
    best = math.max(best, tonumber(candidate.confidence) or 0)
  end
  return best
end

function M.group_source(group)
  local provider = group and group.provider
  if type(provider) == "string" and provider ~= "" then
    if provider:sub(1, 3) == "ai:" then
      return provider
    end
    return "ai:" .. provider
  end
  for _, operation in ipairs(operations(group)) do
    local source = operation.source
    if type(source) == "string" and source ~= "" then
      return source
    end
  end
  for _, candidate in ipairs(group and group.candidates or {}) do
    if candidate.source and candidate.source ~= "" then
      return tostring(candidate.source)
    end
  end
  return "ai"
end

function M.group_rationale(group)
  for _, operation in ipairs(operations(group)) do
    local rationale = operation.rationale and vim.trim(tostring(operation.rationale)) or ""
    if rationale ~= "" then
      return rationale
    end
  end
  for _, candidate in ipairs(group and group.candidates or {}) do
    local rationale = candidate.rationale and vim.trim(tostring(candidate.rationale)) or ""
    if rationale ~= "" then
      return rationale
    end
  end
  return ""
end

local function truncate(text, limit)
  if #text > limit then
    return text:sub(1, limit - 3) .. "..."
  end
  return text
end

function M.group_label(group)
  local parts = {
    M.group_signature(group),
    string.format("%.2f", M.group_confidence(group)),
    M.group_source(group),
  }
  local rationale = truncate(M.group_rationale(group), 64)
  if rationale ~= "" then
    parts[#parts + 1] = rationale
  end
  return table.concat(parts, " · ")
end

local function candidate_text(candidate)
  local intents = {}
  for _, intent in ipairs(candidate.intents or {}) do
    intents[#intents + 1] = tostring(intent)
  end
  local label = #intents > 0 and table.concat(intents, ",") or "?"
  local parts = {
    string.format("%s  %.2f", label, tonumber(candidate.confidence) or 0),
  }
  if candidate.source and candidate.source ~= "" then
    parts[#parts + 1] = tostring(candidate.source)
  end
  if candidate.reason and candidate.reason ~= "" then
    parts[#parts + 1] = tostring(candidate.reason)
  end
  local rationale = candidate.rationale and vim.trim(tostring(candidate.rationale)) or ""
  if rationale ~= "" then
    parts[#parts + 1] = truncate(rationale, 72)
  end
  return "  " .. table.concat(parts, " | ") .. "  "
end

local function operation_text(group)
  local parts = {
    M.group_signature(group),
    string.format("%.2f", M.group_confidence(group)),
    M.group_source(group),
  }
  local rationale = truncate(M.group_rationale(group), 72)
  if rationale ~= "" then
    parts[#parts + 1] = rationale
  end
  return "  " .. table.concat(parts, " | ") .. "  "
end

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

local function clamp_span(line_count, start_line, start_col, end_line, end_col)
  local start_row = math.max(0, math.min(tonumber(start_line) or 0, line_count - 1))
  local end_row = math.max(start_row, math.min(tonumber(end_line) or start_row, line_count - 1))
  return start_row, math.max(0, tonumber(start_col) or 0), end_row, math.max(0, tonumber(end_col) or 0)
end

local function line_length(buf, row)
  return #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
end

local function set_span(buf, line_count, start_line, start_col, end_line, end_col, hl_group, sign_text, sign_hl_group)
  local start_row, s_col, end_row, e_col = clamp_span(line_count, start_line, start_col, end_line, end_col)
  s_col = math.min(s_col, line_length(buf, start_row))
  e_col = math.min(e_col, line_length(buf, end_row))
  if end_row == start_row and e_col < s_col then
    e_col = s_col
  end
  vim.api.nvim_buf_set_extmark(buf, M.ns, start_row, s_col, {
    end_row = end_row,
    end_col = e_col,
    hl_group = hl_group,
    priority = 1100,
  })
  if sign_text then
    vim.api.nvim_buf_set_extmark(buf, M.ns, start_row, 0, {
      sign_text = sign_text,
      sign_hl_group = sign_hl_group,
      priority = 1100,
    })
  end
  return start_row
end

local function set_virtual_line(buf, row, text)
  vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
    virt_lines = { { { text, "CintCandidateReviewLine" } } },
    virt_lines_above = true,
    priority = 1100,
  })
end

local function render_candidate(buf, candidate, review, passive_ai, add_prefix, line_count)
  local ai = M.is_ai(candidate)
  local passive = ai and not review
  if passive and not passive_ai then
    return 0, nil, false
  end
  local hl_group
  local sign_text
  local sign_hl_group
  if review then
    hl_group = "CintCandidateReview"
    sign_text = add_prefix and "+" or "?"
    sign_hl_group = "CintCandidateReviewSign"
  elseif passive then
    hl_group = "CintAiCandidate"
    sign_text = "AI"
    sign_hl_group = "CintAiCandidateSign"
  else
    hl_group = "CintCandidate"
    sign_text = "?"
    sign_hl_group = "CintCandidateSign"
  end
  local row = set_span(
    buf,
    line_count,
    candidate.startLine,
    candidate.startCol,
    candidate.endLine,
    candidate.endCol,
    hl_group,
    sign_text,
    sign_hl_group
  )
  if review then
    local text = candidate_text(candidate)
    if add_prefix then
      text = "  + " .. text:gsub("^%s+", "")
    end
    set_virtual_line(buf, row, text)
  end
  return 1, row, passive
end

local function render_operations(buf, candidates, groups, line_count)
  local rendered = 0
  local seen = {}
  for _, group in ipairs(groups or {}) do
    if M.is_proposal_group(group) then
      local group_ops = operations(group)
      if #group_ops > 0 then
        local has_remove = false
        for _, operation in ipairs(group_ops) do
          if tostring(operation.kind or ""):upper() == "REMOVE" then
            has_remove = true
          end
          set_span(
            buf,
            line_count,
            operation.startLine,
            operation.startCol,
            operation.endLine,
            operation.endCol,
            "CintCandidateReview",
            nil,
            nil
          )
        end
        local row = set_span(
          buf,
          line_count,
          group.startLine,
          group.startCol,
          group.endLine,
          group.endCol,
          "CintCandidateReview",
          has_remove and "−" or "+",
          "CintCandidateReviewSign"
        )
        set_virtual_line(buf, row, operation_text(group))
        rendered = rendered + 1
      end
    end
    for _, candidate in ipairs(group.candidates or {}) do
      local id = candidate.candidateId
      if id then
        seen[id] = true
      end
      local count = render_candidate(buf, candidate, true, true, #operations(group) > 0, line_count)
      rendered = rendered + count
    end
  end
  for _, candidate in ipairs(candidates or {}) do
    local id = candidate.candidateId
    if not id or not seen[id] then
      rendered = rendered + render_candidate(buf, candidate, true, true, true, line_count)
    end
  end
  return rendered
end

function M.render(buf, candidates, review, opts)
  define_highlights()
  M.clear(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  opts = opts or {}
  local line_count = vim.api.nvim_buf_line_count(buf)
  if review and opts.operations then
    return render_operations(buf, candidates, opts.groups or {}, line_count)
  end
  local passive_ai = opts.ai_passive
  if passive_ai == nil then
    passive_ai = true
  end
  local rendered = 0
  local ai_badge_rows = {}
  for _, candidate in ipairs(candidates or {}) do
    local count, row, passive = render_candidate(buf, candidate, review, passive_ai, false, line_count)
    rendered = rendered + count
    if passive and not ai_badge_rows[row] then
      ai_badge_rows[row] = true
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        virt_text = { { " AI", "CintAiCandidateSign" } },
        virt_text_pos = "eol",
        priority = 1100,
      })
    end
  end
  return rendered
end

return M
