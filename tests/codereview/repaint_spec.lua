-- When a paint runs on a resize, and when it must not.
--
-- One question, in a file of its own, because the answer is a rule that crosses everything:
-- the panes, the file tree, both layouts and every path that changes a window. `bounded_spec`
-- is the prior art -- one crosscutting rule, asserted through a seam that no implementation
-- detail can move.
--
-- The seam is `nvim_buf_get_changedtick` on the two panes and the file tree. A paint rewrites
-- each of those buffers exactly once, so a tick that has not moved is a paint that did not
-- run. Nothing here counts calls, wraps `paint` or reaches into the view: a counter would
-- measure the thing it was written beside, and this has to measure the work.
--
-- **Why the rule exists.** The view's resize autocommand listens to `VimResized` *and*
-- `WinResized`, and one terminal resize fires both -- measured over a pty, three resizes
-- giving `WinResized=3 VimResized=3`, and written up in `docs/design-notes.md`. So the
-- callback ran twice for one resize and repainted twice. It also has no pattern and no
-- buffer, so a window resized in another tab page ran it too.
--
-- **What this file can and cannot say.** `WinResized` is fired from the main loop, which a
-- headless Neovim never pumps, so it never lands here and every case that wants one fires it
-- itself. `VimResized` is not: a scripted change of `columns` or `lines` fires it
-- synchronously, so half of a terminal resize is driven through the real trigger. Neither is
-- enough for the double-fire claim itself, which is a fact about a real terminal and is
-- measured over a pty instead. What is asserted here is its consequence: the second of the
-- two callbacks finds the dimensions already recorded and does nothing.
local h = require("tests.helpers")

h.ui(110, 40)
h.cd_fixture("mkfixture")

require("codereview").setup({ syntax = false })

local view = require("codereview.view")

view.open("branch")
local V = view.current()

---@param buf integer|nil
---@return integer|nil
local function tick(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return vim.api.nvim_buf_get_changedtick(buf)
  end
  return nil
end

---How many full paints ran while `fn` ran.
---
---Counted on the after pane's change tick, which one paint moves by exactly one: `write_pane`
---rewrites the whole buffer in a single call. The first case below pins that the before pane
---and the file tree move with it, so what this counts is a repaint of the whole review rather
---than of one buffer of it.
---@param fn fun()
---@return integer
local function paints(fn)
  local before = assert(tick(V.buf))
  fn()
  return assert(tick(V.buf)) - before
end

---@param event "VimResized"|"WinResized"
local function fire(event)
  vim.api.nvim_exec_autocmds(event, {})
end

---The widths and heights of every review window there is.
---@return table
local function dims()
  local out = {}
  for _, name in ipairs({ "win", "before_win", "panel_win" }) do
    local win = V[name]
    if win and vim.api.nvim_win_is_valid(win) then
      out[name] = { vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
    end
  end
  return out
end

-- Everything below reads a change tick as "a paint ran". Without this the file is a row of
-- assertions that nothing moved, and nothing moving is what a broken seam looks like too.
describe("the seam this spec is read through", function()
  local before, after

  before = { after = tick(V.buf), panel = tick(V.panel_buf) }
  view.paint()
  after = { after = tick(V.buf), panel = tick(V.panel_buf) }

  it("has a file tree to read", function()
    assert.is_truthy(V.panel_buf, "the review opened without a file tree")
  end)

  it("moves the after pane's change tick by exactly one", function()
    assert.same(before.after + 1, after.after)
  end)

  it("moves the file tree's with it", function()
    assert.same(before.panel + 1, after.panel)
  end)
end)

describe("a resize event in the unified layout with nothing resized", function()
  it("opened unified", function()
    assert.same("unified", V.layout)
  end)

  it("repaints nothing on VimResized", function()
    assert.same(
      0,
      paints(function()
        fire("VimResized")
      end)
    )
  end)

  it("repaints nothing on WinResized", function()
    assert.same(
      0,
      paints(function()
        fire("WinResized")
      end)
    )
  end)
end)

describe("a resize event in the split layout with nothing resized", function()
  view.toggle_layout()

  it("really is in the split layout", function()
    assert.same("split", V.layout)
    assert.is_truthy(V.before_buf, "the split layout has no before pane")
  end)

  -- The before pane exists only here, so this is where the seam's third buffer is pinned.
  it("has a before pane a paint rewrites too", function()
    local was = assert(tick(V.before_buf))
    view.paint()
    assert.same(was + 1, tick(V.before_buf))
  end)

  it("repaints nothing on VimResized", function()
    assert.same(
      0,
      paints(function()
        fire("VimResized")
      end)
    )
  end)

  it("repaints nothing on WinResized", function()
    assert.same(
      0,
      paints(function()
        fire("WinResized")
      end)
    )
  end)
end)

describe("a pane that really changed width", function()
  local was = vim.api.nvim_win_get_width(V.win)
  local wide = was + 12
  vim.api.nvim_win_set_width(V.win, wide)

  it("really resized the pane", function()
    assert.same(wide, vim.api.nvim_win_get_width(V.win))
    assert.is_true(wide ~= was)
  end)

  it("repaints once", function()
    assert.same(
      1,
      paints(function()
        fire("WinResized")
      end)
    )
  end)

  -- A file header is padded to its pane, so this is what a repaint the guard skipped would
  -- have cost the reviewer.
  it("pads the file headers to the new width", function()
    local row = assert(V.render.file_rows[1])
    local line = vim.api.nvim_buf_get_lines(V.buf, row - 1, row, false)[1]
    assert.same(wide, vim.fn.strdisplaywidth(line))
  end)

  it("repaints nothing when the event fires again", function()
    assert.same(
      0,
      paints(function()
        fire("WinResized")
      end)
    )
  end)
end)

-- Only a pane's *width* is drawn into the diff -- the header padding, the winbar's fitting --
-- so a record holding widths alone reads as complete. Emission is bounded by the viewport,
-- and a viewport is a height: a window that grew taller is showing rows whose marks were
-- never written, and nothing repaints until the reviewer scrolls. This is the ordinary case
-- and not an exotic one -- measured over a pty, a `:split` beside the review took the after
-- pane from 42x37 to 42x18 and gave it back, with the width the same at every step. Dropping
-- the height from the record reds these two cases and nothing else in the suite.
describe("a window that changed only its height", function()
  local before_lines = vim.o.lines
  local before = dims()
  local seen = paints(function()
    vim.o.lines = before_lines + 8
  end)
  local after = dims()

  it("really changed a height and left every width alone", function()
    assert.is_true(after.win[2] ~= before.win[2], "no review window changed height")
    for name, wh in pairs(after) do
      assert.same(before[name][1], wh[1], name .. " changed width as well")
    end
  end)

  it("repaints once", function()
    assert.same(1, seen)
  end)
end)

-- The halving. One terminal resize fires both events -- `VimResized` first, and with the
-- windows already reporting their new dimensions at it, both measured over a pty. So the
-- first callback repaints and records, and the second finds nothing left to do.
--
-- Half of this is driven through the real trigger: a scripted change of `columns` fires
-- `VimResized` for itself, synchronously. `WinResized` is fired from the main loop and never
-- lands in a headless spec, so the spec lands it, in the order the pty measured.
describe("one terminal resize, which fires both events", function()
  local before_cols = vim.o.columns
  local before_dims = dims()
  local seen = paints(function()
    vim.o.columns = before_cols + 20
    fire("WinResized")
  end)
  local after_dims = dims()

  it("really widened a review window", function()
    assert.is_true(vim.o.columns ~= before_cols)
    assert.is_true(
      not vim.deep_equal(before_dims, after_dims),
      "no review window changed size, so this case measures nothing"
    )
  end)

  it("repaints exactly once for the two events", function()
    assert.same(1, seen)
  end)
end)

-- The trap the issue asks to be checked rather than assumed, from the side a spec can reach.
-- The pty says the windows are already resized when the first event arrives, so the order
-- below does not happen on a real resize -- what it pins is that the guard is a *comparison*
-- and never a latch. Coalescing the pair with a flag, or a scheduled repaint, is the obvious
-- alternative and it reads as equivalent: it halves the count just as well. Here it would
-- swallow the event that carries the real change, and the review would be left drawn for a
-- terminal that is no longer that size. An event that finds nothing changed must cost
-- nothing and consume nothing.
describe("a resize event that arrives before anything moved", function()
  local before_cols = vim.o.columns
  local seen = paints(function()
    fire("WinResized")
    vim.o.columns = before_cols - 20
  end)

  it("really narrowed a review window", function()
    assert.is_true(vim.o.columns ~= before_cols)
  end)

  it("still repaints exactly once", function()
    assert.same(1, seen)
  end)
end)

-- The autocommand has no pattern and no buffer, so it runs for a window the review has
-- nothing to do with. Measured over a pty: a `:split` in another tab page fired `WinResized`
-- twice with every review window the size it already was -- two full repaints of a review
-- the reviewer was not even looking at.
describe("a window resized in another tab page", function()
  local before_dims = dims()
  vim.cmd("tabnew")
  vim.cmd("split")
  local after_dims = dims()

  it("left every review window the size it was", function()
    assert.same(before_dims, after_dims)
  end)

  it("repaints nothing", function()
    assert.same(
      0,
      paints(function()
        fire("WinResized")
      end)
    )
  end)

  vim.cmd("tabclose")
end)

-- The tree takes its columns from the panes and gives them back, so both directions are a
-- real change of width. `toggle_panel` repaints for itself -- `WinResized` is fired from the
-- main loop and lands after it has returned -- and the guard must not be what stops it.
describe("the file tree summoned and dismissed", function()
  it("repaints when the tree is dismissed", function()
    assert.same(
      1,
      paints(function()
        view.toggle_panel()
      end)
    )
    assert.is_true(V.panel_win == nil or not vim.api.nvim_win_is_valid(V.panel_win))
  end)

  it("repaints when the tree comes back", function()
    assert.same(
      1,
      paints(function()
        view.toggle_panel()
      end)
    )
    assert.is_truthy(V.panel_win)
  end)

  -- The panes changed width twice and the repaints that followed recorded it, so the event
  -- the main loop lands afterwards has nothing left to do.
  it("repaints nothing when the event lands after it", function()
    assert.same(
      0,
      paints(function()
        fire("WinResized")
      end)
    )
  end)
end)
