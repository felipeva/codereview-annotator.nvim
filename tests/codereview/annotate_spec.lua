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

  it("counts it on the file's panel row", function()
    -- The panel is a tree, so row 1 is a directory; find the file's own row.
    local prow = V.panel_render.file_row[assert(h.file_index(V, "src/fresh.lua"))]
    local line = vim.api.nvim_buf_get_lines(V.panel_buf, prow - 1, prow, false)[1]
    assert.same("1", line:match("(%d)%s*$"))
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

describe("grouping the queue", function()
  queue.clear()
  for _, t in ipairs({ "nitpick", "bug", "issue", "bug" }) do
    at(add_row)
    annotate.annotate(t)
  end

  -- Groups follow the configured type order, not the order notes were captured, so a
  -- reviewer reads bugs before nitpicks however they were written.
  it("orders groups by type, not by capture order", function()
    local groups = queue.grouped(config.get().types)
    assert.same(
      { "bug:2", "nitpick:1", "issue:1" },
      vim.tbl_map(function(g)
        return ("%s:%d"):format(g.type.name, #g.items)
      end, groups)
    )
  end)
end)
