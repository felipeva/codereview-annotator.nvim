-- The split layout: two panes out of one walk.
--
-- Most of this needs no window at all. `render.build` returns both panes together, so pane
-- parity, anchor totality, note mirroring and per-pane chrome are properties of returned
-- data and are asserted against that data directly -- which is the whole point of returning
-- them from one call rather than making two.
--
-- What does need a view is annotation parity, because target resolution reads the focused
-- window and a visual selection has to be live while it is read; and the pane binding,
-- because `scrollbind` and `cursorbind` are Neovim's, not ours.
local h = require("tests.helpers")

h.ui(120, 45)
local root = h.cd_fixture("mkfixture")

local last_ctx
local function setup(layout)
  require("codereview").setup({
    layout = layout,
    syntax = false,
    compose = function(ctx, on_accept, _)
      last_ctx = ctx
      on_accept(nil, "note about " .. ctx.label)
    end,
  })
end
setup("unified")

local config = require("codereview.config")
local git = require("codereview.git")
local render = require("codereview.render")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")
local view = require("codereview.view")

--- Pure: no windows ------------------------------------------------------------

local scope = assert(git.resolve_scope("branch", root))
local files = assert(git.collect(scope, root, { context = 3, untracked = true }))

---@param opts table|nil Overrides on top of a plain 60-column split
---@return CRRender after, CRRender|nil before
local function build(opts)
  local cfg = config.get()
  return render.build(
    files,
    vim.tbl_extend("force", {
      width = 60,
      before_width = 60,
      layout = "split",
      icons = cfg.icons,
      expanded = {},
      reviewed = {},
      notes = {},
      types = cfg.types,
    }, opts or {})
  )
end

---@param path string
---@return integer
local function index_of(path)
  for i, f in ipairs(files) do
    if f.path == path then
      return i
    end
  end
  error("no such file in the fixture: " .. path)
end

---Rows a file occupies in a render, from its header to the row before the next file's.
---@param rendered CRRender
---@param fi integer
---@return integer[]
local function rows_of(rendered, fi)
  local out = {}
  for row = 1, #rendered.lines do
    if rendered.anchors[row].file == fi then
      out[#out + 1] = row
    end
  end
  return out
end

---The virtual lines an extmark on `row` carries in a pane, or nil.
---@param rendered CRRender
---@param row integer
---@return table[]|nil
local function virt_at(rendered, row)
  for _, m in ipairs(rendered.marks) do
    if m.row == row - 1 and m.opts.virt_lines then
      return m.opts.virt_lines
    end
  end
end

describe("one walk, two renders", function()
  it("returns nothing for a second pane in the unified layout", function()
    local after, before = build({ layout = "unified" })
    assert.is_table(after)
    assert.is_nil(before)
  end)

  it("returns a second pane in the split layout", function()
    local after, before = build()
    assert.is_table(after)
    assert.is_table(before)
  end)
end)

describe("pane parity", function()
  local after, before = build()

  it("holds the same number of rows in both panes", function()
    assert.same(#after.lines, #before.lines)
  end)

  -- The invariant the whole layout rests on. Row for row, the two panes must agree about
  -- which file and which hunk they are inside, or a cursor in one pane means something
  -- different from the same cursor in the other.
  it("agrees row for row on the file and the hunk", function()
    for row = 1, #after.lines do
      local a, b = after.anchors[row], before.anchors[row]
      assert.is_table(a, ("after pane has no anchor on row %d"):format(row))
      assert.is_table(b, ("before pane has no anchor on row %d"):format(row))
      assert.same({ a.file, a.hunk }, { b.file, b.hunk }, ("row %d disagrees"):format(row))
    end
  end)

  it("puts every file's header on the same row in both panes", function()
    assert.same(after.file_rows, before.file_rows)
  end)

  it("puts every hunk header on the same row in both panes", function()
    assert.same(after.hunk_rows, before.hunk_rows)
  end)
end)

describe("anchor totality", function()
  local after, before = build()

  it("anchors every row of both panes", function()
    for row = 1, #after.lines do
      assert.is_table(after.anchors[row], ("after row %d"):format(row))
      assert.is_table(before.anchors[row], ("before row %d"):format(row))
    end
  end)

  -- `pad` is the blank row after a hunk, which both panes draw. `fill` is a row one image
  -- has no counterpart for. They dispatch identically -- both fall through to a whole-file
  -- target -- but they mean different things, and the kind is documentation as much as it
  -- is dispatch.
  it("gives filler its own kind, distinct from pad", function()
    local kinds = {}
    for row = 1, #after.lines do
      kinds[after.anchors[row].kind] = true
      kinds[before.anchors[row].kind] = true
    end
    assert.is_true(kinds.fill)
    assert.is_true(kinds.pad)
  end)

  it("never emits filler in the unified layout", function()
    local unified = build({ layout = "unified" })
    for row = 1, #unified.lines do
      assert.is_true(unified.anchors[row] == nil or unified.anchors[row].kind ~= "fill")
    end
  end)
end)

describe("a file that exists on only one side", function()
  local after, before = build()

  it("renders an added file as filler for its whole length on the before pane", function()
    local fi = index_of("src/fresh.lua")
    local seen = 0
    for _, row in ipairs(rows_of(after, fi)) do
      if after.anchors[row].kind == "line" then
        seen = seen + 1
        assert.same("fill", before.anchors[row].kind, ("row %d"):format(row))
      end
    end
    assert.is_true(seen > 0)
  end)

  it("renders a deleted file as filler for its whole length on the after pane", function()
    local fi = index_of("src/gone.lua")
    local seen = 0
    for _, row in ipairs(rows_of(before, fi)) do
      if before.anchors[row].kind == "line" then
        seen = seen + 1
        assert.same("fill", after.anchors[row].kind, ("row %d"):format(row))
      end
    end
    assert.is_true(seen > 0)
  end)

  it("leaves an added file's before-pane header empty rather than naming a path it never had", function()
    local row = after.file_rows[index_of("src/fresh.lua")]
    assert.same("", before.lines[row])
    assert.same("file", before.anchors[row].kind)
  end)
end)

describe("per-pane chrome", function()
  local after, before = build()

  it("splits a hunk header into its pre-image range on the left and its post-image on the right", function()
    local fi = index_of("src/main.lua")
    local hrow
    for _, row in ipairs(rows_of(after, fi)) do
      if after.anchors[row].kind == "hunk" then
        hrow = row
        break
      end
    end
    assert.is_truthy(hrow)
    assert.same("@@ -1,3 @@", before.lines[hrow])
    assert.same("@@ +1,3 @@", after.lines[hrow])
  end)

  it("shows a renamed file's old path on the left and its new path on the right", function()
    local row = after.file_rows[index_of("src/newname.lua")]
    assert.is_truthy(before.lines[row]:find("src/oldname.lua", 1, true))
    assert.is_falsy(before.lines[row]:find("src/newname.lua", 1, true))
    assert.is_truthy(after.lines[row]:find("src/newname.lua", 1, true))
    assert.is_falsy(after.lines[row]:find("src/oldname.lua", 1, true))
  end)

  -- The unified layout has one header to say it in, so it keeps spelling the arrow out.
  it("still writes the rename as one header in the unified layout", function()
    local unified = build({ layout = "unified" })
    local row = unified.file_rows[index_of("src/newname.lua")]
    assert.is_truthy(unified.lines[row]:find("src/oldname.lua → src/newname.lua", 1, true))
  end)

  it("draws the explanatory note of a file with no hunks", function()
    local fi = index_of("src/untracked.bin")
    local drawn
    for _, row in ipairs(rows_of(after, fi)) do
      if after.lines[row]:find("binary", 1, true) and after.anchors[row].kind ~= "file" then
        drawn = row
      end
    end
    assert.is_truthy(drawn, "the binary file's note never rendered")
    assert.same("fill", before.anchors[drawn].kind)
  end)

  it("gives both panes the same file-header text width to pad against", function()
    local narrow = select(2, build({ before_width = 40 }))
    local row = narrow.file_rows[index_of("src/main.lua")]
    assert.is_true(vim.fn.strdisplaywidth(narrow.lines[row]) <= 40)
  end)
end)

describe("where a note is drawn", function()
  local path = "src/main.lua"
  local del_key = render.line_key(path, { side = "del", old = 2 })
  local add_key = render.line_key(path, { side = "add", new = 2 })

  it("keys a deletion to the pre-image and its replacement to the post-image", function()
    assert.same({ "src/main.lua:o:2", "src/main.lua:n:2" }, { del_key, add_key })
    assert.is_true(render.is_before_key(del_key))
    assert.is_false(render.is_before_key(add_key))
  end)

  -- No new rule: the key is already sided, and that side is the pane.
  it("draws a note on a deleted line in the before pane", function()
    local after, before = build({ notes = { [del_key] = { { note = "gone", type = "bug" } } } })
    local row
    for r = 1, #before.lines do
      local a = before.anchors[r]
      if a.kind == "line" and files[a.file].path == path and files[a.file].hunks[a.hunk].lines[a.line].old == 2 then
        row = r
      end
    end
    assert.is_truthy(row)
    local bvirt, avirt = virt_at(before, row), virt_at(after, row)
    assert.is_truthy(bvirt[1][#bvirt[1]][1]:find("gone", 1, true))
    -- The after pane holds its place with a blank of the same height.
    assert.same(#bvirt, #avirt)
    assert.same("", avirt[1][1][1])
  end)

  it("draws a note on an added line in the after pane", function()
    local after, before = build({ notes = { [add_key] = { { note = "here", type = "bug" } } } })
    local row = after.file_rows[index_of(path)]
    for r = 1, #after.lines do
      local a = after.anchors[r]
      if a.kind == "line" and files[a.file].path == path and files[a.file].hunks[a.hunk].lines[a.line].new == 2 then
        row = r
      end
    end
    local avirt, bvirt = virt_at(after, row), virt_at(before, row)
    assert.is_truthy(avirt[1][#avirt[1]][1]:find("here", 1, true))
    assert.same(#avirt, #bvirt)
    assert.same("", bvirt[1][1][1])
  end)

  -- A context line exists in both images, and its key prefers the post-image -- so it reads
  -- in the after pane, exactly as it does everywhere else in the plugin.
  it("draws a note on a context line in the after pane", function()
    local ctx_key = render.line_key(path, { side = "ctx", old = 1, new = 1 })
    local after, before = build({ notes = { [ctx_key] = { { note = "context", type = "bug" } } } })
    local row
    for r = 1, #after.lines do
      local a = after.anchors[r]
      if a.kind == "line" and files[a.file].path == path and files[a.file].hunks[a.hunk].lines[a.line].new == 1 then
        row = r
      end
    end
    assert.is_truthy(virt_at(after, row)[1][#virt_at(after, row)[1]][1]:find("context", 1, true))
    assert.same("", virt_at(before, row)[1][1][1])
  end)

  it("hangs a whole-file note off the after pane's header, and holds the before pane's place", function()
    local key = render.file_key(path)
    local after, before = build({ notes = { [key] = { { note = "all of it", type = "bug" } } } })
    local row = after.file_rows[index_of(path)]
    assert.is_truthy(virt_at(after, row)[1][#virt_at(after, row)[1]][1]:find("all of it", 1, true))
    assert.same(#virt_at(after, row), #virt_at(before, row))
  end)

  it("keeps a whole-file note on the header of a collapsed file", function()
    local key = render.file_key(path)
    local after, before = build({
      notes = { [key] = { { note = "all of it", type = "bug" } } },
      expanded = { [path] = false },
    })
    local row = after.file_rows[index_of(path)]
    assert.is_truthy(virt_at(after, row))
    assert.same(#virt_at(after, row), #virt_at(before, row))
  end)

  it("marks a stale annotation in the split layout", function()
    local after = build({ notes = { [add_key] = { { note = "old", type = "bug", stale = true } } } })
    local found = false
    for _, m in ipairs(after.marks) do
      for _, line in ipairs(m.opts.virt_lines or {}) do
        for _, chunk in ipairs(line) do
          found = found or chunk[2] == "CodeReviewStale"
        end
      end
    end
    assert.is_true(found)
  end)
end)

-- Archived entries take the same anchors live ones do, so they need no rule of their own
-- about which pane draws them: the key is already sided, and that side is the pane. They
-- also ride inside the *same* virtual-line block as the live entries on that anchor, which
-- is what keeps the mirroring that holds the opposite pane's place working on a count that
-- never had to learn they exist.
describe("where an archived entry is drawn", function()
  local path = "src/main.lua"
  local del_key = render.line_key(path, { side = "del", old = 2 })
  local add_key = render.line_key(path, { side = "add", new = 2 })

  ---The row a pane draws one side of `src/main.lua`'s line 2 on.
  ---@param rendered CRRender
  ---@param field "old"|"new"
  ---@return integer
  local function row_of_line(rendered, field)
    for r = 1, #rendered.lines do
      local a = rendered.anchors[r]
      if a.kind == "line" and files[a.file].path == path and files[a.file].hunks[a.hunk].lines[a.line][field] == 2 then
        return r
      end
    end
    error("no row for " .. path .. " line 2 " .. field)
  end

  it("draws one on a deleted line in the before pane, and holds the after pane's place", function()
    local after, before = build({ archived = { [del_key] = { { note = "already sent", type = "bug" } } } })
    local row = row_of_line(before, "old")
    local bvirt, avirt = virt_at(before, row), virt_at(after, row)
    assert.is_truthy(bvirt[1][#bvirt[1]][1]:find("already sent", 1, true))
    assert.same(#bvirt, #avirt)
    assert.same("", avirt[1][1][1])
  end)

  it("hangs one about a whole file off the after pane's header", function()
    local after, before =
      build({ archived = { [render.file_key(path)] = { { note = "all of it, sent", type = "bug" } } } })
    local row = after.file_rows[index_of(path)]
    assert.is_truthy(virt_at(after, row)[1][#virt_at(after, row)[1]][1]:find("all of it, sent", 1, true))
    assert.same(#virt_at(after, row), #virt_at(before, row))
  end)

  it("draws a queued entry above an archived one on the same anchor, in both panes", function()
    local after, before = build({
      notes = { [del_key] = { { note = "still to send", type = "bug" } } },
      archived = { [del_key] = { { note = "already sent", type = "bug" } } },
    })
    local row = row_of_line(before, "old")
    local bvirt, avirt = virt_at(before, row), virt_at(after, row)
    assert.same(2, #bvirt)
    assert.is_truthy(bvirt[1][#bvirt[1]][1]:find("still to send", 1, true))
    assert.is_truthy(bvirt[2][#bvirt[2]][1]:find("already sent", 1, true))
    -- Both entries cost the after pane the same height they cost the before pane, or every
    -- row below this one reads against different code in the two panes.
    assert.same(#bvirt, #avirt)
  end)

  it("gives it groups of its own beside a live entry's type", function()
    local after = build({
      notes = { [add_key] = { { note = "still to send", type = "bug" } } },
      archived = { [add_key] = { { note = "already sent", type = "bug" } } },
    })
    local groups = {}
    for _, m in ipairs(after.marks) do
      for _, line in ipairs(m.opts.virt_lines or {}) do
        for _, chunk in ipairs(line) do
          groups[chunk[2]] = true
        end
      end
    end
    assert.is_true(groups.CodeReviewBug or false, vim.inspect(vim.tbl_keys(groups)))
    assert.is_true(groups.CodeReviewArchived or false, vim.inspect(vim.tbl_keys(groups)))
    assert.is_true(groups.CodeReviewArchivedNote or false, vim.inspect(vim.tbl_keys(groups)))
  end)

  -- The flag is persisted with the entry, so it is there to read, and it says the file had
  -- moved by the time the batch went -- a fact about a queue that no longer exists. Drawn
  -- against the code now it reads as a claim about the code now, which nothing has checked.
  it("never draws an archived entry's stale flag", function()
    local after = build({ archived = { [add_key] = { { note = "old", type = "bug", stale = true } } } })
    for _, m in ipairs(after.marks) do
      for _, line in ipairs(m.opts.virt_lines or {}) do
        for _, chunk in ipairs(line) do
          assert.is_not.same("CodeReviewStale", chunk[2])
        end
      end
    end
  end)
end)

describe("note text in a narrow pane", function()
  local long = "a remark long enough that it cannot possibly fit inside a single narrow "
    .. "column, which is exactly the case a virtual line silently truncates because it "
    .. "clips at the window edge instead of wrapping"
  local key = render.line_key("src/main.lua", { side = "add", new = 2 })

  it("wraps to the pane width rather than being clipped", function()
    local after = build({ width = 46, notes = { [key] = { { note = long, type = "bug" } } } })
    local emitted, total = 0, 0
    for _, m in ipairs(after.marks) do
      for _, line in ipairs(m.opts.virt_lines or {}) do
        local text = ""
        for _, chunk in ipairs(line) do
          text = text .. chunk[1]
        end
        if text ~= "" then
          emitted = emitted + 1
          total = total + #text
          assert.is_true(
            vim.fn.strdisplaywidth(text) <= 46,
            ("virtual line %q is %d columns wide"):format(text, vim.fn.strdisplaywidth(text))
          )
        end
      end
    end
    -- More than one line, and every word still present: wrapped, not truncated.
    assert.is_true(emitted > 1)
    for word in long:gmatch("%S+") do
      assert.is_true(total >= #word)
    end
  end)

  it("keeps every word of the note", function()
    local after = build({ width = 46, notes = { [key] = { { note = long, type = "bug" } } } })
    local joined = {}
    for _, m in ipairs(after.marks) do
      for _, line in ipairs(m.opts.virt_lines or {}) do
        for _, chunk in ipairs(line) do
          joined[#joined + 1] = chunk[1]
        end
      end
    end
    local text = table.concat(joined, " ")
    for word in long:gmatch("%S+") do
      assert.is_truthy(text:find(word, 1, true), ("%q was clipped"):format(word))
    end
  end)

  ---Every virtual line a build emitted, in order, whatever row carries it.
  ---@param rendered CRRender
  ---@return table[][]
  local function note_lines(rendered)
    local out = {}
    for _, m in ipairs(rendered.marks) do
      for _, line in ipairs(m.opts.virt_lines or {}) do
        out[#out + 1] = line
      end
    end
    return out
  end

  -- The block has to read as one comment, which it only does while every row after the first
  -- starts where the prose above it starts. The marker is measured in columns and the indent
  -- under it was measured in bytes, so the two agreed exactly while every shipped glyph was
  -- empty -- four spaces are four of each -- and drifted two columns apart the moment a glyph
  -- arrived. Asserted as the two widths and not as a number, so it holds for a host's glyph
  -- as well as for ours.
  it("indents a continuation row to the column the prose above it starts at", function()
    local lines = note_lines(build({ width = 46, notes = { [key] = { { note = long, type = "bug" } } } }))
    assert.is_true(#lines > 1, "the note did not wrap, so there is no continuation row to read")
    local marker = vim.fn.strdisplaywidth(lines[1][1][1])
    for n = 2, #lines do
      assert.same(marker, vim.fn.strdisplaywidth(lines[n][1][1]), ("continuation row %d"):format(n))
    end
  end)

  -- A note the reviewer broke themselves, in the layout that never wraps one: the same
  -- indent, reached by the other branch. Nothing wraps here, so a case about the pane's
  -- width would say nothing about this one.
  it("indents the rows of a note that carries its own line breaks", function()
    local note = "the first line\nthe second\nthe third"
    local lines =
      note_lines(build({ layout = "unified", width = 80, notes = { [key] = { { note = note, type = "bug" } } } }))
    assert.same(3, #lines)
    local marker = vim.fn.strdisplaywidth(lines[1][1][1])
    for n = 2, 3 do
      assert.same(marker, vim.fn.strdisplaywidth(lines[n][1][1]), ("row %d"):format(n))
    end
  end)

  -- Unwrapped is what the unified layout has always emitted, and it is a full-width window.
  it("leaves the unified layout's notes exactly as they were", function()
    local unified = build({ layout = "unified", width = 46, notes = { [key] = { { note = long, type = "bug" } } } })
    local lines = 0
    for _, m in ipairs(unified.marks) do
      lines = lines + #(m.opts.virt_lines or {})
    end
    assert.same(1, lines)
  end)
end)

--- Configuration ---------------------------------------------------------------

describe("selecting the layout", function()
  it("defaults to unified", function()
    setup(nil)
    assert.same("unified", config.get().layout)
  end)

  it("takes split when asked for", function()
    setup("split")
    assert.same("split", config.get().layout)
  end)

  -- Silently falling back to unified would leave a reviewer wondering why their
  -- configuration did nothing, with the answer nowhere on screen.
  it("rejects an unknown value at setup, naming it", function()
    local ok, err = pcall(setup, "side-by-side")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("side-by-side", 1, true))
    assert.is_truthy(tostring(err):find("layout", 1, true))
  end)
end)

--- With a view -----------------------------------------------------------------

---The entry a fresh annotation produces, reduced to what ADR-0002 says must not depend on
---how it was captured.
---@param e CRAnnotation
---@return table
local function shape(e)
  return { key = e.key, kind = e.kind, tag = e.tag, inline = e.inline, first = e.first, last = e.last, lines = e.lines }
end

---Row in a pane whose line anchor points at the CRLine `pred` accepts.
---@param V CRView
---@param rendered CRRender
---@param path string
---@param pred fun(ln: CRLine): boolean
---@return integer
local function line_row(V, rendered, path, pred)
  for row, a in pairs(rendered.anchors) do
    if a.kind == "line" and V.files[a.file].path == path then
      if pred(V.files[a.file].hunks[a.hunk].lines[a.line]) then
        return row
      end
    end
  end
  error(("no row for %s"):format(path))
end

local DELETED = function(ln)
  return ln.side == "del"
end
local ADDED = function(ln)
  return ln.side == "add"
end

--- Reference entries, captured in the layout that has always existed -------------

local reference = {}
do
  setup("unified")
  view.open("branch")
  local V = view.current()
  queue.clear()

  ---@param path string
  ---@param pred fun(ln: CRLine): boolean
  ---@param what string
  local function capture(what, path, pred)
    queue.clear()
    vim.api.nvim_win_set_cursor(V.win, { line_row(V, V.render, path, pred), 0 })
    annotate.annotate("bug")
    reference[what] = shape(queue.all()[1])
  end

  capture("deleted", "src/main.lua", DELETED)
  capture("added", "src/main.lua", ADDED)
  capture("context", "src/main.lua", function(ln)
    return ln.side == "ctx"
  end)

  queue.clear()
  vim.api.nvim_win_set_cursor(V.win, { assert(V.render.hunk_rows[1]), 0 })
  annotate.annotate("bug")
  reference.hunk = shape(queue.all()[1])

  queue.clear()
  vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[1], 0 })
  annotate.annotate("bug")
  reference.file = shape(queue.all()[1])

  -- A pure-addition range: the one range shape the split layout keeps, since it never
  -- has to span two windows.
  queue.clear()
  vim.api.nvim_win_set_cursor(V.win, { line_row(V, V.render, "src/untracked.lua", ADDED), 0 })
  h.feed("Vjab")
  reference.range = shape(queue.all()[1])

  -- A range covering a context line and the deletion under it. Both rows exist in the
  -- before pane too, and in the same order, so this one crosses the layouts unchanged --
  -- unlike a range spanning a deletion *and its replacement*, which is the documented
  -- exception because the two runs live in different windows.
  queue.clear()
  vim.api.nvim_win_set_cursor(V.win, {
    line_row(V, V.render, "src/main.lua", function(ln)
      return ln.side == "ctx" and ln.old == 1
    end),
    0,
  })
  h.feed("Vjab")
  reference.del_range = shape(queue.all()[1])

  queue.clear()
  view.close()
end

--- The split layout, on screen --------------------------------------------------

local scrollopt_before = vim.go.scrollopt

setup("split")
view.open("branch")
local V = view.current()
queue.clear()

---@param win integer
local function focus(win)
  vim.api.nvim_set_current_win(win)
end

---@param win integer
---@return integer
local function row_in(win)
  return vim.api.nvim_win_get_cursor(win)[1]
end

---@param win integer
---@return integer
local function topline(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.line("w0")
  end)
end

describe("opening in the split layout", function()
  it("opens a second pane", function()
    assert.is_truthy(V.before_win)
    assert.is_true(vim.api.nvim_win_is_valid(V.before_win))
    assert.is_true(V.before_buf ~= V.buf)
  end)

  it("puts the before-image on the left and the after-image on the right", function()
    local left = vim.api.nvim_win_get_position(V.before_win)[2]
    local right = vim.api.nvim_win_get_position(V.win)[2]
    assert.is_true(left < right, ("before at col %d, after at col %d"):format(left, right))
  end)

  it("holds the same number of rows in both buffers", function()
    assert.same(vim.api.nvim_buf_line_count(V.buf), vim.api.nvim_buf_line_count(V.before_buf))
  end)

  it("keeps the tree beside both of them", function()
    assert.is_truthy(V.panel_win and vim.api.nvim_win_is_valid(V.panel_win))
  end)

  it("carries the review status on the after pane's winbar", function()
    local reviewed = ("%s0/%d"):format(require("codereview.config").get().icons.reviewed, #V.files)
    assert.is_truthy(h.winbar(V.win):find(reviewed, 1, true), h.winbar(V.win))
  end)

  -- The one live case behind `chrome_spec`'s data answer: what the abbreviation *is* is a
  -- rule with no repository behind it, and that this bar draws it needs a real branch scope,
  -- whose pre-image is a 40-character object name. The guard is what lets this fail --
  -- abbreviating a name that is already short says nothing. Both halves are asserted,
  -- because finding the short form alone passes over a bar still naming the whole object:
  -- the short one is a prefix of it.
  it("names the revision the before pane is showing, abbreviated", function()
    assert.is_truthy(V.scope.before:match("^%x+$") and #V.scope.before == 40, V.scope.before)
    local drawn = h.winbar(V.before_win)
    assert.is_truthy(drawn:find(render.rev_label(V.scope.before), 1, true), drawn)
    assert.is_falsy(drawn:find(V.scope.before, 1, true), drawn)
  end)
end)

describe("holding the panes together", function()
  -- `scrollopt` is global. A plugin that set it would reach outside its own windows, so
  -- what is accepted instead is its default: vertical synchronization only.
  it("does not modify the global scroll-options setting", function()
    assert.same(scrollopt_before, vim.go.scrollopt)
  end)

  it("binds scrolling and the cursor in both panes", function()
    for _, win in ipairs({ V.win, V.before_win }) do
      assert.is_true(vim.wo[win].scrollbind)
      assert.is_true(vim.wo[win].cursorbind)
    end
  end)

  -- Driven with `normal!` rather than `nvim_win_set_cursor`: the binding follows cursor
  -- *motions*, and the API sets a cursor without moving one. With `cursorbind` off the
  -- before pane stays where it was, which is what gives this case its teeth.
  it("moves the cursor in one pane by moving it in the other", function()
    focus(V.win)
    vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
    vim.api.nvim_win_call(V.before_win, function()
      vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
    end)
    assert.same({ 1, 1 }, { row_in(V.win), row_in(V.before_win) })

    vim.api.nvim_win_call(V.win, function()
      vim.cmd("normal! 20j")
    end)
    assert.same(21, row_in(V.win))
    assert.same(21, row_in(V.before_win))
  end)

  it("scrolls one pane by scrolling the other", function()
    focus(V.win)
    for _, win in ipairs({ V.win, V.before_win }) do
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
      end)
    end
    assert.same({ 1, 1 }, { topline(V.win), topline(V.before_win) })

    vim.api.nvim_win_call(V.win, function()
      vim.cmd("normal! 10\5") -- 10 <C-e>
    end)
    assert.is_true(topline(V.win) > 1)
    assert.same(topline(V.win), topline(V.before_win))
  end)

  ---Leave the panes bound but not where each other is -- exactly the state a binding is in
  ---once a repaint has changed the line count beneath it. Reached by moving one pane with
  ---the binding lifted, because with it on there is no motion the other does not follow:
  ---that is the whole point of it, and it is also why the binding cannot repair itself.
  local function diverge()
    vim.wo[V.before_win].scrollbind = false
    vim.wo[V.before_win].cursorbind = false
    vim.api.nvim_win_call(V.before_win, function()
      vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
    end)
    vim.wo[V.before_win].scrollbind = true
    vim.wo[V.before_win].cursorbind = true
  end

  ---@param what string
  local function aligned(what)
    assert.same(
      vim.api.nvim_buf_line_count(V.buf),
      vim.api.nvim_buf_line_count(V.before_buf),
      ("row counts diverged after %s"):format(what)
    )
    assert.same(row_in(V.win), row_in(V.before_win), ("cursors diverged after %s"):format(what))
    assert.same(topline(V.win), topline(V.before_win), ("toplines diverged after %s"):format(what))
  end

  -- Guards the four cases below: if this passes, the panes really can be knocked apart, and
  -- an assertion that they came back together is measuring something.
  it("really can be knocked out of step", function()
    focus(V.win)
    vim.api.nvim_win_call(V.win, function()
      vim.cmd("normal! 20j")
    end)
    diverge()
    assert.is_true(row_in(V.win) ~= row_in(V.before_win))
    assert.is_true(topline(V.win) ~= topline(V.before_win))
  end)

  -- The binding tracks deltas, so it loses its place whenever a repaint changes the line
  -- count beneath it. Every operation that does ends in a paint, and a paint is where both
  -- panes' views are re-asserted.
  it("puts both panes back at the end of a bare repaint", function()
    focus(V.win)
    vim.api.nvim_win_call(V.win, function()
      vim.cmd("normal! 20j")
    end)
    diverge()
    view.paint()
    aligned("a repaint")
  end)

  it("holds its alignment across toggling expansion and reviewed", function()
    focus(V.win)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[2], 0 })
    diverge()
    view.toggle_expand()
    aligned("toggling expansion")
    diverge()
    view.toggle_expand()
    aligned("toggling expansion back")

    diverge()
    view.toggle_reviewed()
    aligned("toggling reviewed")
    diverge()
    view.toggle_reviewed()
    aligned("toggling reviewed back")
  end)

  it("holds its alignment across reloading the diff", function()
    focus(V.win)
    vim.api.nvim_win_call(V.win, function()
      vim.cmd("normal! 15j")
    end)
    diverge()
    view.refresh()
    aligned("reloading the diff")
  end)

  it("holds its alignment across changing scope", function()
    focus(V.win)
    diverge()
    view.set_scope("staged")
    aligned("changing scope")
    diverge()
    view.set_scope("branch")
    aligned("changing scope back")
  end)
end)

describe("annotating from either pane", function()
  ---@param win integer
  ---@param rendered CRRender
  ---@param path string
  ---@param pred fun(ln: CRLine): boolean
  ---@return table
  local function annotate_at(win, rendered, path, pred)
    queue.clear()
    focus(win)
    vim.api.nvim_win_set_cursor(win, { line_row(V, rendered, path, pred), 0 })
    annotate.annotate("bug")
    return shape(queue.all()[1])
  end

  -- The case that pins ADR-0002 on the surface: a rendering choice must not reach the
  -- receiving agent, so the same logical line has to produce the same entry either way.
  it("captures a deleted line from the before pane exactly as the unified layout does", function()
    assert.same(reference.deleted, annotate_at(V.before_win, V.before_render, "src/main.lua", DELETED))
  end)

  it("captures an added line from the after pane exactly as the unified layout does", function()
    assert.same(reference.added, annotate_at(V.win, V.render, "src/main.lua", ADDED))
  end)

  it("captures a context line the same from either pane, and the same as unified", function()
    local from_after = annotate_at(V.win, V.render, "src/main.lua", function(ln)
      return ln.side == "ctx"
    end)
    local from_before = annotate_at(V.before_win, V.before_render, "src/main.lua", function(ln)
      return ln.side == "ctx"
    end)
    assert.same(reference.context, from_after)
    assert.same(reference.context, from_before)
  end)

  it("captures both images inlined from a hunk header in either pane", function()
    for _, win in ipairs({ V.win, V.before_win }) do
      queue.clear()
      focus(win)
      vim.api.nvim_win_set_cursor(win, { V.render.hunk_rows[1], 0 })
      annotate.annotate("bug")
      assert.same(reference.hunk, shape(queue.all()[1]))
      assert.is_true(queue.all()[1].inline)
    end
  end)

  it("captures the whole file from a file header in either pane", function()
    for _, win in ipairs({ V.win, V.before_win }) do
      queue.clear()
      focus(win)
      vim.api.nvim_win_set_cursor(win, { V.render.file_rows[1], 0 })
      annotate.annotate("bug")
      assert.same(reference.file, shape(queue.all()[1]))
    end
  end)

  -- Pure-addition and pure-deletion ranges still work; only a sub-hunk range spanning both
  -- images is lost, and that is the one documented difference between the layouts.
  it("captures a pure-addition range from the after pane exactly as unified does", function()
    queue.clear()
    focus(V.win)
    vim.api.nvim_win_set_cursor(V.win, { line_row(V, V.render, "src/untracked.lua", ADDED), 0 })
    h.feed("Vjab")
    assert.same(reference.range, shape(queue.all()[1]))
  end)

  -- Fed through the mapping rather than called directly: `capture` reads `mode()` and
  -- `line("v")` while the selection is still live, and the mapping is only reachable if the
  -- before pane's buffer really carries the diff's keys.
  it("captures a range containing a deletion from the before pane, as unified does", function()
    queue.clear()
    focus(V.before_win)
    vim.api.nvim_win_set_cursor(V.before_win, {
      line_row(V, V.before_render, "src/main.lua", function(ln)
        return ln.side == "ctx" and ln.old == 1
      end),
      0,
    })
    h.feed("Vjab")
    assert.same(1, queue.count())
    assert.same(reference.del_range, shape(queue.all()[1]))
    assert.is_true(queue.all()[1].inline)
  end)

  it("binds the diff's keys in the before pane too", function()
    -- Both sides through `vim.keycode`: the API reports a control key in its own notation
    -- (`<C-P>`, capitalized) rather than the one it was bound with, so comparing the
    -- strings as written silently never matches.
    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(V.before_buf, "n")) do
      lhs[vim.keycode(m.lhs)] = true
    end
    for _, key in ipairs({ "ab", "aa", "x", "]f", "]a", "R", "za", "gp", "<C-p>", "Q" }) do
      assert.is_true(lhs[vim.keycode(key)] == true, ("%s is not bound in the before pane"):format(key))
    end
  end)

  -- The cursor is on nothing, so this means the file -- never the unrelated line above it,
  -- which in the split layout is code the reviewer was not looking at.
  it("resolves a cursor on a filler row to the whole file", function()
    queue.clear()
    -- A file whose additions sit *between* context lines, so the filler beside them has
    -- real code above it in the same pane -- which is what a walk upward would have found
    -- instead, and is the whole reason filler carries an anchor of its own.
    local path = "src/routes.lua"
    local fi = assert(h.file_index(V, path))
    local row, above
    for r = 1, vim.api.nvim_buf_line_count(V.buf) do
      local a = V.before_render.anchors[r]
      if a.file == fi and a.kind == "line" then
        above = r
      elseif a.file == fi and a.kind == "fill" and above then
        row = r
        break
      end
    end
    assert.is_truthy(row, "no filler with code above it in " .. path)

    focus(V.before_win)
    vim.api.nvim_win_set_cursor(V.before_win, { row, 0 })
    annotate.annotate("bug")
    local e = queue.all()[1]
    assert.same({ "file", path }, { e.kind, e.path })
    -- Not the line above it, which is what would have been captured without the anchor.
    assert.is_falsy(e.first)
  end)

  it("returns focus to the pane the annotation was started from", function()
    queue.clear()
    focus(V.before_win)
    vim.api.nvim_win_set_cursor(V.before_win, { line_row(V, V.before_render, "src/main.lua", DELETED), 0 })
    annotate.annotate("bug")
    assert.same(V.before_win, last_ctx.origin_win)
  end)

  it("drops an annotation from the pane it was made in", function()
    queue.clear()
    focus(V.before_win)
    local row = line_row(V, V.before_render, "src/main.lua", DELETED)
    vim.api.nvim_win_set_cursor(V.before_win, { row, 0 })
    annotate.annotate("bug")
    assert.same(1, queue.count())

    vim.api.nvim_win_set_cursor(V.before_win, { row, 0 })
    annotate.drop()
    assert.same(0, queue.count())
  end)

  it("drops an annotation on an added line from the after pane", function()
    queue.clear()
    focus(V.win)
    local row = line_row(V, V.render, "src/main.lua", ADDED)
    vim.api.nvim_win_set_cursor(V.win, { row, 0 })
    annotate.annotate("bug")
    vim.api.nvim_win_set_cursor(V.win, { row, 0 })
    annotate.drop()
    assert.same(0, queue.count())
  end)
end)

describe("notes on screen", function()
  queue.clear()
  focus(V.before_win)
  local del_row = line_row(V, V.before_render, "src/main.lua", DELETED)
  vim.api.nvim_win_set_cursor(V.before_win, { del_row, 0 })
  annotate.annotate("bug")
  view.paint()

  ---@param buf integer
  ---@return table[]
  local function virt(buf)
    return vim.tbl_filter(function(m)
      return m[4].virt_lines ~= nil
    end, vim.api.nvim_buf_get_extmarks(buf, h.NS, 0, -1, { details = true }))
  end

  it("draws the note in the pane the line belongs to", function()
    local before_marks = virt(V.before_buf)
    assert.same(1, #before_marks)
    local first = before_marks[1][4].virt_lines[1]
    assert.is_truthy(first[#first][1]:find("note about", 1, true))
  end)

  it("holds the opposite pane's place at the same row, to the same height", function()
    local b, a = virt(V.before_buf)[1], virt(V.buf)[1]
    assert.is_truthy(a, "the after pane drew nothing to hold its place")
    assert.same(b[2], a[2])
    assert.same(#b[4].virt_lines, #a[4].virt_lines)
    assert.same("", a[4].virt_lines[1][1][1])
  end)

  queue.clear()
  view.paint()
end)

describe("getting around in the split layout", function()
  it("moves both panes together when jumping by file", function()
    focus(V.win)
    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    view.jump("file", true)
    assert.same(V.render.file_rows[2], row_in(V.win))
    assert.same(row_in(V.win), row_in(V.before_win))
  end)

  it("moves both panes together when jumping by hunk", function()
    view.jump("hunk", false)
    assert.same("hunk", V.render.anchors[row_in(V.win)].kind)
    assert.same(row_in(V.win), row_in(V.before_win))
  end)

  it("jumps to the next unreviewed file in both panes", function()
    view.jump_unreviewed(true)
    assert.same("file", V.render.anchors[row_in(V.win)].kind)
    assert.same(row_in(V.win), row_in(V.before_win))
  end)

  it("jumps to an annotation on a deleted line, landing in the before pane", function()
    queue.clear()
    focus(V.before_win)
    local row = line_row(V, V.before_render, "src/main.lua", DELETED)
    vim.api.nvim_win_set_cursor(V.before_win, { row, 0 })
    annotate.annotate("bug")

    focus(V.win)
    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    view.jump_annotation(true)
    assert.same(V.before_win, vim.api.nvim_get_current_win())
    assert.same(row, row_in(V.before_win))
    assert.same(row, row_in(V.win))
    queue.clear()
    view.paint()
  end)

  it("jumps straight to a file through the picker", function()
    local index = assert(h.file_index(V, "src/routes.lua"))
    local orig = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb(nil, index)
    end
    focus(V.win)
    view.pick_file()
    vim.ui.select = orig
    assert.same(V.render.file_rows[index], row_in(V.win))
    assert.same(row_in(V.win), row_in(V.before_win))
  end)
end)

-- Nobody else could cover this: the queue float's jump landed before the split layout
-- existed, and it resolves an entry's key back to a row -- which in two panes is also a
-- question about which pane that row is in.
describe("jumping from the queue float in the split layout", function()
  ---@param entry_key_side "del"|"add"
  ---@return CRAnnotation
  local function queued(entry_key_side)
    queue.clear()
    local pane = entry_key_side == "del" and V.before_win or V.win
    local rendered = entry_key_side == "del" and V.before_render or V.render
    focus(pane)
    vim.api.nvim_win_set_cursor(pane, {
      line_row(V, rendered, "src/main.lua", entry_key_side == "del" and DELETED or ADDED),
      0,
    })
    annotate.annotate("bug")
    return queue.all()[1]
  end

  it("lands in the before pane for a note on a deleted line", function()
    local entry = queued("del")
    local row = line_row(V, V.before_render, "src/main.lua", DELETED)
    focus(V.win)
    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    assert.is_true(view.jump_to_entry(entry))
    assert.same(V.before_win, vim.api.nvim_get_current_win())
    assert.same(row, row_in(V.before_win))
  end)

  it("lands in the after pane for a note on an added line", function()
    local entry = queued("add")
    local row = line_row(V, V.render, "src/main.lua", ADDED)
    focus(V.before_win)
    vim.api.nvim_win_set_cursor(V.before_win, { 1, 0 })
    assert.is_true(view.jump_to_entry(entry))
    assert.same(V.win, vim.api.nvim_get_current_win())
    assert.same(row, row_in(V.win))
  end)

  it("expands a collapsed file and still lands in the right pane", function()
    local entry = queued("del")
    local index = assert(h.file_index(V, "src/main.lua"))
    focus(V.win)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index], 0 })
    view.toggle_reviewed()
    assert.is_false(V.expanded["src/main.lua"])

    assert.is_true(view.jump_to_entry(entry))
    assert.is_true(V.expanded["src/main.lua"])
    assert.same(V.before_win, vim.api.nvim_get_current_win())
    assert.same("line", V.before_render.anchors[row_in(V.before_win)].kind)
    assert.same(row_in(V.before_win), row_in(V.win))

    view.toggle_reviewed()
    queue.clear()
    view.paint()
  end)
end)

-- The other intersection nobody else owns: three windows competing for the terminal's
-- columns, and the panel's presence transitioning at runtime underneath two bound panes.
describe("toggling the tree in the split layout", function()
  ---@return integer before, integer after
  local function widths()
    return vim.api.nvim_win_get_width(V.before_win), vim.api.nvim_win_get_width(V.win)
  end

  local shown_b, shown_a = widths()
  view.toggle_panel()
  local hidden_b, hidden_a = widths()
  view.toggle_panel()
  local back_b, back_a = widths()

  it("really dismissed and summoned the tree", function()
    assert.is_truthy(V.panel_win and vim.api.nvim_win_is_valid(V.panel_win))
    assert.is_true(hidden_b > shown_b, ("%d columns did not grow to %d"):format(shown_b, hidden_b))
  end)

  it("gives the reclaimed columns to both panes, not to one", function()
    assert.is_true(math.abs(hidden_b - hidden_a) <= 1, ("%d vs %d"):format(hidden_b, hidden_a))
    assert.is_true(math.abs(back_b - back_a) <= 1, ("%d vs %d"):format(back_b, back_a))
  end)

  it("comes back to the widths it started at", function()
    assert.same({ shown_b, shown_a }, { back_b, back_a })
  end)

  it("keeps the panes aligned across the toggle", function()
    assert.same(vim.api.nvim_buf_line_count(V.buf), vim.api.nvim_buf_line_count(V.before_buf))
    assert.same(row_in(V.win), row_in(V.before_win))
  end)

  it("repaints both panes to the new width", function()
    view.toggle_panel()
    local wide = vim.api.nvim_win_get_width(V.before_win)
    local row = V.before_render.file_rows[assert(h.file_index(V, "src/newname.lua"))]
    assert.is_true(vim.fn.strdisplaywidth(V.before_render.lines[row]) <= math.max(40, wide))
    view.toggle_panel()
  end)
end)

describe("syntax highlighting in the split layout", function()
  -- Re-opened with syntax on: the rest of this file turns it off so that repaints are
  -- about the render and nothing else. The compose stub is carried across with it -- this
  -- is the one `setup` call in the file that does not go through the helper at the top, and
  -- without the stub the next block's annotation opens a real composer float and takes the
  -- focus the winbars below are read under.
  view.close()
  require("codereview").setup({
    layout = "split",
    syntax = true,
    compose = function(ctx, on_accept, _)
      on_accept(nil, "note about " .. ctx.label)
    end,
  })
  view.open("branch")
  V = view.current()

  ---@param buf integer
  ---@return table[]
  local function painted(buf)
    local priority = render.PRIORITY.syntax
    return vim.tbl_filter(function(m)
      return m[4].priority == priority
    end, vim.api.nvim_buf_get_extmarks(buf, h.NS, 0, -1, { details = true }))
  end

  it("paints the after pane from the post-image", function()
    assert.is_true(#painted(V.buf) > 0)
  end)

  it("paints the before pane from the pre-image", function()
    assert.is_true(#painted(V.before_buf) > 0)
  end)

  -- The before pane's captures come from a different parse of a different blob, so they
  -- cannot simply be the after pane's marks copied across.
  it("paints a deleted line, which exists in no post-image at all", function()
    local row = line_row(V, V.before_render, "src/main.lua", DELETED)
    local on_row = vim.tbl_filter(function(m)
      return m[2] == row - 1
    end, painted(V.before_buf))
    assert.is_true(#on_row > 0, ("nothing highlighted on before-pane row %d"):format(row))
  end)
end)

-- The **sticky header**, per pane. The unified layout's bar is `render_spec`'s, arrow and
-- all; what only this layout can say is that each pane names its own side -- the after pane
-- the post-image path, the before pane the pre-image path beside the base revision it
-- already carried. That is the in-buffer file header's rename rule, and this is the winbar
-- following it rather than inventing a second one.
--
-- Last in this file: it widens the terminal, which nothing below it would survive.
describe("the sticky header in the split layout", function()
  local V = view.current()

  -- One annotation, queued here rather than inherited from a block above. The count on this
  -- bar is what one case below is about, and the review was re-opened a moment ago: a queue
  -- is read back from the store once per **checkout** per session, so re-opening a review
  -- does not re-read one -- its entries never left memory, and memory is what a reopen is
  -- showing again. A setup that leans on a reopen refilling the queue is a setup that any
  -- earlier block clearing it can take away.
  queue.clear()
  focus(V.win)
  vim.api.nvim_win_set_cursor(V.win, { line_row(V, V.render, "src/main.lua", ADDED), 0 })
  annotate.annotate("bug")

  -- Both bars have to hold everything they name at once -- the after pane its file and the
  -- whole review summary, the before pane its revision and the pre-image path -- and a third
  -- of a 120-column terminal is not enough for either. The pane would truncate its way to a
  -- pass or a fail for reasons that have nothing to do with which side it names. Widening the
  -- terminal hands every new column to the last window, so the panes are leveled after it,
  -- and the repaint is this test's to drive: `WinResized` never lands in a headless spec.
  local narrow = vim.api.nvim_win_get_width(V.win)
  vim.o.columns = 200
  vim.cmd("wincmd =")
  view.paint()

  ---@param path string
  local function read_into(path)
    local index = assert(h.file_index(V, path))
    focus(V.win)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index] + 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
  end

  read_into("src/newname.lua")
  -- What the two bars draw, not the markup they are set to: a needle that crossed one of the
  -- highlight markers on them would never be found in the option itself.
  local after, before = h.winbar(V.win), h.winbar(V.before_win)

  -- Guards the block: every case below reads a bar that had room for everything it names, and
  -- a bar with less sheds instead -- the summary from its head, the path from its directories.
  -- What that costs a case is a red for a reason that has nothing to do with what it asserts,
  -- so what is guarded is that the widening above took effect at all.
  --
  -- Asserted as *more columns than before it*, and no longer as arithmetic on the before
  -- pane's bar. That reading was sized on a 40-character revision; the revision is seven
  -- characters now, so the before pane fits a revision and a path at every width this spec can
  -- reach and a budget taken there cannot fail. The after pane is where the room is still
  -- tight -- it carries the file *and* the whole review summary -- and a comparison against
  -- the width before the widening can fail whatever either bar happens to need.
  it("really widened the panes before reading their bars", function()
    local wide = vim.api.nvim_win_get_width(V.win)
    assert.is_true(wide > narrow, ("%d columns before the widening, %d after"):format(narrow, wide))
  end)

  it("names the post-image path on the after pane, and only that side", function()
    assert.is_truthy(after:find("src/newname.lua", 1, true), after)
    assert.is_nil(after:find("src/oldname.lua", 1, true), after)
  end)

  it("names the base revision and the pre-image path on the before pane", function()
    assert.is_truthy(before:find(render.rev_label(V.scope.before), 1, true), before)
    assert.is_truthy(before:find("src/oldname.lua", 1, true), before)
  end)

  it("keeps the review summary on the after pane where it has always been", function()
    local reviewed = ("%s0/%d"):format(require("codereview.config").get().icons.reviewed, #V.files)
    assert.is_truthy(after:find(V.scope.label, 1, true), after)
    assert.is_truthy(after:find(reviewed, 1, true), after)
  end)

  -- The before pane's bar gets the same treatment as the after pane's, and this is the only
  -- place either can be said of *it*: the revision it exists to name is accented, the
  -- separator in front of that is as quiet as the summary's, and the pre-image path is styled
  -- by the rule that styles the after pane's path -- each pane names its own side of a
  -- rename, so each side is a path and each path is a quiet half and a bright one.
  it("colors the before pane's bar as it colors the after pane's", function()
    assert.same("CodeReviewBarRev", h.winbar_group(V.before_win, render.rev_label(V.scope.before)))
    assert.same("CodeReviewBarSep", h.winbar_group(V.before_win, "·"))
    assert.same("CodeReviewFileDir", h.winbar_group(V.before_win, "src/"))
    assert.same("CodeReviewFileName", h.winbar_group(V.before_win, "oldname.lua"))
  end)

  -- The note count carries the color notes carry everywhere else, which is the one thing on
  -- this bar `render_spec` cannot reach: nothing is queued while its own summary is measured.
  it("draws the queue's note count in the group the notes themselves carry", function()
    assert.same("CodeReviewNoteCount", h.winbar_group(V.win, ("%s1"):format(config.get().icons.annotated)))
  end)

  -- A file added on the branch exists on one side only, and the before pane's header row for
  -- it is filler. Its winbar says the same thing by naming nothing.
  -- Read through `h.winbar` and never off the option: a path carries a highlight marker
  -- between its two halves now, so `src/fresh.lua` is not a substring of what the option
  -- holds at all, and an assertion made against that string would report the file missing
  -- from a bar that names it.
  it("names no pre-image for a file that has none", function()
    read_into("src/fresh.lua")
    assert.is_truthy(h.winbar(V.win):find("src/fresh.lua", 1, true), h.winbar(V.win))
    assert.is_nil(h.winbar(V.before_win):find("fresh", 1, true), h.winbar(V.before_win))
  end)

  it("still names the revision on a pane naming no file", function()
    local drawn = render.rev_label(V.scope.before)
    assert.is_truthy(vim.wo[V.before_win].winbar:find(drawn, 1, true), vim.wo[V.before_win].winbar)
  end)
end)

-- The sticky header and **muting**, together. Neither slice could see this: the winbar was
-- written against a base with no muting in it, and muting against one whose winbar named no
-- file. What their combination implies is that the file segment is chrome of a review window
-- and has to recede with it. Nothing about that is visible in the bar's *text*, which is
-- identical bright or muted, so this is asserted at the cell and can be asserted nowhere
-- else.
--
-- **One cell, two groups, because a `%#Group#` names only a foreground.** The first character
-- of the path carries `CodeReviewFileDir` over the bar's own background, so the foreground of
-- this cell is the muted set reaching a group of the plugin's own and the background is it
-- reaching `WinBar` and `WinBarNC`. Both halves have been mutation-checked: taking `WinBarNC`
-- out of `EDITOR_GROUPS` reds the background, and taking `CodeReviewFileDir` out of `LINKS`
-- reds the foreground. Neither half can be dropped without the other going on passing.
--
-- One child process per reading, as `muted_spec` does and for the reason measured there:
-- `nvim__inspect_cell` is honest only on the first call a process makes.
describe("the sticky header on a muted pane", function()
  ---@param env table<string, string>
  ---@return string
  local function child(env)
    local run = vim
      .system({
        vim.v.progpath,
        "--clean",
        "-l",
        vim.fs.joinpath(h.root, "tests", "codereview", "winbar_child.lua"),
      }, {
        cwd = root,
        text = true,
        env = vim.tbl_extend("force", {
          FIXTURE = root,
          XDG_STATE_HOME = vim.fn.tempname() .. "-state",
          GIT_CONFIG_GLOBAL = "/dev/null",
          GIT_CONFIG_SYSTEM = "/dev/null",
        }, env),
      })
      :wait(60000)
    -- `nvim -l` sends print to stderr, so read both streams rather than guessing.
    local out = (run.stdout or "") .. (run.stderr or "")
    assert(run.code == 0, out)
    return vim.trim(out)
  end

  -- Always the *after* pane's bar, over the first character of the path it names. Which pane
  -- has focus is what decides whether that pane is the muted one.
  local muted = child({ FOCUS = "before", MUTED = "1" })
  local bright = child({ FOCUS = "after", MUTED = "1" })
  local unmuted_nc = child({ FOCUS = "before", MUTED = "0" })
  -- The fourth reading is a different cell of the same bar: the file's added count, which is
  -- the one segment on the left carrying a group of the plugin's own.
  local stat = child({ FOCUS = "after", MUTED = "1", CELL = "stat" })

  -- Every reading is of a cell inside the path, so a bar that had stopped naming the file
  -- would fail here before any color was compared.
  it("really read the file segment in all three arrangements", function()
    for _, reading in ipairs({ muted, bright, unmuted_nc }) do
      assert.same("cell s", reading:sub(1, #"cell s"), reading)
    end
  end)

  -- `CodeReviewFileDir`'s foreground over `WinBar`'s background: the group of the plugin's own
  -- that the quiet half of a path carries, on the bar of the pane that has focus.
  it("draws the file segment at full brightness on the pane with focus", function()
    assert.same("cell s fg=8844cc bg=006600", bright)
  end)

  -- Both colors blended halfway to `Normal`'s background -- the muted namespace's variants,
  -- not the groups themselves. The foreground is `CodeReviewFileDir` muted and the background
  -- is `WinBarNC` muted, so this one reading covers the two mechanisms the bar mutes on.
  it("mutes the file segment with the pane it names the file for", function()
    assert.same("cell s fg=442266 bg=002200", muted)
  end)

  -- The reading that gives the one above its teeth. A non-current window draws its winbar in
  -- `WinBarNC` whether or not anything is muted, so "the muted pane's bar is not `WinBar`"
  -- would hold with the namespace never reaching the winbar at all. With muting off the same
  -- cell comes back at both groups' own brightness, which is what the muted reading is darker
  -- *than* -- on the background, which is the half `WinBarNC` owns.
  it("comes back at that group's own brightness with muting off", function()
    assert.same("cell s fg=8844cc bg=004400", unmuted_nc)
  end)

  -- The claim no reading of the path can make, and no comparison of two strings can make
  -- either: a group of the plugin's own reaches the screen. The cell is the `+` of the file's
  -- own added count, on the pane with focus, and the reading has to be the group the stat
  -- links into rather than the bar's own foreground -- which is what the bright reading above
  -- is, taken from the same bar three cells to the left. The background is the bar's, because
  -- a `%#Group#` naming a foreground leaves it showing through.
  it("draws the added count in the plugin's own group rather than the bar's foreground", function()
    assert.same("cell + fg=00cc66 bg=006600", stat)
    assert.are_not.same(bright:sub(#"cell + " + 1), stat:sub(#"cell + " + 1), "the same color as the path")
  end)
end)
