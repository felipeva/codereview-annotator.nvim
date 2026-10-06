---The **overlay**: the **queue** drawn on an ordinary file buffer, in a **margin** to the
---right of the buffer's window, one **card** per **entry** at the screen row of its anchor.
---
---A window and not virtual text (ADR-0010). A card has to take a cursor, and a note beside a
---line is what was asked for rather than one under it; right-aligned virtual text draws over
---any line long enough to reach it. So the margin is a split, and every scroll and resize
---rebuilds it from where each anchor sits on screen.
---
---**Not scrollbound, and that is not an oversight.** Scrollbind keeps two windows the same
---number of *lines* apart, and with wrap on in the code window a line can take three screen
---rows: the margin would drift a row per folded line above the anchor. The margin is
---instead rewritten from `screenpos`, which answers in screen rows and already knows about
---wrap, folds and filler.
---
---**Nothing here is stored.** Like **solo**, the overlay is a session-long toggle and is
---written nowhere: not to a store, not per **checkout**, not on an entry (ADR-0009). The
---code buffer's text is never touched either. What the overlay puts in it are extmarks --
---an anchor per entry, so an edit above a line moves its card with the code, and a sign on
---each covered line.
---
---Nothing of the review view is read, so it is not handed in. The margin's keys will act
---through `annotate` the way the queue float's do; that is when a view first has a reason to
---arrive here.
local config = require("codereview.config")
local git = require("codereview.git")
local payload = require("codereview.payload")
local queue = require("codereview.queue")
local render = require("codereview.render")
local types = require("codereview.types")

local M = {}

---The margin's cards and the code buffer's signs. Cleared and redrawn on every paint.
M.NS = vim.api.nvim_create_namespace("codereview_overlay")

---One extmark per drawn entry, at its anchor in the code buffer. A namespace of its own
---because it must survive the paint that clears the signs: an anchor recreated on every
---paint would sit at the recorded line again, and the card would stop following the code.
M.NS_ANCHOR = vim.api.nvim_create_namespace("codereview_overlay_anchor")

---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

--- The layout, as data ----------------------------------------------------------

---@class CROverlayCard
---@field row integer|nil  The margin row its anchor is beside; nil when out of the window
---@field height integer   Rows the card takes in full
---@field pinned boolean|nil A whole-file card, about no row

---@class CROverlaySlot
---@field start integer First margin row the card is drawn on
---@field rows integer  How many of its rows fit above the bottom

---Where each card starts in a margin `height` rows tall.
---
---Pure, so that the rules a reviewer reads off the margin can be stated without a screen.
---A pinned card is about no row, so it takes the top in the order given and no scroll moves
---it. Every other card wants its anchor's row, and gets it unless the card above it is still
---running there, in which case it starts where that one ends: a card is never drawn over
---another. A card whose anchor is out of the window is not drawn, and a card that runs past
---the bottom is cut there rather than scrolled to -- the margin never scrolls on its own.
---
---Cards on one row keep the order they were given in, which is the order the queue holds
---them in.
---@param cards CROverlayCard[]
---@param height integer
---@return (CROverlaySlot|false)[] slots One per card, in the order given; false where not drawn
function M.layout(cards, height)
  local slots, order = {}, {}
  for i, card in ipairs(cards) do
    slots[i] = false
    if card.pinned or card.row then
      order[#order + 1] = i
    end
  end
  -- Pinned first, then by anchor row; the index breaks ties, because `table.sort` is not
  -- stable and two entries on one line must keep queue order.
  table.sort(order, function(a, b)
    local ca, cb = cards[a], cards[b]
    local ra, rb = ca.pinned and 0 or ca.row, cb.pinned and 0 or cb.row
    if ra ~= rb then
      return ra < rb
    end
    return a < b
  end)

  local free = 1
  for _, i in ipairs(order) do
    local card = cards[i]
    local start = math.max(card.pinned and 1 or card.row, free)
    if start <= height and card.height > 0 then
      slots[i] = { start = start, rows = math.min(card.height, height - start + 1) }
      free = start + card.height
    end
  end
  return slots
end

--- What a buffer is about ----------------------------------------------------------

---The checkout and repository-relative path of the file a buffer holds, or nothing.
---
---Resolved the way a capture resolves its buffer, because a review-path entry carries a
---relative path and an absolute one built from the review's root, and only the pair
---(root, relative path) is the same answer from both sides. `root_cached`, not `root`:
---this runs on every scroll, and a git process per scroll is not a price the overlay may
---charge.
---
---Nothing for a buffer that is not a file on disk -- a help page, a terminal, a scratch
---buffer -- and nothing for one the plugin owns, which all carry a `buftype`.
---@param buf integer
---@return { root: string, rel: string }|nil
local function file_of(buf)
  if vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:find("^codereview://") then
    return nil
  end
  local abs = vim.uv.fs_realpath(name)
  if not abs then
    return nil
  end
  local root = git.root_cached(vim.fs.dirname(abs))
  local rel = root and payload.relative_to(abs, root)
  if not rel then
    return nil
  end
  return { root = root, rel = rel }
end

---Whether an entry anchors on a line this buffer cannot show.
---
---A pure deletion is anchored on the pre-image, and the file on disk is the post-image: its
---recorded number names a line that is not there. A range mixing both images keys on
---whichever line came first, so the key alone would throw out a change that has post-image
---lines to stand on; the tag is what says the range has none.
---@param entry CRAnnotation
---@return boolean
local function pre_image(entry)
  return render.is_before_key(entry.key) and entry.tag == "deleted"
end

--- A card, as rows ------------------------------------------------------------------

---The lines a card names: `12`, or `12–15` with an en dash.
---@param entry CRAnnotation
---@return string
local function lines_label(entry)
  if entry.kind == "file" then
    return entry.tag or "whole file"
  end
  if entry.first == entry.last then
    return tostring(entry.first)
  end
  return ("%d–%d"):format(entry.first, entry.last)
end

---What a card is drawn in: its type's group and icon, and the name its header gives it.
---
---An untyped entry carries no type, so its header carries no name; the untyped mark and the
---note group stand in, as they do wherever the queue is drawn. A type the configuration no
---longer has keeps its name -- the entry still says it -- in the note group.
---@param entry CRAnnotation
---@return { hl: string, icon: string, name: string|nil }
local function look(entry)
  if not entry.type then
    return { hl = "CodeReviewNote", icon = types.UNTYPED.icon, name = nil }
  end
  local t = types.get(config.get().types, entry.type)
  if not t then
    return { hl = "CodeReviewNote", icon = config.get().icons.annotated, name = entry.type }
  end
  return { hl = t.hl, icon = t.icon, name = t.name }
end

---A card's rows and the marks on them, at row 0.
---
---Every row starts with the rule, which is the only thing that says where one card ends and
---the next begins: stacked cards have no blank row between them and no box around them.
---The budget the note wraps to and the column it starts at come from one `strdisplaywidth`
---of the rule and its space, and the mark columns from its byte length -- the rule is a
---multibyte glyph, so the two are different numbers.
---@param entry CRAnnotation
---@param width integer Display columns the margin has
---@return { lines: string[], marks: { row: integer, col: integer, end_col: integer, hl: string }[] }
local function card(entry, width)
  local rule = config.get().icons.change_bar
  local prefix = rule .. " "
  local budget = math.max(1, width - vim.fn.strdisplaywidth(prefix))
  local look_ = look(entry)
  local lines, marks = {}, {}

  local function row(text)
    lines[#lines + 1] = prefix .. text
    marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #rule, hl = look_.hl }
    return #lines - 1
  end

  local stale = entry.stale and "⚠ stale" or nil
  local head = look_.icon .. (look_.name and (" " .. look_.name) or "") .. " " .. lines_label(entry)
  head = render.truncate(head, math.max(1, budget - (stale and vim.fn.strdisplaywidth(stale) + 1 or 0)))
  local text = stale and (head .. " " .. stale) or head
  local r = row(text)
  marks[#marks + 1] = { row = r, col = #prefix, end_col = #prefix + #head, hl = look_.hl }
  if stale then
    marks[#marks + 1] = { row = r, col = #prefix + #head + 1, end_col = #prefix + #text, hl = "CodeReviewStale" }
  end

  for _, line in ipairs(render.wrap(entry.note or "", budget)) do
    r = row(line)
    if line ~= "" then
      marks[#marks + 1] = { row = r, col = #prefix, end_col = #prefix + #line, hl = "CodeReviewNote" }
    end
  end
  return { lines = lines, marks = marks }
end

--- The margin -----------------------------------------------------------------------

---@class CROverlayMargin
---@field win integer  The margin window
---@field buf integer  Its buffer, which the plugin owns
---@field code integer The window it was opened beside, whose buffer it draws

---One margin per tab page, keyed by the tab page's handle.
---@type table<integer, CROverlayMargin>
local margins = {}

---Code buffers this session has drawn signs into, so turning the overlay off can clear them.
---@type table<integer, boolean>
local signed = {}

local GROUP = "codereview_overlay"

---Whether the overlay is on, for the rest of this session.
---@return boolean
function M.enabled()
  return config.overlay()
end

---@param m CROverlayMargin|nil
---@return boolean
local function live(m)
  return m ~= nil and vim.api.nvim_win_is_valid(m.win) and vim.api.nvim_win_is_valid(m.code)
end

---The margin of the current tab page, when there is one still standing.
---@return CROverlayMargin|nil
function M.margin()
  local m = margins[vim.api.nvim_get_current_tabpage()]
  return live(m) and m or nil
end

---The first screen row of a window's text, below its winbar if it has one.
---@param win integer
---@return integer
local function text_top(win)
  local info_ = vim.fn.getwininfo(win)[1]
  return info_.winrow + (info_.winbar or 0)
end

---Where an anchor's line sits, as a margin row; nil when the line is not on screen.
---
---Read off the screen rather than counted, so a line folded onto three rows above the anchor
---puts the card three rows down, and a closed fold puts it on the fold's row. Measured from
---each window's own text top, so a winbar on one and not the other does not shift the card.
---@param m CROverlayMargin
---@param line integer 1-based
---@return integer|nil
local function margin_row(m, line)
  local top, bottom = vim.fn.line("w0", m.code), vim.fn.line("w$", m.code)
  if line < top or line > bottom then
    return nil
  end
  local pos = vim.fn.screenpos(m.code, line, 1)
  if pos.row == 0 then
    return nil
  end
  return pos.row - text_top(m.win) + 1
end

---Entry id to anchor extmark, per code buffer. Kept here rather than read back from the
---buffer, because an extmark carries no field for the entry it stands for.
---@type table<integer, table<integer, integer>>
local anchors = {}

---The line an entry's anchor sits on now, creating the anchor at the recorded line the
---first time this buffer is painted with the entry in it.
---@param buf integer
---@param entry CRAnnotation
---@return integer line 1-based
local function anchor_line(buf, entry)
  anchors[buf] = anchors[buf] or {}
  local id = anchors[buf][entry.id]
  if id then
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_ANCHOR, id, {})
    if pos[1] then
      return pos[1] + 1
    end
  end
  anchors[buf][entry.id] = vim.api.nvim_buf_set_extmark(buf, M.NS_ANCHOR, entry.first - 1, 0, {})
  return entry.first
end

---Drop the anchors of entries no longer drawn in a buffer, so a dropped entry captured
---again later is not drawn where the dropped one had drifted to.
---@param buf integer
---@param kept table<integer, boolean>
local function prune_anchors(buf, kept)
  for id, mark in pairs(anchors[buf] or {}) do
    if not kept[id] then
      pcall(vim.api.nvim_buf_del_extmark, buf, M.NS_ANCHOR, mark)
      anchors[buf][id] = nil
    end
  end
end

---Write rows into the margin's buffer, which is read-only to everyone else.
---@param buf integer
---@param lines string[]
local function write(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

---The entries a buffer's file holds, in queue order, and how many of them cannot be drawn.
---@param buf integer
---@return CRAnnotation[] drawn, integer skipped
local function entries_of(buf)
  local file = file_of(buf)
  if not file then
    return {}, 0
  end
  local state = require("codereview.state")
  -- Read back before the queue is asked, or a session's first paint draws an empty margin
  -- over a stored queue. Said in the queue's own wording, as every other first read is.
  local staled = state.ensure_queue()
  if staled > 0 then
    info(queue.stale_phrase(staled))
  end
  -- The queue in memory is the current checkout's and the entries that belong to none.
  -- The second kind carry no relative path, so the path test below already leaves them
  -- out; what it cannot leave out is another checkout's file at the same relative path.
  if file.root ~= state.current_checkout() then
    return {}, 0
  end
  local total = vim.api.nvim_buf_line_count(buf)
  local drawn, skipped = {}, 0
  for _, entry in ipairs(queue.all()) do
    if entry.path == file.rel and entry.kind ~= "note" then
      if entry.kind ~= "file" and (pre_image(entry) or not entry.first or entry.first > total) then
        skipped = skipped + 1
      else
        drawn[#drawn + 1] = entry
      end
    end
  end
  return drawn, skipped
end

---Repaint one margin from the code buffer beside it.
---@param m CROverlayMargin
---@return integer skipped Entries of the file the margin cannot draw
local function paint_margin(m)
  local buf = vim.api.nvim_win_get_buf(m.code)
  local drawn, skipped = entries_of(buf)

  -- Signs and anchors first, because the card rows are read off the anchors.
  vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
  signed[buf] = true
  local bar = config.get().icons.change_bar
  local total = vim.api.nvim_buf_line_count(buf)
  local kept, cards = {}, {}
  local width = vim.api.nvim_win_get_width(m.win)
  -- Measured inside the margin, which does not wrap. `strdisplaywidth` counts in the current
  -- window, and in a window that wraps, a double-width character that crosses its right edge
  -- costs one cell more than it draws: a note wrapped while a narrow code window was current
  -- would break a character early.
  local built = vim.api.nvim_win_call(m.win, function()
    return vim.tbl_map(function(entry)
      return card(entry, width)
    end, drawn)
  end)
  for i, entry in ipairs(drawn) do
    local c = built[i]
    if entry.kind == "file" then
      cards[i] = { pinned = true, height = #c.lines }
    else
      kept[entry.id] = true
      local line = anchor_line(buf, entry)
      local last = math.min(total, line + (entry.last or entry.first) - entry.first)
      for l = line, last do
        vim.api.nvim_buf_set_extmark(buf, M.NS, l - 1, 0, { sign_text = bar, sign_hl_group = look(entry).hl })
      end
      cards[i] = { row = margin_row(m, line), height = #c.lines }
    end
  end
  prune_anchors(buf, kept)

  local height = vim.api.nvim_win_get_height(m.win)
  local rows = {}
  for r = 1, height do
    rows[r] = ""
  end
  local marks = {}
  for i, slot in ipairs(M.layout(cards, height)) do
    if slot then
      for r = 1, slot.rows do
        rows[slot.start + r - 1] = built[i].lines[r]
      end
      for _, mark in ipairs(built[i].marks) do
        if mark.row < slot.rows then
          marks[#marks + 1] = { row = slot.start - 1 + mark.row, col = mark.col, end_col = mark.end_col, hl = mark.hl }
        end
      end
    end
  end

  vim.api.nvim_buf_clear_namespace(m.buf, M.NS, 0, -1)
  write(m.buf, rows)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(m.buf, M.NS, mark.row, mark.col, { end_col = mark.end_col, hl_group = mark.hl })
  end
  -- The buffer is exactly as tall as the window, but a reviewer can still scroll it by hand,
  -- and a margin left scrolled puts every card a row away from its anchor.
  vim.api.nvim_win_call(m.win, function()
    vim.fn.winrestview({ topline = 1 })
  end)
  return skipped
end

local painting = false

---Repaint every margin standing, from the queue as it is now.
---
---What everything that changes the queue calls afterwards, and what a scroll or a resize of
---the window a margin is beside calls. Does nothing while the overlay is off, so a capture
---made with the overlay off stays invisible rather than turning it on.
---@return integer skipped Entries the current tab page's margin could not draw
function M.paint()
  if painting or not M.enabled() then
    return 0
  end
  painting = true
  local current = vim.api.nvim_get_current_tabpage()
  local skipped = 0
  local ok, err = pcall(function()
    for tab, m in pairs(margins) do
      if live(m) then
        local n = paint_margin(m)
        if tab == current then
          skipped = n
        end
      end
    end
  end)
  painting = false
  if not ok then
    error(err, 0)
  end
  return skipped
end

---Whether an event concerns a window some margin follows or is.
---@param ids table<integer, boolean>
---@return boolean
local function concerns(ids)
  for _, m in pairs(margins) do
    if ids[m.code] or ids[m.win] then
      return true
    end
  end
  return false
end

---Listen for what moves an anchor on screen: a scroll and a resize of the window a margin
---is beside. Not `VimResized`, which arrives with every terminal resize together with
---`WinResized` and would paint each margin twice.
local function listen()
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      local ids = {}
      for key in pairs(vim.v.event) do
        local id = tonumber(key)
        if id then
          ids[id] = true
        end
      end
      if concerns(ids) then
        M.paint()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      local ids = {}
      for _, id in ipairs(vim.v.event.windows or {}) do
        ids[id] = true
      end
      if concerns(ids) then
        M.paint()
      end
    end,
  })
end

---Open a margin beside a window, in that window's tab page, if none stands there.
---
---A split rather than a float, so the code window gives up the columns rather than having
---them drawn over; `split = "right"` of that one window rather than `botright`, because the
---margin belongs beside the window it reads and not at the edge of the tab. Focus stays
---where it was.
---@param win integer
---@return CROverlayMargin
local function open(win)
  local tab = vim.api.nvim_win_get_tabpage(win)
  local m = margins[tab]
  if live(m) then
    return m
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "codereview-overlay"
  vim.bo[buf].modifiable = false
  local mwin = vim.api.nvim_open_win(buf, false, {
    split = "right",
    win = win,
    width = config.get().overlay.width,
  })
  local wo = vim.wo[mwin]
  wo.winfixwidth = true
  -- The card rows are cut to the margin's width here, so the window must not fold them back
  -- to column zero, where there is no rule.
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.list = false
  wo.spell = false
  wo.cursorline = false
  m = { win = mwin, buf = buf, code = win }
  margins[tab] = m
  return m
end

---Close every margin and take the signs out of every buffer they were drawn in.
---
---The anchors stay. They are not drawn, and an edit made while the overlay is off still
---moves them, so a card comes back beside the code it was about.
local function close_all()
  for tab, m in pairs(margins) do
    if vim.api.nvim_win_is_valid(m.win) then
      pcall(vim.api.nvim_win_close, m.win, true)
    end
    margins[tab] = nil
  end
  for buf in pairs(signed) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
    end
    signed[buf] = nil
  end
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
end

---The sentence a toggle ends in.
---@param on boolean
---@param skipped integer
---@return string
local function said(on, skipped)
  if not on then
    return "Overlay off"
  end
  if skipped == 0 then
    return "Overlay on"
  end
  return ("Overlay on — %d annotation%s not drawn: on a deleted line, or past the end of the file"):format(
    skipped,
    skipped == 1 and "" or "s"
  )
end

---Draw the margin beside the current window: open it and paint it.
---@return integer skipped
local function show()
  open(vim.api.nvim_get_current_win())
  listen()
  return M.paint()
end

---Turn the overlay on or off for the rest of this session, and say so.
---@return boolean on The state it is now in
function M.toggle()
  local on = config.toggle_overlay()
  local skipped = 0
  if on then
    skipped = show()
  else
    close_all()
  end
  info(said(on, skipped))
  return on
end

---Open the margin for a session configured with the overlay on.
---
---Beside whichever window is current once startup has finished, which is the window the
---files given on the command line were loaded into. A host that loads the plugin late has
---already entered, and gets the margin at once.
function M.start()
  if not M.enabled() then
    return
  end
  if vim.v.vim_did_enter == 1 then
    show()
    return
  end
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
      if M.enabled() then
        show()
      end
    end,
  })
end

return M
