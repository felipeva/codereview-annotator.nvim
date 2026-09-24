-- How the queue float draws an entry.
--
-- The float lists a batch that is read once, before submitting it, so what is asserted here
-- is that an entry has visible extent: a bar in its annotation type's group running down
-- every row it owns, and no bar on the row between it and the next. That boundary is not
-- decoration -- it is the same fact `x` resolves against, so an entry whose extent is
-- visible is an entry that cannot be dropped by accident.
--
-- Rows and highlight *groups*, never colors: what a colorscheme resolves a group to is
-- deliberately not covered anywhere in this suite.
local h = require("tests.helpers")

h.ui(100, 30)
local fixture = h.cd_fixture("mkfixture")

---What the send adapter was handed. An adapter that returns nothing dispatches, which is
---the one condition that both empties the queue and records the batch.
local sent = {}

require("codereview").setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "a note")
  end,
  send = function(text, target)
    sent[#sent + 1] = { text = text, target = target }
  end,
})

local view = require("codereview.view")
local queue = require("codereview.queue")
local config = require("codereview.config")
local state = require("codereview.state")

-- Resolved, because the archive is keyed on the root git answers with and git answers with
-- symlinks resolved. On macOS the fixture lives under a `/var` symlink, so the unresolved
-- form would read a document nothing ever wrote.
local root = assert(vim.uv.fs_realpath(fixture))

-- The **checkout** this session is in, resolved before anything is queued. It is what the
-- capture path does first, and what the entries built by hand below stand in for: a queue
-- belongs to a checkout, so an entry added before one is resolved joins the queue of
-- nowhere. Harmless here beyond that -- nothing is on disk yet to be read back.
state.ensure_queue()

local NS = vim.api.nvim_create_namespace("codereview_queue")

---The reserved gutter and the bar, as the float draws them. Multibyte on purpose: every
---column an extmark is placed at below is a *byte* offset, which is the trap the diff's own
---change bar already records in `docs/design-notes.md`.
local GUTTER = " "
local BAR = config.get().icons.change_bar

---@param over table Fields to set on the entry
---@return CRAnnotation
local function queued(over)
  return queue.add(vim.tbl_extend("force", {
    type = "bug",
    kind = "line",
    path = "src/main.lua",
    abs_path = vim.fs.joinpath(vim.fn.getcwd(), "src/main.lua"),
    key = "src/main.lua:n:1",
    first = 1,
    last = 1,
    note = "a note",
  }, over))
end

---@return integer win, integer buf
local function open_float()
  view.review_queue()
  local win = vim.api.nvim_get_current_win()
  return win, vim.api.nvim_win_get_buf(win)
end

---@param buf integer
---@return string[]
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---Every extmark starting on a row, as { col, end_col, hl }.
---@param buf integer
---@param row integer 1-indexed
---@return { col: integer, end_col: integer, hl: string }[]
local function marks_on(buf, row)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    out[#out + 1] = { col = m[3], end_col = m[4].end_col, hl = m[4].hl_group }
  end
  return out
end

---The group the bar on a row is drawn in, or nil when the row carries no bar.
---
---Identified by the byte span the bar occupies rather than by "the first mark", so a row
---that merely happens to be highlighted somewhere cannot pass for one carrying a bar.
---@param buf integer
---@param row integer
---@return string|nil
local function bar_group(buf, row)
  local text = lines(buf)[row]
  if not text or text:sub(#GUTTER + 1, #GUTTER + #BAR) ~= BAR then
    return nil
  end
  for _, m in ipairs(marks_on(buf, row)) do
    if m.col == #GUTTER and m.end_col == #GUTTER + #BAR then
      return m.hl
    end
  end
end

---@param buf integer
---@param group string
---@return { col: integer, end_col: integer, hl: string }|nil
local function mark_of(buf, row, group)
  for _, m in ipairs(marks_on(buf, row)) do
    if m.hl == group then
      return m
    end
  end
end

---Rows carrying an entry's bar, from the row its number is drawn on downwards.
---@param buf integer
---@param index integer
---@return integer first, integer last
local function extent(buf, index)
  local first
  for row, text in ipairs(lines(buf)) do
    if text:match("^%s*" .. vim.pesc(BAR) .. "%s*" .. index .. "  ") then
      first = row
      break
    end
  end
  assert(first, ("entry %d is not listed in the float"):format(index))
  local last = first
  while bar_group(buf, last + 1) do
    last = last + 1
  end
  return first, last
end

local function fresh()
  queue.clear()
end

---@param win integer
---@param field "title"|"footer"
---@return string
local function chrome(win, field)
  local cfg = vim.api.nvim_win_get_config(win)
  return cfg[field] and tostring(cfg[field][1][1]) or ""
end

---What `?` lists in the focused float, read off the notification it raises.
---@return string
local function key_listing()
  local listing
  local notify = vim.notify
  vim.notify = function(msg)
    listing = msg
  end
  h.feed("?")
  vim.notify = notify
  return listing or ""
end

--- One entry, drawn as a run of rows ------------------------------------------

describe("an entry with an inlined diff block and a multi-line note", function()
  fresh()
  queued({
    inline = true,
    lines = { "-const cfg = load()", "+const cfg = loadCfg()" },
    first = 20,
    last = 21,
    stale = true,
    note = "why the rename? we lose the cached path here\n\nnothing else calls loadCfg yet",
  })
  queued({
    path = "src/routes.lua",
    key = "src/routes.lua:o:14",
    first = 14,
    last = 14,
    tag = "deleted",
    note = "the old handler is still referenced from tests",
  })
  -- A third, of another type, so "the bar is this entry's type" is a claim about the entry
  -- rather than about the whole float.
  queued({ type = "nitpick", note = "a nitpick" })

  local win, buf = open_float()
  local text = lines(buf)
  local first, last = extent(buf, 1)
  local second = extent(buf, 2)
  local third = extent(buf, 3)

  it("draws the group heading and its directive exactly as the payload's grouping says", function()
    assert.same("## Bugs — diagnose and fix these", text[1])
  end)

  it("starts the entry directly under its heading", function()
    assert.same(2, first)
  end)

  it("carries a bar in the annotation type's group on every row it owns", function()
    for row = first, last do
      assert.same("CodeReviewBug", bar_group(buf, row), ("row %d: %q"):format(row, text[row]))
    end
  end)

  it("keeps the note's own lines rather than flattening them to one", function()
    assert.is_truthy(vim.tbl_contains(text, GUTTER .. BAR .. "   why the rename? we lose the cached path here"))
    assert.is_truthy(vim.tbl_contains(text, GUTTER .. BAR .. "   nothing else calls loadCfg yet"))
  end)

  it("runs the bar through the blank line inside that note", function()
    local blank
    for row = first, last do
      if text[row] == GUTTER .. BAR then
        blank = row
      end
    end
    assert.is_truthy(blank, table.concat(text, "\n"))
    assert.same("CodeReviewBug", bar_group(buf, blank))
  end)

  it("renders the inlined diff block inside the same bar", function()
    local rows = {}
    for row = first, last do
      if text[row]:find("loadCfg()", 1, true) or text[row]:find("load()", 1, true) then
        rows[#rows + 1] = row
      end
    end
    assert.same(2, #rows, table.concat(text, "\n"))
    for _, row in ipairs(rows) do
      assert.same("CodeReviewBug", bar_group(buf, row))
    end
  end)

  it("separates the two entries with a row belonging to neither", function()
    assert.same(last + 2, second)
    assert.same("", text[last + 1])
    assert.is_nil(bar_group(buf, last + 1))
  end)

  it("draws an entry of another type in that type's group", function()
    assert.same("CodeReviewBug", bar_group(buf, second))
    assert.same("CodeReviewNitpick", bar_group(buf, third))
  end)

  it("marks the stale entry as stale, and only that one", function()
    assert.is_truthy(mark_of(buf, first, "CodeReviewStale"), text[first])
    assert.is_nil(mark_of(buf, second, "CodeReviewStale"), text[second])
  end)

  -- Staleness and an annotation type must not share a glyph. The mark is learned off this
  -- row rather than written down here, because the claim is about the glyph this float
  -- really spends: written down, the case would go on passing after the float changed it
  -- and the collision it exists to refuse would be back unchecked.
  it("spends a glyph on staleness that no annotation type also spends", function()
    local span = assert(mark_of(buf, first, "CodeReviewStale"), text[first])
    local mark = assert(text[first]:sub(span.col + 1, span.end_col):match("%S+"), text[first])
    local seen = { [mark] = "the stale mark" }
    for _, t in ipairs(config.get().types) do
      assert.is_nil(seen[t.icon], ("%s and %s both draw %q"):format(t.name, tostring(seen[t.icon]), t.icon))
      seen[t.icon] = t.name
    end
  end)

  it("puts the entry's tag in the state column beside it", function()
    local state = assert(mark_of(buf, second, "CodeReviewQueueState"), text[second])
    assert.same("deleted", text[second]:sub(state.col + 1, state.end_col))
  end)

  -- The bar glyph is multibyte, and extmark columns are byte offsets. A highlight placed at
  -- the display column instead lands inside the glyph and paints nothing recognizable --
  -- the same trap the diff's change bar records in the design notes.
  it("highlights the bar by byte offset, not by display column", function()
    assert.is_true(#BAR > vim.fn.strdisplaywidth(BAR), "the bar under test is not multibyte")
    local bar = mark_of(buf, first, "CodeReviewBug")
    assert.same({ col = #GUTTER, end_col = #GUTTER + #BAR }, { col = bar.col, end_col = bar.end_col })
  end)

  it("reserves the gutter to the left of every bar", function()
    for row = first, last do
      assert.same(GUTTER, text[row]:sub(1, #GUTTER), ("row %d: %q"):format(row, text[row]))
    end
  end)

  vim.api.nvim_win_close(win, true)
end)

--- Wrapping --------------------------------------------------------------------

describe("a note wider than the float", function()
  fresh()
  -- No spaces, so the wrap has nowhere to break but mid-word -- which is where cutting by
  -- byte or by character count goes wrong. Each of these occupies two display columns.
  local cjk = ("字"):rep(120)
  queued({ note = cjk })
  queued({ type = "nitpick", note = ("🎉"):rep(60) })

  local win, buf = open_float()
  local width = vim.api.nvim_win_get_width(win)
  local text = lines(buf)
  local first, last = extent(buf, 1)
  local body = {}
  for row = first + 1, last do
    body[#body + 1] = text[row]:sub(#GUTTER + #BAR + 1):gsub("^%s+", "")
  end

  it("wrapped it over several rows", function()
    assert.is_true(#body > 1, table.concat(body, "\n"))
  end)

  it("keeps every row inside the float", function()
    for row = 1, #text do
      assert.is_true(
        vim.fn.strdisplaywidth(text[row]) <= width,
        ("row %d is %d columns wide in a %d-column float"):format(row, vim.fn.strdisplaywidth(text[row]), width)
      )
    end
  end)

  -- The assertion that fails when the wrap counts characters rather than columns: each of
  -- these is two columns, so a row holding as many characters as it has columns to spend is
  -- twice as wide as the float.
  it("wrapped by display width rather than by character count", function()
    for _, row in ipairs(body) do
      assert.is_true(vim.fn.strchars(row) < vim.fn.strdisplaywidth(row) + 1, row)
      assert.is_true(vim.fn.strdisplaywidth(row) > vim.fn.strchars(row), row)
    end
  end)

  it("breaks between characters, not inside one", function()
    assert.same(cjk, table.concat(body))
  end)

  it("wraps an emoji note the same way", function()
    local from, to = extent(buf, 2)
    local out = {}
    for row = from + 1, to do
      out[#out + 1] = text[row]:sub(#GUTTER + #BAR + 1):gsub("^%s+", "")
    end
    assert.is_true(#out > 1, table.concat(out, "\n"))
    assert.same(("🎉"):rep(60), table.concat(out))
  end)

  vim.api.nvim_win_close(win, true)
end)

--- Resolving the cursor --------------------------------------------------------

describe("dropping from anywhere inside an entry", function()
  ---Drop with the cursor on `row`, and say what survived.
  ---@param row integer
  ---@return string[] remaining notes
  local function drop_at(row)
    local win = select(1, open_float())
    vim.api.nvim_win_set_cursor(win, { row, 0 })
    h.feed("x")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    return vim.tbl_map(function(item)
      return item.note
    end, queue.all())
  end

  ---Two entries, the first of them tall enough to have a middle and a last row.
  local function two()
    fresh()
    queued({ note = "first\n\nnote", inline = true, lines = { "+one", "+two" } })
    queued({ type = "nitpick", note = "second" })
  end

  two()
  local win, buf = open_float()
  local first, last = extent(buf, 1)
  local second = extent(buf, 2)
  vim.api.nvim_win_close(win, true)

  it("has an entry several rows tall to act on", function()
    assert.is_true(last > first + 1, ("rows %d..%d"):format(first, last))
  end)

  it("drops it from its first row", function()
    two()
    assert.same({ "second" }, drop_at(first))
  end)

  it("drops it from a middle row", function()
    two()
    assert.same({ "second" }, drop_at(first + 1))
  end)

  -- The one the old nearest-heading-above resolution got wrong: the last row of an entry
  -- is as far from its heading as a row can be while still belonging to it.
  it("drops it from its last row", function()
    two()
    assert.same({ "second" }, drop_at(last))
  end)

  it("drops the second entry from its own row, not the first one", function()
    two()
    assert.same({ "first\n\nnote" }, drop_at(second))
  end)

  -- All three of these dropped the *previous* entry while the cursor resolved to the
  -- nearest heading above it, which is the hazard: none of them is anywhere a reviewer can
  -- see an entry, and one is a whole group away from what used to answer for it.
  it("drops nothing from the row between two entries", function()
    two()
    assert.same({ "first\n\nnote", "second" }, drop_at(last + 1))
  end)

  it("drops nothing from the heading of the group below", function()
    two()
    assert.same({ "first\n\nnote", "second" }, drop_at(second - 1))
  end)

  it("drops nothing from the first group's heading", function()
    two()
    assert.same({ "first\n\nnote", "second" }, drop_at(1))
  end)
end)

describe("dropping the last entry of a group", function()
  fresh()
  queued({ note = "bug one" })
  queued({ type = "nitpick", note = "nit one" })

  local win, buf = open_float()
  local _, last = extent(buf, 1)
  vim.api.nvim_win_set_cursor(win, { last, 0 })
  h.feed("x")
  local landed = vim.api.nvim_win_get_cursor(win)[1]
  local after = vim.api.nvim_win_get_buf(win)

  -- Otherwise the cursor is left on the heading the repaint moved under it, and the second
  -- `x` of a run silently does nothing.
  it("leaves the cursor on an entry rather than on chrome", function()
    assert.same("CodeReviewNitpick", bar_group(after, landed), lines(after)[landed])
  end)

  it("acts on that entry next", function()
    h.feed("x")
    assert.same(0, queue.count())
  end)

  it("closes once the queue is empty", function()
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)
end)

--- Types and their groups ------------------------------------------------------

describe("an entry carrying no annotation type", function()
  fresh()
  -- Added by hand rather than through the helper: `tbl_extend` cannot express "and no
  -- type", which is the one thing this case is about.
  queue.add({
    kind = "line",
    path = "src/main.lua",
    abs_path = vim.fs.joinpath(vim.fn.getcwd(), "src/main.lua"),
    key = "src/main.lua:n:1",
    first = 1,
    last = 1,
    note = "untyped",
  })

  local win, buf = open_float()
  local text = lines(buf)
  local row = extent(buf, 1)

  it("still gets its own heading, with no directive on it", function()
    assert.same("## Untyped", text[1])
  end)

  it("falls back to the group an unresolvable type's note is drawn in", function()
    assert.same("CodeReviewNote", bar_group(buf, row))
  end)

  vim.api.nvim_win_close(win, true)
end)

describe("the float's own highlight groups", function()
  local hl = require("codereview.hl")

  it("are links a colorscheme already defines", function()
    assert.same("LineNr", vim.api.nvim_get_hl(0, { name = "CodeReviewQueueIndex" }).link)
    assert.same("Comment", vim.api.nvim_get_hl(0, { name = "CodeReviewQueueState" }).link)
  end)

  -- `default = true` is what makes an override stick: re-applying, as a colorscheme change
  -- does, must not take a user's definition back.
  it("leave an override alone when they are re-applied", function()
    vim.api.nvim_set_hl(0, "CodeReviewQueueState", { link = "ErrorMsg" })
    hl.apply()
    assert.same("ErrorMsg", vim.api.nvim_get_hl(0, { name = "CodeReviewQueueState" }).link)
  end)
end)

--- Where submitting from the float ends up -------------------------------------

-- The case neither slice could have written, and the reason it is here.
--
-- This float was restructured against a base with no archive; the archive was built
-- against a base with the old float. They meet at one keystroke: `<C-s>` closes the float
-- and submits, and a **dispatch** is the single condition that both empties the queue and
-- records the batch. Each side was green in isolation and nothing covered the join.
--
-- Driven through the float's own key rather than `view.submit()`, because what is in doubt
-- is the path from this surface, not the rule at the end of it -- `delivery_spec` already
-- owns which outcomes write to the archive, and `archive_spec` owns what survives a
-- restart.
describe("submitting from the float", function()
  fresh()
  queued({ note = "went out from the float" })
  queued({ type = "nitpick", note = "and this one with it" })

  local before = #state.archive(root)
  local listed = #sent
  local win = select(1, open_float())
  h.feed("<C-s>")

  it("hands the batch to the send adapter", function()
    assert.same(listed + 1, #sent)
    assert.is_truthy(sent[#sent].text:find("went out from the float", 1, true), sent[#sent].text)
  end)

  it("empties the queue", function()
    assert.same(0, queue.count())
  end)

  -- The invariant the float's window handle is recorded for, restated here because this is
  -- the keystroke that has to honor it: a batch that has gone must not be left on screen.
  it("leaves no float listing a batch that has already gone", function()
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("records the batch in the archive", function()
    assert.same(before + 1, #state.archive(root))
  end)

  it("archives every entry the float was listing, and only those", function()
    assert.same(
      { "went out from the float", "and this one with it" },
      vim.tbl_map(function(entry)
        return entry.note
      end, state.archive(root)[1].entries)
    )
  end)

  -- The same name the float's own footer was reporting while it was open, so what the
  -- archive says about where a batch went agrees with what the reviewer was told.
  it("names where it went", function()
    assert.same("local", state.archive(root)[1].target)
  end)
end)

--- Copying from the float ------------------------------------------------------

-- The float is where a batch is read before it goes, so it is also where a copy of it is
-- asked for. `gy` is `<C-s>`'s opposite in the one way that matters here: nothing is
-- handed to the adapter, so nothing leaves the queue and nothing is archived -- which is
-- why this key, alone among the ones that act on the batch, leaves the float open.
--
-- What is copied is `delivery_spec`'s to own. What this asserts is the surface: the key is
-- bound, the footer says so, and the list is still there afterwards.
describe("copying from the float", function()
  fresh()
  queued({ note = "copied from the float" })
  queued({ type = "nitpick", note = "and this one with it" })

  local before = #state.archive(root)
  local listed = #sent
  vim.fn.setreg("+", "")
  local win, buf = open_float()
  local rows = #lines(buf)
  h.feed("gy")

  it("puts the payload in the + register", function()
    assert.is_truthy(vim.fn.getreg("+"):find("copied from the float", 1, true), vim.fn.getreg("+"))
  end)

  it("hands the send adapter nothing", function()
    assert.same(listed, #sent)
  end)

  it("keeps the batch it was listing", function()
    assert.same(2, queue.count())
  end)

  it("archives nothing, because a copy is not a dispatch", function()
    assert.same(before, #state.archive(root))
  end)

  -- Where `<C-s>` must leave no float listing a batch that has gone, this must leave the
  -- float exactly as it was: the batch has not gone, so every row is still true.
  it("leaves the float open on the same rows", function()
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.same(rows, #lines(buf))
  end)

  -- Listed under `?` rather than in the footer, which went to the keys that act on one entry:
  -- a copy is asked for once a batch, if at all. The footer still says where to look.
  it("advertises the key under ?, beside the ones already there", function()
    local footer = chrome(win, "footer")
    local listing = key_listing()
    assert.is_truthy(listing:find("  gy ", 1, true), listing)
    assert.is_truthy(footer:find("^S submit", 1, true), footer)
    assert.is_truthy(footer:find("? keys", 1, true), footer)
  end)
end)

--- Editing from the float -----------------------------------------------------

-- `e` resolves the cursor exactly as `x` does, so the same rows are tried: the first, a
-- middle and the last row of an entry several rows tall, and the rows that belong to no
-- entry. The entry edited is the first of two, so an edit that re-queued would land last.
describe("editing from anywhere inside an entry", function()
  ---The compose adapter, swapped for this block alone. `reply` is what it answers with;
  ---false never calls back, which is how an abandoned composer looks from here.
  ---@type string|false
  local reply = false
  local seen
  local shipped = config.get().compose
  config.get().compose = function(ctx, on_accept)
    seen = ctx
    if reply then
      on_accept(nil, reply)
    end
  end

  local function two()
    fresh()
    seen = nil
    queued({ note = "first\n\nnote", inline = true, lines = { "+one", "+two" } })
    queued({ type = "nitpick", note = "second" })
  end

  ---Press `e` with the cursor on `row`, answering the composer with `text`.
  ---@return string[] notes, integer[] ids, integer win
  local function edit_at(row, text)
    reply = text
    local win = select(1, open_float())
    vim.api.nvim_win_set_cursor(win, { row, 0 })
    h.feed("e")
    local notes, ids = {}, {}
    for _, item in ipairs(queue.all()) do
      notes[#notes + 1] = item.note
      ids[#ids + 1] = item.id
    end
    return notes, ids, win
  end

  local function close(win)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  two()
  local win, buf = open_float()
  local first, last = extent(buf, 1)
  local second = extent(buf, 2)
  local footer = vim.api.nvim_win_get_config(win).footer
  footer = footer and tostring(footer[1][1]) or ""
  vim.api.nvim_win_close(win, true)

  it("has an entry several rows tall to act on", function()
    assert.is_true(last > first + 1, ("rows %d..%d"):format(first, last))
  end)

  for name, row in pairs({ ["first row"] = first, ["middle row"] = first + 1, ["last row"] = last }) do
    it(("edits it from its %s, in place and under the same id"):format(name), function()
      two()
      local ids = vim.tbl_map(function(item)
        return item.id
      end, queue.all())
      local notes, after, w = edit_at(row, "first, edited")
      close(w)
      assert.same("first\n\nnote", seen and seen.text)
      assert.same({ "first, edited", "second" }, notes)
      assert.same(ids, after)
    end)
  end

  it("edits the second entry from its own row, not the first one", function()
    two()
    local notes, _, w = edit_at(second, "second, edited")
    close(w)
    assert.same("second", seen and seen.text)
    assert.same({ "first\n\nnote", "second, edited" }, notes)
  end)

  it("opens no composer from the row between two entries", function()
    two()
    local notes, _, w = edit_at(last + 1, "never asked for")
    close(w)
    assert.is_nil(seen)
    assert.same({ "first\n\nnote", "second" }, notes)
  end)

  it("opens no composer from a group heading", function()
    two()
    local notes, _, w = edit_at(1, "never asked for")
    close(w)
    assert.is_nil(seen)
    assert.same({ "first\n\nnote", "second" }, notes)
  end)

  it("changes nothing when the composer is abandoned, and keeps the float open", function()
    two()
    local notes, _, w = edit_at(first, false)
    local open = vim.api.nvim_win_is_valid(w)
    close(w)
    assert.is_true(open)
    assert.same({ "first\n\nnote", "second" }, notes)
  end)

  it("advertises the key in the footer, beside the ones already there", function()
    assert.is_truthy(footer:find("e edit", 1, true), footer)
    assert.is_truthy(footer:find("x drop", 1, true), footer)
  end)

  config.get().compose = shipped
end)

describe("the float after an edit", function()
  local shipped = config.get().compose
  config.get().compose = function(_, on_accept)
    on_accept(nil, "shorter now")
  end

  -- The middle entry shrinks from four note rows to one, so every row below it moves up
  -- three, and the row the cursor was on belongs to the third entry afterwards. A float that
  -- left the cursor where it was would be on the wrong entry.
  fresh()
  queued({ note = "above" })
  queued({ note = "one\ntwo\nthree\nfour" })
  queued({ note = "below\nand more\nand more\nand more" })
  local win, buf = open_float()
  local _, last = extent(buf, 2)
  vim.api.nvim_win_set_cursor(win, { last, 0 })
  h.feed("e")
  local landed = vim.api.nvim_win_get_cursor(win)[1]
  local from, to = extent(buf, 2)
  local text = lines(buf)

  it("shows the new note in the float", function()
    assert.is_truthy(vim.tbl_contains(text, GUTTER .. BAR .. "   shorter now"), table.concat(text, "\n"))
    assert.is_false(vim.tbl_contains(text, GUTTER .. BAR .. "   four"), table.concat(text, "\n"))
  end)

  it("leaves the cursor on the entry it edited", function()
    assert.is_true(landed >= from and landed <= to, ("row %d is outside %d..%d"):format(landed, from, to))
  end)

  vim.api.nvim_win_close(win, true)
  config.get().compose = shipped
end)

-- ADR-0002: an entry never records which path captured it, so neither can an edit. The
-- capture path's entry comes through the public entry point from an ordinary buffer, and a
-- **bare note** has no file behind it and sits in the store that belongs to no checkout.
describe("editing an entry from the capture path, and a bare note", function()
  local shipped = config.get().compose
  local reply = "as captured"
  config.get().compose = function(_, on_accept)
    on_accept(nil, reply)
  end

  fresh()
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(root, "src/main.lua")))
  require("codereview").annotate("bug")
  queue.add({ type = "nitpick", kind = "note", key = "(no file)", inline = false, note = "a bare thought" })
  local ids = vim.tbl_map(function(item)
    return item.id
  end, queue.all())

  local win, buf = open_float()
  reply = "captured, then edited"
  vim.api.nvim_win_set_cursor(win, { extent(buf, 1), 0 })
  h.feed("e")
  reply = "a bare thought, edited"
  vim.api.nvim_win_set_cursor(win, { extent(buf, 2), 0 })
  h.feed("e")
  vim.api.nvim_win_close(win, true)

  it("edits both, each in its place", function()
    assert.same(
      { "captured, then edited", "a bare thought, edited" },
      vim.tbl_map(function(item)
        return item.note
      end, queue.all())
    )
  end)

  it("keeps both ids", function()
    assert.same(
      ids,
      vim.tbl_map(function(item)
        return item.id
      end, queue.all())
    )
  end)

  config.get().compose = shipped
end)

--- Changing the type from the float ------------------------------------------

-- `t` resolves the cursor exactly as `e` and `x` do, so the same rows are tried. The entry
-- changed is the first of two and the float groups by type, so a change that re-queued
-- would land last in the queue, and one that landed would move the entry to another group
-- in the float -- the cursor's old row then belongs to the other entry.
describe("changing the type from anywhere inside an entry", function()
  ---What the stub picker answers with: the row whose label ends in this text, or false to
  ---dismiss it. `offered` is what it was handed, nil when no picker opened.
  ---@type string|false
  local answer = false
  local offered
  local select = vim.ui.select
  vim.ui.select = function(items, _, cb)
    offered = items
    for i, item in ipairs(items) do
      if answer and item:find(answer, 1, true) then
        return cb(item, i)
      end
    end
    cb(nil, nil)
  end

  ---@param first_type string|false The first entry's type; false queues it untyped
  local function two(first_type)
    fresh()
    offered = nil
    -- Set after the fact rather than passed in: `queued` fills in a type wherever it is
    -- handed none, and a nil in its table of fields is no field at all.
    queued({ note = "first\n\nnote", inline = true, lines = { "+one", "+two" } }).type = first_type or nil
    queued({ type = "nitpick", note = "second" })
  end

  ---@return { type: string|false, note: string, id: integer }[]
  local function snapshot()
    return vim.tbl_map(function(item)
      return { type = item.type or false, note = item.note, id = item.id }
    end, queue.all())
  end

  ---Press `t` with the cursor on `row`, answering the picker with `pick`.
  ---@return integer win, integer buf
  local function retype_at(row, pick)
    answer = pick
    local win, buf = open_float()
    vim.api.nvim_win_set_cursor(win, { row, 0 })
    h.feed("t")
    return win, buf
  end

  local function close(win)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  two("bug")
  local win, buf = open_float()
  local first, last = extent(buf, 1)
  local second = extent(buf, 2)
  local footer = chrome(win, "footer")
  vim.api.nvim_win_close(win, true)

  for name, row in pairs({ ["first row"] = first, ["middle row"] = first + 1, ["last row"] = last }) do
    it(("changes it from its %s, in place and under the same id"):format(name), function()
      two("bug")
      local before = snapshot()
      close(retype_at(row, "suggestion"))
      before[1].type = "suggestion"
      assert.same(before, snapshot())
    end)
  end

  it("marks the current type in the picker, and only that one", function()
    two("bug")
    close(retype_at(first, false))
    local marked = vim.tbl_filter(function(item)
      return vim.startswith(item, "✓ ")
    end, offered or {})
    assert.same(1, #marked, vim.inspect(offered))
    assert.is_truthy(marked[1]:find(" bug ", 1, true), marked[1])
  end)

  it("offers no type as a choice", function()
    two("bug")
    close(retype_at(first, false))
    assert.is_truthy(offered and offered[#offered]:find("no type", 1, true), vim.inspect(offered))
  end)

  it("makes a typed entry untyped", function()
    two("bug")
    local before = snapshot()
    close(retype_at(first, "no type"))
    before[1].type = false
    assert.same(before, snapshot())
  end)

  it("marks no type as current on an untyped entry, and gives it a type", function()
    two(false)
    local before = snapshot()
    answer = "bug"
    local w, b = open_float()
    -- Second in the float, though first in the queue: the untyped group is listed after
    -- every configured one.
    vim.api.nvim_win_set_cursor(w, { extent(b, 2), 0 })
    h.feed("t")
    close(w)
    assert.is_truthy(offered and vim.startswith(offered[#offered], "✓ "), vim.inspect(offered))
    before[1].type = "bug"
    assert.same(before, snapshot())
  end)

  it("changes the second entry from its own row, not the first one", function()
    two("bug")
    local before = snapshot()
    close(retype_at(second, "issue"))
    before[2].type = "issue"
    assert.same(before, snapshot())
  end)

  it("changes nothing when the picker is dismissed, and keeps the float open", function()
    two("bug")
    local before = snapshot()
    local w = retype_at(first, false)
    local open = vim.api.nvim_win_is_valid(w)
    close(w)
    assert.is_true(open)
    assert.is_truthy(offered)
    assert.same(before, snapshot())
  end)

  it("opens no picker from the row between two entries", function()
    two("bug")
    local before = snapshot()
    close(retype_at(last + 1, "issue"))
    assert.is_nil(offered)
    assert.same(before, snapshot())
  end)

  it("opens no picker from a group heading", function()
    two("bug")
    local before = snapshot()
    close(retype_at(1, "issue"))
    assert.is_nil(offered)
    assert.same(before, snapshot())
  end)

  it("advertises the key in the footer, beside the ones already there", function()
    assert.is_truthy(footer:find("t type", 1, true), footer)
    assert.is_truthy(footer:find("e edit", 1, true), footer)
  end)

  vim.ui.select = select
end)

describe("the float after a change of type", function()
  local select = vim.ui.select
  vim.ui.select = function(items, _, cb)
    for i, item in ipairs(items) do
      if item:find("no type", 1, true) then
        return cb(item, i)
      end
    end
  end

  -- The bug is listed above the nitpick, and untyped entries are listed last, so the bug
  -- moves from the top of the float to the bottom: the row the cursor was on belongs to the
  -- nitpick afterwards. A float that left the cursor where it was would be on the wrong entry.
  fresh()
  local bug = queued({ note = "was a bug" })
  queued({ type = "nitpick", note = "a nitpick" })
  local win, buf = open_float()
  vim.api.nvim_win_set_cursor(win, { extent(buf, 1), 0 })
  h.feed("t")
  local landed = vim.api.nvim_win_get_cursor(win)[1]
  local text = lines(buf)
  local from, to = extent(buf, 2)

  it("lists the entry under its new type", function()
    assert.same("## Untyped", text[from - 1], table.concat(text, "\n"))
    assert.same(GUTTER .. BAR .. "   was a bug", text[to], table.concat(text, "\n"))
  end)

  it("draws its bar in the new type's group", function()
    assert.same("CodeReviewNote", bar_group(buf, from))
  end)

  it("leaves the cursor on the entry it changed", function()
    assert.is_true(landed >= from and landed <= to, ("row %d is outside %d..%d"):format(landed, from, to))
    assert.same(bug.id, queue.all()[1].id)
  end)

  vim.api.nvim_win_close(win, true)
  vim.ui.select = select
end)

--- Every key, under `?` ----------------------------------------------------------

-- The footer holds the keys a reviewer reaches for while reading; `?` holds all of them.
-- The list below is written out rather than read off the buffer, because reading it off the
-- buffer is what `?` itself does and a check made the same way cannot disagree with it.
describe("listing the keys", function()
  fresh()
  queued({ note = "first" })
  queued({ type = "nitpick", note = "second" })
  local before = vim.tbl_map(function(item)
    return item.note
  end, queue.all())
  local win, buf = open_float()
  local rows = lines(buf)
  local listing = key_listing()

  it("lists every key the float binds", function()
    for _, key in ipairs({ "<CR>", "e", "t", "x", "gy", "^T", "^S", "^A", "q", "<Esc>", "?" }) do
      assert.is_truthy(listing:find("\n  " .. key .. " ", 1, true), key .. " is missing:\n" .. listing)
    end
  end)

  it("says what each one does", function()
    assert.is_truthy(listing:find("Change the type", 1, true), listing)
    assert.is_truthy(listing:find("Edit the note", 1, true), listing)
  end)

  it("changes nothing in the queue, and leaves the float open on the same rows", function()
    assert.same(
      before,
      vim.tbl_map(function(item)
        return item.note
      end, queue.all())
    )
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.same(rows, lines(buf))
  end)

  it("is advertised in the footer", function()
    assert.is_truthy(chrome(win, "footer"):find("? keys", 1, true), chrome(win, "footer"))
  end)

  vim.api.nvim_win_close(win, true)
end)

-- A title or a footer wider than the border is clipped from the left, silently, and what is
-- cut goes with it. Measured at the narrowest the float is drawn, with a long target name and
-- a stale entry, which is the widest either line gets.
describe("the float at its narrowest", function()
  local delivery = require("codereview.delivery")
  local label = delivery.target_label
  delivery.target_label = function()
    return "janus · Analyze RUM patterns across every service"
  end
  -- Sixty-two columns is the widest terminal the float is still fifty wide in: its width is
  -- four fifths of the editor's, floored at fifty.
  local columns = vim.o.columns
  vim.o.columns = 62

  fresh()
  for i = 1, 12 do
    queued({ note = "entry " .. i, stale = i == 1 })
  end
  local win = open_float()
  local width = vim.api.nvim_win_get_width(win)
  local title, footer = chrome(win, "title"), chrome(win, "footer")
  vim.api.nvim_win_close(win, true)
  vim.o.columns = columns
  delivery.target_label = label

  it("is fifty columns wide", function()
    assert.same(50, width)
  end)

  it("fits its footer inside the border", function()
    assert.is_true(vim.fn.strdisplaywidth(footer) <= width, ("%d: %s"):format(vim.fn.strdisplaywidth(footer), footer))
  end)

  it("fits its title inside the border, target and all", function()
    assert.is_true(vim.fn.strdisplaywidth(title) <= width, ("%d: %s"):format(vim.fn.strdisplaywidth(title), title))
    assert.is_truthy(title:find("12 annotations · 1 stale → janus", 1, true), title)
  end)
end)
