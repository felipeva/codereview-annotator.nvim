---The **overlay**: the **queue** drawn on an ordinary file buffer, in one of two styles. In
---the margin style, a **margin** to the right of the buffer's window, one **card** per
---**entry** at the screen row of its anchor. In the inline style, one **caption** per entry,
---a virtual line above its anchor line. One toggle, one set of rules -- which entries, which
---are skipped, the stale flag, the sign on each covered line -- and two drawings.
---
---The margin is a window and not virtual text (ADR-0010). A card has to take a cursor, and a
---note beside a line is what was asked for rather than one under it; right-aligned virtual
---text draws over any line long enough to reach it. So the margin is a split, and every
---scroll and resize rebuilds it from where each anchor sits on screen.
---
---The caption is virtual text (ADR-0011): it takes no cursor, and a virtual *line* takes a
---row of its own and draws over nothing. It hangs on the entry's anchor, so the code carries
---it, and nothing in it depends on a screen row: it paints on entering a buffer, on a queue
---change -- in every buffer that holds captions -- on a resize and on a write, and never on a
---scroll. No window, no keys, no quiet line.
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
---an anchor per entry, so an edit above a line moves its card or its caption with the code,
---the captions themselves hung on those anchors, and a sign on each covered line.
---
---**It follows the reviewer.** In both styles the overlay follows one window per tab page,
---and the inline style paints that window's buffer; what follows here is the margin's. One
---margin per tab page, beside the window it follows; the
---cursor entering a split that holds a file moves it there, and that window's buffer changing
---repaints it. Floats and the margin itself are never followed. Beside a file with nothing to
---draw it holds one quiet line; beside a window holding no file it closes and the toggle stays
---on. Closing it by hand turns the toggle off. The window events this rides on arrive in an
---order that does not say what the reviewer did, so several decisions wait a tick -- each one
---says why where it is made.
---
---**The review view is handed in rather than required**, as the queue float is handed it.
---The margin's keys are the float's keys, and the ones that act on the whole **batch** --
---the target, the copy, both submits -- run the view's exported actions, which work with no
---review open. Requiring `view` for them would close a cycle through `delivery`, which
---repaints this module. The keys that act on one **entry** reach `annotate` function-locally,
---as the float's do, so the margin, the float and the diff edit through one path.
local config = require("codereview.config")
local git = require("codereview.git")
local payload = require("codereview.payload")
local queue = require("codereview.queue")
local render = require("codereview.render")
local types = require("codereview.types")

local M = {}

---The margin's cards, the code buffer's signs, and the captions of whole-file entries, which
---have no anchor. Cleared and redrawn on every paint.
M.NS = vim.api.nvim_create_namespace("codereview_overlay")

---One extmark per drawn entry, at its anchor in the code buffer. A namespace of its own
---because it must survive the paint that clears the signs: an anchor recreated on every
---paint would sit at the recorded line again, and the card would stop following the code.
---In the inline style the captions hang on these marks, so an edit above moves them too.
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

---Whether a buffer holds a file, in or out of any checkout: what decides whether the margin
---stands beside it at all.
---
---A different question from `file_of`, and the difference is the margin's empty state. A
---file of another checkout, of no checkout, or one not yet written is still a file a reviewer
---is reading, and the margin stays up with its empty line, so moving between files does not
---make the layout jump. A help page, a terminal, a scratch buffer and every buffer the plugin
---owns carry a `buftype` or a name with a scheme, and the margin closes beside them.
---@param buf integer
---@return boolean
local function is_file(buf)
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and not name:find("^%a[%w+.-]*://")
end

---The checkout and repository-relative path of the file a buffer holds, or nothing.
---
---Resolved the way a capture resolves its buffer, because a review-path entry carries a
---relative path and an absolute one built from the review's root, and only the pair
---(root, relative path) is the same answer from both sides. `root_cached`, not `root`:
---this runs on every scroll, and a git process per scroll is not a price the overlay may
---charge.
---
---Nothing for a buffer that is not a file (see `is_file`), and nothing for a file outside
---every checkout.
---@param buf integer
---@return { root: string, rel: string }|nil
local function file_of(buf)
  if not is_file(buf) then
    return nil
  end
  local abs = vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf))
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

---What a card or a caption is drawn in: its type's group and icon, and the name a card's
---header gives it. The group covers the note as well as the glyph, because the type is the
---one thing about an entry that changes what the agent is told to do, and a note in grey
---left a reviewer reading every glyph to sort the bugs from the nitpicks.
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
      marks[#marks + 1] = { row = r, col = #prefix, end_col = #prefix + #line, hl = look_.hl }
    end
  end
  return { lines = lines, marks = marks }
end

--- A caption, as virtual lines ------------------------------------------------------

---A caption's rows, as `virt_lines` chunks.
---
---The first row is the connector, the icon and the note's first line in the type's group,
---with the stale flag in its own group between them when it is set; the rest of the note
---follows under that line, in the type's group too. The budget
---the note wraps to and the indent of its continuation rows come from one `strdisplaywidth`
---of everything before the note, so the two cannot disagree: the connector is a two-column
---glyph of six bytes, and a byte count would push every continuation row past the edge.
---
---The note is wrapped in full rather than cut, because a virtual line clips at the window's
---edge even under `wrap` and the part written last is the part that would go.
---@param entry CRAnnotation
---@param width integer Display columns of the window's text, after its number, sign and fold columns
---@return table[] rows
local function caption(entry, width)
  local look_ = look(entry)
  local stale = entry.stale and "⚠ stale " or nil
  local lead = config.get().icons.caption .. " " .. look_.icon .. " "
  local indent = vim.fn.strdisplaywidth(lead .. (stale or ""))
  local rows = {}
  for n, line in ipairs(render.wrap(entry.note or "", math.max(1, width - indent))) do
    if n == 1 then
      local row = { { lead, look_.hl } }
      if stale then
        row[#row + 1] = { stale, "CodeReviewStale" }
      end
      row[#row + 1] = { line, look_.hl }
      rows[1] = row
    else
      rows[n] = { { (" "):rep(indent) }, { line, look_.hl } }
    end
  end
  return rows
end

--- The margin -----------------------------------------------------------------------

---@class CROverlayMargin
---@field code integer|nil The window it follows, whose buffer it draws; nil from that window
---                        closing until the next one is entered
---@field win integer|nil  The margin window; nil while the window it follows holds no file
---@field buf integer|nil  Its buffer, which the plugin owns
---@field dismissed boolean|nil Closed by the reviewer, until the next tick says whether that
---                        was the margin alone or its whole tab page
---@field rows table<integer, integer>|nil Margin row to the id of the entry drawn on it, as of
---                        the last paint; every row of a card, header and note alike
---@field cards { id: integer, start: integer, line: integer|nil }[]|nil The cards drawn at the
---                        last paint, top to bottom: the row each starts on and the line its
---                        anchor sat on, nil for a whole-file card

---One margin per tab page, keyed by the tab page's handle. A tab page with an entry and no
---margin window is one whose followed window holds no file: the toggle is still on there,
---and the margin comes back when a file does.
---@type table<integer, CROverlayMargin>
local margins = {}

---Code buffers this session has drawn signs or captions into, so turning the overlay off, or
---switching its style, can clear them.
---@type table<integer, boolean>
local signed = {}

local GROUP = "codereview_overlay"

---What a margin says beside a file it has no card for. The same line for a file of another
---checkout or of none: what the reviewer needs to know is that nothing here is drawn, and the
---margin staying up is what stops the layout jumping between files.
local EMPTY = "no annotations in this file"

---Whether the overlay is on, for the rest of this session.
---@return boolean
function M.enabled()
  return config.overlay()
end

---Which drawing it uses, for the rest of this session.
---@return "margin"|"inline"
function M.style()
  return config.overlay_style()
end

---Whether a margin's window is up and still holds the margin's buffer.
---@param m CROverlayMargin|nil
---@return boolean
local function standing(m)
  return m ~= nil and m.win ~= nil and vim.api.nvim_win_is_valid(m.win) and vim.api.nvim_win_get_buf(m.win) == m.buf
end

---@param m CROverlayMargin|nil
---@return boolean
local function live(m)
  return standing(m) and m.code ~= nil and vim.api.nvim_win_is_valid(m.code)
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

---What the file on disk and its buffer captures were at the last rehash, per absolute path.
---@type table<string, string>
local judged = {}

---Judge the file's buffer captures against the file on disk again, when it can have moved.
---
---A restore judges a checkout's captures once, and a file edited after that would otherwise
---keep a card saying nothing over lines that have changed. Only captures from a buffer: their
---**blob** is the working tree's, so the file on disk is what they are judged against. A
---review-path entry's blob is an index or commit blob, which the working file may differ from
---for good reasons, and it keeps what the review view last judged.
---
---Gated, because the paint runs on every scroll and a `git hash-object` per scroll is a
---process a reviewer reading a file would pay for nothing. The gate is the file's stat, not
---the buffer's `changedtick`: the capture hashed the file on disk, so an edit not yet written
---cannot change the answer, and a change made outside Neovim -- a checkout, another editor --
---moves the stat and no tick. The ids of the file's captures are in the key too, so an entry
---arriving between two paints is judged before it is drawn.
---@param file { root: string, rel: string }
---@param ids integer[] The file's buffer captures, in queue order
local function rehash(file, ids)
  if #ids == 0 then
    return
  end
  local abs = vim.fs.joinpath(file.root, file.rel)
  local st = vim.uv.fs_stat(abs)
  local key = (st and ("%d.%d:%d"):format(st.mtime.sec, st.mtime.nsec, st.size) or "gone")
    .. "|"
    .. table.concat(ids, ",")
  if judged[abs] == key then
    return
  end
  judged[abs] = key
  require("codereview.state").reconcile_queue(file.root, file.rel)
end

---The entries a buffer's file holds, in queue order, and how many of them cannot be drawn.
---
---`judge` is false for a buffer the reviewer is not in, which a queue change repaints and
---must not hash. The gate cannot be trusted to hold there: its key has the ids of the file's
---captures in it, so a drop of one of them reads as a change and would spawn the process.
---@param buf integer
---@param judge boolean Rehash the file's buffer captures, through the gate
---@return CRAnnotation[] drawn, integer skipped
local function entries_of(buf, judge)
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
  local drawn, skipped, captured = {}, 0, {}
  for _, entry in ipairs(queue.all()) do
    if entry.path == file.rel and entry.kind ~= "note" then
      if entry.worktree then
        captured[#captured + 1] = entry.id
      end
      if entry.kind ~= "file" and (pre_image(entry) or not entry.first or entry.first > total) then
        skipped = skipped + 1
      else
        drawn[#drawn + 1] = entry
      end
    end
  end
  -- Before any card is built, since the card is where the flag is read.
  if judge then
    rehash(file, captured)
  end
  return drawn, skipped
end

---Draw the sign on every covered line of a buffer and settle each drawn entry's anchor, the
---same in both styles: the line each anchor sits on now, by the entry's index in `drawn`, nil
---for a whole-file entry, which has no anchor.
---@param buf integer
---@param drawn CRAnnotation[]
---@return table<integer, integer> anchored
local function anchor_and_sign(buf, drawn)
  vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
  signed[buf] = true
  local bar = config.get().icons.change_bar
  local total = vim.api.nvim_buf_line_count(buf)
  local kept, anchored = {}, {}
  for i, entry in ipairs(drawn) do
    if entry.kind ~= "file" then
      kept[entry.id] = true
      local line = anchor_line(buf, entry)
      anchored[i] = line
      local last = math.min(total, line + (entry.last or entry.first) - entry.first)
      for l = line, last do
        vim.api.nvim_buf_set_extmark(buf, M.NS, l - 1, 0, { sign_text = bar, sign_hl_group = look(entry).hl })
      end
    end
  end
  prune_anchors(buf, kept)
  return anchored
end

---Repaint one margin from the code buffer beside it.
---@param m CROverlayMargin
---@return integer skipped Entries of the file the margin cannot draw
local function paint_margin(m)
  local buf = vim.api.nvim_win_get_buf(m.code)
  local drawn, skipped = entries_of(buf, true)

  -- Signs and anchors first, because the card rows are read off the anchors.
  local anchored = anchor_and_sign(buf, drawn)
  local cards = {}
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
    if entry.kind == "file" then
      cards[i] = { pinned = true, height = #built[i].lines }
    else
      cards[i] = { row = margin_row(m, anchored[i]), height = #built[i].lines }
    end
  end

  local height = vim.api.nvim_win_get_height(m.win)
  local rows = {}
  for r = 1, height do
    rows[r] = ""
  end
  local marks = {}
  m.rows, m.cards = {}, {}
  for i, slot in ipairs(M.layout(cards, height)) do
    if slot then
      for r = 1, slot.rows do
        rows[slot.start + r - 1] = built[i].lines[r]
        m.rows[slot.start + r - 1] = drawn[i].id
      end
      m.cards[#m.cards + 1] = { id = drawn[i].id, start = slot.start, line = anchored[i] }
      for _, mark in ipairs(built[i].marks) do
        if mark.row < slot.rows then
          marks[#marks + 1] = { row = slot.start - 1 + mark.row, col = mark.col, end_col = mark.end_col, hl = mark.hl }
        end
      end
    end
  end
  table.sort(m.cards, function(a, b)
    return a.start < b.start
  end)
  if #drawn == 0 then
    rows[1] = EMPTY
    marks[#marks + 1] = { row = 0, col = 0, end_col = #EMPTY, hl = "CodeReviewOverlayEmpty" }
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

---Take every caption out of a buffer and keep its anchors where the code has moved them.
---
---An anchor's captions go by setting the mark again at its own position with nothing on it:
---deleting it would lose the place an edit made while the overlay was off still moves.
---@param buf integer
local function strip(buf)
  vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
  for _, mark in pairs(anchors[buf] or {}) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_ANCHOR, mark, {})
    if pos[1] then
      vim.api.nvim_buf_set_extmark(buf, M.NS_ANCHOR, pos[1], pos[2], { id = mark })
    end
  end
end

---The text width each buffer's captions were last wrapped to, for a repaint of a buffer no
---window shows: it is wrapped as it was, and the enter that shows it again wraps it anew.
---@type table<integer, integer>
local widths = {}

---Repaint the captions of one buffer, wrapped to the text width of `win`.
---
---Every caption of one line hangs on one mark, the anchor of the first of them in queue
---order, with whole-file entries ahead of the rest on line 1. Not one block per anchor:
---Neovim stacks the virtual lines of two marks on one row in the order the marks were
---made, and an anchor made late -- an entry past the end until the file grew -- would draw
---above an older entry's.
---
---A whole-file entry has no anchor, as it has no line; when nothing on line 1 has one either,
---its caption hangs on a mark of the paint's own, at the top of the buffer.
---@param buf integer
---@param win integer|nil A window showing it; nil when none does
---@param judge boolean Rehash its file's buffer captures (see `entries_of`)
---@return integer skipped Entries of the file the captions cannot draw
local function paint_captions(buf, win, judge)
  if not is_file(buf) then
    return 0
  end
  local drawn, skipped = entries_of(buf, judge)
  local anchored = anchor_and_sign(buf, drawn)
  -- The signs and anchors are gone already, and their captions with them; a file with
  -- nothing to draw is the common case on an enter, and it costs no redraw.
  if #drawn == 0 then
    return skipped
  end

  local width = widths[buf]
  if win then
    -- After the signs: under `signcolumn=auto` the first sign is what opens the column, and
    -- the window reports its new text offset only once it has been redrawn. Measured: 0
    -- before the redraw, 2 after. `nvim__redraw` would confine it to the one window, but it
    -- is not API.
    vim.cmd("redraw")
    width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
    widths[buf] = width
  end
  -- Hidden, and never wrapped: the signs are drawn, and the enter that shows it draws the rest.
  if not width then
    return skipped
  end
  -- Measured in the window the rows are for: `strdisplaywidth` counts in the current window,
  -- and the current window can be the queue float, narrower than the code (see the margin's
  -- note on the same trap). Every row is no wider than this window's text, so no
  -- double-width character crosses its edge and the count is the drawn one.
  local built = vim.api.nvim_win_call(win or 0, function()
    return vim.tbl_map(function(entry)
      return caption(entry, width)
    end, drawn)
  end)

  local groups = {}
  local function add(line, i)
    groups[line] = groups[line] or { rows = {} }
    local g = groups[line]
    if not g.carrier and anchored[i] then
      g.carrier = anchors[buf][drawn[i].id]
    end
    vim.list_extend(g.rows, built[i])
  end
  for i, entry in ipairs(drawn) do
    if entry.kind == "file" then
      add(1, i)
    end
  end
  for i in ipairs(drawn) do
    if anchored[i] then
      add(anchored[i], i)
    end
  end

  local carried = {}
  for _, g in pairs(groups) do
    if g.carrier then
      carried[g.carrier] = g.rows
    else
      vim.api.nvim_buf_set_extmark(buf, M.NS, 0, 0, { virt_lines = g.rows, virt_lines_above = true })
    end
  end
  for _, mark in pairs(anchors[buf] or {}) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS_ANCHOR, mark, {})
    if pos[1] then
      local rows = carried[mark]
      vim.api.nvim_buf_set_extmark(buf, M.NS_ANCHOR, pos[1], pos[2], {
        id = mark,
        virt_lines = rows,
        virt_lines_above = rows ~= nil or nil,
      })
    end
  end

  -- Virtual lines above line 1 are filler above the window's top line, and Neovim shows
  -- none of it until the window is scrolled up into it: measured, a window at its top draws
  -- line 1 first and the caption only after `<C-y>`. So a window already at its top is
  -- scrolled to show them; one scrolled down is left where the reviewer put it.
  if win and groups[1] and vim.fn.line("w0", win) == 1 then
    local fill = vim.api.nvim_win_text_height(win, { start_row = 0, end_row = 0 }).fill
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topfill = fill })
    end)
  end
  return skipped
end

local painting = false

---Run a paint, unless one is running already: a paint can raise the events that ask for one.
---@param fn fun(): integer
---@return integer skipped
local function exclusive(fn)
  if painting or not M.enabled() then
    return 0
  end
  painting = true
  local ok, res = pcall(fn)
  painting = false
  if not ok then
    error(res, 0)
  end
  return res
end

---A window showing a buffer, for its captions' width: one in the current tab page if there is
---one, and never a float.
---@param buf integer
---@return integer|nil
local function shown_in(buf)
  local current = vim.api.nvim_get_current_tabpage()
  local elsewhere
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      if vim.api.nvim_win_get_tabpage(win) == current then
        return win
      end
      elsewhere = elsewhere or win
    end
  end
  return elsewhere
end

---Repaint every margin standing, or in the inline style the captions of every buffer that
---holds them, from the queue as it is now.
---
---What everything that changes the queue calls afterwards, and what a scroll or a resize of
---the window a margin is beside calls. Does nothing while the overlay is off, so a capture
---made with the overlay off stays invisible rather than turning it on.
---
---The followed window and not the current one, so a drop from the queue float, which is
---current while it runs, repaints the buffer under it. In the inline style every other
---loaded buffer painted this session is repainted after it, because a caption is on the
---buffer and a dropped entry's caption would otherwise stay up wherever the reviewer is not.
---Those cost extmarks and no git process: only a followed buffer is judged again.
---@return integer skipped Entries the current tab page's drawing could not draw
function M.paint()
  return exclusive(function()
    local current = vim.api.nvim_get_current_tabpage()
    local skipped = 0
    local followed = {}
    for tab, m in pairs(margins) do
      if not vim.api.nvim_tabpage_is_valid(tab) then
        margins[tab] = nil
      elseif M.style() == "inline" then
        if m.code and vim.api.nvim_win_is_valid(m.code) then
          local buf = vim.api.nvim_win_get_buf(m.code)
          if not followed[buf] then
            followed[buf] = paint_captions(buf, m.code, true)
          end
          if tab == current then
            skipped = followed[buf]
          end
        end
      elseif live(m) and not m.dismissed then
        local n = paint_margin(m)
        if tab == current then
          skipped = n
        end
      end
    end
    if M.style() == "inline" then
      for buf in pairs(signed) do
        if not followed[buf] and vim.api.nvim_buf_is_loaded(buf) then
          paint_captions(buf, shown_in(buf), false)
        end
      end
    end
    return skipped
  end)
end

---Repaint the captions of a buffer just written, and judge its file again.
---
---The write moved the file's stat, so the rehash's gate lets it through once and holds after.
---Only this buffer: the write changed one file and no entry. Wrapped to the window the
---overlay follows when that window shows it, as an enter would wrap it.
---@param buf integer
local function paint_written(buf)
  exclusive(function()
    local m = margins[vim.api.nvim_get_current_tabpage()]
    local win = m
      and m.code
      and vim.api.nvim_win_is_valid(m.code)
      and vim.api.nvim_win_get_buf(m.code) == buf
      and m.code
    paint_captions(buf, win or shown_in(buf), true)
    return 0
  end)
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

---The review view, as the last toggle handed it in. Read by the keys that act on the batch.
local view_

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

---Put the margin's cursor on the start of a card.
---@param m CROverlayMargin
---@param card { start: integer }|nil
local function put(m, card)
  if card and standing(m) then
    pcall(vim.api.nvim_win_set_cursor, m.win, { card.start, 0 })
  end
end

---Put the margin's cursor on the card nearest the line the code window's cursor is on.
---
---The card anchored on that line, else the one whose anchor is nearest; the upper of two
---as near, and the first in queue order of several on one line, which is the order the
---margin draws them in. Measured to the anchor and not to the card's row, because a card
---pushed down by the one above it is still about the line it was anchored to. A whole-file
---card is about no line, and is where the cursor goes only when no other card is drawn.
---@param m CROverlayMargin
local function land(m)
  local line = vim.api.nvim_win_get_cursor(m.code)[1]
  local best, gap
  for _, card in ipairs(m.cards or {}) do
    if card.line and (not gap or math.abs(card.line - line) < gap) then
      best, gap = card, math.abs(card.line - line)
    end
  end
  put(m, best or (m.cards or {})[1])
end

---Bind the queue float's keys on a margin's buffer, with the same meanings.
---
---On the margin's own buffer and nowhere else: the plugin binds no global keys, and the
---code window is the host's. So `e` and `t` hide no motion a reviewer reads a file with.
---There is no `<Esc>`: the margin is a window a reviewer reads beside the code, not a dialog
---in front of it, and `q` turns the overlay off rather than closing one window.
---@param m CROverlayMargin
local function bind(m)
  local buf = m.buf

  ---The entry the cursor is on. Every row of a card is mapped to it, its note as well as its
  ---header; an empty row and the quiet line answer nil.
  local function at_cursor()
    if not standing(m) or not m.rows then
      return nil
    end
    return queued(m.rows[vim.api.nvim_win_get_cursor(m.win)[1]])
  end

  ---The card that entry is drawn as now, wherever the repaint moved it.
  local function card_of(id)
    for _, card in ipairs(m.cards or {}) do
      if card.id == id then
        return card
      end
    end
  end

  ---After an edit that `annotate` made, which has repainted the margin already. The composer
  ---and the picker are open for as long as the reviewer likes, and the margin can close
  ---under them.
  local function after_edit(edited)
    put(m, card_of(edited.id))
  end

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, desc = desc })
  end

  -- The overlay stays on, where the float closes: the margin is still beside the code the
  -- cursor goes to. The anchor's line now and not the recorded one, so a file edited since
  -- the capture still lands on the line the card is about.
  map("<CR>", function()
    local entry = at_cursor()
    if not entry or not live(m) then
      return
    end
    if entry.kind ~= "file" then
      local line = anchor_line(vim.api.nvim_win_get_buf(m.code), entry)
      vim.api.nvim_win_set_cursor(m.code, { line, 0 })
    end
    vim.api.nvim_set_current_win(m.code)
  end, "Go to the annotated line")

  -- Through annotate, for the reason the float gives: one drop from every surface. The drop
  -- repaints the margin itself. The cursor then goes to the nearest card, as the float's
  -- does, or the second `x` of a run would land on an empty row and do nothing.
  map("x", function()
    local entry = at_cursor()
    if not entry then
      return
    end
    local row = vim.api.nvim_win_get_cursor(m.win)[1]
    require("codereview.annotate").drop_entry(entry)
    if not standing(m) then
      return
    end
    local height = vim.api.nvim_win_get_height(m.win)
    for _, range in ipairs({ { row, height, 1 }, { row, 1, -1 } }) do
      for r = range[1], range[2], range[3] do
        if m.rows[r] then
          put(m, card_of(m.rows[r]))
          return
        end
      end
    end
  end, "Drop annotation")

  map("e", function()
    local entry = at_cursor()
    if entry then
      require("codereview.annotate").edit_note(entry, after_edit)
    end
  end, "Edit the note")

  map("t", function()
    local entry = at_cursor()
    if entry then
      require("codereview.annotate").change_type(entry, after_edit)
    end
  end, "Change the type")

  -- Nothing to repaint after: the margin does not name the target.
  map("<C-t>", function()
    view_.pick_target()
  end, "Choose target")

  map("gy", function()
    view_.copy()
  end, "Copy the batch to the clipboard")

  -- The submit repaints the overlay itself, so a dispatched batch leaves the quiet line.
  map("<C-s>", function()
    view_.submit()
  end, "Submit the batch")

  map("<C-a>", function()
    view_.submit_with_preamble()
  end, "Submit the batch under a preamble")

  map("q", function()
    M.toggle(view_)
  end, "Turn the overlay off")

  -- Read off the keys this buffer really has, as the float's list is.
  map("?", function()
    local listed = {}
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if km.desc then
        listed[#listed + 1] = { key = km.lhs:gsub("^<C%-(%a)>$", "^%1"), desc = km.desc }
      end
    end
    table.sort(listed, function(a, b)
      return a.key < b.key
    end)
    local rows = { "Margin keys:" }
    for _, l in ipairs(listed) do
      rows[#rows + 1] = ("  %-6s %s"):format(l.key, l.desc)
    end
    info(table.concat(rows, "\n"))
  end, "List these keys")
end

---Put the margin beside a window: move it there if it stands elsewhere in that tab page, and
---open it if it does not stand at all.
---
---A split rather than a float, so the code window gives up the columns rather than having
---them drawn over; `split = "right"` of that one window rather than `botright`, because the
---margin belongs beside the window it reads and not at the edge of the tab. Focus stays
---where it was.
---
---Moved rather than closed and opened again: `nvim_win_set_config` takes a split to another
---window's side, keeps its handle and options, and fires no `WinClosed`, `WinNew` or
---`WinEnter` doing it, so a move cannot be mistaken for the reviewer closing the margin. It
---does even out the width, so the width goes in the same call.
---
---Opened with autocommands blocked, because `nvim_open_win` raises `BufWinEnter` with the new
---window current, and `follow` would read that as the reviewer arriving in a buffer that is
---not a file.
---@param win integer
---@return CROverlayMargin
local function place(win)
  local tab = vim.api.nvim_win_get_tabpage(win)
  local m = margins[tab]
  local width = config.get().overlay.width
  if standing(m) then
    if m.code ~= win then
      vim.api.nvim_win_set_config(m.win, { split = "right", win = win, width = width })
      m.code = win
    end
    return m
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "codereview-overlay"
  vim.bo[buf].modifiable = false
  local mwin = vim.api.nvim_open_win(buf, false, {
    split = "right",
    win = win,
    width = width,
    noautocmd = true,
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
  bind(m)
  return m
end

---Whether the margin window being closed is the plugin's own doing, which `WinClosed` cannot
---otherwise tell from the reviewer's.
local closing = false

---Take a margin's window down and keep following: the toggle stays on.
---@param m CROverlayMargin
local function shut(m)
  if standing(m) then
    closing = true
    pcall(vim.api.nvim_win_close, m.win, true)
    closing = false
  end
  m.win, m.buf = nil, nil
end

---Take the signs and captions out of every buffer they were drawn in.
local function strip_all()
  for buf in pairs(signed) do
    if vim.api.nvim_buf_is_valid(buf) then
      strip(buf)
    end
    signed[buf] = nil
  end
end

---Close every margin and take the signs and captions out of every buffer they were drawn in.
---
---The listeners go first, so the windows closed here raise nothing this module hears.
---
---The anchors stay. They are not drawn, and an edit made while the overlay is off still
---moves them, so a card comes back beside the code it was about.
local function close_all()
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
  for tab, m in pairs(margins) do
    shut(m)
    margins[tab] = nil
  end
  strip_all()
end

---Settle where a tab page's margin stands, now that the cursor is in `win` or `win` has a new
---buffer.
---
---A floating window is never followed: a picker or a float of this plugin opening over the
---code would otherwise take the margin with it. The margin itself is not followed either, so
---entering it moves nothing and closes nothing. A window holding no file is followed only
---when nothing else is, or when it is the window already followed, whose file has just gone:
---the cursor passing through a help split leaves the margin beside the code. Everything
---else -- the followed window with a file in it, or another window with a file in it -- puts
---the margin beside that window and paints it. In the inline style there is no margin to
---put: that window becomes the one followed, and its buffer's captions are painted.
---@param win integer
---@return integer skipped Entries of the file the current tab page's margin cannot draw
local function follow(win)
  if not M.enabled() or not vim.api.nvim_win_is_valid(win) then
    return 0
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return 0
  end
  local tab = vim.api.nvim_win_get_tabpage(win)
  local m = margins[tab]
  if m and (m.dismissed or win == m.win) then
    return 0
  end
  local file = is_file(vim.api.nvim_win_get_buf(win))
  local following = m ~= nil and m.code ~= nil and vim.api.nvim_win_is_valid(m.code)
  if following and win ~= m.code and not file then
    return 0
  end
  if not file then
    if m then
      shut(m)
      m.code = win
    else
      margins[tab] = { code = win }
    end
    return 0
  end
  if M.style() == "inline" then
    m = m or {}
    margins[tab] = m
    m.code = win
  else
    place(win)
  end
  return M.paint()
end

---The reviewer closed a margin. Whether that turns the overlay off waits a tick.
---
---`:tabclose` closes the margin before the window it follows, with that window current and
---every window of the tab page still valid: in that moment it is indistinguishable from
---`:only` in the code window, which is the reviewer closing the margin. Only afterwards does
---the tab page say whether it is gone. Until then the margin is marked dismissed, so the
---`WinEnter` that the close itself raises cannot open it again.
---@param tab integer
---@param m CROverlayMargin
local function dismissed(tab, m)
  m.dismissed = true
  m.win, m.buf = nil, nil
  vim.schedule(function()
    if margins[tab] ~= m then
      return
    end
    if not vim.api.nvim_tabpage_is_valid(tab) then
      margins[tab] = nil
      return
    end
    if M.enabled() then
      config.toggle_overlay()
    end
    close_all()
    info("Overlay off")
  end)
end

---The window a margin follows is closing.
---
---The margin's rows are about a file no longer on screen, so they go at once. Where the
---margin goes waits a tick: the `WinEnter` the close raises comes while the window is still
---closing, when no split can be made (E242), and a window closed with the cursor elsewhere
---raises no `WinEnter` at all. Either way, the window the cursor is in afterwards is the one
---followed.
---@param m CROverlayMargin
local function lost(m)
  m.code = nil
  if standing(m) then
    vim.api.nvim_buf_clear_namespace(m.buf, M.NS, 0, -1)
    write(m.buf, {})
  end
  vim.schedule(function()
    follow(vim.api.nvim_get_current_win())
  end)
end

---`:q` in a window whose only neighbour is its margin.
---
---Without this the quit would close the code window and leave the reviewer alone with the
---margin, and closing the margin from the code window's `WinClosed` instead aborts the quit
---with E855. So the margin goes first and the quit does what it would have done without
---one: close the tab page, or Neovim. A quit refused over an unsaved buffer leaves the code
---window standing, and following it again on the next tick brings the margin back.
local function quitting()
  local win = vim.api.nvim_get_current_win()
  local m = margins[vim.api.nvim_get_current_tabpage()]
  if not standing(m) or m.code ~= win then
    return
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= win and w ~= m.win and vim.api.nvim_win_get_config(w).relative == "" then
      return
    end
  end
  shut(m)
  vim.schedule(function()
    follow(vim.api.nvim_get_current_win())
  end)
end

---Listen for what moves an anchor on screen, what changes which window a margin follows, and
---what closes one.
---
---A scroll and a resize of the window a margin is beside; not `VimResized`, which arrives with
---every terminal resize together with `WinResized` and would paint each margin twice.
---`WinEnter` and `BufWinEnter`, both read as "the cursor is in this window now": `BufWinEnter`
---raised by `nvim_win_set_buf` names the window the buffer went into as current, and a buffer
---that reaches a window this way is one the reviewer is about to read. `BufWinEnter` is what
---carries a buffer change in the followed window, which raises no `WinEnter`. A write, for the
---inline style's stale flag. No `FocusGained`: a file changed outside Neovim while it is on
---screen is judged on the next enter or write (#270 leaves that out of scope).
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
      -- Nothing in a caption depends on a screen row, so a scroll has nothing to repaint.
      if M.style() ~= "inline" and concerns(ids) then
        M.paint()
      end
    end,
  })
  -- In the inline style too: the captions are wrapped to the window's width.
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
  -- Whether the window the cursor last left was a float. A float closing raises its
  -- `WinLeave` while it is still a float, and by the `WinEnter` that follows, `winnr("#")`
  -- names the window entered, so this is the only moment the question can be asked.
  local left_float = false
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      left_float = vim.api.nvim_win_get_config(0).relative ~= ""
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local m = margins[vim.api.nvim_get_current_tabpage()]
      -- The followed window is closing, and this is the cursor landing elsewhere as it goes.
      -- Moving the margin now fails with E242, since no split may be made while a window
      -- closes; `lost` has already asked for the follow on the next tick.
      if m and m.code == nil then
        return
      end
      -- The reviewer entering the margin: on the card nearest the line they came from,
      -- painted first, because an edit since the last paint may have moved an anchor. Not
      -- after a float closed over the margin -- the composer of `e`, the picker of `t` --
      -- which has put the cursor on the edited card already.
      if m and win == m.win then
        if not left_float and live(m) and not m.dismissed then
          M.paint()
          land(m)
        end
        return
      end
      -- `:new` splits the window with its buffer, enters the split, and only then gives it
      -- an empty one, so a window entered on the buffer the margin already draws may be
      -- about to hold something else. Followed a tick later, it is a split of the file the
      -- reviewer is in or it is not a file at all; followed now, the margin would move
      -- beside `:new`'s window and then close there.
      if
        m
        and m.code
        and m.code ~= win
        and vim.api.nvim_win_is_valid(m.code)
        and vim.api.nvim_win_get_buf(m.code) == vim.api.nvim_win_get_buf(win)
      then
        vim.schedule(function()
          if vim.api.nvim_get_current_win() == win then
            follow(win)
          end
        end)
        return
      end
      follow(win)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function()
      follow(vim.api.nvim_get_current_win())
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local id = tonumber(ev.match)
      for tab, m in pairs(margins) do
        if id == m.win and not closing and not m.dismissed then
          dismissed(tab, m)
        elseif id == m.code then
          lost(m)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("QuitPre", { group = group, callback = quitting })
  -- A capture's blob is the file on disk, so a write is when its stale flag can change, and
  -- in the inline style nothing else repaints a buffer the reviewer stays in. Not the
  -- margin's: its scroll paint judges the file through the same gate.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if M.style() == "inline" and signed[ev.buf] then
        paint_written(ev.buf)
      end
    end,
  })
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

---Draw the margin beside the current window, or wait for a file if it holds none.
---@return integer skipped
local function show()
  listen()
  return follow(vim.api.nvim_get_current_win())
end

---Change the drawing while the overlay is on, and keep it on.
---
---The margins go through their own close, which `WinClosed` knows is the plugin's, and not
---through the reviewer's: closing one by hand turns the toggle off, and this must not. The
---captions go from every buffer they were painted in, and the signs with them; the new
---drawing puts the signs back where it draws. Each tab page keeps the window it followed,
---so the drawing comes back beside the same code.
---@param style "margin"|"inline"
---@return integer skipped
local function switch(style)
  for _, m in pairs(margins) do
    shut(m)
  end
  strip_all()
  config.set_overlay_style(style)
  follow(vim.api.nvim_get_current_win())
  -- Again, for the cursor in a float, which `follow` leaves alone.
  return M.paint()
end

---Turn the overlay on or off for the rest of this session, or name the style it draws in,
---and say so.
---
---With a style: on in that style when it was off, and a switch in place when it was on --
---never off, so two host keys for the two drawings each always show something.
---@param view table The review view, whose exported actions the margin's keys run
---@param style "margin"|"inline"|nil
---@return boolean on The state it is now in
function M.toggle(view, style)
  view_ = view
  if style and M.enabled() then
    local skipped = style ~= M.style() and switch(style) or M.paint()
    info(said(true, skipped))
    return true
  end
  if style then
    config.set_overlay_style(style)
  end
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
---@param view table The review view, as `toggle` takes it
function M.start(view)
  view_ = view
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
