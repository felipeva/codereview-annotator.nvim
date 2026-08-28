-- The surface that reads the last dispatched batch back.
--
-- Not `archive_spec`, which owns the record itself: what reached the disk, what a restart
-- finds, the bound and the id a new annotation takes. This owns the float over it -- which
-- batch it decides went last, how it lists one, and the four things it must refuse.
--
-- One process on purpose, which is the opposite of `archive_spec`'s reason and not a
-- contradiction of it: nothing here is a claim about persistence, and every batch below is
-- written by a real dispatch and read back through the accessors, not out of memory.
--
-- Both stores are emptied between blocks. The two halves of one dispatch are rejoined by
-- their shared stamp, and `os.time()` has one-second resolution, so a spec that submits in
-- a loop can otherwise leave a previous batch's bare note in reach of the next one's stamp.
-- Clearing is what keeps every case below a statement about the batch it dispatched.
--
-- Rows, window chrome and highlight *groups*, never colors.
local h = require("tests.helpers")

h.ui(100, 30)
local fixture = h.cd_fixture("mkfixture")

---What the send adapter was handed. An adapter that returns nothing dispatches, which is
---the one condition that both empties the queue and records the batch.
local sent = {}

---What the composer answers with when it is asked for a **preamble** rather than for a note.
---Set by whichever block is about to dispatch under one.
---
---Two answers from one adapter, because a stub that said the same thing to both would leave
---"the float shows the preamble" satisfied by a row holding an entry's note.
local preamble_text = ""

local codereview = require("codereview")
codereview.setup({
  syntax = false,
  compose = function(ctx, on_accept)
    on_accept(nil, ctx.preamble and preamble_text or "a note")
  end,
  pick_target = function(cb)
    cb({ short = "agent", cwd = fixture })
  end,
  send = function(text, target)
    sent[#sent + 1] = { text = text, target = target }
  end,
})

local archive = require("codereview.archive")
local config = require("codereview.config")
local delivery = require("codereview.delivery")
local git = require("codereview.git")
local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

-- Resolved, because the archive is keyed on the root git answers with and git answers with
-- symlinks resolved. On macOS the fixture lives under a `/var` symlink, so the unresolved
-- form would read a document nothing ever wrote.
local root = assert(vim.uv.fs_realpath(fixture))
local main = vim.fs.joinpath(root, "src/main.lua")

-- The **checkout** this session is in, resolved before anything is queued. It is what the
-- capture path does first, and what the entries built by hand below stand in for: a queue
-- belongs to a checkout, so an entry added before one is resolved joins the queue of
-- nowhere. Harmless here beyond that -- nothing is on disk yet to be read back.
state.ensure_queue()

local NS = vim.api.nvim_create_namespace("codereview_archive")

---The reserved gutter and the bar, as the float draws them. Multibyte on purpose: every
---column an extmark is placed at below is a *byte* offset.
local GUTTER = " "
local BAR = config.get().icons.change_bar

---Forget every batch, in both stores, so a block says only what it dispatched itself.
local function fresh()
  queue.clear()
  state.clear(root)
  state.clear_global()
end

---@param over table Fields to set on the entry
---@return CRAnnotation
local function queued(over)
  return queue.add(vim.tbl_extend("force", {
    type = "bug",
    kind = "line",
    path = "src/main.lua",
    abs_path = main,
    key = "src/main.lua:n:1",
    first = 1,
    last = 1,
    note = "a note",
  }, over))
end

---An annotation with no file behind it, which is what routes to the store needing no root.
---Added by hand because `tbl_extend` cannot express "and no path", which is the whole point.
---@param note string
---@param type_name string|nil
local function bare_note(note, type_name)
  return queue.add({ type = type_name, kind = "note", key = "note:" .. note, note = note })
end

---Dispatch whatever is queued, without the notifications reaching the runner.
local function dispatch()
  local _, restore = h.capture_notify()
  codereview.submit()
  restore()
end

---Dispatch whatever is queued under a **preamble**, which is the only way a batch acquires
---one: it is composed at submit time and never sits in the queue.
---@param text string What the composer answers with
local function dispatch_under(text)
  preamble_text = text
  local _, restore = h.capture_notify()
  delivery.submit_with_preamble()
  restore()
  -- Drained here rather than left to whatever pumps the loop next. The submit puts focus
  -- back on a later tick, and a restore that landed after the float had opened would take
  -- focus off it -- and the keys a block below feeds would go somewhere else entirely.
  vim.wait(50)
end

---@return integer win, integer buf
local function open_float()
  codereview.last_batch()
  local win = vim.api.nvim_get_current_win()
  return win, vim.api.nvim_win_get_buf(win)
end

---@param buf integer
---@return string[]
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---A row of an entry's note, as either float draws it: the gutter, the bar, and an indent
---as wide as the batch's numbering. Every batch below has fewer than ten entries, so that
---column is one digit and the indent is three.
---@param text string
---@return string
local function note_row(text)
  return GUTTER .. BAR .. "   " .. text
end

---The row a line is drawn on, or nil when nothing in the float reads exactly that.
---@param buf integer
---@param want string
---@return integer|nil
local function row_of(buf, want)
  for row, text in ipairs(lines(buf)) do
    if text == want then
      return row
    end
  end
end

---The row the batch itself starts on: the first group heading the listing writes.
---@param buf integer
---@return integer
local function first_heading(buf)
  for row, text in ipairs(lines(buf)) do
    if text:find("^## ") then
      return row
    end
  end
  error("the float lists no group at all:\n" .. table.concat(lines(buf), "\n"))
end

---Every extmark starting on a row, as { col, end_col, hl }.
---@param buf integer
---@param row integer 1-indexed
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
---@param row integer
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

---Normal-mode mappings bound to a buffer, as a set.
---
---Through `vim.keycode` on both sides: the API reports a key in its own notation rather
---than the one it was bound with, so comparing the strings as written can silently never
---match.
---@param buf integer
---@return table<string, boolean>
local function bound(buf)
  local lhs = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    lhs[vim.keycode(m.lhs)] = true
  end
  return lhs
end

---A window's title or footer, as one string.
---@param win integer
---@param field "title"|"footer"
---@return string
local function chrome(win, field)
  local value = vim.api.nvim_win_get_config(win)[field]
  return value and tostring(value[1][1]) or ""
end

--- Nothing dispatched yet -------------------------------------------------------

describe("with an empty archive", function()
  fresh()
  local before = vim.api.nvim_get_current_win()
  local msgs, restore = h.capture_notify()
  codereview.last_batch()
  restore()

  it("says so rather than opening onto nothing", function()
    assert.is_true(h.notified(msgs, "Nothing has been dispatched"), vim.inspect(msgs))
  end)

  it("opens no window at all", function()
    assert.same(before, vim.api.nvim_get_current_win())
  end)
end)

--- What the batch that went last is ---------------------------------------------

describe("the batch a dispatch leaves behind", function()
  fresh()
  queued({ note = "the batch that went" })
  queued({ type = "nitpick", note = "and this one with it" })
  delivery.pick_target()
  dispatch()

  local win, buf = open_float()
  local text = lines(buf)

  it("was dispatched, so the queue is empty and the archive is not", function()
    assert.same(0, queue.count())
    assert.same(1, #state.archive(root))
  end)

  it("lists every entry of it, and only those", function()
    assert.same(2, #state.archive(root)[1].entries)
    assert.is_truthy(vim.tbl_contains(text, note_row("the batch that went")), table.concat(text, "\n"))
    assert.is_truthy(vim.tbl_contains(text, note_row("and this one with it")), table.concat(text, "\n"))
  end)

  it("groups them by annotation type, through the grouping the payload shares", function()
    assert.same("## Bugs — diagnose and fix these", text[1])
    assert.is_truthy(
      vim.tbl_contains(text, "## Nitpicks — low priority — batch these together"),
      table.concat(text, "\n")
    )
  end)

  it("draws each entry's bar in its own type's group", function()
    assert.same("CodeReviewBug", bar_group(buf, extent(buf, 1)))
    assert.same("CodeReviewNitpick", bar_group(buf, extent(buf, 2)))
  end)

  it("carries that bar on every row an entry owns, over a reserved gutter", function()
    local first, last = extent(buf, 1)
    for row = first, last do
      assert.same("CodeReviewBug", bar_group(buf, row), ("row %d: %q"):format(row, text[row]))
      assert.same(GUTTER, text[row]:sub(1, #GUTTER), ("row %d: %q"):format(row, text[row]))
    end
  end)

  it("names the target the batch went to", function()
    assert.same("agent", state.archive(root)[1].target)
    assert.is_truthy(chrome(win, "footer"):find("agent", 1, true), chrome(win, "footer"))
  end)

  it("says when it was dispatched", function()
    local at = state.archive(root)[1].at
    assert.is_truthy(chrome(win, "title"):find(os.date("%Y-%m-%d %H:%M", at), 1, true), chrome(win, "title"))
  end)

  it("counts what it is listing", function()
    assert.is_truthy(chrome(win, "title"):find("2 annotations", 1, true), chrome(win, "title"))
  end)

  it("says it is read-only before a key is pressed", function()
    assert.is_truthy(chrome(win, "footer"):find("read-only", 1, true), chrome(win, "footer"))
  end)

  vim.api.nvim_win_close(win, true)
end)

--- The location an entry carries ------------------------------------------------

describe("how an entry says where it was", function()
  fresh()
  queued({ first = 20, last = 21, note = "a range", inline = true, lines = { "-was", "+is" } })
  queued({ kind = "file", key = "src/routes.lua:f:0", path = "src/routes.lua", note = "a whole file" })
  queued({ first = 14, last = 14, tag = "deleted", path = "src/routes.lua", key = "o:14", note = "a deleted line" })
  dispatch()

  local win, buf = open_float()
  local text = lines(buf)

  it("prints a range as the file and the lines it covered", function()
    assert.is_truthy(text[extent(buf, 1)]:find("src/main.lua:20-21", 1, true), text[extent(buf, 1)])
  end)

  it("tags a whole-file entry as one", function()
    local row = extent(buf, 2)
    local tag = assert(mark_of(buf, row, "CodeReviewQueueState"), text[row])
    assert.same("whole file", text[row]:sub(tag.col + 1, tag.end_col))
  end)

  it("keeps the tag an entry carried", function()
    local row = extent(buf, 3)
    local tag = assert(mark_of(buf, row, "CodeReviewQueueState"), text[row])
    assert.same("deleted", text[row]:sub(tag.col + 1, tag.end_col))
  end)

  it("draws the code it inlined inside the same bar, in the diff's own colors", function()
    local first, last = extent(buf, 1)
    local rows = {}
    for row = first, last do
      if text[row]:find("was", 1, true) or text[row]:find("is", 1, true) then
        rows[#rows + 1] = row
      end
    end
    assert.same(2, #rows, table.concat(text, "\n"))
    assert.is_truthy(mark_of(buf, rows[1], "CodeReviewDel"), text[rows[1]])
    assert.is_truthy(mark_of(buf, rows[2], "CodeReviewAdd"), text[rows[2]])
  end)

  -- The queue float prints `⚠ stale` beside an entry whose file moved since capture. That
  -- is worth acting on before a batch goes; on one that has already gone it would read as a
  -- claim about the code now, which this surface has no way to make.
  it("says nothing about staleness, which is a fact about a queue that no longer exists", function()
    for row = 1, #text do
      assert.is_nil(mark_of(buf, row, "CodeReviewStale"), ("row %d: %q"):format(row, text[row]))
    end
    assert.is_nil(table.concat(text, "\n"):find("stale", 1, true))
  end)

  vim.api.nvim_win_close(win, true)
end)

--- A batch split across the two stores ------------------------------------------

-- The case a single accessor cannot answer. A dispatch is recorded in two documents, split
-- on the rule that already routes the queue, and a batch that held both is missing exactly
-- the entries with nowhere else to be listed when only one of them is read -- so a bare note
-- becomes the one thing that vanishes from what a reviewer reads back.
describe("a batch holding a bare note as well as a file", function()
  fresh()
  -- The bare note first and of the *same* annotation type as the file entry, both on
  -- purpose. The two go to different documents, so a rejoin that merely put one store after
  -- the other would list them the wrong way round -- and a different type would hide that
  -- behind the grouping instead of showing it.
  local first = bare_note("first, and it has no file behind it", "bug")
  local second = queued({ note = "second, and it does" })
  bare_note("a third, carrying no type at all")
  dispatch()

  local win, buf = open_float()
  local text = lines(buf)

  it("is a batch the two stores really did split", function()
    assert.same(1, #state.archive(root), vim.inspect(state.archive(root)))
    assert.same(1, #state.archive(root)[1].entries)
    assert.same(2, #state.global_archive()[1].entries)
  end)

  it("lists the bare notes like anything else", function()
    assert.is_truthy(vim.tbl_contains(text, note_row("first, and it has no file behind it")), table.concat(text, "\n"))
    assert.is_truthy(vim.tbl_contains(text, note_row("a third, carrying no type at all")), table.concat(text, "\n"))
  end)

  it("says a bare note is about no file, rather than printing a path it has not got", function()
    assert.is_truthy(text[extent(buf, 1)]:find("(no file)", 1, true), text[extent(buf, 1)])
  end)

  it("counts the whole batch, not the half one store holds", function()
    assert.is_truthy(chrome(win, "title"):find("3 annotations", 1, true), chrome(win, "title"))
  end)

  -- Otherwise the case below is vacuous: two entries the queue numbered the same way round
  -- as the stores hold them would list identically either way.
  it("queued the loose entry before the owned one", function()
    assert.is_true(first.id < second.id, ("%d is not below %d"):format(first.id, second.id))
  end)

  it("puts the two halves back in the order they were queued in", function()
    assert.is_truthy(text[extent(buf, 2)]:find("src/main.lua", 1, true), text[extent(buf, 2)])
  end)

  it("groups them by type, untyped last, exactly as anything else is grouped", function()
    assert.same("## Bugs — diagnose and fix these", text[1])
    assert.is_truthy(vim.tbl_contains(text, "## Untyped"), table.concat(text, "\n"))
    assert.same("CodeReviewBug", bar_group(buf, extent(buf, 1)))
    assert.same("CodeReviewNote", bar_group(buf, extent(buf, 3)))
  end)

  vim.api.nvim_win_close(win, true)
end)

--- The preamble the batch went under --------------------------------------------

-- A **preamble** is part of what was sent, so it is part of what is read back: a float that
-- showed the findings and not the covering note would be describing a message nobody
-- received. Drawn where the payload drew it -- above the batch, read before the findings --
-- and drawn as prose, because it is not an **entry** and carries none of what lists one.
describe("a batch dispatched under a preamble", function()
  fresh()
  queued({ note = "the batch that went" })
  dispatch_under("read the deleted-line rule first")

  local win, buf = open_float()
  local text = lines(buf)
  local row = row_of(buf, "read the deleted-line rule first")

  it("kept it with the batch", function()
    assert.same("read the deleted-line rule first", state.archive(root)[1].preamble)
  end)

  it("shows it", function()
    assert.is_truthy(row, table.concat(text, "\n"))
  end)

  it("draws it above the batch, where the agent read it", function()
    assert.is_true(assert(row) < first_heading(buf), table.concat(text, "\n"))
  end)

  -- The same blank row the payload writes between the two. Without it the covering note runs
  -- straight into the first group heading, and what covers the batch reads as part of it.
  it("separates it from the batch, as the payload separated it", function()
    assert.same("", text[assert(row) + 1])
    assert.same(row + 2, first_heading(buf))
  end)

  -- The gutter and the bar are what say "entry" on this surface. A preamble is about the
  -- batch and not about a place in the code, and it is drawn as what it is.
  it("draws it as prose rather than as an entry", function()
    assert.is_nil(bar_group(buf, assert(row)), text[row])
  end)

  it("lists the batch's entries exactly as it lists any other batch's", function()
    assert.is_truthy(vim.tbl_contains(text, note_row("the batch that went")), table.concat(text, "\n"))
    assert.same("CodeReviewBug", bar_group(buf, extent(buf, 1)))
  end)

  it("counts the annotations, which the preamble is not one of", function()
    assert.is_truthy(chrome(win, "title"):find("1 annotation ", 1, true), chrome(win, "title"))
  end)

  vim.api.nvim_win_close(win, true)
end)

-- The read-only claim covers the preamble in full, for the reason it covers everything else
-- here: an archived record says something happened, and a surface that let you revise it
-- would be claiming the plugin can revise what an agent already received.
describe("the preamble on a surface that refuses to edit", function()
  fresh()
  queued({ note = "already gone" })
  dispatch_under("as it was dispatched")

  local win, buf = open_float()
  local row = assert(row_of(buf, "as it was dispatched"), table.concat(lines(buf), "\n"))
  vim.api.nvim_win_set_cursor(win, { row, 0 })

  it("holds a buffer nothing can be typed into", function()
    assert.is_false(vim.bo[buf].modifiable)
  end)

  -- With the cursor on the preamble itself, which is where a reviewer who wants to change it
  -- would put it. The notification is asserted as well as the record: `x` on a `nomodifiable`
  -- buffer changes nothing either, and would leave this green while saying `E21`.
  it("says why, rather than editing anything, on the key that drops from the queue float", function()
    local msgs, restore = h.capture_notify()
    h.feed("x")
    restore()
    assert.is_true(h.notified(msgs, "annotate again"), vim.inspect(msgs))
    assert.same("as it was dispatched", lines(buf)[row])
    assert.same("as it was dispatched", state.archive(root)[1].preamble)
  end)

  -- The whole of what this surface binds, asserted as a set rather than one key at a time:
  -- a key added to rewrite a preamble is exactly what this case exists to red.
  it("binds nothing that could rewrite it", function()
    local expected = {}
    for _, key in ipairs({ "x", "<C-s>", "q", "<Esc>" }) do
      expected[vim.keycode(key)] = true
    end
    assert.same(expected, bound(buf))
  end)

  h.feed("q")
end)

-- A preamble belongs to the **dispatch** and not to either half of it, so both halves carry
-- the same one -- exactly as they already carry the same stamp and the same **target**. Read
-- back, the rejoined batch has one covering note and not two.
describe("a preamble on a batch the two stores split", function()
  fresh()
  bare_note("a thought with no file behind it", "bug")
  queued({ note = "and a file with one" })
  dispatch_under("both halves are one batch")

  local win, buf = open_float()
  local text = lines(buf)

  it("is a batch the two stores really did split", function()
    assert.same(1, #state.archive(root)[1].entries)
    assert.same(1, #state.global_archive()[1].entries)
  end)

  it("carries the same preamble in both halves", function()
    assert.same("both halves are one batch", state.archive(root)[1].preamble)
    assert.same("both halves are one batch", state.global_archive()[1].preamble)
  end)

  it("shows it once, over the batch the two were rejoined into", function()
    local seen = 0
    for _, line in ipairs(text) do
      if line == "both halves are one batch" then
        seen = seen + 1
      end
    end
    assert.same(1, seen, table.concat(text, "\n"))
  end)

  vim.api.nvim_win_close(win, true)
end)

-- The fast path costs this surface nothing either. A batch that went with no covering note
-- has none to read back, and the float draws what it drew before a batch could carry one.
describe("a batch dispatched with no preamble", function()
  fresh()
  queued({ note = "no covering note" })
  dispatch()

  local win, buf = open_float()

  it("records none", function()
    assert.is_nil(state.archive(root)[1].preamble)
  end)

  it("opens on the batch itself, with nothing above it", function()
    assert.same(1, first_heading(buf))
  end)

  vim.api.nvim_win_close(win, true)
end)

-- The submit key means submit, so an empty composer dispatches anyway -- and an empty
-- preamble renders nothing into the payload. The record says the same thing: nothing was
-- sent above the batch, so there is nothing above it to read back.
describe("a batch dispatched under an empty preamble", function()
  fresh()
  queued({ note = "an empty composer" })
  dispatch_under("  \n  ")

  local win, buf = open_float()

  it("was dispatched", function()
    assert.same(0, queue.count())
    assert.same(1, #state.archive(root))
  end)

  it("records none", function()
    assert.is_nil(state.archive(root)[1].preamble)
  end)

  it("draws as a batch that was never offered one", function()
    assert.same(1, first_heading(buf))
  end)

  vim.api.nvim_win_close(win, true)
end)

-- The window does not wrap -- a row folded back to column zero would leave the bar behind and
-- an entry would appear to end -- so every row this float draws, it wraps itself. A preamble
-- is prose a reviewer typed and is under no obligation to be narrow.
describe("a preamble wider than the float", function()
  fresh()
  queued({ note = "a note" })
  -- No spaces, so the wrap has nowhere to break but mid-word, and each of these occupies two
  -- display columns -- which is where cutting by byte or by character count goes wrong.
  local cjk = ("字"):rep(120)
  dispatch_under(cjk)

  local win, buf = open_float()
  local width = vim.api.nvim_win_get_width(win)
  local text = lines(buf)
  local body = {}
  for row = 1, first_heading(buf) - 1 do
    if text[row] ~= "" then
      body[#body + 1] = text[row]
    end
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

  it("wrapped by display width rather than by character count", function()
    for _, row in ipairs(body) do
      assert.is_true(vim.fn.strdisplaywidth(row) > vim.fn.strchars(row), row)
    end
  end)

  it("breaks between characters, not inside one", function()
    assert.same(cjk, table.concat(body))
  end)

  vim.api.nvim_win_close(win, true)
end)

--- Which batch is the last one --------------------------------------------------

describe("with more than one batch archived", function()
  fresh()
  queued({ note = "the older batch" })
  dispatch()
  queued({ note = "the newer batch" })
  dispatch()

  local win, buf = open_float()
  local text = lines(buf)

  it("has two to choose between", function()
    assert.same(2, #state.archive(root))
  end)

  it("lists the newest, and only it", function()
    assert.is_truthy(vim.tbl_contains(text, note_row("the newer batch")), table.concat(text, "\n"))
    assert.is_false(vim.tbl_contains(text, note_row("the older batch")), table.concat(text, "\n"))
  end)

  it("counts one annotation, not both batches'", function()
    assert.is_truthy(chrome(win, "title"):find("1 annotation ", 1, true), chrome(win, "title"))
  end)

  vim.api.nvim_win_close(win, true)
end)

--- Read-only --------------------------------------------------------------------

describe("what the float refuses to do", function()
  fresh()
  queued({ note = "already gone" })
  dispatch()
  -- Queued after the dispatch, so the queue holding something is what "left exactly as it
  -- was" is asserted against -- an empty queue is satisfied by a surface that emptied it.
  queued({ note = "still to send" })
  queued({ type = "nitpick", note = "and this" })
  local before_queue = vim.deepcopy(queue.all())
  local before_archive = vim.deepcopy(state.archive(root))
  local listed = #sent

  local win, buf = open_float()

  it("lists the batch that went, not the queue that has not", function()
    local text = lines(buf)
    assert.is_truthy(vim.tbl_contains(text, note_row("already gone")), table.concat(text, "\n"))
    assert.is_false(vim.tbl_contains(text, note_row("still to send")), table.concat(text, "\n"))
  end)

  it("holds a buffer nothing can be typed into", function()
    assert.is_false(vim.bo[buf].modifiable)
  end)

  -- The notification is asserted as well as the record, and it is what stops these two
  -- passing on a key that is merely unbound: `x` against a `nomodifiable` buffer changes
  -- nothing either, and would leave every assertion below it green while saying `E21`.
  it("drops nothing on the key that drops from the queue float", function()
    local msgs, restore = h.capture_notify()
    h.feed("x")
    restore()
    assert.same(before_archive, state.archive(root))
    assert.same(before_queue, queue.all())
    assert.is_true(h.notified(msgs, "annotate again"), vim.inspect(msgs))
  end)

  it("resubmits nothing on the key that submits from the queue float", function()
    local msgs, restore = h.capture_notify()
    h.feed("<C-s>")
    restore()
    assert.same(listed, #sent)
    assert.same(before_archive, state.archive(root))
    assert.is_true(h.notified(msgs, "annotate again"), vim.inspect(msgs))
  end)

  it("is still open, having done neither", function()
    assert.is_true(vim.api.nvim_win_is_valid(win))
  end)

  it("leaves the queue exactly as it was when it closes", function()
    h.feed("q")
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.same(before_queue, queue.all())
  end)
end)

--- What it leaves alone ----------------------------------------------------------

describe("the queue float beside it", function()
  fresh()
  queued({ note = "already gone" })
  dispatch()
  queued({ note = "still to send" })

  local win = select(1, open_float())
  h.feed("q")

  it("still lists what is left to send, and not what went", function()
    view.review_queue()
    local qwin = vim.api.nvim_get_current_win()
    local text = lines(vim.api.nvim_win_get_buf(qwin))
    assert.is_truthy(vim.tbl_contains(text, note_row("still to send")), table.concat(text, "\n"))
    assert.is_false(vim.tbl_contains(text, note_row("already gone")), table.concat(text, "\n"))
    vim.api.nvim_win_close(qwin, true)
  end)

  it("opened with no review view, and left none behind", function()
    assert.is_false(codereview.is_open())
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)
end)

-- A batch is not a window: it can be read back from anywhere, including from inside a
-- review, and reading it must leave that review exactly where it was.
describe("opened with a review view on screen", function()
  fresh()
  queued({ note = "already gone" })
  dispatch()

  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local diff_win = review.win
  local rows = #vim.api.nvim_buf_get_lines(review.buf, 0, -1, false)

  local win = select(1, open_float())

  it("opens over it rather than instead of it", function()
    assert.is_true(vim.api.nvim_win_is_valid(diff_win))
    assert.are_not.same(diff_win, win)
  end)

  it("leaves the diff behind it untouched", function()
    h.feed("q")
    assert.same(review, view.current())
    assert.same(rows, #vim.api.nvim_buf_get_lines(review.buf, 0, -1, false))
  end)

  codereview.close()
end)

--- The key beside the command ---------------------------------------------------

-- `gb` names the **batch**, and it opens the surface the command opens rather than one of
-- its own: there is one surface for one fact. Bound in the diff and in the tree, so which
-- window a reviewer is in never decides whether a key exists.
describe("the key inside a review", function()
  fresh()
  queued({ note = "already gone" })
  dispatch()

  codereview.open()
  local review = assert(view.current(), "no review view opened")

  ---The float `gb` opens from one of the review's windows, as rows and frame.
  ---
  ---Guarded as a *float* rather than merely as another window: a key that is not bound at
  ---all leaves focus where it was, and "somewhere other than the diff" is then satisfied by
  ---the tree — which would read the tree's own rows and close the review with the `q` below.
  ---@param from integer The window to press it in
  ---@return string[] rows, string title
  local function by_key(from)
    vim.api.nvim_set_current_win(from)
    h.feed("gb")
    local win = vim.api.nvim_get_current_win()
    assert.are_not.same(from, win, "gb opened no window of its own")
    assert.are_not.same("", vim.api.nvim_win_get_config(win).relative, "gb opened no float")
    local out = { lines(vim.api.nvim_win_get_buf(win)), chrome(win, "title") }
    h.feed("q")
    return out[1], out[2]
  end

  it("is bound in the diff and in the tree", function()
    assert.is_true(bound(review.buf)[vim.keycode("gb")] == true, "gb is not bound in the diff")
    assert.is_true(bound(assert(review.panel_buf))[vim.keycode("gb")] == true, "gb is not bound in the tree")
  end)

  -- Opening a file from the review is a new tab, and `gt`/`gT` are how a reviewer comes
  -- back from it. The `g` family this joins may take neither.
  it("shadows neither of the tab-switching keys", function()
    for _, buf in ipairs({ review.buf, assert(review.panel_buf) }) do
      assert.is_nil(bound(buf)[vim.keycode("gt")], "gt is shadowed")
      assert.is_nil(bound(buf)[vim.keycode("gT")], "gT is shadowed")
    end
  end)

  it("opens the same float the command opens, pressed in the diff", function()
    local rows, title = by_key(review.win)
    local win, buf = open_float()
    local commanded, commanded_title = lines(buf), chrome(win, "title")
    h.feed("q")
    assert.same(commanded, rows)
    assert.same(commanded_title, title)
  end)

  it("opens it from the file tree as well", function()
    local rows = by_key(assert(review.panel_win, "no file tree"))
    assert.is_true(vim.tbl_contains(rows, note_row("already gone")), table.concat(rows, "\n"))
  end)

  it("leaves the review it was pressed in on screen", function()
    assert.same(review, view.current())
    assert.is_true(vim.api.nvim_win_is_valid(review.win))
  end)

  codereview.close()
end)

-- The plugin binds no global mappings, and this key changes nothing about that: a host
-- that wants the batch one keystroke away from anywhere maps the command itself.
describe("the key outside a review", function()
  it("is bound nowhere globally", function()
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      assert.are_not.same(vim.keycode("gb"), vim.keycode(m.lhs), "gb is mapped globally")
    end
  end)

  it("leaves the command opening the float with no review open", function()
    assert.is_false(codereview.is_open())
    local _, buf = open_float()
    assert.is_true(vim.tbl_contains(lines(buf), note_row("already gone")), table.concat(lines(buf), "\n"))
    h.feed("q")
  end)
end)

--- Wrapping ----------------------------------------------------------------------

describe("a note wider than the float", function()
  fresh()
  -- No spaces, so the wrap has nowhere to break but mid-word -- which is where cutting by
  -- byte or by character count goes wrong. Each of these occupies two display columns.
  local cjk = ("字"):rep(120)
  queued({ note = cjk })
  dispatch()

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
      assert.is_true(vim.fn.strdisplaywidth(row) > vim.fn.strchars(row), row)
    end
  end)

  it("breaks between characters, not inside one", function()
    assert.same(cjk, table.concat(body))
  end)

  vim.api.nvim_win_close(win, true)
end)

--- Which batch `last` picks ------------------------------------------------------

-- The rule underneath the float, asserted where the two stores can be arranged by hand
-- rather than only through whichever dispatch a fixture happens to produce.
describe("choosing between the two stores", function()
  it("takes the newest of the pair when only one of them holds anything", function()
    fresh()
    bare_note("nothing but a thought")
    dispatch()
    local batch = assert(archive.last(root))
    assert.same(1, #batch.entries)
    assert.same("nothing but a thought", batch.entries[1].note)
  end)

  it("answers with nothing at all when neither holds anything", function()
    fresh()
    assert.is_nil(archive.last(root))
  end)

  -- Outside a repository there is no document to key against, so the store that needs no
  -- root is the only one there is -- and a bare note dispatched from anywhere is still the
  -- last batch, exactly as it is still part of the one queue.
  it("reads the store that needs no root with no repository behind it", function()
    fresh()
    bare_note("dispatched from nowhere in particular")
    dispatch()
    local batch = assert(archive.last(nil))
    assert.same("dispatched from nowhere in particular", batch.entries[1].note)
  end)
end)

--- Where the scope and this float meet -------------------------------------------

-- The case neither slice could have written, and the reason it is here.
--
-- `since-batch` diffs the working tree against the newest archived batch's **snapshot**;
-- this float lists the newest archived batch's **entries**. A reviewer reads one beside the
-- other -- that is the whole point of keeping a batch -- so if the two ever disagreed about
-- which batch is newest, the diff on screen would be the response to one dispatch and the
-- annotations beside it would belong to another, and nothing anywhere would say so.
--
-- Each side was green against a base that did not have the other, and each independently
-- reached for the head of the archive. They now go through `state.last_batch`, and this is
-- what makes that one query rather than two that happen to agree.
--
-- Two dispatches, because with one batch archived both answers are forced and agreeing
-- costs nothing.
describe("the scope and the float, on which batch is newest", function()
  fresh()
  queued({ note = "the older batch" })
  dispatch()

  -- Edited between the two dispatches, standing in for the agent's response. Without it both
  -- `git stash create` calls mint a commit from the same tree in the same second and return
  -- the *same* sha, so "the scope diffs against the newest batch's snapshot" is satisfied by
  -- either batch and the case measures nothing.
  local touched = vim.fs.joinpath(root, "src/main.lua")
  vim.fn.writefile(vim.list_extend(vim.fn.readfile(touched), { "-- between the two batches" }), touched)

  queued({ note = "the newer batch" })
  dispatch()

  local archived = state.archive(root)
  local scope = assert(git.resolve_scope("since-batch", root))

  ---The batch the scope actually resolved against, found by the snapshot it is diffing from
  ---rather than by taking the head of the archive a third time -- which is the assumption
  ---under test and cannot also be the way the test looks it up.
  local diffed
  for _, batch in ipairs(archived) do
    if batch.snapshot == scope.before then
      diffed = batch
    end
  end

  local win, buf = open_float()
  local text = lines(buf)

  it("archived two batches with different snapshots, so agreeing is a choice", function()
    assert.same(2, #archived)
    assert.are_not.same(archived[1].snapshot, archived[2].snapshot)
  end)

  it("resolves the scope against one of them", function()
    assert.is_truthy(diffed, ("%s is no archived batch's snapshot"):format(tostring(scope.before)))
  end)

  it("lists the entries of the very batch the scope is diffing against", function()
    for _, entry in ipairs(diffed.entries) do
      assert.is_truthy(vim.tbl_contains(text, note_row(entry.note)), table.concat(text, "\n"))
    end
    assert.is_false(vim.tbl_contains(text, note_row("the older batch")), table.concat(text, "\n"))
  end)

  it("counts what that batch held, and nothing from the other", function()
    local n = #diffed.entries
    assert.is_truthy(chrome(win, "title"):find(("%d annotation"):format(n), 1, true), chrome(win, "title"))
  end)

  vim.api.nvim_win_close(win, true)
end)
