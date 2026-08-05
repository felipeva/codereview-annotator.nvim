-- Where the cursor ends up around the queue float, and after an annotation.
--
-- The regression these guard: routing a batch opens an asynchronous picker, and by the
-- time it answers the float has lost focus to the diff underneath. Anything that fires a
-- callback on a later tick has to put focus back where the user left it.
local h = require("tests.helpers")

h.ui(120, 45)
h.cd_fixture("mktree")

local sent = {}
local pending_pick -- the picker's callback, held so it fires asynchronously like a real one

-- Swapped per block. The queue float's cases want a composer that answers and gets out of
-- the way; the annotation cases at the bottom want one shaped like a host's, which is a
-- different thing entirely.
--
-- Synchronous either way. Insert mode is unreachable in headless Neovim, so the
-- insert-mode leak and its fix cannot be exercised here at all -- that is
-- interactive_spec's job.
local composer = function(ctx, on_accept, _)
  on_accept(nil, "note on " .. ctx.rel_path)
end

---@param panel table|nil Panel options, or nil for the default: enabled, on the left
local function setup(panel)
  require("codereview").setup({
    syntax = false,
    panel = panel,
    compose = function(ctx, on_accept, label)
      composer(ctx, on_accept, label)
    end,
    -- Mimics vim.ui.select: the callback lands on a later tick, not inline.
    pick_target = function(cb)
      pending_pick = function()
        cb({ short = "janus · api", pane_id = "wV:p3", cwd = "/elsewhere" })
      end
    end,
    send = function(text, target)
      sent[#sent + 1] = { text = text, target = target }
    end,
  })
end

setup(nil)

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")

view.open("branch")
local V = view.current()
queue.clear()

---@param kind "line"|"hunk"|"file"
---@return integer row
local function row_of(kind)
  for row = 1, vim.api.nvim_buf_line_count(V.buf) do
    local a = V.render.anchors[row]
    if a and a.kind == kind then
      return row
    end
  end
  error("no " .. kind .. " row in the render")
end

local function first_line_row()
  return row_of("line")
end

local function annotate_something(kind)
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { first_line_row(), 0 })
  annotate.annotate(kind)
end

describe("opening the queue float", function()
  annotate_something("bug")

  it("queues the annotation", function()
    assert.same(1, queue.count())
  end)

  view.review_queue()
  local qwin = vim.api.nvim_get_current_win()

  it("takes focus", function()
    assert.is_true(qwin ~= V.win)
  end)

  it("is tracked so it can be cleaned up", function()
    assert.same(qwin, V.queue_win)
  end)

  local function footer()
    local cfg = vim.api.nvim_win_get_config(qwin)
    return cfg.footer and tostring(cfg.footer[1][1]) or ""
  end

  it("footers the local target to begin with", function()
    assert.is_truthy(footer():find("local", 1, true))
  end)

  describe("routing from the float", function()
    -- Press <C-t>; the picker has not answered yet.
    h.feed("<C-t>")

    it("holds focus while the picker is open", function()
      assert.same(qwin, vim.api.nvim_get_current_win())
    end)

    pending_pick()

    -- Asserted through the winbar rather than the field behind it: where the target is
    -- stored is the plugin's business, and it has already moved once.
    it("records the target", function()
      assert.is_truthy(vim.wo[V.win].winbar:find("→ janus · api", 1, true), vim.wo[V.win].winbar)
    end)

    it("returns focus to the float, not the diff underneath", function()
      assert.same(qwin, vim.api.nvim_get_current_win())
      assert.is_true(vim.api.nvim_win_is_valid(qwin))
    end)

    it("repaints the footer with the new target", function()
      assert.is_truthy(footer():find("janus", 1, true))
    end)
  end)

  describe("submitting from the float", function()
    h.feed("<C-s>")

    it("sends the batch to the chosen agent", function()
      assert.same(1, #sent)
      assert.same("wV:p3", sent[1].target.pane_id)
    end)

    it("empties the queue and closes the float", function()
      assert.same(0, queue.count())
      assert.is_false(vim.api.nvim_win_is_valid(qwin))
      assert.is_nil(V.queue_win)
    end)
  end)
end)

describe("submitting from the diff while a float is open", function()
  sent = {}
  annotate_something("fix")
  view.review_queue()
  local qwin = vim.api.nvim_get_current_win()

  it("opened a second float", function()
    assert.is_true(vim.api.nvim_win_is_valid(qwin))
  end)

  -- Reproduces the old failure mode directly: submit while focus sits in the diff, and
  -- the float is left on screen listing a batch that has already been sent.
  vim.api.nvim_set_current_win(V.win)
  view.submit()

  it("still submits", function()
    assert.same(1, #sent)
    assert.same(0, queue.count())
  end)

  it("leaves no stale float behind", function()
    assert.is_false(vim.api.nvim_win_is_valid(qwin))
  end)
end)

describe("routing from the diff", function()
  vim.api.nvim_set_current_win(V.win)
  view.pick_target()
  pending_pick()

  it("returns focus to the diff", function()
    assert.same(V.win, vim.api.nvim_get_current_win())
  end)

  it("shows the target in the winbar", function()
    assert.is_truthy(vim.wo[V.win].winbar:find("janus", 1, true))
  end)
end)

--- After an annotation ----------------------------------------------------------

local function float()
  local buf = vim.api.nvim_create_buf(false, true)
  return vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = 40,
    height = 6,
    row = 5,
    col = 5,
    style = "minimal",
  })
end

---A composer shaped like a host's: a float that takes focus, opens a picker while it is up
---(an `@file` reference, a change of target), takes focus back from it, and closes.
---
---The nested window is the point of this stand-in, not decoration. Closing a float hands
---focus to whatever window Neovim last recorded, and what gets recorded here is the picker
----- which is gone by the time the composer closes, so focus falls through to the first
---window in the tab instead. With the tree on the left, that is the tree.
---
---A stand-in without the nested window keeps focus on the diff by luck and passes against
---the bug. Change this and the tests below stop guarding anything.
---@param text string Note the composer comes back with
---@return fun(ctx: table, on_accept: fun(target: table|nil, text: string))
local function host_composer(text)
  return function(_, on_accept)
    local win = float()
    local picker = float()
    vim.api.nvim_win_close(picker, true)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_close(win, true)
    on_accept(nil, text)
  end
end

---Focus is restored on the tick after the composer hands back, so give it one.
---
---Bounded rather than fixed: this returns the moment focus settles where it should, and
---only spends the whole wait when the assertion after it is going to fail anyway.
---@param win integer Window focus is expected to settle on
---@return integer focused
local function settled(win)
  vim.wait(200, function()
    return vim.api.nvim_get_current_win() == win
  end)
  return vim.api.nvim_get_current_win()
end

--- Submitting under a preamble ---------------------------------------------------

-- `<C-a>` is a submit too, so the two window rules a submit carries are its rules as well,
-- one composer later. The float here has already lost focus, which is the state the view's
-- own rule exists for: the failure `<C-s>` had was a batch sent with a dialog left on
-- screen listing it.
--
-- The composer for the submit itself hands back from the tree, rather than through the
-- host-shaped stand-in above. Measured, not assumed: closing that stand-in's windows leaves
-- focus on the diff here anyway, so an assertion made against it would pass with nothing
-- restoring anything -- the same trap the stand-in was written for on the annotation path.
-- A host composer is a window of its own and is entitled to hand back from wherever it
-- likes; the plugin is what puts focus back (see `codereview-opt-compose`).
---@param text string
---@return fun(ctx: table, on_accept: fun(target: table|nil, text: string))
local function composer_handing_back_from_the_tree(text)
  return function(_, on_accept)
    local tree = assert(V.panel_win, "no file tree to hand back from")
    vim.api.nvim_set_current_win(tree)
    on_accept(nil, text)
  end
end

describe("submitting under a preamble from the diff while a float is open", function()
  sent = {}
  composer = host_composer("something worth covering")
  annotate_something("fix")
  composer = composer_handing_back_from_the_tree("read the whole thing first")
  view.review_queue()
  local qwin = vim.api.nvim_get_current_win()

  it("opened a float", function()
    assert.is_true(vim.api.nvim_win_is_valid(qwin))
  end)

  vim.api.nvim_set_current_win(V.win)
  view.submit_with_preamble()

  it("submits the batch under what the composer collected", function()
    assert.same(1, #sent)
    assert.same("read the whole thing first", vim.split(sent[1].text, "\n")[1])
    assert.same(0, queue.count())
  end)

  it("leaves no stale float behind", function()
    assert.is_false(vim.api.nvim_win_is_valid(qwin))
    assert.is_nil(V.queue_win)
  end)
end)

-- Where the reviewer is left afterwards. A batch that did not go repaints nothing --
-- there is nothing new to draw and the entries are all still queued -- so nothing behind
-- the composer moves the cursor back, and a reviewer who asked from the diff would be left
-- in the tree with a batch to retry.
describe("a preamble whose batch the adapter refused", function()
  local cfg = require("codereview.config").get()
  local sending = cfg.send
  composer = host_composer("something worth covering")
  annotate_something("fix")
  -- Drained before the submit starts. The annotation above restores focus on the *next*
  -- tick, so a submit begun on this one would be measured against that restore rather than
  -- against anything this block does -- and the case would pass with nothing here restoring
  -- anything. Measured: without this the assertion below survives the restore being cut.
  vim.wait(50)
  cfg.send = function()
    return false, "the agent pane is gone"
  end
  composer = composer_handing_back_from_the_tree("kept for the retry")

  vim.api.nvim_set_current_win(V.win)
  local msgs, restore = h.capture_notify()
  view.submit_with_preamble()
  restore()
  local focused = settled(V.win)
  cfg.send = sending

  it("keeps the batch to be retried", function()
    assert.same(1, queue.count())
    assert.is_true(h.notified(msgs, "the agent pane is gone"), vim.inspect(msgs))
  end)

  it("still puts focus back in the window the submit was asked from", function()
    assert.same(V.win, focused)
  end)
end)

describe("annotating from the diff", function()
  composer = host_composer("a note")

  for _, kind in ipairs({ "line", "hunk", "file" }) do
    local row = row_of(kind)
    local before = queue.count()
    vim.api.nvim_set_current_win(V.win)
    vim.api.nvim_win_set_cursor(V.win, { row, 0 })
    annotate.annotate("bug")
    local focused = settled(V.win)
    local cursor = vim.api.nvim_win_get_cursor(V.win)[1]

    it(("queues the %s annotation"):format(kind), function()
      assert.same(before + 1, queue.count())
    end)

    it(("keeps focus in the diff, not the tree, for a %s annotation"):format(kind), function()
      assert.same(V.win, focused)
    end)

    it(("leaves the cursor where the %s annotation was made"):format(kind), function()
      assert.same(row, cursor)
    end)
  end
end)

describe("annotating through the type picker", function()
  local orig = vim.ui.select
  -- A real picker is a window in its own right: it takes focus, and gives it back.
  vim.ui.select = function(items, _, cb)
    local win = float()
    vim.api.nvim_win_close(win, true)
    cb(items[1], 1)
  end

  local before = queue.count()
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { row_of("line"), 0 })
  annotate.annotate_pick()
  local focused = settled(V.win)
  vim.ui.select = orig

  it("queues the annotation", function()
    assert.same(before + 1, queue.count())
  end)

  it("keeps focus in the diff", function()
    assert.same(V.win, focused)
  end)
end)

describe("annotating a visual selection", function()
  local before = queue.count()
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { row_of("line"), 0 })
  -- Through the real mapping: the selection has to be live when the annotation resolves,
  -- which calling the function directly cannot reproduce.
  h.feed("Vjab")
  local focused = settled(V.win)

  -- Guards the test itself. A selection that resolved to nothing would open no composer,
  -- move no focus, and pass the assertion below without exercising anything.
  it("queues the annotation", function()
    assert.same(before + 1, queue.count())
  end)

  it("keeps focus in the diff", function()
    assert.same(V.win, focused)
  end)
end)

describe("a composer that comes back empty", function()
  composer = host_composer("")
  local before = queue.count()
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { row_of("line"), 0 })
  annotate.annotate("bug")
  local focused = settled(V.win)
  composer = host_composer("a note")

  it("queues nothing", function()
    assert.same(before, queue.count())
  end)

  it("still puts focus back in the diff", function()
    assert.same(V.win, focused)
  end)
end)

-- Which side the tree is on is what made this bug visible or invisible: focus fell through
-- to the first window in the tab, which is the tree only when the tree is on the left.
-- Neither layout should depend on that any more.
for _, layout in ipairs({
  { label = "with the tree on the right", panel = { position = "right" } },
  { label = "with no tree at all", panel = { enabled = false } },
}) do
  describe(("annotating %s"):format(layout.label), function()
    view.close()
    setup(layout.panel)
    view.open("branch")
    V = view.current()
    composer = host_composer("a note")

    local before = queue.count()
    vim.api.nvim_set_current_win(V.win)
    vim.api.nvim_win_set_cursor(V.win, { row_of("line"), 0 })
    annotate.annotate("bug")
    local focused = settled(V.win)

    it("queues the annotation", function()
      assert.same(before + 1, queue.count())
    end)

    it("keeps focus in the diff", function()
      assert.same(V.win, focused)
    end)
  end)
end

-- Capture, where the window that asked is not the review view's and never could be.
describe("capturing from a buffer in a split", function()
  vim.cmd("tabnew " .. vim.fn.fnameescape("apps/api/src/main.lua"))
  local first = vim.api.nvim_get_current_win()
  vim.cmd("belowright split " .. vim.fn.fnameescape("docs/guide.md"))
  local second = vim.api.nvim_get_current_win()
  composer = host_composer("a note")

  local before = queue.count()
  require("codereview").annotate("bug")
  local focused = settled(second)

  it("queues the annotation", function()
    assert.same(before + 1, queue.count())
  end)

  it("stays in the window it was started from, not the first one in the tab", function()
    assert.is_true(first ~= second)
    assert.same(second, focused)
  end)
end)

describe("when the window it was started from is gone", function()
  local pending
  composer = function(_, on_accept)
    pending = function()
      on_accept(nil, "a note")
    end
  end

  local before = queue.count()
  local tab = vim.api.nvim_get_current_tabpage()
  require("codereview").annotate("bug")
  vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
  local landed = vim.api.nvim_get_current_win()
  pending()
  vim.wait(50, function()
    return false
  end)

  it("still queues the note", function()
    assert.same(before + 1, queue.count())
  end)

  it("leaves focus alone rather than dragging it into the review", function()
    assert.same(landed, vim.api.nvim_get_current_win())
    assert.same(tab, vim.api.nvim_get_current_tabpage())
  end)
end)
