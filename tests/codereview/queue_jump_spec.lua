-- Jumping from the queue float to the annotation under the cursor.
--
-- The float lists a queue that is shared with the capture path and is reachable with no
-- review view open. With no view, an entry's file is opened in place of the diff. Several
-- entries have nowhere to go at all, and those are three different failures with three
-- different remedies -- nothing, change scope, find the file -- which is why the messages
-- are asserted apart rather than merely counted.
local h = require("tests.helpers")

-- Deliberately short: whether a landing row is *centered* is only observable when the diff
-- outruns the window and there is somewhere else the cursor could have been put.
h.ui(100, 20)
h.cd_fixture("mkfixture")

require("codereview").setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "a note")
  end,
  send = function() end,
})

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")

view.open("branch")
local V = view.current()
queue.clear()

---A row carrying an anchor of `kind`, scanned in buffer order.
---
---In buffer order rather than through `pairs` over the anchor map: which row an assertion
---is about is the whole point here, and `pairs` would pick an arbitrary one.
---@param kind "file"|"line"
---@param path string|nil Restrict to one file
---@param last boolean|nil Scan from the bottom instead
---@return integer|nil
local function row_of(kind, path, last)
  local from, to, step = 1, vim.api.nvim_buf_line_count(V.buf), 1
  if last then
    from, to, step = to, from, -1
  end
  for row = from, to, step do
    local a = V.render.anchors[row]
    if a and a.kind == kind and (not path or V.files[a.file].path == path) then
      return row
    end
  end
end

---@param row integer
---@return integer row
local function annotate_row(row)
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
  annotate.annotate("bug")
  return row
end

---Park the diff at the top, so a jump is a move rather than a coincidence.
local function park()
  vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
  vim.api.nvim_win_call(V.win, function()
    vim.cmd("normal! zt")
  end)
end

local function fresh_queue()
  queue.clear()
  if view.current() then
    view.paint()
  end
end

---@return integer win
local function open_float()
  view.review_queue()
  return vim.api.nvim_get_current_win()
end

---Put the float's cursor inside the numbered entry.
---
---An entry's number no longer sits at column zero: it is drawn behind the reserved gutter
---and the bar that runs down every row the entry owns, so the row is found by that prefix.
---@param win integer
---@param index integer The number the float printed against the entry
---@param offset integer|nil Rows below the heading, for the "cursor is inside it" case
local function cursor_on(win, index, offset)
  local bar = vim.pesc(require("codereview.config").get().icons.change_bar)
  local buf = vim.api.nvim_win_get_buf(win)
  for row, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if text:match("^%s*" .. bar .. "%s*" .. index .. "  ") then
      vim.api.nvim_win_set_cursor(win, { row + (offset or 0), 0 })
      return row
    end
  end
  error(("entry %d is not listed in the float"):format(index))
end

---@param win integer
---@return string
local function footer(win)
  local cfg = vim.api.nvim_win_get_config(win)
  return cfg.footer and tostring(cfg.footer[1][1]) or ""
end

---What `?` lists in the focused float, read off the notification it raises.
---@return string
local function key_listing()
  local listing
  local notify = vim.notify
  vim.notify = function(msg)
    listing = msg
  end
  h.feed("?")
  vim.notify = notify
  return listing or ""
end

---What each unavailable case said, in the order the cases run.
local said = {}

---Press the jump key in the focused float and collect what it reported.
---@return string[] messages
local function jump()
  local messages, restore = h.capture_notify()
  h.feed("<CR>")
  restore()
  return messages
end

describe("jumping to a line annotation", function()
  fresh_queue()
  local target = annotate_row(row_of("line", nil, true))
  park()
  local win = open_float()
  cursor_on(win, 1)
  jump()

  local height = vim.api.nvim_win_get_height(V.win)
  local landed = vim.api.nvim_win_get_cursor(V.win)[1]
  local winline = vim.api.nvim_win_call(V.win, vim.fn.winline)

  -- Guards the test itself: a target already on screen would pass the centering assertion
  -- with nothing scrolling it.
  it("is a jump that has to scroll", function()
    assert.is_true(target > height, ("row %d, window height %d"):format(target, height))
  end)

  it("closes the float", function()
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.is_nil(V.queue_win)
  end)

  it("leaves focus in the diff", function()
    assert.same(V.win, vim.api.nvim_get_current_win())
  end)

  it("lands on the line the annotation is about", function()
    assert.same(target, landed)
  end)

  it("centers it", function()
    assert.is_true(
      math.abs(winline - math.ceil(height / 2)) <= 1,
      ("cursor on screen row %d of %d"):format(winline, height)
    )
  end)
end)

describe("the entry the cursor is inside", function()
  fresh_queue()
  local first = annotate_row(row_of("line"))
  local second = annotate_row(row_of("line", nil, true))
  park()
  local win = open_float()
  -- Below the heading rather than on it: the float resolves an entry the same way dropping
  -- one does, which is the nearest heading at or above the cursor.
  cursor_on(win, 2, 1)
  jump()
  local landed = vim.api.nvim_win_get_cursor(V.win)[1]

  it("is the one the cursor was inside, not the first one listed", function()
    assert.is_true(first ~= second)
    assert.same(second, landed)
  end)
end)

describe("jumping to a whole-file annotation", function()
  fresh_queue()
  local header = annotate_row(row_of("file", "src/newname.lua"))
  park()
  local win = open_float()
  cursor_on(win, 1)
  jump()

  it("lands on that file's header", function()
    assert.same(header, vim.api.nvim_win_get_cursor(V.win)[1])
  end)
end)

describe("jumping into a collapsed file", function()
  fresh_queue()
  local path = "src/main.lua"
  annotate_row(row_of("line", path))

  -- Marking it reviewed collapses it, so the row the annotation is about stops being
  -- rendered at all -- the case where landing on the header would be landing on nothing.
  vim.api.nvim_win_set_cursor(V.win, { row_of("file", path), 0 })
  view.toggle_reviewed()
  local while_collapsed = row_of("line", path)

  park()
  local win = open_float()
  cursor_on(win, 1)
  jump()
  local landed = vim.api.nvim_win_get_cursor(V.win)[1]
  local reopened = row_of("line", path)

  -- Put it back, so the cases below see the diff the ones above did.
  vim.api.nvim_win_set_cursor(V.win, { row_of("file", path), 0 })
  view.toggle_reviewed()

  it("had nothing to land on before the jump", function()
    assert.is_nil(while_collapsed)
  end)

  it("expands the file", function()
    assert.is_true(V.expanded[path])
    assert.is_truthy(reopened)
  end)

  it("lands on the code rather than the header", function()
    assert.same(reopened, landed)
  end)
end)

describe("jumping to a stale annotation", function()
  fresh_queue()
  local at_capture = row_of("line", nil, true)
  local path = V.files[V.render.anchors[at_capture].file].path
  annotate_row(at_capture)
  queue.all()[1].stale = true

  -- Collapsing a file above it moves the row this annotation is drawn on while leaving the
  -- anchor it is keyed by alone. What the jump resolves against has to be the diff now, not
  -- a row that was true when the note was written.
  local above = "src/main.lua"
  vim.api.nvim_win_set_cursor(V.win, { row_of("file", above), 0 })
  view.toggle_reviewed()
  local moved = row_of("line", path, true)

  park()
  local win = open_float()
  cursor_on(win, 1)
  jump()
  local landed = vim.api.nvim_win_get_cursor(V.win)[1]

  vim.api.nvim_win_set_cursor(V.win, { row_of("file", above), 0 })
  view.toggle_reviewed()

  it("is drawn somewhere else than when it was captured", function()
    assert.is_true(moved ~= at_capture, ("row %d either way"):format(moved))
  end)

  it("still goes wherever its anchor now points", function()
    assert.same(moved, landed)
  end)
end)

describe("the keys the float already had", function()
  -- `<C-t>` and `<C-s>` are focus_spec's, which drives both across the asynchronous
  -- picker; what is left to pin here is that none of them has stopped being advertised.
  -- The footer holds the few a reviewer reaches for, and `?` lists every one.
  fresh_queue()
  annotate_row(row_of("line"))
  annotate_row(row_of("line", nil, true))
  local win = open_float()
  local advertised = footer(win)
  local listing = key_listing()

  cursor_on(win, 2)
  h.feed("x")
  local left = queue.count()
  local open_after_drop = vim.api.nvim_win_is_valid(win)
  h.feed("q")

  it("advertises the jump alongside them", function()
    for _, key in ipairs({ "x drop", "^S submit", "? keys" }) do
      assert.is_truthy(advertised:find(key, 1, true), advertised)
    end
    for _, key in ipairs({ "^T ", "<CR> ", "x ", "^S ", "q " }) do
      assert.is_truthy(listing:find("  " .. key, 1, true), listing)
    end
    assert.is_truthy(listing:find("Jump", 1, true), listing)
  end)

  it("still drops the entry under the cursor", function()
    assert.same(1, left)
  end)

  it("keeps the float open after a drop", function()
    assert.is_true(open_after_drop)
  end)

  it("still closes on q", function()
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)
end)

-- The float's drop goes through the diff's own drop now, which writes with or without a
-- view. With one open it has to paint as well: the diff's note and the file tree's
-- **state** mark are both drawn from the queue, and a drop that skipped the paint would
-- leave both on screen for an entry that is gone.
describe("a drop from the float with a review view open", function()
  fresh_queue()
  local row = annotate_row(row_of("line"))
  local path = V.files[V.render.anchors[row].file].path
  local annotated = require("codereview.config").get().icons.annotated

  ---What the file tree says on the row of the annotated file.
  local function tree_mark()
    local prow = V.panel_render.file_row[assert(h.file_index(V, path))]
    local line = vim.api.nvim_buf_get_lines(V.panel_buf, prow - 1, prow, false)[1]
    return vim.trim(line):sub(1, #annotated)
  end

  local notes_before, mark_before = #h.virt_marks(V), tree_mark()
  local win = open_float()
  cursor_on(win, 1)
  h.feed("x")
  local notes_after, mark_after = #h.virt_marks(V), tree_mark()

  it("starts with the note on the diff and the file marked annotated", function()
    assert.same(1, notes_before)
    assert.same(annotated, mark_before)
  end)

  it("takes the note off the diff", function()
    assert.same(0, queue.count())
    assert.same(0, notes_after)
  end)

  it("takes the annotated mark off the file tree", function()
    assert.are_not.same(annotated, mark_after)
  end)
end)

describe("a bare note", function()
  fresh_queue()
  -- An unnamed buffer has nothing on disk to anchor to, which is the one kind that will
  -- never have a destination.
  vim.cmd("tabnew")
  require("codereview").annotate("bug")
  vim.cmd("tabclose")

  park()
  local win = open_float()
  cursor_on(win, 1)
  local messages = jump()
  said[#said + 1] = messages[1]
  local still_open = vim.api.nvim_win_is_valid(win)
  h.feed("q")

  it("queued a note with no file behind it", function()
    assert.same("note", queue.all()[1].kind)
  end)

  it("says there is nowhere to go", function()
    assert.same(1, #messages)
    assert.is_true(h.notified(messages, "nowhere to jump"), messages[1])
  end)

  it("leaves the float open", function()
    assert.is_true(still_open)
  end)
end)

describe("an annotation whose file is outside the scope", function()
  fresh_queue()
  annotate_row(row_of("line", "src/main.lua"))
  -- Only `src/routes.lua` is staged, so the annotated file is genuinely not in the review
  -- any more -- and changing scope is the only thing that would bring it back.
  view.set_scope("staged")

  park()
  local win = open_float()
  cursor_on(win, 1)
  local messages = jump()
  said[#said + 1] = messages[1]
  local still_open = vim.api.nvim_win_is_valid(win)

  it("really is out of scope", function()
    assert.is_nil(h.file_index(V, "src/main.lua"))
  end)

  it("names the file and blames the scope", function()
    assert.same(1, #messages)
    assert.is_true(h.notified(messages, "src/main.lua"), messages[1])
    assert.is_true(h.notified(messages, "scope"), messages[1])
  end)

  it("leaves the float open", function()
    assert.is_true(still_open)
  end)
end)

-- With no review view there is no diff to land in, so the float opens the file itself, the
-- way the diff's own `<CR>` does. Every case below runs with the view closed.
local root = vim.uv.fs_realpath(V.root)

---Leave `path` loaded with its cursor parked on `line`, then go back to the tab that was
---current.
---
---A buffer opened again lands where it was last left, and a fresh tab lands on line 1. So
---without this, a jump that ignored the entry's line would still land on line 1 for a
---whole-file entry, and that case would pass with nothing tested.
---@param path string
---@param line integer
local function parked_at(path, line)
  vim.cmd("tabedit " .. vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd("tabclose")
end

---Press `<CR>` in the float on the first entry, and report where the reviewer is after.
---@return { messages: string[], tabs: integer, name: string, line: integer, cwd: string, float_open: boolean }
local function jump_from_float()
  local tabs = vim.fn.tabpagenr("$")
  local win = open_float()
  cursor_on(win, 1)
  local messages = jump()
  local seen = {
    messages = messages,
    tabs = vim.fn.tabpagenr("$") - tabs,
    name = vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) or "",
    line = vim.api.nvim_win_get_cursor(0)[1],
    -- As Neovim reports it, not resolved here: the expected side is the realpath.
    cwd = vim.fn.getcwd(),
    float_open = vim.api.nvim_win_is_valid(win),
  }
  if seen.float_open then
    vim.api.nvim_win_close(win, true)
  elseif seen.tabs == 1 then
    vim.cmd("tabclose")
  end
  return seen
end

describe("a line annotation with no review view open", function()
  fresh_queue()
  -- Back from the staged scope the case above left, which does not hold this file.
  view.set_scope("branch")
  annotate_row(row_of("line", "src/main.lua", true))
  view.close()
  local entry = queue.all()[1]
  local abs = vim.fs.joinpath(root, entry.path)
  -- Elsewhere than the recorded line, so landing there is the jump's doing.
  parked_at(abs, entry.first == 1 and 3 or 1)
  -- From a tab rooted somewhere else, so a rooted tab is the jump's doing too: a new tab
  -- inherits its parent's directory. Inside the checkout, because the queue the float lists
  -- is the one of the checkout the reviewer stands in.
  vim.cmd("tabnew")
  vim.cmd("tcd " .. vim.fn.fnameescape(vim.fs.joinpath(root, "src")))
  local seen = jump_from_float()
  vim.cmd("tabclose")

  it("is no review view and a line that is not the first", function()
    assert.is_nil(view.current())
    assert.is_true(entry.first > 1, ("line %d"):format(entry.first))
  end)

  it("opens the file in a new tab", function()
    assert.same({}, seen.messages)
    assert.same(1, seen.tabs)
    assert.same(abs, seen.name)
  end)

  it("puts the cursor on the recorded first line", function()
    assert.same(entry.first, seen.line)
  end)

  it("roots the tab in the checkout", function()
    assert.same(root, seen.cwd)
  end)

  it("closes the float", function()
    assert.is_false(seen.float_open)
  end)
end)

describe("a whole-file annotation with no review view open", function()
  fresh_queue()
  view.open("branch")
  V = view.current()
  annotate_row(row_of("file", "src/newname.lua"))
  view.close()
  local entry = queue.all()[1]
  local abs = vim.fs.joinpath(root, entry.path)
  parked_at(abs, 3)
  local seen = jump_from_float()

  it("is about the whole file", function()
    assert.same("file", entry.kind)
  end)

  it("opens the file at line 1", function()
    assert.same(abs, seen.name)
    assert.same(1, seen.line)
    assert.is_false(seen.float_open)
  end)
end)

describe("a bare note with no review view open", function()
  fresh_queue()
  vim.cmd("tabnew")
  require("codereview").annotate("bug")
  vim.cmd("tabclose")
  local seen = jump_from_float()
  said[#said + 1] = seen.messages[1]

  it("still says there is nowhere to go", function()
    assert.is_nil(view.current())
    assert.same(1, #seen.messages)
    assert.is_true(h.notified(seen.messages, "nowhere to jump"), seen.messages[1])
  end)

  it("opens nothing and leaves the float open", function()
    assert.same(0, seen.tabs)
    assert.is_true(seen.float_open)
  end)
end)

describe("a file in no repository", function()
  fresh_queue()
  local outside = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "one", "two", "three", "four" }, outside)
  outside = vim.uv.fs_realpath(outside)
  local cwd = vim.uv.fs_realpath(vim.fn.getcwd())
  -- From a visual-mode mapping, because capture reads a selection only while it is live,
  -- and in normal mode it takes the whole file, which would land on line 1 regardless.
  vim.keymap.set({ "n", "x" }, "<F5>", function()
    require("codereview").annotate("bug")
  end)
  vim.cmd("tabedit " .. vim.fn.fnameescape(outside))
  h.feed("3GV<F5>")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("tabclose")
  local entry = queue.all()[1]
  local seen = jump_from_float()

  it("is a line of a file with an absolute path and no checkout", function()
    assert.same("line", entry.kind)
    assert.is_nil(entry.path)
    assert.same(outside, entry.abs_path)
  end)

  it("opens it by that path at its line", function()
    assert.same(outside, seen.name)
    assert.same(3, seen.line)
    assert.is_false(seen.float_open)
  end)

  it("leaves the tab's directory alone", function()
    assert.same(cwd, seen.cwd)
  end)

  describe("once it is gone", function()
    os.remove(outside)
    local gone = jump_from_float()
    said[#said + 1] = gone.messages[1]

    it("says so and opens nothing", function()
      assert.same(1, #gone.messages)
      assert.is_true(h.notified(gone.messages, vim.fn.fnamemodify(outside, ":t")), gone.messages[1])
      assert.same(0, gone.tabs)
      assert.is_true(gone.float_open)
    end)
  end)
end)

describe("a recorded line past the end of the file", function()
  fresh_queue()
  local shrunk = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "one", "two", "three", "four" }, shrunk)
  shrunk = vim.uv.fs_realpath(shrunk)
  vim.cmd("tabedit " .. vim.fn.fnameescape(shrunk))
  h.feed("4GV<F5>")
  -- Wiped rather than closed, so the jump reads the file from disk and not the four lines
  -- still in memory, and a fresh buffer puts the cursor on line 1 -- which is not the line
  -- the clamp is to land on.
  vim.cmd("bwipeout!")
  vim.fn.writefile({ "one", "two" }, shrunk)
  local entry = queue.all()[1]
  local seen = jump_from_float()

  it("records a line the file no longer has", function()
    assert.same(4, entry.first)
  end)

  it("opens the file at its last line", function()
    assert.same(shrunk, seen.name)
    assert.same(2, seen.line)
    assert.is_false(seen.float_open)
  end)
end)

describe("the unavailable cases", function()
  it("give distinct messages, not one shared one", function()
    -- A bare note with a view, out of scope, a bare note without one, a file that is gone.
    assert.same(4, #said)
    assert.same(said[1], said[3])
    assert.is_true(said[1] ~= said[2], said[1])
    assert.is_true(said[2] ~= said[4], said[2])
    assert.is_true(said[1] ~= said[4], said[4])
  end)
end)
