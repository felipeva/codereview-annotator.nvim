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
  ---Stand in for `vim.ui.select` until `restore` is called. `choose` gets the rows as the
  ---picker would draw them and answers with an index, or nil to dismiss.
  ---@param choose fun(rows: string[]): integer|nil
  ---@return { rows: string[] }[] calls, fun() restore
  local function stub_select(choose)
    local calls = {}
    local orig = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      local rows = vim.tbl_map(opts.format_item or tostring, items)
      calls[#calls + 1] = { rows = rows }
      local i = choose(rows)
      cb(i and items[i], i)
    end
    return calls, function()
      vim.ui.select = orig
    end
  end

  local function types_left()
    return vim.tbl_map(function(e)
      return e.type
    end, queue.all())
  end

  queue.clear()
  at(add_row)
  annotate.annotate("bug")
  annotate.annotate("fix")

  it("allows more than one note on a line", function()
    assert.same(2, queue.count())
  end)

  -- `x` then `<CR>` is still "undo the note I just wrote": the newest entry is the one the
  -- picker opens on.
  it("offers the most recent first", function()
    local calls, restore = stub_select(function()
      return 1
    end)
    at(add_row)
    annotate.drop()
    restore()
    assert.same(1, #calls)
    assert.same({ "bug" }, types_left())
  end)

  it("drops the last one at once, with no picker", function()
    local calls, restore = stub_select(function()
      return 1
    end)
    at(add_row)
    annotate.drop()
    restore()
    assert.same(0, #calls)
    assert.same(0, queue.count())
  end)

  it("names each entry by type, place and the start of its note, newest first", function()
    queue.clear()
    at(add_row)
    annotate.annotate("bug")
    annotate.annotate("nitpick")
    local calls, restore = stub_select(function()
      return nil
    end)
    at(add_row)
    annotate.drop()
    restore()
    local rows = calls[1].rows
    assert.same(2, #rows)
    -- Capture order is bug then nitpick; the picker reads the other way.
    assert.is_truthy(rows[1]:find("^nitpick%s+src/fresh%.lua:1%s+note about Nitpick"), rows[1])
    assert.is_truthy(rows[2]:find("^bug%s+src/fresh%.lua:1%s+note about Bug"), rows[2])
  end)

  it("drops nothing when the picker is dismissed", function()
    assert.same({ "bug", "nitpick" }, types_left())
  end)

  -- Neither end of the queue, so neither "newest" nor "oldest" can pass by accident.
  it("drops the older entry chosen and leaves the rest", function()
    queue.clear()
    at(add_row)
    for _, t in ipairs({ "bug", "fix", "nitpick" }) do
      annotate.annotate(t)
    end
    local _, restore = stub_select(function(rows)
      for i, row in ipairs(rows) do
        if row:find("^fix") then
          return i
        end
      end
    end)
    at(add_row)
    annotate.drop()
    restore()
    assert.same({ "bug", "nitpick" }, types_left())
  end)

  it("says so when the line has no annotation", function()
    queue.clear()
    local calls, restore_select = stub_select(function()
      return 1
    end)
    local msgs, restore = h.capture_notify()
    at(add_row)
    annotate.drop()
    restore()
    restore_select()
    assert.same(0, #calls)
    assert.is_true(h.notified(msgs, "No annotation on this line"), vim.inspect(msgs))
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
