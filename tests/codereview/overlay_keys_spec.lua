-- The **margin**'s keys: the queue float's set, acting on the **card** under the cursor, and
-- where the cursor lands when the reviewer enters the margin.
--
-- In-process and in a real window, as overlay_follow_spec is: `WinEnter` fires inside the
-- `<C-w>l` that raises it. The composer and the type picker are stubs, so `e` and `t` never
-- reach insert mode, which a headless run cannot test (design notes, "Windows, modes and
-- focus"). No review view is opened anywhere in this file: the margin's keys have to work
-- with none.
--
-- A drop surviving a restart is read in overlay_drop_restart_spec, in a second process.
--
-- Every case starts from one window holding the long file, the overlay off and the queue
-- empty, and leaves the same behind: plenary runs each `it` as it reaches it, and the toggle
-- is module state.
local h = require("tests.helpers")

h.ui(120, 30)
local fixture = h.cd_fixture("mkfixture")

local LONG = "src/long.lua"
do
  local lines = {}
  for i = 1, 200 do
    lines[i] = ("local l%d = %d"):format(i, i)
  end
  vim.fn.writefile(lines, vim.fs.joinpath(fixture, LONG))
end

---What the stub composer answers with, and the text it was opened on.
local composed, opened_with = "edited note", nil
local sent = {}
require("codereview").setup({
  syntax = false,
  compose = function(ctx, on_accept)
    opened_with = ctx.text
    on_accept(nil, composed)
  end,
  send = function(text)
    sent[#sent + 1] = text
    return true
  end,
})

local codereview = require("codereview")
local config = require("codereview.config")
local overlay = require("codereview.overlay")
local queue = require("codereview.queue")
local state = require("codereview.state")
local types = require("codereview.types")
local view = require("codereview.view")

local BAR = config.get().icons.change_bar
local EMPTY = "no annotations in this file"
local root = assert(vim.uv.fs_realpath(fixture))

state.ensure_queue()

---@param first integer
---@param note string
---@param over table|nil
---@return CRAnnotation
local function queued(first, note, over)
  return queue.add(vim.tbl_extend("force", {
    type = "bug",
    kind = "line",
    path = LONG,
    abs_path = vim.fs.joinpath(root, LONG),
    key = ("%s:n:%d"):format(LONG, first),
    first = first,
    last = first,
    note = note,
  }, over or {}))
end

local function tick()
  vim.wait(50, function()
    return false
  end)
end

---One window holding the long file, at the top.
---@return integer win, integer buf
local function code_window()
  vim.cmd("silent! tabonly")
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, LONG)))
  vim.cmd("normal! gg")
  return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

local function on()
  assert(not overlay.enabled(), "a case before this one left the overlay on")
  local _, restore = h.capture_notify()
  assert.is_true(codereview.overlay())
  restore()
end

local function reset()
  if overlay.enabled() then
    local _, restore = h.capture_notify()
    codereview.overlay()
    restore()
  end
  tick()
  vim.cmd("silent! tabonly")
  vim.cmd("silent! only")
  queue.clear()
end

---@return CROverlayMargin
local function margin()
  return assert(overlay.margin(), "no margin is open")
end

---@param buf integer
---@return string[]
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---The row a card's header is on, found by the lines it names.
---@param buf integer
---@param label string e.g. "bug 12"
---@return integer|nil
local function header_row(buf, label)
  for i, line in ipairs(lines(buf)) do
    if line:sub(-#label - 1) == " " .. label then
      return i
    end
  end
end

---The groups drawn over a margin row, in column order.
---@param buf integer
---@param row integer 1-based
---@return string[]
local function groups_on(buf, row)
  local out = {}
  for _, mk in
    ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.NS, { row - 1, 0 }, { row - 1, -1 }, {
      details = true,
    }))
  do
    out[#out + 1] = mk[4].hl_group
  end
  return out
end

---From the code window, with its cursor on `line`, into the margin by the window key.
---@param code integer
---@param line integer
---@return integer row The margin row the cursor landed on
local function enter_from(code, line)
  local m = margin()
  -- Off every card first, so a cursor that stayed where it was cannot pass for one that
  -- landed: the margin's last row is below every card these cases draw.
  vim.api.nvim_win_set_cursor(m.win, { vim.api.nvim_win_get_height(m.win), 0 })
  vim.api.nvim_set_current_win(code)
  vim.api.nvim_win_set_cursor(code, { line, 0 })
  h.feed("<C-w>l")
  assert.equal(m.win, vim.api.nvim_get_current_win())
  return vim.api.nvim_win_get_cursor(m.win)[1]
end

describe("entering the margin", function()
  after_each(reset)

  it("lands on the card anchored on the line the cursor came from", function()
    queued(3, "upper")
    queued(10, "lower")
    local code = code_window()
    on()
    local m = margin()
    assert.equal(header_row(m.buf, "bug 10"), enter_from(code, 10))
    assert.equal(header_row(m.buf, "bug 3"), enter_from(code, 3))
  end)

  it("lands on the nearer card from a line between two", function()
    queued(5, "upper")
    queued(15, "lower")
    local code = code_window()
    on()
    local m = margin()
    assert.equal(header_row(m.buf, "bug 15"), enter_from(code, 12))
    assert.equal(header_row(m.buf, "bug 5"), enter_from(code, 8))
  end)

  -- The second card is pushed down by the first, so its header row is not its anchor's row:
  -- landing by row would put the cursor inside the first card.
  it("lands on a card pushed down by the one above, by its anchor", function()
    queued(5, "one\ntwo\nthree\nfour")
    local pushed = queued(6, "pushed")
    local code = code_window()
    on()
    local m = margin()
    local row = header_row(m.buf, "bug 6")
    assert.is_true(row > 6, "the card on line 6 was not pushed down")
    assert.equal(row, enter_from(code, 6))
    assert.equal(pushed.id, m.rows[row])
  end)

  it("stays where it was when a float closes over the margin", function()
    queued(3, "upper")
    queued(10, "lower")
    local code = code_window()
    on()
    local m = margin()
    local lower = enter_from(code, 10)
    vim.api.nvim_win_set_cursor(code, { 3, 0 })
    local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 10,
      height = 2,
    })
    vim.api.nvim_win_close(float, true)
    assert.equal(m.win, vim.api.nvim_get_current_win())
    assert.equal(lower, vim.api.nvim_win_get_cursor(m.win)[1])
  end)
end)

describe("the margin's keys", function()
  after_each(reset)

  it("map every row of a card to its entry, the note's as well as the header's", function()
    local e = queued(4, "first\nsecond")
    code_window()
    on()
    local m = margin()
    assert.same({ [4] = e.id, [5] = e.id, [6] = e.id }, m.rows)
  end)

  it("<CR> puts the cursor on the anchor's line now, in the code window", function()
    queued(20, "about twenty")
    local code, buf = code_window()
    -- Two lines above it, so the anchor and the recorded line part.
    on()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- one", "-- two" })
    enter_from(code, 1)
    local m = margin()
    assert.equal(header_row(m.buf, "bug 20"), vim.api.nvim_win_get_cursor(m.win)[1])
    h.feed("<CR>")
    assert.equal(code, vim.api.nvim_get_current_win())
    assert.equal(22, vim.api.nvim_win_get_cursor(code)[1])
    assert.is_true(overlay.enabled())
    vim.cmd("silent! edit!")
  end)

  it("<CR> on a whole-file card enters the code window and leaves its line", function()
    queued(1, "about the file", { kind = "file", first = nil, last = nil, key = LONG .. ":file" })
    local code = code_window()
    on()
    vim.api.nvim_win_set_cursor(code, { 7, 0 })
    h.feed("<C-w>l")
    local m = margin()
    assert.equal(1, vim.api.nvim_win_get_cursor(m.win)[1])
    h.feed("<CR>")
    assert.equal(code, vim.api.nvim_get_current_win())
    assert.equal(7, vim.api.nvim_win_get_cursor(code)[1])
  end)

  it("x drops the entry, takes its card away and lands on the next", function()
    local gone = queued(3, "dropped")
    local kept = queued(10, "kept")
    local code = code_window()
    on()
    enter_from(code, 3)
    local m = margin()
    assert.is_nil(view.current())
    h.feed("x")
    assert.same(
      { kept.id },
      vim.tbl_map(function(item)
        return item.id
      end, queue.all())
    )
    assert.is_nil(header_row(m.buf, "bug 3"))
    assert.is_false(vim.tbl_contains(vim.tbl_values(m.rows), gone.id))
    assert.equal(header_row(m.buf, "bug 10"), vim.api.nvim_win_get_cursor(m.win)[1])
  end)

  it("e opens the composer on the note, and the card shows the edited one", function()
    local e = queued(4, "before the edit")
    local code = code_window()
    on()
    enter_from(code, 4)
    local m = margin()
    opened_with = nil
    h.feed("e")
    assert.equal("before the edit", opened_with)
    assert.equal("edited note", queue.all()[1].note)
    assert.equal(BAR .. " edited note", lines(m.buf)[5])
    assert.is_false(vim.tbl_contains(lines(m.buf), BAR .. " before the edit"))
    assert.equal(e.id, m.rows[vim.api.nvim_win_get_cursor(m.win)[1]])
  end)

  it("t changes the type, and the header and rule take the new type's group", function()
    queued(4, "retype me")
    local code = code_window()
    on()
    enter_from(code, 4)
    local m = margin()
    local bug = types.get(config.get().types, "bug").hl
    local nitpick = types.get(config.get().types, "nitpick").hl
    assert.same({ bug, bug }, groups_on(m.buf, 4))

    local select = vim.ui.select
    vim.ui.select = function(items, _, cb)
      for i, item in ipairs(items) do
        if item:find("nitpick", 1, true) then
          return cb(item, i)
        end
      end
    end
    h.feed("t")
    vim.ui.select = select

    assert.equal("nitpick", queue.all()[1].type)
    local row = assert(header_row(m.buf, "nitpick 4"))
    assert.same({ nitpick, nitpick }, groups_on(m.buf, row))
    assert.same({ nitpick, "CodeReviewNote" }, groups_on(m.buf, row + 1))
  end)

  it("<C-s> submits the batch, and the margin shows the empty line", function()
    queued(3, "one")
    queued(10, "two")
    local code = code_window()
    on()
    enter_from(code, 3)
    local m = margin()
    local before = #sent
    local _, restore = h.capture_notify()
    h.feed("<C-s>")
    restore()
    assert.equal(before + 1, #sent)
    assert.is_truthy(sent[#sent]:find("one", 1, true))
    assert.equal(0, queue.count())
    assert.equal(EMPTY, lines(m.buf)[1])
  end)

  it("q turns the overlay off and closes the margin, and <Esc> is not mapped", function()
    queued(3, "one")
    local code = code_window()
    on()
    enter_from(code, 3)
    local m = margin()
    local mapped = {}
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(m.buf, "n")) do
      mapped[km.lhs] = true
    end
    assert.is_true(mapped.q)
    assert.is_nil(mapped["<Esc>"])

    local win = m.win
    local _, restore = h.capture_notify()
    h.feed("q")
    restore()
    assert.is_false(overlay.enabled())
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.is_nil(overlay.margin())
    assert.equal(code, vim.api.nvim_get_current_win())
  end)

  it("? lists every key, and changes nothing", function()
    queued(3, "one")
    local code = code_window()
    on()
    enter_from(code, 3)
    local m = margin()
    local rows = lines(m.buf)
    local said, restore = h.capture_notify()
    h.feed("?")
    restore()
    local listing = table.concat(said, "\n")
    for _, key in ipairs({ "<CR>", "e", "t", "x", "gy", "^T", "^S", "^A", "q", "?" }) do
      assert.is_truthy(listing:find("\n  " .. key .. " ", 1, true), key .. " is missing:\n" .. listing)
    end
    assert.is_falsy(listing:find("<Esc>", 1, true), listing)
    assert.equal(1, queue.count())
    assert.same(rows, lines(m.buf))
  end)
end)
