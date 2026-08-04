-- Emission bounded by the viewport: what a paint writes into a pane's buffer, what a
-- scroll adds to it, and what scrolling back does not.
--
-- Every claim here needs a diff genuinely taller than the window and the margin around it.
-- A bounding assertion made on a diff that fits on screen passes with the bounding deleted,
-- which is the failure `tests/README.md` already records twice -- "centring is unobservable
-- in a window taller than its buffer", and "a filter test needs a fixture only that filter
-- can reject". So this is the one spec that builds `mkbig`, small enough to build in a
-- fraction of a second and still eight times taller than everything one paint can reach,
-- and its first case guards that it really is. Without that guard the whole file silently
-- stops measuring the moment a fixture or a default window size moves.
--
-- What is asserted is the shape of the work -- which marks reached which buffer -- and
-- never how long any of it took. Timing lives in `perf.lua`, which is a report, not a gate.
local h = require("tests.helpers")

local syntax = require("codereview.syntax")
local render = require("codereview.render")

h.ui(110, 40)
h.cd_fixture("mkbig", "6", "200")

-- A synchronous stub composer, so an annotation is queued and drawn inside the call.
require("codereview").setup({
  compose = function(_, on_accept, _)
    on_accept(nil, "note about this line")
  end,
})

local view = require("codereview.view")
local annotate = require("codereview.annotate")

view.open("branch")
local V = view.current()

local BAND = syntax.VIEWPORT_MARGIN

---The diff's own marks in a buffer: what the render put there, and nothing the treesitter
---replay did. The two share a namespace, and only these are bounded by a band -- a file
---near the window is parsed and painted *whole*, so a syntax mark can legitimately sit on a
---row this bounding has not reached.
---@param buf integer
---@return table[]
local function emitted(buf)
  return vim.tbl_filter(function(m)
    return m[4].priority ~= render.PRIORITY.syntax
  end, vim.api.nvim_buf_get_extmarks(buf, h.NS, 0, -1, { details = true }))
end

---How many marks a buffer carries on each 1-indexed row.
---@param buf integer
---@return table<integer, integer>
local function in_buffer(buf)
  local out = {}
  for _, m in ipairs(emitted(buf)) do
    out[m[2] + 1] = (out[m[2] + 1] or 0) + 1
  end
  return out
end

---How many marks a render gives each 1-indexed row.
---@param rendered CRRender
---@return table<integer, integer>
local function in_render(rendered)
  local out = {}
  for _, m in ipairs(rendered.marks) do
    out[m.row + 1] = (out[m.row + 1] or 0) + 1
  end
  return out
end

---The rows the window is showing.
---@return integer first, integer last
local function on_screen()
  -- Read through a table: `nvim_win_call` propagates only the first return value.
  local span = vim.api.nvim_win_call(V.win, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end)
  return span[1], span[2]
end

---The last row of the last band a paint at this scroll position reaches.
---@return integer
local function reach()
  local _, hi = syntax.viewport(V)
  return (math.floor((hi - 1) / BAND) + 1) * BAND
end

---Put the window on `row` and fire the trigger a reviewer's scroll would.
---
---Neither `nvim_win_set_cursor` nor a `normal!` motion raises `CursorMoved` under a
---headless Neovim -- see "Things that bite" -- so a case that only moved the window would
---be asserting against a top-up that never ran.
---@param row integer
local function scroll_to(row)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
  vim.api.nvim_win_call(V.win, function()
    vim.cmd("normal! zz")
  end)
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
end

---A pane carries every mark its render gave the rows up to `through`, and none above them.
---@param buf integer
---@param rendered CRRender
---@param through integer
local function complete_through(buf, rendered, through)
  local buf_rows, render_rows = in_buffer(buf), in_render(rendered)
  for row = 1, #rendered.lines do
    if row <= through then
      assert.same(render_rows[row], buf_rows[row], ("row %d, inside the painted bands"):format(row))
    else
      assert.is_nil(buf_rows[row], ("row %d is past them and carries marks"):format(row))
    end
  end
end

---A pane's marks come out in row order, which is what makes a band a slice of them rather
---than a filter over all of them.
---@param rendered CRRender
local function in_row_order(rendered)
  local previous = -1
  for i, m in ipairs(rendered.marks) do
    assert.is_true(m.row >= previous, ("mark %d is on row %d, after row %d"):format(i, m.row + 1, previous + 1))
    previous = m.row
  end
end

describe("a paint of a diff taller than the window", function()
  -- The guard the rest of the file rests on. Everything below is satisfied by a diff that
  -- fits on screen, whether or not anything is bounded.
  it("renders more rows than one paint can reach", function()
    assert.is_true(
      #V.render.lines > reach() * 2,
      ("%d rows is not enough taller than the %d a paint reaches"):format(#V.render.lines, reach())
    )
  end)

  it("hands its marks over in row order", function()
    in_row_order(V.render)
  end)

  it("writes the rows near the window and stops", function()
    complete_through(V.buf, V.render, reach())
  end)

  it("leaves the buffer holding a fraction of what the render produced", function()
    assert.is_true(
      #emitted(V.buf) * 3 < #V.render.marks,
      ("%d of %d marks is not bounded"):format(#emitted(V.buf), #V.render.marks)
    )
  end)

  -- The guard against the cheapest wrong way to pass every case above: a render that
  -- stopped producing the marks nobody can see. `split_spec`, `spans_spec` and
  -- `render_spec` all assert against returned data, and this is what keeps that seam honest.
  it("still produces the marks the buffer never receives", function()
    local last_file = assert(V.render.file_rows[#V.files])
    local produced = 0
    for _, m in ipairs(V.render.marks) do
      produced = produced + (m.row + 1 >= last_file and 1 or 0)
    end
    local written = 0
    for _, m in ipairs(emitted(V.buf)) do
      written = written + (m[2] + 1 >= last_file and 1 or 0)
    end
    assert.is_true(produced > 0, "the render gave the last file no marks at all")
    assert.same(0, written)
  end)

  -- The margin is the harvest's own. Two figures would drift, and a harvest reaching
  -- further than the emission is highlighting on rows with no diff background under them.
  it("stops at the bound the harvest is judged against", function()
    local _, hi = syntax.viewport(V)
    local top = 0
    for _, m in ipairs(emitted(V.buf)) do
      top = math.max(top, m[2] + 1)
    end
    assert.is_true(top >= hi, ("row %d is short of the harvest's bound at %d"):format(top, hi))
    assert.is_true(top < hi + BAND, ("row %d is past the harvest's bound at %d"):format(top, hi))
  end)

  it("carries the diff background, change bar, line number and span emphasis on screen", function()
    local first, last = on_screen()
    local groups = {}
    for _, m in ipairs(emitted(V.buf)) do
      local row = m[2] + 1
      if row >= first and row <= last then
        groups[m[4].line_hl_group or m[4].hl_group or ""] = true
      end
    end
    assert.is_true(groups.CodeReviewAdd, "no added line carries its background")
    assert.is_true(groups.CodeReviewDel, "no deleted line carries its background")
    assert.is_true(groups.CodeReviewAddBar, "no added line carries the change bar")
    assert.is_true(groups.CodeReviewDelBar, "no deleted line carries the change bar")
    assert.is_true(groups.CodeReviewLineNr, "no row carries its line number")
    assert.is_true(groups.CodeReviewAddSpan, "nothing inside a changed line is emphasised")
  end)
end)

describe("an annotation on a row on screen", function()
  local row = select(1, on_screen()) + 4
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
  annotate.annotate("bug")

  it("draws its virtual lines", function()
    local found = vim.tbl_filter(function(m)
      return m[4].virt_lines ~= nil and m[2] + 1 == row
    end, emitted(V.buf))
    assert.same(1, #found)
  end)

  it("has not lifted the bound to do it", function()
    complete_through(V.buf, V.render, reach())
  end)
end)

describe("scrolling into rows nothing has been emitted onto", function()
  local far = #V.render.lines
  -- Read while the window is still at the top: what a paint reaches is a fact about where
  -- the window is, so asking again after scrolling would be asking about the far end.
  local from_the_top = reach()
  local before

  it("finds them empty first", function()
    before = #emitted(V.buf)
    local buf_rows = in_buffer(V.buf)
    for row = from_the_top + 1, far do
      assert.is_nil(buf_rows[row], ("row %d was already painted"):format(row))
    end
  end)

  it("emits that region's marks", function()
    scroll_to(far)
    assert.is_true(#emitted(V.buf) > before, "scrolling to the end emitted nothing")
    local first, last = on_screen()
    local buf_rows, render_rows = in_buffer(V.buf), in_render(V.render)
    for row = first, last do
      assert.same(render_rows[row], buf_rows[row], ("row %d, on screen at the end"):format(row))
    end
  end)

  -- The middle was never near the window, so a top-up that emitted everything up to where
  -- the reviewer scrolled would pass the case above and fail this one.
  it("emits only that region", function()
    local buf_rows = in_buffer(V.buf)
    local lo = syntax.viewport(V)
    -- The last row below the bands the window has now reached.
    local middle = math.floor((lo - 1) / BAND) * BAND
    assert.is_true(middle > from_the_top, "the two painted regions meet, so there is no middle to check")
    for row = from_the_top + 1, middle do
      assert.is_nil(buf_rows[row], ("row %d was painted without ever being near the window"):format(row))
    end
  end)

  it("re-emits nothing when the reviewer scrolls back", function()
    local written = #emitted(V.buf)
    scroll_to(1)
    assert.same(written, #emitted(V.buf))
  end)
end)

describe("the split layout", function()
  view.toggle_layout()

  it("holds two panes of the same height", function()
    assert.is_not_nil(V.before_render)
    assert.same(#V.render.lines, #V.before_render.lines)
  end)

  it("hands both panes' marks over in row order", function()
    in_row_order(V.render)
    in_row_order(V.before_render)
  end)

  -- Both panes bounded by the same bands, so the two images stay comparable row for row
  -- wherever a reviewer has scrolled: a bound that moved per pane would leave one of them
  -- drawing a change bar the other had not reached.
  it("bounds both panes at the same rows", function()
    complete_through(V.buf, V.render, reach())
    complete_through(V.before_buf, V.before_render, reach())
  end)

  it("tops both up together when the reviewer scrolls", function()
    scroll_to(#V.render.lines)
    local first, last = on_screen()
    local after_rows, before_rows = in_buffer(V.buf), in_buffer(V.before_buf)
    local after_render, before_render_rows = in_render(V.render), in_render(V.before_render)
    local seen = 0
    for row = first, last do
      assert.same(after_render[row], after_rows[row], ("after pane, row %d"):format(row))
      assert.same(before_render_rows[row], before_rows[row], ("before pane, row %d"):format(row))
      seen = seen + (before_rows[row] or 0)
    end
    assert.is_true(seen > 0, "the before pane drew nothing on screen, so it agrees vacuously")
  end)
end)
