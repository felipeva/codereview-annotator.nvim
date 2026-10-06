-- The **overlay** on an ordinary file buffer: the toggle, the **margin** it opens, the
-- **cards** in it and the signs beside the code.
--
-- A real window throughout. The layout's rules are stated as data in overlay_layout_spec;
-- this file is what proves the rows reach the margin, at the anchor's row on screen, in the
-- groups a reviewer sees -- groups, never colours, which are the colorscheme's.
--
-- 80x24 because that is the grid headless Neovim keeps whatever `columns` and `lines` say,
-- and the sign case reads a painted cell off it. The code window is then 39 columns and the
-- margin 40, both 22 rows tall.
--
-- The toggle is module state and outlives every case, and plenary runs each `it` as it
-- reaches it, so every case that turns the overlay on turns it off again before it ends.
local h = require("tests.helpers")

h.ui(80, 24)
local fixture = h.cd_fixture("mkfixture")

-- Long enough to scroll: the fixture's own files are three lines each. Untracked, which is
-- still a file of this checkout, and the overlay asks nothing of git but where the root is.
local LONG = "src/long.lua"
do
  local lines = {}
  for i = 1, 200 do
    lines[i] = ("local l%d = %d"):format(i, i)
  end
  vim.fn.writefile(lines, vim.fs.joinpath(fixture, LONG))
end

local NOTE = "queued from the buffer"
-- Every submit here goes through this stub, which reports a dispatch, so the queue empties.
local sent = {}
require("codereview").setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, NOTE)
  end,
  send = function(text)
    sent[#sent + 1] = text
    return true
  end,
})

local codereview = require("codereview")
local config = require("codereview.config")
local overlay = require("codereview.overlay")
local queue = require("codereview.queue")
local state = require("codereview.state")

local BAR = config.get().icons.change_bar
local EMPTY = "no annotations in this file"
local root = assert(vim.uv.fs_realpath(fixture))

-- Read back before anything is queued by hand, as a capture does, so that the first paint's
-- own read-back finds this checkout already latched and leaves the queue alone.
state.ensure_queue()

---Queue an entry about the long file, by hand, as the queue float's spec does.
---@param over table
---@return CRAnnotation
local function queued(over)
  local first = over.first or 1
  return queue.add(vim.tbl_extend("force", {
    type = "bug",
    kind = "line",
    path = LONG,
    abs_path = vim.fs.joinpath(root, LONG),
    key = ("%s:n:%d"):format(LONG, first),
    first = first,
    last = first,
    note = "a note",
  }, over))
end

---One window, holding the long file, scrolled to the top.
---@return integer win, integer buf
local function code_window()
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, LONG)))
  vim.cmd("normal! gg")
  return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

---Turn the overlay on, from off, and hand back what it said.
---@return string[] said
local function on()
  assert(not overlay.enabled(), "a case before this one left the overlay on")
  local said, restore = h.capture_notify()
  assert.is_true(codereview.overlay())
  restore()
  return said
end

local function off()
  if overlay.enabled() then
    assert.is_false(codereview.overlay())
  end
end

local function clear_queue()
  queue.clear()
end

---@return CROverlayMargin
local function margin()
  return assert(overlay.margin(), "no margin is open")
end

---@param buf integer
---@return string[]
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---Every highlight in the overlay's namespace on a buffer, as `row:group` over the text it
---covers.
---@param buf integer
---@return { row: integer, text: string, hl: string }[]
local function marks(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.NS, 0, -1, { details = true })) do
    local row, col, d = m[2], m[3], m[4]
    if d.hl_group then
      local text = vim.api.nvim_buf_get_text(buf, row, col, row, d.end_col, {})[1]
      out[#out + 1] = { row = row + 1, text = text, hl = d.hl_group }
    end
  end
  return out
end

---The group a text was drawn in on a margin row, or nil.
---@param buf integer
---@param row integer 1-based
---@param text string
---@return string|nil
local function group_of(buf, row, text)
  for _, m in ipairs(marks(buf)) do
    if m.row == row and m.text == text then
      return m.hl
    end
  end
end

---The signs in a code buffer, by 1-based line, with the group each is drawn in.
---@param buf integer
---@return table<integer, string[]>
local function signs(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.NS, 0, -1, { details = true })) do
    local d = m[4]
    if d.sign_text then
      out[m[2] + 1] = out[m[2] + 1] or {}
      table.insert(out[m[2] + 1], d.sign_hl_group)
    end
  end
  return out
end

---The 1-based margin row whose text is `text`, or nil.
---@param buf integer
---@param text string
---@return integer|nil
local function row_of(buf, text)
  for i, line in ipairs(lines(buf)) do
    if line == text then
      return i
    end
  end
end

describe("the overlay's toggle", function()
  after_each(off)

  -- First, while nothing in this process has touched the switch: unset means configured,
  -- and configured is off.
  it("is off until it is toggled", function()
    assert.is_false(overlay.enabled())
    code_window()
    assert.is_nil(overlay.margin())
  end)

  it("returns the state it leaves the overlay in, both ways", function()
    code_window()
    on()
    assert.is_true(overlay.enabled())
    assert.is_false(codereview.overlay())
    assert.is_false(overlay.enabled())
    assert.is_nil(overlay.margin())
  end)

  it("is what :CodeReviewOverlay does", function()
    code_window()
    vim.cmd("CodeReviewOverlay")
    assert.is_true(overlay.enabled())
    assert.is_not_nil(overlay.margin())
    vim.cmd("CodeReviewOverlay")
    assert.is_false(overlay.enabled())
    assert.is_nil(overlay.margin())
  end)

  it("never writes the configured value", function()
    code_window()
    on()
    assert.is_false(config.get().overlay.enabled)
    off()
  end)
end)

describe("the margin", function()
  after_each(off)

  it("is a split of the configured width to the right of the window, fixed, on a plugin buffer", function()
    local win = code_window()
    on()
    local m = margin()
    assert.equal(win, m.code)
    assert.equal(40, vim.api.nvim_win_get_width(m.win))
    assert.is_true(vim.wo[m.win].winfixwidth)
    -- Beside the code window and not floating over it: same top row, to its right.
    assert.equal("", vim.api.nvim_win_get_config(m.win).relative)
    local code_pos, margin_pos = vim.fn.win_screenpos(win), vim.fn.win_screenpos(m.win)
    assert.equal(code_pos[1], margin_pos[1])
    assert.is_true(margin_pos[2] > code_pos[2] + vim.api.nvim_win_get_width(win) - 1)
    assert.equal("nofile", vim.bo[m.buf].buftype)
    assert.is_false(vim.bo[m.buf].modifiable)
    -- Focus stays where the reviewer was.
    assert.equal(win, vim.api.nvim_get_current_win())
    off()
  end)

  -- Toggled on there, the margin waits for a file rather than standing beside a buffer it
  -- could never draw a card for. overlay_follow_spec has it coming back.
  it("does not open beside a buffer that is not a file, and the toggle is on", function()
    vim.cmd("silent! only")
    vim.cmd("enew")
    vim.bo.buftype = "nofile"
    clear_queue()
    queued({ first = 1 })
    local before = #vim.api.nvim_tabpage_list_wins(0)
    on()
    assert.is_true(overlay.enabled())
    assert.is_nil(overlay.margin())
    assert.equal(before, #vim.api.nvim_tabpage_list_wins(0))
    off()
    clear_queue()
  end)
end)

-- The cases in this block read one margin, painted by the first of them, so the overlay
-- stays on between them and the last case turns it off.
describe("a card", function()
  local win, buf, m

  -- One of each header the card can have, all in view at the top of the file, spaced so no
  -- two of them stack.
  local bug, range, stale, untyped
  it("is drawn for each queued entry of the file, at its anchor's row", function()
    clear_queue()
    win, buf = code_window()
    bug = queued({ first = 2, note = "first note" })
    range = queued({ type = "suggestion", kind = "range", first = 6, last = 9, note = "a range" })
    stale = queued({ first = 11, stale = true, note = "stale one" })
    untyped = queued({ type = false, first = 15, note = "no type" })
    -- `queue.add` keeps whatever it was handed, and an untyped entry carries no type at all.
    untyped.type = nil
    on()
    m = margin()
    local rows = lines(m.buf)
    -- Topline is 1, so a line's screen row is the line itself.
    assert.equal(BAR .. " ✗ bug 2", rows[2])
    assert.equal(BAR .. " first note", rows[3])
    assert.equal(BAR .. " ✦ suggestion 6–9", rows[6])
    assert.equal(BAR .. " a range", rows[7])
    assert.equal(BAR .. " ✗ bug 11 ⚠ stale", rows[11])
    assert.equal(BAR .. " stale one", rows[12])
    assert.equal(BAR .. " • 15", rows[15])
    assert.equal(BAR .. " no type", rows[16])
    -- And nothing between the cards.
    for _, r in ipairs({ 1, 4, 5, 8, 10, 13, 14, 17 }) do
      assert.equal("", rows[r], ("row %d"):format(r))
    end
  end)

  it("draws its header, rule and note in the type's group", function()
    assert.equal("CodeReviewBug", group_of(m.buf, 2, "✗ bug 2"))
    assert.equal("CodeReviewBug", group_of(m.buf, 2, BAR))
    assert.equal("CodeReviewBug", group_of(m.buf, 3, BAR))
    assert.equal("CodeReviewBug", group_of(m.buf, 3, "first note"))
    assert.equal("CodeReviewSuggestion", group_of(m.buf, 7, "a range"))
    assert.equal("CodeReviewSuggestion", group_of(m.buf, 6, "✦ suggestion 6–9"))
  end)

  it("says stale in the stale group, and only on a stale entry", function()
    assert.equal("CodeReviewStale", group_of(m.buf, 11, "⚠ stale"))
    assert.equal("CodeReviewBug", group_of(m.buf, 11, "✗ bug 11"))
    -- The flag sits in the header; the note under it keeps its type's group.
    assert.equal("CodeReviewBug", group_of(m.buf, 12, "stale one"))
    assert.is_nil(lines(m.buf)[2]:find("stale", 1, true))
  end)

  it("draws an untyped entry with the untyped mark, no name, in the note group", function()
    assert.equal("CodeReviewNote", group_of(m.buf, 15, "• 15"))
    assert.equal("CodeReviewNote", group_of(m.buf, 15, BAR))
    -- An untyped note gives no instruction, and grey is what says so.
    assert.equal("CodeReviewNote", group_of(m.buf, 16, "no type"))
  end)

  it("puts a sign in the type's group on every covered line", function()
    local s = signs(buf)
    assert.same({ "CodeReviewBug" }, s[2])
    for l = 6, 9 do
      assert.same({ "CodeReviewSuggestion" }, s[l], ("line %d"):format(l))
    end
    assert.same({ "CodeReviewNote" }, s[15])
    assert.is_nil(s[5])
    assert.is_nil(s[10])
  end)

  -- A painted cell, because a sign extmark exists whatever the window shows: only the screen
  -- can say the sign column hides it. Column 1 of the code window, on a covered line and on
  -- a line nothing covers, so each reading has a control.
  it("shows the sign in the sign column, and nothing when the host has signcolumn=no", function()
    vim.wo[win].signcolumn = "yes"
    vim.cmd("redraw!")
    assert.equal(BAR, vim.fn.screenstring(2, 1))
    assert.equal(" ", vim.fn.screenstring(1, 1))
    vim.wo[win].signcolumn = "no"
    vim.cmd("redraw!")
    assert.equal("l", vim.fn.screenstring(2, 1))
    vim.wo[win].signcolumn = "auto"
  end)

  -- The note wraps to the card's width minus the rule, by display width, and keeps its
  -- paragraphs: a blank line inside a note is a row with the rule and nothing else.
  it("wraps its note to the card's width and keeps its paragraphs", function()
    off()
    clear_queue()
    local word = ("界"):rep(30)
    queued({ first = 3, note = word .. "\n\nafter" })
    on()
    local rows = lines(margin().buf)
    -- 40 columns, less the rule and its space: 38, so 19 two-column characters a row.
    assert.equal(BAR .. " ✗ bug 3", rows[3])
    assert.equal(BAR .. " " .. ("界"):rep(19), rows[4])
    assert.equal(BAR .. " " .. ("界"):rep(11), rows[5])
    assert.equal(BAR, (rows[6]:gsub("%s+$", "")))
    assert.equal(BAR .. " after", rows[7])
    -- Every row of the note, the continuation and the next paragraph alike, in its type's group.
    local mbuf = margin().buf
    assert.equal("CodeReviewBug", group_of(mbuf, 4, ("界"):rep(19)))
    assert.equal("CodeReviewBug", group_of(mbuf, 5, ("界"):rep(11)))
    assert.equal("CodeReviewBug", group_of(mbuf, 7, "after"))
    -- Measured in the margin, which does not wrap: in the 39-column code window, which does,
    -- the character crossing its edge would cost a cell more than it draws.
    vim.api.nvim_win_call(margin().win, function()
      for r = 3, 7 do
        assert.is_true(vim.fn.strdisplaywidth(rows[r]) <= 40, ("row %d"):format(r))
      end
    end)
  end)

  -- The paint can run with any window current, and `strdisplaywidth` measures in that one.
  -- Nine columns with wrap on fit four of these characters a row and pad the fifth onto the
  -- next, so a wrap measured there would break the note a character early. The rows have to
  -- come out exactly as they did with the code window current.
  it("wraps the same whichever window is current when it is painted", function()
    local before = lines(margin().buf)
    vim.cmd("vertical new")
    local narrow = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(narrow, 9)
    vim.wo[narrow].wrap = true
    overlay.paint()
    local after = lines(margin().buf)
    vim.api.nvim_win_close(narrow, true)
    assert.equal(BAR .. " " .. ("界"):rep(19), after[4])
    assert.same(before, after)
    off()
  end)
end)

describe("cards that would overlap", function()
  after_each(off)

  it("stack: the second starts on the row after the first ends", function()
    clear_queue()
    code_window()
    queued({ first = 4, note = "one\ntwo\nthree" })
    queued({ type = "nitpick", first = 5, note = "next" })
    on()
    local rows = lines(margin().buf)
    assert.equal(BAR .. " ✗ bug 4", rows[4])
    assert.equal(BAR .. " three", rows[7])
    -- Its anchor is row 5, inside the first card; it starts where that card ends.
    assert.equal(BAR .. " ▫ nitpick 5", rows[8])
    assert.equal(BAR .. " next", rows[9])
    off()
  end)

  it("on one line draw in id order", function()
    clear_queue()
    code_window()
    local a = queued({ type = "issue", first = 4, note = "a" })
    local b = queued({ type = "fix", first = 4, note = "b" })
    assert.is_true(a.id < b.id)
    on()
    local rows = lines(margin().buf)
    assert.equal(BAR .. " ⚑ issue 4", rows[4])
    assert.equal(BAR .. " ✎ fix 4", rows[6])
    off()
  end)
end)

describe("scrolling the code window", function()
  after_each(off)

  -- The paint is called by hand after each scroll. `WinScrolled` fires from the main loop's
  -- check between two inputs, and a case here never yields to it: fed keys and `:redraw`
  -- both run without it. What a scroll *triggers* is overlay_scroll_child's to prove, on a
  -- main loop of its own; what is proved here is where the paint puts each card.
  local win, m

  it("moves each visible card to its anchor's new row and drops the one that left", function()
    clear_queue()
    win = code_window()
    queued({ first = 3, note = "near the top" })
    queued({ type = "fix", first = 20, note = "further down" })
    on()
    m = margin()
    assert.equal(3, row_of(m.buf, BAR .. " ✗ bug 3"))
    assert.equal(20, row_of(m.buf, BAR .. " ✎ fix 20"))
    -- Ten lines down: line 20 is now the window's tenth row, and line 3 is above it.
    h.feed("10<C-e>")
    overlay.paint()
    assert.equal(11, vim.fn.line("w0", win))
    assert.equal(10, row_of(m.buf, BAR .. " ✎ fix 20"))
    assert.is_nil(row_of(m.buf, BAR .. " ✗ bug 3"))
    -- And back: the card that left comes back beside its line.
    h.feed("10<C-y>")
    overlay.paint()
    assert.equal(3, row_of(m.buf, BAR .. " ✗ bug 3"))
  end)

  it("keeps a whole-file card pinned at the top after scrolling past line 1", function()
    clear_queue()
    win = code_window()
    queued({ type = "issue", first = 5, note = "a line" })
    queue.add({
      type = "suggestion",
      kind = "file",
      path = LONG,
      abs_path = vim.fs.joinpath(root, LONG),
      key = LONG .. ":f:0",
      tag = "whole file",
      note = "the whole thing",
    })
    on()
    m = margin()
    -- Pinned above the line card, which is pushed below it.
    assert.equal(BAR .. " ✦ suggestion whole file", lines(m.buf)[1])
    assert.equal(5, row_of(m.buf, BAR .. " ⚑ issue 5"))
    h.feed("30<C-e>")
    overlay.paint()
    assert.equal(31, vim.fn.line("w0", win))
    assert.equal(BAR .. " ✦ suggestion whole file", lines(m.buf)[1])
    assert.equal(BAR .. " the whole thing", lines(m.buf)[2])
    assert.is_nil(row_of(m.buf, BAR .. " ⚑ issue 5"))
  end)

  -- Wrap on in the code window: line 2 folds onto several rows, so line 3's card sits that
  -- many rows lower than its line number. Scrollbind would put it on row 3.
  it("places a card by screen row when a line above it wraps", function()
    clear_queue()
    win = code_window()
    local buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { ("x"):rep(100) })
    vim.wo[win].wrap = true
    queued({ first = 3, note = "below a long line" })
    on()
    -- 100 columns in a 39-column window is three rows, so line 3 is on row 5.
    assert.equal(5, row_of(margin().buf, BAR .. " ✗ bug 3"))
    off()
    vim.wo[win].wrap = false
    vim.cmd("silent! edit!")
  end)
end)

describe("an edit above an anchor", function()
  after_each(off)

  it("moves the card with the code", function()
    clear_queue()
    local win, buf = code_window()
    queued({ first = 6, note = "follows" })
    on()
    assert.equal(6, row_of(margin().buf, BAR .. " ✗ bug 6"))
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- one", "-- two" })
    overlay.paint()
    -- The header still names the recorded line; the card sits beside the code it was about.
    assert.equal(8, row_of(margin().buf, BAR .. " ✗ bug 6"))
    assert.same({ "CodeReviewBug" }, signs(buf)[8])
    off()
    vim.api.nvim_win_call(win, function()
      vim.cmd("silent! edit!")
    end)
  end)
end)

describe("entries the overlay cannot draw", function()
  after_each(off)

  it("are skipped, and the toggle says how many", function()
    clear_queue()
    code_window()
    -- A pure deletion, anchored on the pre-image.
    queued({ first = 7, key = LONG .. ":o:7", tag = "deleted", inline = true, note = "gone" })
    -- Past the end of a 200-line file.
    queued({ first = 500, note = "too far" })
    -- Drawn, as the control: a change whose first line is a deletion keys on the pre-image
    -- too, and draws at its recorded lines.
    queued({ type = "fix", kind = "range", first = 9, last = 10, key = LONG .. ":o:9", tag = "change", note = "mixed" })
    local said = on()
    local m = margin()
    assert.is_true(h.notified(said, "2 annotations not drawn"), vim.inspect(said))
    assert.is_nil(row_of(m.buf, BAR .. " gone"))
    assert.is_nil(row_of(m.buf, BAR .. " too far"))
    assert.equal(9, row_of(m.buf, BAR .. " ✎ fix 9–10"))
    off()
  end)

  it("is nothing to report when every entry is drawn", function()
    clear_queue()
    code_window()
    queued({ first = 2 })
    local said = on()
    assert.is_true(h.notified(said, "Overlay on"))
    assert.is_false(h.notified(said, "not drawn"))
    off()
  end)

  -- The same relative path in another repository. The queue in memory is this checkout's,
  -- and its entry about `src/long.lua` is not about that file.
  it("include this checkout's entry, beside the same path in another checkout", function()
    local other = vim.fn.tempname() .. "-other"
    vim.fn.mkdir(vim.fs.joinpath(other, "src"), "p")
    vim.system({ "git", "init", "-q", other }):wait()
    vim.fn.writefile(vim.fn.readfile(vim.fs.joinpath(fixture, LONG)), vim.fs.joinpath(other, LONG))
    clear_queue()
    vim.cmd("silent! only")
    vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(other, LONG)))
    queued({ first = 2, note = "about this checkout's file" })
    on()
    assert.same({ { row = 1, text = EMPTY, hl = "CodeReviewOverlayEmpty" } }, marks(margin().buf))
    assert.same({}, signs(vim.api.nvim_get_current_buf()))
  end)

  it("include a bare note and an entry of another file", function()
    clear_queue()
    code_window()
    queue.add({ kind = "note", key = "note:0", inline = false, note = "a bare note", type = "bug" })
    queued({ path = "src/main.lua", key = "src/main.lua:n:2", first = 2, note = "other file" })
    on()
    assert.same({ { row = 1, text = EMPTY, hl = "CodeReviewOverlayEmpty" } }, marks(margin().buf))
    off()
    clear_queue()
  end)
end)

describe("a capture from the buffer", function()
  after_each(off)

  it("adds a card while the overlay is on", function()
    clear_queue()
    code_window()
    on()
    codereview.annotate("bug", { first = 12, last = 13 })
    local m = margin()
    assert.equal(12, row_of(m.buf, BAR .. " ✗ bug 12–13"))
    assert.equal(13, row_of(m.buf, BAR .. " " .. NOTE))
    off()
  end)

  it("opens nothing while the overlay is off", function()
    clear_queue()
    code_window()
    local before = #vim.api.nvim_tabpage_list_wins(0)
    codereview.annotate("bug", { first = 12, last = 12 })
    assert.equal(1, #queue.all())
    assert.is_false(overlay.enabled())
    assert.equal(before, #vim.api.nvim_tabpage_list_wins(0))
    assert.is_nil(overlay.margin())
  end)

  it("dropped through annotate takes its card away", function()
    clear_queue()
    code_window()
    queued({ first = 4, note = "to drop" })
    on()
    assert.equal(5, row_of(margin().buf, BAR .. " to drop"))
    local annotate = require("codereview.annotate")
    local pick = annotate.pick_entry
    -- The cursor lookup is the review view's; the drop's tail is what is under test.
    annotate.pick_entry = function(_, cb)
      cb(queue.all()[1])
    end
    annotate.drop()
    annotate.pick_entry = pick
    assert.is_nil(row_of(margin().buf, BAR .. " to drop"))
    off()
  end)
end)

describe("a drop from the queue float", function()
  after_each(off)

  -- `x` in the float, with no review view open: the float's drop runs through
  -- `annotate.drop_entry`, the one drop path, and the margin is repainted there.
  it("takes that card and its signs out of the margin and leaves the other", function()
    clear_queue()
    local _, buf = code_window()
    queued({ first = 4, note = "dropped from the float" })
    queued({ type = "fix", first = 10, note = "kept" })
    on()
    local m = margin()
    assert.equal(4, row_of(m.buf, BAR .. " ✗ bug 4"))
    assert.same({ "CodeReviewBug" }, signs(buf)[4])
    require("codereview.view").review_queue()
    local float = vim.api.nvim_get_current_win()
    assert.is_true(vim.fn.search("dropped from the float") > 0, "the float does not list the entry")
    h.feed("x")
    if vim.api.nvim_win_is_valid(float) then
      vim.api.nvim_win_close(float, true)
    end
    assert.equal(1, #queue.all())
    assert.is_nil(row_of(m.buf, BAR .. " ✗ bug 4"))
    assert.is_nil(row_of(m.buf, BAR .. " dropped from the float"))
    assert.is_nil(signs(buf)[4])
    assert.equal(10, row_of(m.buf, BAR .. " ✎ fix 10"))
    assert.same({ "CodeReviewFix" }, signs(buf)[10])
  end)
end)

describe("a submit", function()
  after_each(off)

  -- Through `delivery.submit`, which is where the review view's `<C-s>` and `<C-a>` and the
  -- float's end: none of them passes through `codereview.submit()`.
  it("takes the cards of the batch that went out of the margin", function()
    clear_queue()
    code_window()
    queued({ first = 4, note = "goes out" })
    on()
    assert.equal(4, row_of(margin().buf, BAR .. " ✗ bug 4"))
    local before = #sent
    assert.is_true(require("codereview.delivery").submit())
    assert.equal(before + 1, #sent)
    assert.equal(0, #queue.all())
    assert.same({ { row = 1, text = EMPTY, hl = "CodeReviewOverlayEmpty" } }, marks(margin().buf))
    assert.same({}, signs(vim.api.nvim_get_current_buf()))
  end)
end)

describe("the toggle", function()
  after_each(off)

  it("changes no entry, no store and no archive", function()
    clear_queue()
    code_window()
    codereview.annotate("bug", { first = 2, last = 2 })
    queued({ first = 5, stale = true })
    local entries = vim.deepcopy(queue.all())
    local path = state.path(root)
    local stored = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
    local archive = vim.deepcopy(state.archive(root))
    on()
    off()
    on()
    off()
    assert.same(entries, queue.all())
    assert.same(stored, vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {})
    assert.same(archive, state.archive(root))
    -- And the signs went with the margin.
    assert.same({}, signs(vim.api.nvim_get_current_buf()))
  end)
end)

-- The events, on a main loop that turns. See overlay_scroll_child for why no case above can
-- reach them: each reading below starts from a margin that would read differently had the
-- event not repainted it.
describe("the events the margin listens to", function()
  local run = vim
    .system({
      vim.v.progpath,
      "--clean",
      "--headless",
      "-c",
      "luafile " .. vim.fs.joinpath(h.root, "tests", "codereview", "overlay_scroll_child.lua"),
    }, {
      cwd = fixture,
      text = true,
      env = {
        XDG_STATE_HOME = vim.fn.tempname() .. "-state",
        FIXTURE = fixture,
        GIT_CONFIG_GLOBAL = "/dev/null",
        GIT_CONFIG_SYSTEM = "/dev/null",
      },
    })
    :wait(60000)
  local ok, out = pcall(vim.json.decode, vim.trim(run.stdout or ""))
  if not ok then
    out = {}
  end
  local said = (run.stdout or "") .. (run.stderr or "")

  it("repaint the margin when the code window scrolls", function()
    assert.equal(0, run.code, said)
    assert.equal(20, out.before, said)
    assert.equal(10, out.scrolled, said)
  end)

  it("repaint the margin to its new height when the windows are resized", function()
    assert.equal(18, out.height, said)
    assert.equal(18, out.rows, said)
  end)
end)
