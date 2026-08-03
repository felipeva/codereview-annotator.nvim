-- Jumping from the queue float to the annotation under the cursor.
--
-- The float lists a queue that is shared with the capture path and is reachable with no
-- review view open, so several of the annotations it lists have nowhere to go. Those are
-- three different failures with three different remedies -- nothing, open a review, change
-- scope -- which is why the messages are asserted apart rather than merely counted.
local h = require("tests.helpers")

-- Deliberately short: whether a landing row is *centred* is only observable when the diff
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
---@param win integer
---@param index integer The number the float printed against the entry
---@param offset integer|nil Rows below the heading, for the "cursor is inside it" case
local function cursor_on(win, index, offset)
  local buf = vim.api.nvim_win_get_buf(win)
  for row, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if text:match("^" .. index .. "%. ") then
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

  -- Guards the test itself: a target already on screen would pass the centring assertion
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

  it("centres it", function()
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
  -- picker; what is left to pin here is that neither has lost its place in the footer.
  fresh_queue()
  annotate_row(row_of("line"))
  annotate_row(row_of("line", nil, true))
  local win = open_float()
  local advertised = footer(win)

  cursor_on(win, 2)
  h.feed("x")
  local left = queue.count()
  local open_after_drop = vim.api.nvim_win_is_valid(win)
  h.feed("q")

  it("advertises the jump alongside them", function()
    for _, key in ipairs({ "^T", "jump", "x drop", "^S submit", "q close" }) do
      assert.is_truthy(advertised:find(key, 1, true), advertised)
    end
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

describe("with no review view open", function()
  fresh_queue()
  annotate_row(row_of("line"))
  view.close()

  local win = open_float()
  cursor_on(win, 1)
  local messages = jump()
  said[#said + 1] = messages[1]
  local still_open = vim.api.nvim_win_is_valid(win)

  it("says the review view is what is missing", function()
    assert.same(1, #messages)
    assert.is_true(h.notified(messages, "No review view open"), messages[1])
  end)

  it("leaves the float open", function()
    assert.is_true(still_open)
  end)
end)

describe("the three unavailable cases", function()
  it("give three distinct messages, not one shared one", function()
    assert.same(3, #said)
    assert.is_true(said[1] ~= said[2], said[1])
    assert.is_true(said[2] ~= said[3], said[2])
    assert.is_true(said[1] ~= said[3], said[3])
  end)
end)
