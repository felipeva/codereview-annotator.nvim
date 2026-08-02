-- The composer the plugin ships: what opens when a host wires no `compose` adapter.
--
-- Everything here drives the public entry points, because the composer is only reachable
-- that way -- there is no "open the composer" API and there should not be one. What insert
-- mode does is not observable headless at all; that is interactive_spec's job.
local h = require("tests.helpers")

h.ui(120, 45)
h.cd_fixture("mktree")

-- Deliberately no `compose`: the built-in composer is the subject of this file.
local pending_pick -- the picker's callback, held so it answers on a later tick like a real one
require("codereview").setup({
  syntax = false,
  pick_target = function(cb)
    pending_pick = function()
      cb({ short = "janus · api", pane_id = "wV:p3", cwd = "/elsewhere" })
    end
  end,
})

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

---The floating window in this tab, if there is one. Identified by being floating rather
---than by a handle the plugin hands out: a test that asks the composer where it is would
---pass against a composer that never appeared.
---@return integer|nil
local function floating()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      return win
    end
  end
end

---Focus is restored on the tick after a note is accepted, so give it one. Bounded rather
---than fixed: returns as soon as focus settles, and spends the whole wait only when the
---assertion after it is going to fail anyway.
---@param win integer Window focus is expected to settle on
---@return integer focused
local function settled(win)
  vim.wait(200, function()
    return vim.api.nvim_get_current_win() == win
  end)
  return vim.api.nvim_get_current_win()
end

---Annotate the first line-kind row, from the diff.
---@param type_name? string
local function annotate_line(type_name)
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { row_of("line"), 0 })
  annotate.annotate(type_name or "bug")
end

describe("annotating with no composer wired", function()
  -- Stubbed rather than left alone: the built-in prompt blocks headless Neovim, so a
  -- regression here would hang the suite instead of failing it.
  local prompted = false
  local orig = vim.ui.input
  vim.ui.input = function()
    prompted = true
  end

  annotate_line()
  local win = floating()
  vim.ui.input = orig

  it("does not fall back to a prompt", function()
    assert.is_false(prompted)
  end)

  it("opens a composer window", function()
    assert.is_truthy(win, "no floating window was opened")
  end)

  it("puts the cursor in it", function()
    assert.same(win, vim.api.nvim_get_current_win())
  end)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end)

describe("submitting a note", function()
  queue.clear()
  annotate_line()
  local win = floating()

  -- Written into the buffer rather than typed: insert mode is unreachable headless, and
  -- what this is about is that whatever ends up in the composer ends up in the queue.
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "why the rename?", "", "no callers were updated" })
  h.feed("<C-s>")

  it("queues one annotation", function()
    assert.same(1, queue.count())
  end)

  it("keeps the note as written, blank lines and all", function()
    assert.same("why the rename?\n\nno callers were updated", queue.all()[1].note)
  end)

  it("closes the composer", function()
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)
end)

describe("abandoning a note", function()
  for _, key in ipairs({ "q", "<Esc>" }) do
    queue.clear()
    annotate_line()
    local win = floating()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "half a thought" })
    h.feed(key)

    it(("closes the composer on %s"):format(key), function()
      assert.is_false(vim.api.nvim_win_is_valid(win))
    end)

    it(("queues nothing on %s"):format(key), function()
      assert.same(0, queue.count())
    end)
  end
end)

-- Opening the composer by accident should cost nothing, and submitting an empty one is
-- how that gets undone by someone who has already forgotten which key aborts.
describe("submitting an empty note", function()
  queue.clear()
  local msgs, restore = h.capture_notify()
  annotate_line()
  local win = floating()
  h.feed("<C-s>")
  restore()

  it("queues nothing", function()
    assert.same(0, queue.count())
  end)

  it("closes the composer", function()
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("says nothing alarming about it", function()
    assert.is_false(h.notified(msgs, "Queued"), vim.inspect(msgs))
  end)
end)

-- Closing a float focuses whatever window Neovim recorded last, and the first window in
-- the tab when that one is gone -- which with the tree on the left is the tree. Submitting
-- is covered by the plugin's own restore; abandoning never reaches it, so the composer
-- owns that half itself.
describe("where focus lands afterwards", function()
  ---Open a window from inside the composer and close it again, then take focus back.
  ---
  ---This is what `<C-t>` does, and what `@` will. Without it these assertions pass on luck:
  ---the window Neovim recorded is still the diff, so its fallback happens to be right and a
  ---composer that restored nothing would look identical.
  local function picker_flicker()
    local composer_win = vim.api.nvim_get_current_win()
    local picker = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
      relative = "editor",
      width = 20,
      height = 4,
      row = 2,
      col = 2,
      style = "minimal",
    })
    vim.api.nvim_win_close(picker, true)
    vim.api.nvim_set_current_win(composer_win)
  end

  queue.clear()
  annotate_line()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a note" })
  picker_flicker()
  h.feed("<C-s>")
  local after_submit = settled(V.win)

  it("returns to the diff after submitting", function()
    assert.same(V.win, after_submit)
  end)

  annotate_line()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "second thoughts" })
  picker_flicker()
  h.feed("q")
  local after_abandon = settled(V.win)

  it("returns to the diff after abandoning", function()
    assert.same(V.win, after_abandon)
  end)
end)

describe("the composer's chrome", function()
  queue.clear()
  local row = row_of("line")
  local path = V.files[V.render.anchors[row].file].path
  annotate_line()
  local cfg_win = vim.api.nvim_win_get_config(floating())
  local title = cfg_win.title and tostring(cfg_win.title[1][1]) or ""
  local footer = cfg_win.footer and tostring(cfg_win.footer[1][1]) or ""
  h.feed("q")

  it("titles itself with the type and what is being annotated", function()
    assert.is_truthy(title:find("Bug", 1, true), title)
    assert.is_truthy(title:find(path, 1, true), title)
  end)

  it("names the submit, routing and abandon keys in the footer", function()
    assert.is_truthy(footer:find("^S", 1, true), footer)
    assert.is_truthy(footer:find("^T", 1, true), footer)
    assert.is_truthy(footer:find("q", 1, true), footer)
  end)

  -- The verb the caller passed, not a hardcoded one: an annotation is queued, not sent.
  it("names the submit key with the verb it was given", function()
    assert.is_truthy(footer:find("queue", 1, true), footer)
  end)
end)

describe("routing from the composer", function()
  queue.clear()
  annotate_line()
  local win = floating()
  h.feed("<C-t>")

  it("reaches the pick_target adapter", function()
    assert.is_truthy(pending_pick, "<C-t> never opened the picker")
  end)

  it("holds focus in the composer while the picker is open", function()
    assert.same(win, vim.api.nvim_get_current_win())
  end)

  -- Guarded so an unbound key fails these assertions instead of erroring out of the file
  -- and taking every test below it with it.
  if pending_pick then
    pending_pick()
  end

  local function footer_now()
    local cfg_win = vim.api.nvim_win_get_config(win)
    return cfg_win.footer and tostring(cfg_win.footer[1][1]) or ""
  end

  it("comes back to the composer, not the diff underneath", function()
    assert.same(win, vim.api.nvim_get_current_win())
    assert.is_true(vim.api.nvim_win_is_valid(win))
  end)

  it("shows the chosen target in the footer", function()
    assert.is_truthy(footer_now():find("janus", 1, true), footer_now())
  end)

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a routed note" })
  h.feed("<C-s>")

  it("still queues the note it was holding", function()
    assert.same(1, queue.count())
    assert.same("a routed note", queue.all()[1].note)
  end)
end)

-- Comes last: it reconfigures the plugin. The guarantee is that shipping a composer took
-- nothing away from a host that already had one.
describe("with a composer wired", function()
  local seen
  require("codereview").setup({
    syntax = false,
    compose = function(ctx, on_accept, composer_label)
      seen = { ctx = ctx, label = composer_label }
      on_accept(nil, "from the host's composer")
    end,
  })
  queue.clear()
  annotate_line()

  it("does not open the built-in composer", function()
    assert.is_nil(floating())
  end)

  it("queues what the host's composer collected", function()
    assert.same(1, queue.count())
    assert.same("from the host's composer", queue.all()[1].note)
  end)

  -- Field by field rather than by shape: an adapter written against the old context has to
  -- keep working, and that is only true if nothing was added, renamed or dropped.
  it("hands it the context it has always been handed", function()
    assert.same("none", seen.ctx.scope)
    assert.same("queue", seen.label)
    assert.is_truthy(seen.ctx.label)
    assert.is_truthy(seen.ctx.rel_path)
    assert.is_truthy(seen.ctx.file_path)
    assert.same(V.win, seen.ctx.origin_win)
  end)
end)
