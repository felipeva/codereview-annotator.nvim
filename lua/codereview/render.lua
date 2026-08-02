---Turn a parsed diff into buffer lines, extmarks, and the anchor map.
---
---Pure: takes data and returns data. No buffers, no windows, no git. The anchor map it
---produces is the single source of truth that navigation, annotation targeting, collapse
---and the syntax replay all read -- every "which change is row 47?" question is answered
---here and nowhere else.
local M = {}

---@class CRAnchor
---@field kind "file"|"sep"|"hunk"|"line"|"pad"|"note"
---@field file integer        Index into the file list
---@field hunk integer|nil    Index into that file's hunks
---@field line integer|nil    Index into that hunk's lines
---@field col integer|nil     Byte offset where code text starts, for the syntax replay

---@class CRRender
---@field lines string[]
---@field anchors table<integer, CRAnchor>  Keyed by 1-indexed buffer row
---@field marks table[]                     { row, col, opts } for nvim_buf_set_extmark
---@field file_rows integer[]               1-indexed header row of each file
---@field hunk_rows integer[]               1-indexed row of every visible hunk header

local SEP = " │ "

---Explicit so the layers compose predictably: diff backgrounds sit underneath, the
---treesitter foregrounds `syntax.lua` adds sit on top. Leaving these at the extmark
---default makes the result depend on insertion order, which changes as the view repaints.
M.PRIORITY = { diff = 100, gutter = 110, syntax = 150 }

---Stable identity for an annotatable line, independent of buffer position.
---
---Sided because a deleted line and an added line can share a number: `foo.ts:o:20` and
---`foo.ts:n:20` are different places, and collapsing them would move annotations onto
---code they were never about.
---@param path string
---@param line CRLine
---@return string
function M.line_key(path, line)
  if line.new then
    return ("%s:n:%d"):format(path, line.new)
  end
  return ("%s:o:%d"):format(path, line.old)
end

---Anchor key for an annotation about a whole file. Shares the `path:` prefix that the
---per-file note tally scans for, and cannot collide with a line key.
---@param path string
---@return string
function M.file_key(path)
  return path .. ":f:0"
end

---Widest line number anywhere in the diff.
---
---Computed across all files, not just expanded ones, so the gutter does not resize --
---and every row shift -- when a file is expanded.
---@param files CRFile[]
---@return integer
local function gutter_digits(files)
  local max = 1
  for _, file in ipairs(files) do
    for _, hunk in ipairs(file.hunks) do
      for _, ln in ipairs(hunk.lines) do
        local n = ln.new or ln.old or 0
        if n > max then
          max = n
        end
      end
    end
  end
  return #tostring(max)
end

---@param n integer
---@param width integer
---@return string
local function rpad_num(n, width)
  local s = tostring(n)
  return (" "):rep(math.max(0, width - #s)) .. s
end

---@param text string
---@param width integer
---@return string
local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(1, width - 1)) .. "…"
end

---Build the view.
---@param files CRFile[]
---@param opts { width: integer, icons: table, expanded: table<string, boolean>, reviewed: table<string, string>, notes: table<string, table[]>, types: CRType[] }
---@return CRRender
function M.build(files, opts)
  local icons = opts.icons
  local width = math.max(40, opts.width or 80)
  local digits = gutter_digits(files)

  local lines, anchors, marks = {}, {}, {}
  local file_rows, hunk_rows = {}, {}

  ---@param row integer 1-indexed
  ---@param col integer 0-indexed byte
  ---@param opts_ table
  local function mark(row, col, opts_)
    if opts_.priority == nil and not opts_.virt_lines then
      opts_.priority = opts_.line_hl_group and M.PRIORITY.diff or M.PRIORITY.gutter
    end
    marks[#marks + 1] = { row = row - 1, col = col, opts = opts_ }
  end

  ---@param text string
  ---@param anchor CRAnchor
  ---@return integer row
  local function push(text, anchor)
    lines[#lines + 1] = text
    anchors[#lines] = anchor
    return #lines
  end

  ---Annotations attached to a row, rendered as virtual lines beneath it.
  ---@param row integer
  ---@param key string
  local function attach_notes(row, key)
    local items = opts.notes and opts.notes[key]
    if not items or #items == 0 then
      return
    end
    local virt = {}
    for _, item in ipairs(items) do
      local type_def = require("codereview.types").get(opts.types, item.type)
      local icon = type_def and type_def.icon or "•"
      local group = type_def and type_def.hl or "CodeReviewNote"
      local prefix = ("   %s "):format(icon)
      -- A multi-line note becomes multiple virtual lines; the continuation lines are
      -- indented to the icon so the block reads as one comment.
      for n, text in ipairs(vim.split(item.note, "\n", { plain = true })) do
        if n == 1 then
          local chunks = { { prefix, group } }
          if item.stale then
            chunks[#chunks + 1] = { "⚠ stale  ", "CodeReviewStale" }
          end
          chunks[#chunks + 1] = { text, "CodeReviewNote" }
          virt[#virt + 1] = chunks
        else
          virt[#virt + 1] = { { (" "):rep(#prefix), "CodeReviewNote" }, { text, "CodeReviewNote" } }
        end
      end
    end
    mark(row, 0, { virt_lines = virt })
  end

  for fi, file in ipairs(files) do
    local reviewed = opts.reviewed and opts.reviewed[file.path] ~= nil
    local expanded = opts.expanded[file.path]
    if expanded == nil then
      expanded = not reviewed
    end

    -- Count notes on this file so the header can advertise them even when collapsed --
    -- otherwise a reviewed file silently hides the comments you left on it.
    local note_count = 0
    if opts.notes then
      for key, items in pairs(opts.notes) do
        if key:sub(1, #file.path + 1) == file.path .. ":" then
          note_count = note_count + #items
        end
      end
    end

    --- File header -----------------------------------------------------------
    local icon = reviewed and icons.reviewed or (note_count > 0 and icons.annotated or icons.unreviewed)
    local chevron = expanded and icons.expanded or icons.collapsed
    local name = file.old_path and ("%s → %s"):format(file.old_path, file.path) or file.path

    local left = ("%s %s %s"):format(icon, chevron, name)
    local stat = file.binary and "binary" or ("+%d -%d"):format(file.added, file.removed)
    local right = note_count > 0 and ("%s  [%d note%s]"):format(stat, note_count, note_count == 1 and "" or "s") or stat

    left = truncate(left, math.max(10, width - #right - 2))
    local pad = math.max(1, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right))
    local header = left .. (" "):rep(pad) .. right

    local row = push(header, { kind = "file", file = fi })
    file_rows[fi] = row
    mark(row, 0, { line_hl_group = reviewed and "CodeReviewFileReviewed" or "CodeReviewFileHeader" })
    -- Colour only the +N/-M inside the stat, not the note count that may follow it.
    local stat_col = #header - #right
    local plus_len = file.binary and 0 or #(("+%d"):format(file.added))
    if not file.binary then
      mark(row, stat_col, { end_col = stat_col + plus_len, hl_group = "CodeReviewStatAdd" })
      mark(row, stat_col + plus_len + 1, { end_col = stat_col + #stat, hl_group = "CodeReviewStatDel" })
    end
    if note_count > 0 then
      mark(row, stat_col + #stat, { end_col = #header, hl_group = "CodeReviewNoteCount" })
    end
    -- Whole-file annotations hang off the header, so they stay visible even when the
    -- file is collapsed -- which is exactly when a file-level note matters most.
    attach_notes(row, M.file_key(file.path))

    if not expanded then
      push("", { kind = "pad", file = fi })
      goto next_file
    end

    if file.note then
      local r = push("   " .. file.note, { kind = "pad", file = fi })
      mark(r, 0, { line_hl_group = "CodeReviewNote" })
      push("", { kind = "pad", file = fi })
      goto next_file
    end

    --- Hunks -----------------------------------------------------------------
    for hi, hunk in ipairs(file.hunks) do
      local head = hunk.heading ~= "" and ("%s %s"):format(hunk.header, hunk.heading) or hunk.header
      local hrow = push(truncate(head, width), { kind = "hunk", file = fi, hunk = hi })
      hunk_rows[#hunk_rows + 1] = hrow
      mark(hrow, 0, { line_hl_group = "CodeReviewHunkHeader" })

      for li, ln in ipairs(hunk.lines) do
        local changed = ln.side ~= "ctx"
        local bar = changed and icons.change_bar or " "
        local sign = ln.side == "add" and "+" or (ln.side == "del" and "-" or " ")
        local number = rpad_num(ln.new or ln.old, digits)
        local prefix = bar .. number .. SEP .. sign
        local text = prefix .. ln.text

        -- Byte offset, not display width: extmark columns are byte offsets, and both the
        -- change bar and the separator are multibyte.
        local code_col = #prefix
        local r = push(text, { kind = "line", file = fi, hunk = hi, line = li, col = code_col })

        if ln.side == "add" then
          mark(r, 0, { line_hl_group = "CodeReviewAdd" })
          mark(r, 0, { end_col = #bar, hl_group = "CodeReviewAddBar" })
        elseif ln.side == "del" then
          mark(r, 0, { line_hl_group = "CodeReviewDel" })
          mark(r, 0, { end_col = #bar, hl_group = "CodeReviewDelBar" })
        end
        mark(r, #bar, { end_col = #bar + digits + #SEP, hl_group = "CodeReviewLineNr" })

        attach_notes(r, M.line_key(file.path, ln))
      end
      push("", { kind = "pad", file = fi, hunk = hi })
    end

    ::next_file::
  end

  return {
    lines = lines,
    anchors = anchors,
    marks = marks,
    file_rows = file_rows,
    hunk_rows = hunk_rows,
  }
end

return M
