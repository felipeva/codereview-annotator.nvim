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
local sent = {} -- what reached the delivery adapter
-- What the target picker answers with next. Reassigned by the cases that need the batch's
-- target and a note's target to be different things.
local pick_answer = { short = "janus · api", pane_id = "wV:p3", cwd = "/elsewhere" }
require("codereview").setup({
  syntax = false,
  pick_target = function(cb)
    pending_pick = function()
      cb(pick_answer)
    end
  end,
  send = function(text, to)
    sent[#sent + 1] = { text = text, target = to }
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
local drafts = require("codereview.drafts")
local annotate = require("codereview.annotate")

view.open("branch")
local V = view.current()
queue.clear()

---Start a block from nothing.
---
---Drafts outlive a composer on purpose, so a block that abandons a note leaves one behind
---for the next block to open into. Anything that assumes an empty composer has to say so,
---exactly as it already says it wants an empty queue.
local function reset()
  queue.clear()
  drafts.clear()
end

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

---Annotate a line in a different file from the one `annotate_line` lands on.
---@return string path The file annotated
local function annotate_other_file()
  local first = V.render.anchors[row_of("line")].file
  for row = 1, vim.api.nvim_buf_line_count(V.buf) do
    local a = V.render.anchors[row]
    if a and a.kind == "line" and a.file ~= first then
      vim.api.nvim_set_current_win(V.win)
      vim.api.nvim_win_set_cursor(V.win, { row, 0 })
      annotate.annotate("bug")
      return V.files[a.file].path
    end
  end
  error("the render has only one file")
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
  reset()
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
    reset()
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
  reset()
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

  reset()
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
  reset()
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
  reset()
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
  reset()
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
  reset()
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
    reset()
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
  reset()
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
  reset()
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
  reset()
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
  reset()
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
  reset()
  file_answer = { path = "docs/guide.md", first = 3 }
  annotate_line()
  h.feed("icompare with @<Esc>")
  h.feed("<C-s>")

  it("queues the note with the reference intact", function()
    assert.same(1, queue.count())
    assert.same("compare with @docs/guide.md#L3", queue.all()[1].note)
  end)
end)

-- A note you walked away from is worth more than the keystrokes it took, which is the whole
-- argument for keeping one.
describe("abandoning a note with text in it", function()
  reset()
  annotate_line()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "half a thought" })
  h.feed("q")

  annotate_line()
  local reopened = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local composer_win = floating()
  h.feed("q")

  it("offers the text back the next time that file is annotated", function()
    assert.same({ "half a thought" }, reopened)
  end)

  it("queued nothing on the way", function()
    assert.same(0, queue.count())
  end)

  if composer_win and vim.api.nvim_win_is_valid(composer_win) then
    vim.api.nvim_win_close(composer_win, true)
  end
end)

describe("a restored draft", function()
  local function footer_of(win)
    local cfg_win = vim.api.nvim_win_get_config(win)
    return cfg_win.footer and tostring(cfg_win.footer[1][1]) or ""
  end

  reset()
  annotate_line()
  local fresh_footer = footer_of(floating())
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "half a thought" })
  h.feed("q")

  local msgs, restore = h.capture_notify()
  annotate_line()
  restore()
  local win = floating()
  local restored_footer = footer_of(win)

  it("is not advertised when there is nothing to discard", function()
    assert.is_falsy(fresh_footer:find("^D", 1, true), fresh_footer)
  end)

  it("says that it restored one", function()
    assert.is_true(h.notified(msgs, "Draft restored"), vim.inspect(msgs))
  end)

  it("offers the discard key while there is one", function()
    assert.is_truthy(restored_footer:find("^D", 1, true), restored_footer)
  end)

  h.feed("<C-d>")
  local emptied = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local discarded_footer = footer_of(win)

  it("empties the composer when discarded", function()
    assert.same({ "" }, emptied)
  end)

  it("stops offering the discard key once there is nothing to discard", function()
    assert.is_falsy(discarded_footer:find("^D", 1, true), discarded_footer)
  end)

  -- The point of discarding: it is gone, not merely off screen.
  h.feed("q")
  annotate_line()
  local reopened = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local last = floating()
  h.feed("q")

  it("does not come back after being discarded", function()
    assert.same({ "" }, reopened)
  end)

  if last and vim.api.nvim_win_is_valid(last) then
    vim.api.nvim_win_close(last, true)
  end
end)

describe("a draft picked up and put down again", function()
  reset()
  annotate_line()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first thought" })
  h.feed("q")

  annotate_line() -- restores it
  h.feed("q") -- and abandons it again, untouched

  annotate_line()
  local twice = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local win = floating()
  h.feed("q")

  it("is still there the third time", function()
    assert.same({ "first thought" }, twice)
  end)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end)

describe("a draft whose note gets submitted", function()
  reset()
  annotate_line()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "not finished yet" })
  h.feed("q")

  annotate_line() -- restores it
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "finished now" })
  h.feed("<C-s>")

  annotate_line()
  local after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local win = floating()
  h.feed("q")

  it("queued the note that was actually sent", function()
    assert.same(1, queue.count())
    assert.same("finished now", queue.all()[1].note)
  end)

  -- A note you have already made must never come back as a draft.
  it("leaves nothing behind to restore", function()
    assert.same({ "" }, after)
  end)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end)

-- A note about one file surfacing while you annotate another would be worse than losing it.
describe("a draft belonging to another file", function()
  reset()
  annotate_line()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "about the first file" })
  h.feed("q")

  annotate_other_file()
  local other = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  h.feed("q")

  annotate_line()
  local original = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local win = floating()
  h.feed("q")

  it("does not surface on a different file", function()
    assert.same({ "" }, other)
  end)

  it("is still waiting on the file it belongs to", function()
    assert.same({ "about the first file" }, original)
  end)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end)

-- Annotating a file in the review and capturing it from an ordinary buffer are the same
-- thought about the same code. They meet the same draft, which is only true because the key
-- is the absolute path -- the one name both paths already agree on.
describe("a draft started in the review and reopened from the buffer", function()
  reset()
  local path = V.files[V.render.anchors[row_of("line")].file].path
  annotate_line()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "same thought, either way" })
  h.feed("q")

  vim.cmd("tabedit " .. vim.fn.fnameescape(path))
  require("codereview").annotate("bug")
  local captured = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local win = floating()
  h.feed("q")
  vim.cmd("tabclose")

  it("is offered back to capture, not just to the review", function()
    assert.same({ "same thought, either way" }, captured)
  end)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end)

-- The two below write the store directly. Neither state can be reached through the
-- composer: you cannot corrupt a file by annotating, and you cannot wait a week.
describe("a draft store that cannot be read", function()
  reset()
  vim.fn.mkdir(vim.fs.dirname(drafts.path()), "p")
  vim.fn.writefile({ "{ this is not json" }, drafts.path())

  local msgs, restore = h.capture_notify()
  annotate_line()
  local opened = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  restore()
  local win = floating()
  h.feed("q")

  -- Failing here would cost the note you were about to write in order to report one you
  -- had already abandoned, which is the wrong way round.
  it("opens an empty composer instead of erroring", function()
    assert.is_truthy(win, "the composer never opened")
    assert.same({ "" }, opened)
  end)

  it("says nothing about a draft", function()
    assert.is_false(h.notified(msgs, "Draft restored"), vim.inspect(msgs))
  end)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end)

describe("a draft old enough to have aged out", function()
  reset()
  annotate_line()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "long forgotten" })
  h.feed("q")

  -- Backdate what was just written, rather than wait a week for it.
  local raw = vim.json.decode(table.concat(vim.fn.readfile(drafts.path()), "\n"))
  for _, entry in pairs(raw.drafts) do
    entry.at = os.time() - 30 * 24 * 60 * 60
  end
  vim.fn.writefile({ vim.json.encode(raw) }, drafts.path())

  annotate_line()
  local opened = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local win = floating()
  h.feed("q")

  it("is pruned rather than restored", function()
    assert.same({ "" }, opened)
  end)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end)

--- Immediate sends ------------------------------------------------------------

---@param win integer
---@return string
local function footer_of(win)
  local cfg_win = vim.api.nvim_win_get_config(win)
  return cfg_win.footer and tostring(cfg_win.footer[1][1]) or ""
end

---Start an immediate send from an ordinary buffer, in a tab of its own.
---
---Through the public capture seam, because that is the only way in: there is no "open the
---composer" API and no sibling entry point for sending.
---@param answer table|nil What the target picker answers with
---@return integer origin The window it was started from
local function send_from_buffer(answer)
  local path = V.files[V.render.anchors[row_of("line")].file].path
  vim.cmd("tabedit " .. vim.fn.fnameescape(path))
  local origin = vim.api.nvim_get_current_win()
  pending_pick = nil
  pick_answer = answer
  require("codereview").annotate("bug", nil, { immediate = true })
  return origin
end

-- The note carries its own target here, so the footer has to name *that* one and `^T` has
-- to change it. Both are wrong on the host's equivalent path today: the footer names the
-- batch's target while the note goes somewhere else entirely.
describe("the composer on an immediate send", function()
  reset()
  local before = #sent

  -- A batch target first, and a different one, so a footer naming the wrong choice is
  -- visible rather than coincidentally right.
  pick_answer = { short = "janus · api", pane_id = "wV:p3", cwd = "/elsewhere" }
  view.pick_target()
  if pending_pick then
    pending_pick()
  end

  local origin = send_from_buffer({ short = "shell", pane_id = "wV:p7", cwd = vim.uv.cwd() })

  it("asks for a target before the composer opens", function()
    assert.is_nil(floating(), "the composer opened before a target was chosen")
    assert.is_truthy(pending_pick, "the target picker was never opened")
  end)

  if pending_pick then
    pending_pick()
  end
  local win = floating()
  local chosen_footer = win and footer_of(win) or ""

  it("opens the composer once a target is chosen", function()
    assert.is_truthy(win, "no composer window was opened")
  end)

  it("names the note's target, not the batch's", function()
    assert.is_truthy(chosen_footer:find("shell", 1, true), chosen_footer)
    assert.is_falsy(chosen_footer:find("janus", 1, true), chosen_footer)
  end)

  it("names the submit key with the verb this path passes", function()
    assert.is_truthy(chosen_footer:find("send", 1, true), chosen_footer)
  end)

  pending_pick = nil
  pick_answer = { short = "third", pane_id = "wV:p9", cwd = vim.uv.cwd() }
  h.feed("<C-t>")
  if pending_pick then
    pending_pick()
  end
  local rerouted_footer = win and footer_of(win) or ""

  it("reroutes this note when ^T is pressed, and says where to", function()
    assert.is_truthy(rerouted_footer:find("third", 1, true), rerouted_footer)
  end)

  it("leaves the batch pointing where it was", function()
    assert.same("janus · api", view.target_label())
  end)

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "send this one now" })
  h.feed("<C-s>")

  it("delivers to the target the note was rerouted to", function()
    assert.same(before + 1, #sent)
    assert.same("third", sent[#sent].target.short)
    assert.is_truthy(sent[#sent].text:find("send this one now", 1, true), sent[#sent].text)
  end)

  it("queues nothing on the way", function()
    assert.same(0, queue.count())
  end)

  vim.cmd("tabclose")
end)

-- Walking away from an immediate send costs no more than walking away from a queued one.
describe("abandoning an immediate send", function()
  reset()
  local before = #sent
  local origin = send_from_buffer({ short = "shell", pane_id = "wV:p7", cwd = vim.uv.cwd() })
  if pending_pick then
    pending_pick()
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "half a thought, sent nowhere" })
  h.feed("q")
  local landed = settled(origin)

  it("delivers nothing", function()
    assert.same(before, #sent)
  end)

  it("returns focus to the window it was started from", function()
    assert.same(origin, landed)
  end)

  require("codereview").annotate("bug", nil, { immediate = true })
  if pending_pick then
    pending_pick()
  end
  local reopened = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local win = floating()
  h.feed("q")

  it("keeps what was written as a draft", function()
    assert.same({ "half a thought, sent nowhere" }, reopened)
  end)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  vim.cmd("tabclose")
end)

-- Reconfigures, so it comes after everything that wants a picker. The plugin ships none:
-- every config already has one, and `@` staying a literal `@` is what "the composer is
-- still fully usable without it" means.
describe("with no file picker wired", function()
  require("codereview").setup({ syntax = false })
  reset()
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
  reset()
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

-- Routing is part of the compose contract, not a private arrangement with the composer the
-- plugin ships. A host composer has to be able to name this note's target and change it
-- too, or "the footer names where the note goes" is only true of one composer.
describe("a host composer on an immediate send", function()
  local seen
  local named = {}
  local host_sent = {}
  require("codereview").setup({
    syntax = false,
    pick_target = function(cb)
      pending_pick = function()
        cb(pick_answer)
      end
    end,
    send = function(text, to)
      host_sent[#host_sent + 1] = { text = text, target = to }
    end,
    compose = function(ctx, on_accept, composer_label)
      seen = { ctx = ctx, label = composer_label }
      -- A note joining the queue is routed by the batch, so it is handed nothing: a host
      -- composer written before any of this keeps working untouched.
      if not ctx.routing then
        on_accept(nil, "queued through the host's composer")
        return
      end
      named[#named + 1] = ctx.routing.label()
      pick_answer = { short = "elsewhere", pane_id = "wV:p8", cwd = vim.uv.cwd() }
      ctx.routing.pick(function()
        named[#named + 1] = ctx.routing.label()
        on_accept(nil, "sent through the host's composer")
      end)
      -- The picker answers on a later tick, as a real one does.
      pending_pick()
    end,
  })

  reset()
  send_from_buffer({ short = "first", pane_id = "wV:p1", cwd = vim.uv.cwd() })
  if pending_pick then
    pending_pick()
  end

  it("passes the `send` verb rather than `queue`", function()
    assert.same("send", seen.label)
  end)

  it("hands it the rest of the context unchanged", function()
    assert.same("none", seen.ctx.scope)
    assert.is_truthy(seen.ctx.label)
    assert.is_truthy(seen.ctx.rel_path)
    assert.is_truthy(seen.ctx.file_path)
    assert.is_truthy(seen.ctx.origin_win)
  end)

  it("lets it name the target before and after rerouting", function()
    assert.same({ "first", "elsewhere" }, named)
  end)

  it("delivers where the host composer rerouted it", function()
    assert.same(1, #host_sent)
    assert.same("elsewhere", host_sent[1].target.short)
    assert.is_truthy(host_sent[1].text:find("sent through the host's composer", 1, true), host_sent[1].text)
  end)

  it("queues nothing", function()
    assert.same(0, queue.count())
  end)

  require("codereview").annotate("bug")

  it("hands no routing to a note that joins the queue", function()
    assert.is_nil(seen.ctx.routing)
    assert.same(1, queue.count())
    assert.same("queued through the host's composer", queue.all()[1].note)
  end)

  vim.cmd("tabclose")
end)
