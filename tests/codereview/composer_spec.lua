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
local file_answer -- what the file picker answers with; nil is a cancel
local file_picks = 0 -- how many times it was opened at all
local file_pick_hook -- runs inside the picker, before it answers
require("codereview").setup({
  syntax = false,
  pick_target = function(cb)
    pending_pick = function()
      cb({ short = "janus · api", pane_id = "wV:p3", cwd = "/elsewhere" })
    end
  end,
  -- Answers inline. A real picker takes focus and gives it back; `file_pick_hook` is how a
  -- test makes it behave like one -- moving the cursor, say -- before it answers.
  pick_file = function(cb)
    file_picks = file_picks + 1
    if file_pick_hook then
      file_pick_hook()
    end
    cb(file_answer)
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

describe("referencing a file", function()
  queue.clear()
  file_answer = { path = "apps/web/src/index.lua" }
  annotate_line()
  local composer_win = floating()
  h.feed("i@")
  local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  -- Closed through the API, not by feeding `q`: abandoning has its own test, and a stray
  -- `q` that arrives after the composer has gone reaches the review buffer, where it
  -- closes the whole review and takes every assertion below with it.
  h.feed("<Esc>")
  if composer_win and vim.api.nvim_win_is_valid(composer_win) then
    vim.api.nvim_win_close(composer_win, true)
  end

  it("opens the file picker", function()
    assert.is_true(file_picks > 0, "pick_file was never called")
  end)

  -- Trailing space because you are mid-sentence: a reference is something you write *into*
  -- a note, not the end of one.
  it("splices a reference to the chosen file", function()
    assert.same("@apps/web/src/index.lua ", line)
  end)
end)

-- A real picker takes focus and the cursor with it, and can leave the composer's cursor
-- anywhere at all by the time it answers. The splice belongs where the `@` was typed.
describe("referencing a file mid-sentence", function()
  queue.clear()
  file_answer = { path = "docs/guide.md" }
  annotate_line()
  local composer_win = floating()

  -- A picker that moves the cursor before it answers, which any real one does by taking
  -- focus. What gets spliced must not depend on where it left things.
  local moved = false
  file_pick_hook = function()
    vim.api.nvim_win_set_cursor(composer_win, { 1, 0 })
    moved = true
  end

  -- One feed, not two: `nvim_feedkeys` does not reliably leave the editor in insert mode
  -- between calls, so a second feed would arrive in normal mode and never reach the
  -- insert-mode `@`.
  h.feed("icompare with @")
  local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  file_pick_hook = nil
  h.feed("<Esc>")
  if composer_win and vim.api.nvim_win_is_valid(composer_win) then
    vim.api.nvim_win_close(composer_win, true)
  end

  it("ran a picker that moved the cursor", function()
    assert.is_true(moved)
  end)

  it("splices where the @ was typed, not where the cursor ended up", function()
    assert.same("compare with @docs/guide.md ", line)
  end)
end)

-- The form has to be the one the payload renders for an annotation's own lines, or the
-- coupling this work exists to remove has simply moved: the composer would be authoring a
-- syntax the module that reads it never produces. Note the single line collapses to `#L12`
-- rather than `#L12-12`.
describe("referencing lines in a file", function()
  for _, case in ipairs({
    { answer = { path = "docs/guide.md", first = 12, last = 20 }, expect = "@docs/guide.md#L12-20 " },
    { answer = { path = "docs/guide.md", first = 12, last = 12 }, expect = "@docs/guide.md#L12 " },
    { answer = { path = "docs/guide.md" }, expect = "@docs/guide.md " },
  }) do
    queue.clear()
    file_answer = case.answer
    annotate_line()
    local composer_win = floating()
    h.feed("i@")
    local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
    h.feed("<Esc>")
    if composer_win and vim.api.nvim_win_is_valid(composer_win) then
      vim.api.nvim_win_close(composer_win, true)
    end

    it(("splices %s"):format(case.expect), function()
      assert.same(case.expect, line)
    end)
  end
end)

-- Notes contain email addresses. An `@` that continues a word is a character, not a
-- request for a picker.
describe("an @ that does not begin a word", function()
  queue.clear()
  file_answer = { path = "docs/guide.md" }
  local before = file_picks
  annotate_line()
  local composer_win = floating()
  h.feed("iask someone@example.com about this")
  local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  h.feed("<Esc>")
  if composer_win and vim.api.nvim_win_is_valid(composer_win) then
    vim.api.nvim_win_close(composer_win, true)
  end

  it("does not open the picker", function()
    assert.same(before, file_picks)
  end)

  it("leaves the address as typed", function()
    assert.same("ask someone@example.com about this", line)
  end)
end)

-- A picker is entitled to answer with an absolute path. What lands in the note should read
-- the way every other reference in the batch reads.
describe("a picker that answers with an absolute path", function()
  queue.clear()
  file_answer = { path = vim.fs.joinpath(vim.uv.cwd(), "docs/guide.md"), first = 3 }
  annotate_line()
  local composer_win = floating()
  h.feed("i@")
  local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  h.feed("<Esc>")
  if composer_win and vim.api.nvim_win_is_valid(composer_win) then
    vim.api.nvim_win_close(composer_win, true)
  end

  it("splices it relative to the working directory", function()
    assert.same("@docs/guide.md#L3 ", line)
  end)
end)

-- Outside the tree there is nothing to be relative to, and an absolute path is the only
-- name the file has.
describe("a picker that answers with a path outside the tree", function()
  queue.clear()
  file_answer = { path = "/etc/hosts" }
  annotate_line()
  local composer_win = floating()
  h.feed("i@")
  local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  h.feed("<Esc>")
  if composer_win and vim.api.nvim_win_is_valid(composer_win) then
    vim.api.nvim_win_close(composer_win, true)
  end

  it("leaves it absolute", function()
    assert.same("@/etc/hosts ", line)
  end)
end)

-- The sentinel is written before the picker opens precisely so that this is what cancelling
-- costs you: nothing.
describe("cancelling the file picker", function()
  queue.clear()
  file_answer = nil
  annotate_line()
  local composer_win = floating()
  h.feed("ilook at @")
  local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  h.feed("<Esc>")
  if composer_win and vim.api.nvim_win_is_valid(composer_win) then
    vim.api.nvim_win_close(composer_win, true)
  end

  it("leaves the literal @ the user typed, and nothing else", function()
    assert.same("look at @", line)
  end)
end)

describe("a note carrying a reference", function()
  queue.clear()
  file_answer = { path = "docs/guide.md", first = 3 }
  annotate_line()
  h.feed("icompare with @<Esc>")
  h.feed("<C-s>")

  it("queues the note with the reference intact", function()
    assert.same(1, queue.count())
    assert.same("compare with @docs/guide.md#L3", queue.all()[1].note)
  end)
end)

-- Reconfigures, so it comes after everything that wants a picker. The plugin ships none:
-- every config already has one, and `@` staying a literal `@` is what "the composer is
-- still fully usable without it" means.
describe("with no file picker wired", function()
  require("codereview").setup({ syntax = false })
  queue.clear()
  annotate_line()
  local composer_win = floating()
  h.feed("ilook at @")
  local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  h.feed("<Esc>")
  if composer_win and vim.api.nvim_win_is_valid(composer_win) then
    vim.api.nvim_win_close(composer_win, true)
  end

  it("inserts a literal @ and opens nothing", function()
    assert.same("look at @", line)
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
