---The queue read before it goes: every **entry** still waiting, and the keys that act on
---one of them or on the whole **batch**.
---
---A module of its own because the **queue** is a module-level singleton elsewhere, not part
---of any review view. A float over it needs a buffer, a window and keys and none of the
---view's mutable state, which is why it opens with no review open at all -- exactly as the
---archive float does, and for the same reason.
---
---**The review view is handed in rather than required**, as `keymaps.lua` is handed it. The
---keys here run the view's exported actions, and taking them as an argument is what keeps
---this module out of the cycle `view` and `annotate` already sit in.
---
---**Two things deliberately stayed behind there.** The jump from a queued entry into the
---diff, which reads the file list, both layouts' renders, expansion state and both panes --
---eight distinct reads of view state, and the reason this file is small. And the float's own
---window handle, which the view records so a **submit** can close a float listing a batch
---that has just gone: that is a rule about the view's windows, and moving the handle out
---would split one rule across two modules to save two accessors.
local config = require("codereview.config")
local delivery = require("codereview.delivery")
local queue = require("codereview.queue")
local render = require("codereview.render")
local types = require("codereview.types")

local M = {}

---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

---Read the persisted queue back if this session has not, and say what came back stale.
---
---The latch itself belongs to persistence, which owns the stores it reads and returns a
---count rather than phrasing one. What is left here is the sentence, worded exactly as a
---review reports staleness: with no view open this is the only moment a restored
---annotation's untrustworthy line anchors would otherwise go unmentioned.
local function ensure_queue()
  local staled = require("codereview.state").ensure_queue()
  if staled > 0 then
    info(queue.stale_phrase(staled))
  end
end

--- Rendering the queue as rows ------------------------------------------------

---Extmarks belonging to the float, in a namespace of its own so clearing them cannot
---disturb the diff's or the tree's.
local NS_QUEUE = vim.api.nvim_create_namespace("codereview_queue")

---One column to the left of every bar, reserved so a later change can put a selection
---marker there without moving anything. Nothing draws in it yet.
local GUTTER = " "

---Where a queued entry is, and what state rides on the right of its first row.
---
---Not `annotate.describe`, which folds the tag into the location because a composer title
---is one line with everything to say in it. A row has a right-hand column, so the tag reads
---as state rather than as part of the path -- and that column is where staleness now lives,
---instead of the `⚠` prefix that was this float's entire vocabulary for saying anything
---about an entry.
---@param entry CRAnnotation
---@return string where, { text: string, hl: string }[] state
local function entry_state(entry)
  local state = {}
  if entry.stale then
    state[#state + 1] = { text = "⚠ stale", hl = "CodeReviewStale" }
  end
  -- A bare note is about no file, so there is no location to print and no tag to print it
  -- with; every branch below reads a path this one does not have.
  if entry.kind == "note" then
    return "(no file)", state
  end
  -- Outside a checkout there is no repository-relative path, and the absolute one is the
  -- only name the file has.
  local where = entry.path or entry.abs_path
  if entry.kind == "file" then
    state[#state + 1] = { text = entry.tag or "whole file", hl = "CodeReviewQueueState" }
    return where, state
  end
  if entry.tag then
    state[#state + 1] = { text = entry.tag, hl = "CodeReviewQueueState" }
  end
  local range = entry.first == entry.last and tostring(entry.first) or ("%d-%d"):format(entry.first, entry.last)
  return ("%s:%s"):format(where, range), state
end

---Turn the queue into the float's rows.
---
---An entry is a run of rows carrying a bar in its annotation type's group -- its heading,
---its inlined diff block, every wrapped line of its note, and the blank lines *inside* that
---note. The blank row *between* two entries carries none. That is what makes the boundary
---hold whatever a note contains: once notes keep their own line structure, a blank line can
---no longer separate entries, because a note can contain one. It costs no extra rows over
---the flat list it replaces, and it makes an entry's type legible at every row rather than
---only where the reviewer happened to enter it.
---
---The bar is buffer text rather than an extmark, as the diff's change bar is. That is what
---keeps `rows` -- which maps *every* row to the entry owning it, not only the headings --
---trivially exact, so resolving the cursor stops being a nearest-heading-above guess and a
---reviewer can no longer drop something whose extent they cannot see.
---
---Its highlight columns are byte offsets, not display columns: the bar glyph is multibyte,
---and so is anything a host configures in its place.
---@param items CRAnnotation[]
---@param opts { types: CRType[], bar: string, width: integer }
---@return { lines: string[], marks: table[], rows: table<integer, integer> }
local function build_queue(items, opts)
  local lines, marks, rows = {}, {}, {}
  local bar = opts.bar
  local bar_col, bar_end = #GUTTER, #GUTTER + #bar
  -- Padded to the widest number in the batch, so entry 10 does not shift the column every
  -- row below it is drawn in.
  local digits = #tostring(#items)
  local indent = GUTTER .. bar .. (" "):rep(digits + 2)
  local body = math.max(8, opts.width - vim.fn.strdisplaywidth(indent))

  ---@param row integer 1-indexed
  ---@param col integer 0-indexed byte
  local function mark(row, col, o)
    marks[#marks + 1] = { row = row - 1, col = col, opts = o }
  end

  ---A row belonging to `entry`, carrying its bar and nothing else by default.
  ---@return integer row
  local function bar_row(id, group, text)
    lines[#lines + 1] = text
    rows[#lines] = id
    mark(#lines, bar_col, { end_col = bar_end, hl_group = group })
    return #lines
  end

  local index = 0
  -- The same helper the payload renders through, handed the same list: what the float
  -- shows and what the batch says have to be the one grouping, not two that agree today.
  for gi, group in ipairs(types.group(items, opts.types)) do
    if gi > 1 then
      lines[#lines + 1] = ""
    end
    local label = ("## %s"):format(group.type.label)
    local heading = label
    if group.type.directive and group.type.directive ~= "" then
      heading = heading .. (" — %s"):format(group.type.directive)
    end
    lines[#lines + 1] = heading
    -- Painted rather than inherited. The float used to set `filetype=markdown` and take
    -- whatever the `##` and `>` prefixes happened to attract, which coloured its chrome by
    -- accident and an entry's annotation type not at all.
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

      local where, state = entry_state(entry)
      local right = table.concat(
        vim.tbl_map(function(chunk)
          return chunk.text
        end, state),
        " · "
      )
      local room = body - (right ~= "" and vim.fn.strdisplaywidth(right) + 2 or 0)
      where = render.truncate(where, math.max(8, room))
      local head = GUTTER .. bar .. ("%" .. digits .. "d"):format(index) .. "  " .. where
      if right ~= "" then
        head = head .. (" "):rep(math.max(1, room - vim.fn.strdisplaywidth(where) + 2)) .. right
      end

      local row = bar_row(entry.id, bar_hl, head)
      mark(row, bar_end, { end_col = bar_end + digits, hl_group = "CodeReviewQueueIndex" })
      mark(row, #indent, { end_col = #indent + #where, hl_group = "CodeReviewFileHeader" })
      -- From the right, chunk by chunk: the pad before it is display width and the columns
      -- an extmark wants are bytes, so the only offset that can be counted on is the end.
      local col = #head
      for i = #state, 1, -1 do
        mark(row, col - #state[i].text, { end_col = col, hl_group = state[i].hl })
        col = col - #state[i].text - #" · "
      end

      -- The code an entry carries travels inside its bar. `+`/`-` already say which side a
      -- line is, so they are drawn in the colours the diff gives them.
      if entry.inline and entry.lines then
        for _, code in ipairs(entry.lines) do
          local text = indent .. render.truncate(code, body)
          local r = bar_row(entry.id, bar_hl, text)
          local sign = code:sub(1, 1)
          if sign == "+" or sign == "-" then
            mark(r, #indent, { end_col = #text, hl_group = sign == "+" and "CodeReviewAdd" or "CodeReviewDel" })
          end
        end
      end

      -- Kept as the reviewer wrote it: newlines used to be replaced with spaces before
      -- rendering, so prose that was structured read back as a run-on. Wrapped by display
      -- width, which is why the renderer's helper is shared rather than copied -- splitting
      -- by byte passes every ASCII assertion and corrupts the first CJK or emoji note.
      for _, text in ipairs(render.wrap(entry.note, body)) do
        -- A blank line inside a note is a bar and nothing after it, which is what keeps the
        -- entry unbroken across one.
        bar_row(entry.id, bar_hl, text == "" and (GUTTER .. bar) or (indent .. text))
      end
    end
  end

  return { lines = lines, marks = marks, rows = rows }
end

--- The float -------------------------------------------------------------------

---List the queued annotations, drop any of them, then submit the batch.
---@param view table The review view, whose exported actions these keys run.
function M.open(view)
  ensure_queue()
  if queue.count() == 0 then
    info("Queue is empty — annotate something first")
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(100, math.max(50, math.floor(vim.o.columns * 0.8)))
  local height = math.min(28, math.max(10, math.floor(vim.o.lines * 0.7)))
  local cfg_win = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = "",
    title_pos = "center",
    footer = "",
    footer_pos = "center",
  }

  local win = vim.api.nvim_open_win(buf, true, cfg_win)
  -- The rows wrap themselves, to a width they know, so that a bar keeps running down the
  -- left of every one of them. Letting the window wrap instead would fold a long line back
  -- to column zero, where there is no bar and no gutter, and the entry would appear to end.
  vim.wo[win].wrap = false
  -- Handed to the view so `submit` can close the float no matter which window it was
  -- triggered from; a submitted batch must never leave a dialog listing it still on screen.
  view.hold_queue_float(win)

  ---The rows on screen, and which entry each of them belongs to.
  local painted = { lines = {}, marks = {}, rows = {} }

  local function close()
    view.release_queue_float(win)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function paint_queue()
    local cfg = config.get()
    painted = build_queue(queue.all(), {
      types = cfg.types,
      -- The change-bar vocabulary the diff already speaks, including when a host has
      -- configured a glyph of its own, so an entry's bar reads as structure rather than as
      -- decoration this surface invented.
      bar = cfg.icons.change_bar,
      width = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or width,
    })

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, painted.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, NS_QUEUE, 0, -1)
    for _, m in ipairs(painted.marks) do
      pcall(vim.api.nvim_buf_set_extmark, buf, NS_QUEUE, m.row, m.col, m.opts)
    end

    local n, stale = queue.count(), queue.stale_count()
    local name = delivery.target_label()
    cfg_win.title = (" Review queue · %d annotation%s%s "):format(
      n,
      n == 1 and "" or "s",
      stale > 0 and (" · %d stale"):format(stale) or ""
    )
    cfg_win.footer = (" ^T %s · ⏎ jump · x drop · gy copy · ^S submit · ^A preamble · q close "):format(
      #name > 24 and (name:sub(1, 23) .. "…") or name
    )
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, cfg_win)
    end
  end

  ---The entry the cursor is on. Exact, because every row of an entry is mapped to it --
  ---a group heading and the blank row between two entries belong to none, and answer nil.
  local function entry_at_cursor()
    return painted.rows[vim.api.nvim_win_get_cursor(win)[1]]
  end

  ---Put the cursor back on an entry after a repaint.
  ---
  ---Dropping the last entry of a group leaves the cursor on the blank row that separated it
  ---from the next one, or on a heading -- rows that deliberately belong to nothing now that
  ---resolving one is exact. Without this, the second `x` of a run would silently do nothing.
  local function settle_cursor()
    local row = math.min(vim.api.nvim_win_get_cursor(win)[1], math.max(#painted.lines, 1))
    for _, range in ipairs({ { row, #painted.lines, 1 }, { row, 1, -1 } }) do
      for r = range[1], range[2], range[3] do
        if painted.rows[r] then
          pcall(vim.api.nvim_win_set_cursor, win, { r, 0 })
          return
        end
      end
    end
  end

  ---That entry as it sits in the queue.
  ---@param id integer|nil
  ---@return CRAnnotation|nil
  local function queued(id)
    for _, item in ipairs(queue.all()) do
      if item.id == id then
        return item
      end
    end
  end

  vim.keymap.set("n", "<CR>", function()
    local entry = queued(entry_at_cursor())
    if not entry then
      return
    end
    -- Only a jump that happened costs the list: a reviewer who pressed a key that could
    -- not act did not ask to lose what they were reading.
    if view.jump_to_entry(entry) then
      close()
    end
  end, { buffer = buf, desc = "Jump to the annotation" })

  vim.keymap.set("n", "x", function()
    local id = entry_at_cursor()
    if not id then
      return
    end
    queue.remove(id)
    if view.current() then
      view.paint()
      view.persist()
    end
    if queue.count() == 0 then
      close()
      info("Queue is now empty")
      return
    end
    paint_queue()
    settle_cursor()
  end, { buffer = buf, desc = "Drop annotation" })

  vim.keymap.set("n", "<C-t>", function()
    view.pick_target(paint_queue)
  end, { buffer = buf, desc = "Choose target" })

  -- Leaves the float open, where submitting closes it: what is on screen still describes
  -- the queue exactly, because copying took nothing out of it.
  vim.keymap.set("n", "gy", view.copy, { buffer = buf, desc = "Copy the batch to the clipboard" })

  vim.keymap.set("n", "<C-s>", function()
    close()
    view.submit()
  end, { buffer = buf, desc = "Submit the batch" })

  -- Closed first, exactly as `<C-s>` closes it: the composer opens over this list, and a
  -- batch that is about to go must not be left listed behind it.
  vim.keymap.set("n", "<C-a>", function()
    close()
    view.submit_with_preamble()
  end, { buffer = buf, desc = "Submit the batch under a preamble" })

  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close (keeps the queue)" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "Close (keeps the queue)" })

  paint_queue()
end

return M
