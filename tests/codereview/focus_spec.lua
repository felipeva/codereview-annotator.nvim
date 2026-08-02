-- Where the cursor ends up around the queue float.
--
-- The regression these guard: routing a batch opens an asynchronous picker, and by the
-- time it answers the float has lost focus to the diff underneath. Anything that fires a
-- callback on a later tick has to put focus back where the user left it.
local h = require("tests.helpers")

h.ui(120, 45)
h.cd_fixture("mktree")

local sent = {}
local pending_pick -- the picker's callback, held so it fires asynchronously like a real one

require("codereview").setup({
  syntax = false,
  -- Synchronous. Insert mode is unreachable in headless Neovim, so the insert-mode leak
  -- and its fix cannot be exercised here at all -- that is interactive_spec's job.
  compose = function(ctx, on_accept, _)
    on_accept(nil, "note on " .. ctx.rel_path)
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

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")

view.open("branch")
local V = view.current()
queue.clear()

local function first_line_row()
  for row, a in pairs(V.render.anchors) do
    if a.kind == "line" then
      return row
    end
  end
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

    it("records the target", function()
      assert.same("janus · api", V.target.short)
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
  V.target = nil
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
