---The archive read back: the batch that went last, as a surface of its own.
---
---What a reviewer asked for should be a fact the plugin holds, not something to scroll an
---agent's transcript for. This is where that fact is read: the **entries** of the newest
---archived **batch**, the **target** it went to, and when it went.
---
---**Read-only, and that is a claim about the record rather than a feature left unwritten.**
---An archived entry says something happened. A surface that let you drop, edit or resubmit
---one would be claiming the plugin can revise what an agent already received, which it
---cannot. Re-raising a point means annotating again, which is an ordinary capture and
---already has a path.
---
---A module of its own because a buffer, a window and keys do not have to live on the review
---view to exist -- and because a **batch is not a window**: this opens with no review open,
---exactly as the queue float does, so what was asked for can be checked from anywhere.
local config = require("codereview.config")
local render = require("codereview.render")
local state = require("codereview.state")
local types = require("codereview.types")

local M = {}

---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

--- Which batch went last -------------------------------------------------------

---The batch that went last, wherever its entries were kept.
---
---**One dispatch can be two records.** `state.archive_batch` splits a batch on the rule
---that already routes the queue -- an entry with a repository-relative path to that
---repository's document, a bare note or a file outside a checkout to the store that needs
---no root -- and stamps both halves from a single `os.time()`. Read back through one
---accessor alone, a batch that held both is missing exactly the entries with nowhere else
---to be listed, and a bare note becomes the one thing that vanishes.
---
---So: the newest record across the two, and the other store's newest with it when the two
---carry the same stamp and the same target, which is what one dispatch looks like on disk.
---
---The repository's half comes through `state.last_batch`, which is also what the
---`since-batch` scope resolves against -- one query, so the diff that scope draws and the
---entries listed here can never describe two different dispatches. The other half is read
---inline because it has exactly one reader: no scope resolves against a record with no
---repository behind it, since a **snapshot** can only belong to the half that has one.
---@param root string|nil nil outside a repository, where only the store that needs none applies
---@return CRBatch|nil
function M.last(root)
  -- Each store keeps its batches newest first, so the head of each is the only candidate.
  local owned = state.last_batch(root)
  local loose = state.global_archive()[1]

  if owned and loose and owned.at == loose.at and owned.target == loose.target then
    local entries = {}
    vim.list_extend(entries, owned.entries or {})
    vim.list_extend(entries, loose.entries or {})
    -- Back into the order they were written in, which is the order they reached the agent:
    -- ids are issued as annotations are queued and are unique across the two stores, so the
    -- split that put these in different documents is undone by sorting on one field.
    table.sort(entries, function(a, b)
      return (a.id or 0) < (b.id or 0)
    end)
    return { at = owned.at, target = owned.target, snapshot = owned.snapshot, entries = entries }
  end

  if not owned or (loose and loose.at > owned.at) then
    return loose
  end
  return owned
end

--- Rendering the batch as rows -------------------------------------------------

---Extmarks belonging to this float, in a namespace of its own so clearing them cannot
---disturb the queue float's, the diff's or the tree's.
local NS = vim.api.nvim_create_namespace("codereview_archive")

---One column to the left of every bar, reserved exactly as the queue float reserves it.
---The two surfaces list the same shape of thing and should read as one family; a gutter
---here and none there would be a dialect, not a distinction.
local GUTTER = " "

---Where an archived entry was, and the tag that rides on the right of its first row.
---
---**Staleness is deliberately absent**, where the queue float prints it. A queued entry's
---`⚠ stale` says its line numbers may have moved since it was captured, which is worth
---acting on before it goes. The same flag on an entry that has already gone is a fact about
---a queue that no longer exists, and printing it here would read as a claim about the code
---now. Whether an archived entry's file has moved since its batch went is a different
---question, with a word of its own, and not this surface's to answer.
---@param entry CRAnnotation
---@return string where, string|nil tag
local function locate(entry)
  -- A bare note is about no file, so there is no location to print; every branch below
  -- reads a path this one does not have.
  if entry.kind == "note" then
    return "(no file)", nil
  end
  -- Captured outside a checkout there is no repository-relative path, and the absolute one
  -- is the only name the file has.
  local where = entry.path or entry.abs_path
  if entry.kind == "file" then
    return where, entry.tag or "whole file"
  end
  local range = entry.first == entry.last and tostring(entry.first) or ("%d-%d"):format(entry.first, entry.last)
  return ("%s:%s"):format(where, range), entry.tag
end

---Turn an archived batch's entries into the float's rows.
---
---The queue float's shape, minus the machinery it grew for acting on an entry. An entry is
---a run of rows carrying a bar in its annotation type's group -- its location, the code it
---inlined, and every line of its note -- and the blank row *between* two entries carries
---none, so a boundary holds whatever a note contains. What is not here is the row-to-entry
---map: that exists so `x` can resolve the cursor exactly, and nothing here acts on an entry.
---
---Its highlight columns are byte offsets, not display columns: the bar glyph is multibyte,
---and so is anything a host configures in its place.
---@param entries CRAnnotation[]
---@param opts { types: CRType[], bar: string, width: integer }
---@return { lines: string[], marks: table[] }
local function build(entries, opts)
  local lines, marks = {}, {}
  local bar = opts.bar
  local bar_col, bar_end = #GUTTER, #GUTTER + #bar
  -- Padded to the widest number in the batch, so entry 10 does not shift the column every
  -- row below it is drawn in.
  local digits = #tostring(#entries)
  local indent = GUTTER .. bar .. (" "):rep(digits + 2)
  local body = math.max(8, opts.width - vim.fn.strdisplaywidth(indent))

  ---@param row integer 1-indexed
  ---@param col integer 0-indexed byte
  local function mark(row, col, o)
    marks[#marks + 1] = { row = row - 1, col = col, opts = o }
  end

  ---A row carrying an entry's bar and nothing else by default.
  ---@return integer row
  local function bar_row(group, text)
    lines[#lines + 1] = text
    mark(#lines, bar_col, { end_col = bar_end, hl_group = group })
    return #lines
  end

  local index = 0
  -- The same helper the payload rendered this batch through when it went, and the same one
  -- the queue float lists what is still to send through. A third implementation would be a
  -- third thing that agrees today; the two that existed before this one already drifted.
  for gi, group in ipairs(types.group(entries, opts.types)) do
    if gi > 1 then
      lines[#lines + 1] = ""
    end
    local label = ("## %s"):format(group.type.label)
    local heading = label
    if group.type.directive and group.type.directive ~= "" then
      heading = heading .. (" — %s"):format(group.type.directive)
    end
    lines[#lines + 1] = heading
    mark(#lines, 0, { end_col = #label, hl_group = "CodeReviewTitle" })
    if #heading > #label then
      mark(#lines, #label, { end_col = #heading, hl_group = "CodeReviewNote" })
    end

    -- A configured type always carries one; `types.UNTYPED` is not a configured type and
    -- has none, and falls back to what the diff draws an unresolvable type's note in.
    local bar_hl = group.type.hl or "CodeReviewNote"

    for ei, entry in ipairs(group.items) do
      index = index + 1
      -- Between entries and nowhere else: this row belongs to neither of them, which is
      -- exactly what makes the boundary visible.
      if ei > 1 then
        lines[#lines + 1] = ""
      end

      local where, tag = locate(entry)
      local room = body - (tag and vim.fn.strdisplaywidth(tag) + 2 or 0)
      where = render.truncate(where, math.max(8, room))
      local head = GUTTER .. bar .. ("%" .. digits .. "d"):format(index) .. "  " .. where
      if tag then
        head = head .. (" "):rep(math.max(1, room - vim.fn.strdisplaywidth(where) + 2)) .. tag
      end

      local row = bar_row(bar_hl, head)
      mark(row, bar_end, { end_col = bar_end + digits, hl_group = "CodeReviewQueueIndex" })
      mark(row, #indent, { end_col = #indent + #where, hl_group = "CodeReviewFileHeader" })
      if tag then
        -- From the right: the pad before it is display width and the column an extmark
        -- wants is bytes, so the only offset that can be counted on is the end.
        mark(row, #head - #tag, { end_col = #head, hl_group = "CodeReviewQueueState" })
      end

      -- The code an entry carried travels inside its bar, exactly as it did in the payload.
      -- `+`/`-` already say which side a line is, so they keep the diff's own colours.
      if entry.inline and entry.lines then
        for _, code in ipairs(entry.lines) do
          local text = indent .. render.truncate(code, body)
          local r = bar_row(bar_hl, text)
          local sign = code:sub(1, 1)
          if sign == "+" or sign == "-" then
            mark(r, #indent, { end_col = #text, hl_group = sign == "+" and "CodeReviewAdd" or "CodeReviewDel" })
          end
        end
      end

      -- Kept as the reviewer wrote it and wrapped by display width, through the renderer's
      -- own helper rather than a copy of it: splitting by byte passes every ASCII assertion
      -- and corrupts the first CJK or emoji note.
      for _, text in ipairs(render.wrap(entry.note, body)) do
        -- A blank line inside a note is a bar and nothing after it, which is what keeps the
        -- entry unbroken across one.
        bar_row(bar_hl, text == "" and (GUTTER .. bar) or (indent .. text))
      end
    end
  end

  return { lines = lines, marks = marks }
end

--- The float -------------------------------------------------------------------

---Say why a key that acts on the queue does nothing here.
---
---The keys that drop and submit are bound to this rather than left unbound, because a
---reviewer arrives with the queue float's muscle memory and `x` on a `nomodifiable` buffer
---answers `E21` -- which says the buffer cannot be changed, not why this one must not be.
local function read_only()
  info("This batch has already gone — annotate again to raise a point a second time")
end

---Read the last dispatched batch back.
---
---Keyed on the repository the queue itself is keyed on, which is the working directory's.
---A review view is not consulted and does not have to be open: a batch has already gone,
---so nothing about which window is current could change which one went last.
function M.open()
  local batch = M.last(state.ambient_root())
  local entries = batch and batch.entries or {}
  if #entries == 0 then
    -- Said rather than opened onto nothing. An empty archive is an ordinary state -- every
    -- repository is in it until the first submit -- and a float with no rows would leave a
    -- reviewer wondering which of the two had gone wrong.
    info("Nothing has been dispatched yet — there is no batch to read back")
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(100, math.max(50, math.floor(vim.o.columns * 0.8)))
  local height = math.min(28, math.max(10, math.floor(vim.o.lines * 0.7)))
  local n = #entries
  local cfg = config.get()
  -- The label as delivery worded it at the moment of dispatch, stored rather than resolved
  -- again: the target itself is a live destination this session may no longer have, and the
  -- record is of where the batch went, not of where one would go now.
  local name = batch.target or ""

  local cfg_win = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    -- What went and when, where the queue float carries what is still to go. Absolute
    -- rather than "12 minutes ago": telling this morning's batch from yesterday's is the
    -- whole reason the moment is recorded, and a stamp says it without rounding.
    title = (" Last batch · %d annotation%s · %s "):format(
      n,
      n == 1 and "" or "s",
      os.date("%Y-%m-%d %H:%M", batch.at)
    ),
    title_pos = "center",
    -- Where it went, and the one thing this surface will not do, said before a key is
    -- pressed rather than only in answer to one.
    footer = (" → %s · read-only · q close "):format(#name > 24 and (name:sub(1, 23) .. "…") or name),
    footer_pos = "center",
  }

  local win = vim.api.nvim_open_win(buf, true, cfg_win)
  -- The rows wrap themselves, to a width they know, so a bar keeps running down the left of
  -- every one of them. Letting the window wrap instead would fold a long line back to
  -- column zero, where there is no bar and no gutter, and the entry would appear to end.
  vim.wo[win].wrap = false

  local painted = build(entries, {
    types = cfg.types,
    -- The change-bar vocabulary the diff and the queue float already speak, including when
    -- a host has configured a glyph of its own.
    bar = cfg.icons.change_bar,
    width = vim.api.nvim_win_get_width(win),
  })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, painted.lines)
  -- Not merely a consequence of a scratch buffer: this is the record of a batch that has
  -- gone, and nothing typed into it could mean anything.
  vim.bo[buf].modifiable = false
  for _, m in ipairs(painted.marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, m.row, m.col, m.opts)
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "x", read_only, { buffer = buf, desc = "An archived entry cannot be dropped" })
  vim.keymap.set("n", "<C-s>", read_only, { buffer = buf, desc = "An archived batch cannot be resubmitted" })
  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "Close" })
end

return M
