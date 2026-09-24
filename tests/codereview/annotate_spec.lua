-- What a cursor position or a visual selection turns into: which lines an annotation
-- captures, whether it can travel as an `@ref` or must carry its diff inline, and how the
-- queue behaves once entries pile up.
local h = require("tests.helpers")

h.ui(110, 40)
h.cd_fixture("mkfixture")

-- A synchronous stub composer, so capture completes inside the `annotate` call rather
-- than on a later tick.
local last_ctx
require("codereview").setup({
  syntax = false,
  compose = function(ctx, on_accept, _)
    last_ctx = ctx
    on_accept(nil, "note about " .. ctx.label)
  end,
})

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")
local render = require("codereview.render")
local config = require("codereview.config")

view.open("branch")
local V = view.current()
queue.clear()

local function at(row)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
end

local add_row = assert(h.line_row(V, "src/fresh.lua"))

describe("annotating an added line", function()
  queue.clear()
  at(add_row)
  annotate.annotate("bug")
  local e = queue.all()[1]

  it("records the type and kind", function()
    assert.same({ "bug", "line" }, { e.type, e.kind })
  end)

  -- A pure addition exists on disk at the post-image line number, so it can travel as a
  -- bare `@path#Lline` and the reader can open it.
  it("does not need to inline its diff", function()
    assert.is_false(e.inline)
  end)

  it("keys off the post-image line number", function()
    assert.same("src/fresh.lua:n:1", e.key)
    assert.same({ 1, 1 }, { e.first, e.last })
  end)

  -- Kept even though this entry renders as an @ref: an out-of-tree target needs the code.
  it("still carries its code", function()
    assert.same({ "+local function fresh() end" }, e.lines)
  end)

  it("hands the composer a titled context", function()
    assert.same("Bug · src/fresh.lua:1", last_ctx.label)
  end)

  -- What a composer needs to put focus back when the user dismisses it, which is the one
  -- path that never reaches the plugin.
  it("tells the composer which window the annotation came from", function()
    assert.same(V.win, last_ctx.origin_win)
  end)
end)

describe("annotating a deleted line", function()
  queue.clear()
  at(assert(h.line_row(V, "src/gone.lua")))
  annotate.annotate("issue")
  local e = queue.all()[1]

  -- A deleted line is not in the working tree, so an `@ref` would point at whatever now
  -- occupies that number. It has to carry the diff instead.
  it("inlines its diff and says why", function()
    assert.is_true(e.inline)
    assert.same("deleted", e.tag)
  end)

  it("uses the pre-image line number", function()
    assert.same({ 1, 1 }, { e.first, e.last })
    assert.same("src/gone.lua:o:1", e.key)
  end)

  it("carries the diff", function()
    assert.same({ "-local gone = true" }, e.lines)
  end)
end)

describe("annotating a visual range across a change", function()
  queue.clear()
  at(assert(h.row_of(V, "src/main.lua", function(a)
    return a.kind == "line" and a.line == 1
  end)))
  h.feed("Vjjjas") -- select all 4 rendered lines, annotate as a suggestion
  local e = queue.all()[1]

  it("queues exactly one annotation", function()
    assert.same(1, queue.count())
  end)

  it("records it as a range", function()
    assert.same("range", e.kind)
  end)

  it("inlines because the range touches a deletion", function()
    assert.is_true(e.inline)
    assert.same("change", e.tag)
  end)

  it("captures the whole diff block", function()
    assert.same({
      ' local app = require("app")',
      "-local cfg = load()",
      "+local cfg = load_config()",
      " app.listen(cfg.port)",
    }, e.lines)
  end)
end)

describe("annotating a pure-addition range", function()
  queue.clear()
  at(assert(h.row_of(V, "src/untracked.lua", function(a)
    return a.kind == "line" and a.line == 1
  end)))
  h.feed("Vjan")
  local e = queue.all()[1]

  it("does not need to inline", function()
    assert.is_false(e.inline)
  end)

  it("spans post-image line numbers", function()
    assert.same({ 1, 2 }, { e.first, e.last })
  end)

  it("records the chosen type", function()
    assert.same("nitpick", e.type)
  end)
end)

describe("annotating a hunk header", function()
  queue.clear()
  at(assert(h.row_of(V, "src/main.lua", function(a)
    return a.kind == "hunk"
  end)))
  annotate.annotate("fix")
  local e = queue.all()[1]

  it("captures the hunk", function()
    assert.same("hunk", e.kind)
    assert.same(4, #e.lines)
  end)

  -- A hunk spans both sides by definition, so it is never reducible to a line reference.
  it("is always inlined", function()
    assert.is_true(e.inline)
  end)
end)

describe("annotating a file header", function()
  queue.clear()
  at(V.render.file_rows[1])
  annotate.annotate("suggestion")
  local e = queue.all()[1]

  it("targets the whole file", function()
    assert.same("file", e.kind)
    assert.same("whole file", e.tag)
  end)

  it("keys off the path alone", function()
    assert.same(render.file_key(V.files[1].path), e.key)
  end)
end)

describe("annotating a binary file", function()
  queue.clear()
  at(V.render.file_rows[assert(h.file_index(V, "src/untracked.bin"))])
  annotate.annotate("issue")
  local e = queue.all()[1]

  -- There are no lines to point at, so a line-level annotation would be a lie.
  it("falls back to the whole file", function()
    assert.same("file", e.kind)
    assert.same("binary", e.tag)
  end)
end)

describe("a selection that runs past the end of a file", function()
  queue.clear()
  local messages, restore = h.capture_notify()

  -- Start on an actual diff line of fresh.lua and run past its end into gone.lua.
  at(add_row)
  h.feed("V4jab")
  local e = queue.all()[1]

  it("still queues exactly one annotation", function()
    assert.same(1, queue.count())
  end)

  it("binds it to the first file in the selection", function()
    assert.same("src/fresh.lua", e.path)
    assert.same("line", e.kind)
  end)

  -- fresh.lua contributes exactly one diff line, so the clamped range collapses to it.
  it("keeps only that file's lines", function()
    assert.same({ 1, 1 }, { e.first, e.last })
  end)

  it("says that it clamped", function()
    assert.is_true(h.notified(messages, "clamped"))
  end)

  restore()
end)

describe("a selection anchored on a file header", function()
  queue.clear()
  local messages, restore = h.capture_notify()

  at(1)
  h.feed("V7jab")
  local e = queue.all()[1]

  -- Still "whole file", but the overlap is reported rather than silently discarded.
  it("stays a whole-file annotation on the right file", function()
    assert.same("file", e.kind)
    assert.same("src/fresh.lua", e.path)
  end)

  it("still warns", function()
    assert.is_true(h.notified(messages, "clamped"))
  end)

  restore()
end)

describe("rendering queued annotations", function()
  queue.clear()
  at(add_row)
  annotate.annotate("bug")
  at(assert(h.line_row(V, "src/gone.lua")))
  annotate.annotate("nitpick")
  view.paint()

  it("draws each one as virtual lines", function()
    assert.same(2, #h.virt_marks(V))
  end)

  it("puts the note text in the virtual lines", function()
    local first = h.virt_marks(V)[1][4].virt_lines[1]
    assert.is_truthy(first[#first][1]:find("note about", 1, true))
  end)

  it("advertises the count on the file header", function()
    local row = V.render.file_rows[1]
    local header = vim.api.nvim_buf_get_lines(V.buf, row - 1, row, false)[1]
    assert.is_truthy(header:find("[1 note]", 1, true))
  end)

  -- The count number left the file row with #242 and its columns went to the `+N -M` **stat**,
  -- so what says a file holds an entry is the **state** mark: annotated rather than
  -- unreviewed. Trailing digits are the stat's now, and a case reading them reads a size.
  it("marks the file annotated on its panel row", function()
    -- The panel is a tree, so row 1 is a directory; find the file's own row.
    local prow = V.panel_render.file_row[assert(h.file_index(V, "src/fresh.lua"))]
    local line = vim.api.nvim_buf_get_lines(V.panel_buf, prow - 1, prow, false)[1]
    local annotated = config.get().icons.annotated
    assert.same(annotated, vim.trim(line):sub(1, #annotated))
    assert.is_truthy(line:find("fresh.lua", 1, true))
  end)
end)

describe("a file-level note on a collapsed file", function()
  queue.clear()
  at(V.render.file_rows[1])
  annotate.annotate("issue")
  at(V.render.file_rows[1])
  view.toggle_reviewed()

  -- The lines it would hang off are gone, but the note is about the file, so it has
  -- somewhere to live.
  it("stays visible", function()
    assert.same(1, #h.virt_marks(V))
  end)

  view.toggle_reviewed()
end)

describe("dropping annotations", function()
  queue.clear()
  at(add_row)
  annotate.annotate("bug")
  annotate.annotate("fix")

  it("allows more than one note on a line", function()
    assert.same(2, queue.count())
  end)

  it("drops the most recent first", function()
    at(add_row)
    annotate.drop()
    assert.same(1, queue.count())
    assert.same("bug", queue.all()[1].type)
  end)

  it("empties the line when dropped again", function()
    at(add_row)
    annotate.drop()
    assert.same(0, queue.count())
  end)
end)

-- The review path offers the same menu and the same way out of it: an annotation made over
-- the diff has no more need to invent a type than one captured from a buffer.
describe("declining a type over the diff", function()
  queue.clear()
  at(add_row)

  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb)
    cb(items[#items], #items)
  end
  annotate.annotate_pick()
  vim.ui.select = orig

  it("queues the annotation carrying no type", function()
    assert.same(1, queue.count())
    assert.is_nil(queue.all()[1].type)
  end)

  it("anchors it exactly as a typed annotation would be", function()
    assert.same({ "src/fresh.lua:n:1", "line" }, { queue.all()[1].key, queue.all()[1].kind })
  end)

  it("titles the composer without inventing a type", function()
    assert.same("Untyped · src/fresh.lua:1", last_ctx.label)
  end)

  -- The inline renderer already had a fallback for an annotation whose type it cannot
  -- resolve. Until now nothing could produce one, so this is the first thing to reach it.
  it("still projects onto the diff", function()
    view.paint()
    assert.same(1, #h.virt_marks(V))
  end)

  it("says what it dropped without naming a type it never had", function()
    local msgs, restore = h.capture_notify()
    at(add_row)
    annotate.drop()
    restore()
    assert.same(0, queue.count())
    assert.is_true(h.notified(msgs, "Dropped untyped note"), vim.inspect(msgs))
  end)

  -- Escape still means never mind, on this path as on the other.
  it("abandons the annotation when the picker is dismissed instead", function()
    queue.clear()
    at(add_row)
    local dismiss = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb(nil, nil)
    end
    annotate.annotate_pick()
    vim.ui.select = dismiss
    assert.same(0, queue.count())
  end)
end)

describe("grouping the queue", function()
  queue.clear()
  for _, t in ipairs({ "nitpick", "bug", "issue", "bug" }) do
    at(add_row)
    annotate.annotate(t)
  end

  -- Groups follow the configured type order, not the order notes were captured, so a
  -- reviewer reads bugs before nitpicks however they were written.
  it("orders groups by type, not by capture order", function()
    local groups = require("codereview.types").group(queue.all(), config.get().types)
    assert.same(
      { "bug:2", "nitpick:1", "issue:1" },
      vim.tbl_map(function(g)
        return ("%s:%d"):format(g.type.name, #g.items)
      end, groups)
    )
  end)
end)

--- Editing a queued note --------------------------------------------------------

-- An edit changes the note and nothing else. Measured on the first of three entries, so
-- an edit that re-queues -- a remove and an add -- lands last and shows, and from a note
-- that differs from the new one, so an edit that did nothing cannot read as one that did.
describe("editing a queued note", function()
  local state = require("codereview.state")

  ---The compose adapter, swapped for this block alone. `reply` is what it answers with;
  ---false never calls back, which is how a reviewer abandoning a composer looks from here.
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

  queue.clear()
  for _, t in ipairs({ "bug", "fix", "nitpick" }) do
    reply = "the note as captured, a " .. t
    at(add_row)
    annotate.annotate(t)
  end
  local before = queue.all()
  local target = before[1]
  local old = target.note
  -- By hand, because the fixture's files do not move under a running spec. What the edit
  -- has to do with it is leave it alone, and this is a field it can only keep by copying.
  target.stale = true

  local ids = vim.tbl_map(function(e)
    return e.id
  end, before)

  reply = "the corrected note"
  local msgs, restore = h.capture_notify()
  annotate.edit_note(target)
  restore()
  local after = queue.all()

  it("hands the composer the note it holds now", function()
    assert.same(old, seen.text)
  end)

  it("titles the composer the way a capture does", function()
    assert.same("Bug · src/fresh.lua:1", seen.label)
  end)

  it("tells the composer which window the edit came from", function()
    assert.same(V.win, seen.origin_win)
  end)

  it("puts the new note in place of the old one", function()
    assert.same("the corrected note", after[1].note)
    assert.is_false(vim.tbl_contains(
      vim.tbl_map(function(e)
        return e.note
      end, after),
      old
    ))
  end)

  it("keeps the id and the place in the queue", function()
    assert.same(
      ids,
      vim.tbl_map(function(e)
        return e.id
      end, after)
    )
    assert.same({ "bug", "fix", "nitpick" }, {
      after[1].type,
      after[2].type,
      after[3].type,
    })
  end)

  it("leaves the anchor, the range and the blob alone", function()
    assert.same(
      { before[1].key, before[1].kind, before[1].first, before[1].last, before[1].blob },
      { after[1].key, after[1].kind, after[1].first, after[1].last, after[1].blob }
    )
  end)

  it("leaves a stale entry stale", function()
    assert.is_true(after[1].stale)
  end)

  it("repaints the diff with the new note", function()
    local found = false
    for _, m in ipairs(h.virt_marks(V)) do
      for _, line in ipairs(m[4].virt_lines) do
        for _, chunk in ipairs(line) do
          found = found or chunk[1]:find("the corrected note", 1, true) ~= nil
        end
      end
    end
    assert.is_true(found)
  end)

  it("writes the edit to the disk", function()
    local stored = vim.tbl_map(function(e)
      return e.note
    end, state.load(V.root).queue)
    assert.is_true(vim.tbl_contains(stored, "the corrected note"), vim.inspect(stored))
    assert.is_false(vim.tbl_contains(stored, old), vim.inspect(stored))
  end)

  it("says what it edited, the way a capture says what it queued", function()
    assert.is_true(h.notified(msgs, "Edited bug src/fresh.lua:1 (3 in queue)"), vim.inspect(msgs))
  end)

  it("leaves the note as it was when the composer is abandoned", function()
    reply = false
    annotate.edit_note(queue.all()[2])
    assert.same(before[2].note, queue.all()[2].note)
  end)

  it("leaves the note as it was when the submitted note is empty", function()
    reply = "  \n  "
    annotate.edit_note(queue.all()[2])
    assert.same(before[2].note, queue.all()[2].note)
    assert.same(3, queue.count())
  end)

  config.get().compose = shipped
end)
