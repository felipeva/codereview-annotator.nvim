-- **Wrap**: a line too wide for its window folded onto further rows.
--
-- Two seams, and they answer different questions. The number the render reports is pure
-- data -- no window and no repository -- and it is asserted there, including on a diff whose
-- line numbers need more digits than this fixture's ever will. Everything else is a claim
-- about the screen, and it is read off the screen: where a character lands, and what colour
-- the cell under it took. An assertion that read `breakindentopt` back would pass with the
-- indent pointed at the wrong number, which is the whole thing this is here to catch.
--
-- `screenpos`, `screenstring` and `screenattr` all answer in a headless Neovim -- measured,
-- not assumed -- and unlike `nvim__inspect_cell` they answer more than once per process,
-- which is what lets this file stay one process rather than the child `faded_spec` needs.
--
-- Syntax and both blends are off. Not because a review runs that way, but because each of
-- them puts a second reason on the cell this file reads a colour off: the replay paints a
-- foreground over the code, and a blend moves the background of every file but one. What is
-- being asserted is that the *line's own* background reaches its continuation rows.
local h = require("tests.helpers")

h.ui(110, 40)
vim.o.termguicolors = true
local fixture = h.cd_fixture("mkfixture")

-- One line far wider than any pane this spec opens, appended to a file the branch scope
-- already carries so it arrives with context lines around it. Written here rather than into
-- `mkfixture.sh`: nothing else in the suite wants a line this wide, and a fixture every
-- other spec builds is not the place to put one.
local WIDE = 'local url = "https://example.com/' .. ("segment/"):rep(40) .. 'index.html"'
local main = vim.fs.joinpath(fixture, "src/main.lua")
vim.fn.writefile(vim.list_extend(vim.fn.readfile(main), { WIDE }), main)

require("codereview").setup({
  syntax = false,
  muted = { enabled = false },
  faded = { enabled = false },
  compose = function(_, on_accept, _)
    on_accept(nil, "note about a folded line")
  end,
})

local annotate = require("codereview.annotate")
local config = require("codereview.config")
local git = require("codereview.git")
local queue = require("codereview.queue")
local render = require("codereview.render")
local view = require("codereview.view")

--- Pure: no window, no repository ----------------------------------------------

---One hunk of `count` added lines ending at `last`, as a file list `render.build` takes.
---@param last integer
---@return CRFile[]
local function synthetic(last)
  local lines = {}
  for n = last - 2, last do
    lines[#lines + 1] = { side = "add", new = n, text = "x" }
  end
  return {
    {
      path = "src/wide.lua",
      status = "M",
      added = #lines,
      removed = 0,
      binary = false,
      hunks = { { header = "@@ -1 +1 @@", heading = "", old_start = 1, new_start = last - 2, lines = lines } },
    },
  }
end

---@param files CRFile[]
---@param opts table|nil
---@return CRRender after, CRRender|nil before
local function build(files, opts)
  local cfg = config.get()
  return render.build(
    files,
    vim.tbl_extend("force", {
      width = 80,
      icons = cfg.icons,
      expanded = {},
      reviewed = {},
      notes = {},
      types = cfg.types,
    }, opts or {})
  )
end

describe("the gutter the render reports", function()
  local scope = assert(git.resolve_scope("branch", fixture))
  local files = assert(git.collect(scope, fixture, { context = 3, untracked = true }))

  it("is the columns every diff line row actually spends before its code", function()
    local rendered = build(files)
    for row, a in pairs(rendered.anchors) do
      if a.kind == "line" then
        local prefix = rendered.lines[row]:sub(1, a.col)
        assert.same(rendered.gutter, vim.fn.strdisplaywidth(prefix), ("row %d: %q"):format(row, prefix))
      end
    end
  end)

  it("is the same number in both panes of a split", function()
    local after, before = build(files, { layout = "split", before_width = 80 })
    assert.same(after.gutter, before.gutter)
  end)

  -- The bar, the line number, the separator and the sign: 1 + 1 + 3 + 1 with single-digit
  -- line numbers, and four columns more when they reach five digits. Asserted as the two
  -- numbers rather than as the arithmetic, so a change to the separator has to be read here.
  it("widens for a diff whose line numbers need five digits", function()
    assert.same(6, build(synthetic(9)).gutter)
    assert.same(10, build(synthetic(99999)).gutter)
  end)
end)

--- On the screen ----------------------------------------------------------------

view.open("branch")
local V = assert(view.current(), "no review view opened")

-- Taken before anything has queued a note, so that the comparison further down is between
-- two renders of the same diff rather than between one that carries an annotation and one
-- that does not.
local marks_unwrapped = vim.deepcopy(V.render.marks)

---The row the wide line was drawn on, and its anchor.
---@return integer row, CRAnchor anchor
local function wide_row()
  for row, a in pairs(V.render.anchors) do
    if a.kind == "line" then
      local ln = V.files[a.file].hunks[a.hunk].lines[a.line]
      if ln.side == "add" and ln.text == WIDE then
        return row, a
      end
    end
  end
  error("the wide line is not in the render")
end

---Put the cursor on a row and let the screen catch up.
---@param row integer
local function show(row)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
  vim.cmd("normal! zz")
  vim.cmd("redraw!")
end

---Where the first code column of `row` lands, where the first code column of the screen row
---that continues it lands, and the byte the fold happened at.
---
---Screen coordinates, which is what `screenpos` answers in and what `screenstring` and
---`screenattr` take. The file tree is drawn to the left of the pane, so a column here is not
---a column of the window -- `left` below is what turns one into the other.
---@param row integer
---@param col integer Byte offset the code starts at
---@return table first, table|nil continuation, integer|nil byte
local function code_columns(row, col)
  local first = vim.fn.screenpos(V.win, row, col + 1)
  assert(first.row > 0, "the row under test is off screen")
  local text = vim.api.nvim_buf_get_lines(V.buf, row - 1, row, false)[1]
  for byte = col + 1, #text do
    local at = vim.fn.screenpos(V.win, row, byte)
    if at.row == first.row + 1 then
      return first, at, byte
    end
  end
  return first, nil, nil
end

---The screen column the pane's own first column is drawn in, on `row`.
---@param row integer
---@return integer
local function left(row)
  return vim.fn.screenpos(V.win, row, 1).col
end

---An entry without the two fields no two captures can share: the id a counter issues, and
---the moment it was made.
---@param entry CRAnnotation
---@return table
local function anonymous(entry)
  local out = vim.deepcopy(entry)
  out.id, out.at = nil, nil
  return out
end

---What the wide line queued while it was not folding.
---@type table
local unfolded

---A row of the same file drawn from a context line, which carries no diff background.
---@param fi integer
---@return integer
local function context_row(fi)
  for row, a in pairs(V.render.anchors) do
    if a.kind == "line" and a.file == fi then
      local ln = V.files[a.file].hunks[a.hunk].lines[a.line]
      if ln.side == "ctx" then
        return row
      end
    end
  end
  error("that file has no context line")
end

describe("with wrap off", function()
  it("leaves the after pane unwrapped", function()
    assert.is_false(vim.wo[V.win].wrap)
  end)

  it("leaves the file tree unwrapped", function()
    assert.is_false(vim.wo[V.panel_win].wrap)
  end)

  it("runs the wide line off the right edge rather than folding it", function()
    local row, a = wide_row()
    show(row)
    local _, continuation = code_columns(row, a.col)
    assert.is_nil(continuation)
  end)

  -- Kept for the folded case below to be compared against. What an entry says about a line
  -- is the whole of what reaches the receiving agent, so the claim worth making is that the
  -- two are the same entry rather than that either one is any particular shape.
  it("queues an entry for the wide line", function()
    show((wide_row()))
    queue.clear()
    annotate.annotate("bug")
    assert.same(1, #queue.all())
    unfolded = anonymous(queue.all()[1])
    queue.clear()
  end)
end)

describe("with wrap on, in the unified layout", function()
  require("codereview").setup({
    wrap = true,
    syntax = false,
    muted = { enabled = false },
    faded = { enabled = false },
    compose = function(_, on_accept, _)
      on_accept(nil, "note about a folded line")
    end,
  })
  view.paint()

  it("wraps the after pane", function()
    assert.is_true(vim.wo[V.win].wrap)
  end)

  -- Dismissed and summoned again, so the window being read was *built* while wrap was on.
  -- Reading the one the review opened with would pass on a helper that folded every window
  -- it was handed, because that window was made before the setting was.
  it("still leaves the file tree unwrapped, even one summoned since", function()
    assert.is_false(vim.wo[V.panel_win].wrap)
    view.toggle_panel()
    view.toggle_panel()
    assert.is_true(vim.api.nvim_win_is_valid(V.panel_win))
    assert.is_false(vim.wo[V.panel_win].wrap)
  end)

  it("starts a continuation row's code in the column the row it continues starts in", function()
    local row, a = wide_row()
    show(row)
    local first, continuation = code_columns(row, a.col)
    assert.is_table(continuation, "the wide line did not fold")
    assert.same(first.col, continuation.col)
  end)

  it("draws the marker where the change bar would be", function()
    local row, a = wide_row()
    show(row)
    local first = vim.fn.screenpos(V.win, row, a.col + 1)
    -- `screenstring` counts from the screen's left edge and the file tree is drawn there,
    -- so the bar's column is asked of the row rather than assumed to be column one.
    assert.same(config.get().icons.change_bar, vim.fn.screenstring(first.row, left(row)))
    assert.same(config.get().icons.continuation, vim.fn.screenstring(first.row + 1, left(row)))
  end)

  it("carries the line's own background onto every row it folds onto", function()
    local row, a = wide_row()
    show(row)
    local first, continuation = code_columns(row, a.col)
    assert.is_table(continuation)
    local added = vim.fn.screenattr(first.row, first.col)
    assert.same(added, vim.fn.screenattr(continuation.row, continuation.col))
    -- And it is the *added* background rather than whatever every cell here happens to
    -- carry: a context line of the same file, read in the same column, differs.
    local ctx = vim.fn.screenpos(V.win, context_row(a.file), a.col + 1)
    assert.are_not.same(added, vim.fn.screenattr(ctx.row, ctx.col))
  end)

  it("changes no mark the render emits", function()
    assert.same(marks_unwrapped, V.render.marks)
  end)

  it("queues the entry a folded line queues unfolded", function()
    show((wide_row()))
    queue.clear()
    annotate.annotate("bug")
    assert.same(1, #queue.all())
    assert.same(unfolded, anonymous(queue.all()[1]))
    queue.clear()
  end)

  it("moves the file and hunk keys exactly as far as they moved", function()
    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    local landed = {}
    for _, spec in ipairs({ { "file", true }, { "hunk", true }, { "hunk", false }, { "file", false } }) do
      view.jump(spec[1], spec[2])
      landed[#landed + 1] = vim.api.nvim_win_get_cursor(V.win)[1]
    end
    assert.same({ V.render.file_rows[2], V.render.hunk_rows[2], V.render.hunk_rows[1], V.render.file_rows[1] }, landed)
  end)

  -- `]a` and `[a` move between *annotations* rather than between rows of the diff, so they
  -- need one to move to. The folded line is one of the two on purpose: a key that resolved
  -- through the screen rather than through the anchor map would land somewhere else on it.
  it("moves the annotation keys onto the rows the annotations are on", function()
    queue.clear()
    local folded = wide_row()
    local other = assert(h.line_row(V, "src/fresh.lua"), "the fixture lost src/fresh.lua")
    for _, row in ipairs({ math.min(folded, other), math.max(folded, other) }) do
      show(row)
      annotate.annotate("bug")
    end
    assert.same(2, #queue.all())

    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    local landed = {}
    for _, forward in ipairs({ true, true, false }) do
      view.jump_annotation(forward)
      landed[#landed + 1] = vim.api.nvim_win_get_cursor(V.win)[1]
    end
    local first, second = math.min(folded, other), math.max(folded, other)
    assert.same({ first, second, first }, landed)
    queue.clear()
  end)
end)

describe("a narrower window", function()
  it("re-folds the wide line and keeps the continuation indented", function()
    local row, a = wide_row()
    show(row)
    local was = select(3, code_columns(row, a.col))
    vim.api.nvim_win_set_width(V.win, vim.api.nvim_win_get_width(V.win) - 20)
    vim.api.nvim_exec_autocmds("WinResized", {})
    show(row)
    local first, continuation, byte = code_columns(row, a.col)
    assert.is_true(vim.wo[V.win].wrap)
    assert.is_table(continuation)
    assert.same(first.col, continuation.col)
    assert.same(V.render.gutter, first.col - left(row))
    -- A narrower pane holds fewer columns of the line, so it folds at an earlier byte. Left
    -- unasserted, this whole case would pass on a window that never re-read its width.
    assert.is_true(byte < was, ("folded at byte %d, and at %d before the resize"):format(byte, was))
  end)
end)

describe("in the split layout", function()
  it("leaves both panes unwrapped", function()
    view.toggle_layout()
    V = assert(view.current())
    assert.is_true(config.get().wrap)
    assert.is_false(vim.wo[V.win].wrap)
    assert.is_false(vim.wo[V.before_win].wrap)
  end)

  it("folds again on the way back to unified", function()
    view.toggle_layout()
    V = assert(view.current())
    assert.is_true(vim.wo[V.win].wrap)
  end)
end)

describe("a diff whose line numbers need five digits", function()
  it("indents the continuation past the wider gutter", function()
    local narrow = V.render.gutter
    -- A file long enough to push every line number in the review to five digits. Untracked,
    -- so no commit is needed and the branch scope picks it up.
    local long = {}
    for n = 1, 10000 do
      long[n] = ("local n%d = %d"):format(n, n)
    end
    vim.fn.writefile(long, vim.fs.joinpath(fixture, "src/tall.lua"))
    view.refresh()
    V = assert(view.current())

    assert.same(narrow + 4, V.render.gutter)
    local row, a = wide_row()
    show(row)
    local first, continuation = code_columns(row, a.col)
    assert.is_table(continuation, "the wide line did not fold")
    assert.same(first.col, continuation.col)
    assert.same(V.render.gutter, continuation.col - left(row))
  end)
end)
