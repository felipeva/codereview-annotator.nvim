-- The **margin** following the reviewer: which window it stands beside, what it holds beside
-- a file with no **card**, when it closes and comes back, and what closing it by hand does.
--
-- In-process, because `WinEnter`, `BufWinEnter`, `WinClosed` and `QuitPre` fire inside the
-- command that raises them, unlike the scroll events overlay_scroll_child exists for. Two
-- things here wait a tick, and the cases that reach them spin `vim.wait`: a window entered
-- on the buffer the margin already draws, and the verdict on a margin closed by hand.
--
-- Every case starts from one window holding the long file, the overlay off and the queue
-- empty, and leaves the same behind: plenary runs each `it` as it reaches it, and the toggle
-- is module state.
local h = require("tests.helpers")

h.ui(120, 30)
local fixture = h.cd_fixture("mkfixture")

local LONG = "src/long.lua"
local MAIN = "src/main.lua"
-- Committed on the branch and annotated by nothing here.
local PLAIN = "src/newname.lua"

---Write a 200-line file at `rel` under `dir`.
local function long_file(dir, rel)
  local lines = {}
  for i = 1, 200 do
    lines[i] = ("local l%d = %d"):format(i, i)
  end
  vim.fn.mkdir(vim.fs.dirname(vim.fs.joinpath(dir, rel)), "p")
  vim.fn.writefile(lines, vim.fs.joinpath(dir, rel))
end
long_file(fixture, LONG)

---A repository of its own, holding the long file at the same relative path.
---@return string
local function repository(suffix)
  local dir = vim.fn.tempname() .. suffix
  vim.fn.mkdir(dir, "p")
  vim.system({ "git", "init", "-q", dir }):wait()
  long_file(dir, LONG)
  return dir
end

require("codereview").setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "queued from the buffer")
  end,
  send = function()
    return true
  end,
})

local codereview = require("codereview")
local config = require("codereview.config")
local overlay = require("codereview.overlay")
local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

local BAR = config.get().icons.change_bar
local EMPTY = "no annotations in this file"
local root = assert(vim.uv.fs_realpath(fixture))

-- Read back first, so no paint below is this checkout's first and the queue holds only what
-- each case adds.
state.ensure_queue()

---@param path string
---@param first integer
---@param note string
local function queued(path, first, note)
  return queue.add({
    type = "bug",
    kind = "line",
    path = path,
    abs_path = vim.fs.joinpath(root, path),
    key = ("%s:n:%d"):format(path, first),
    first = first,
    last = first,
    note = note,
  })
end

local function on()
  assert(not overlay.enabled(), "a case before this one left the overlay on")
  local _, restore = h.capture_notify()
  assert.is_true(codereview.overlay())
  restore()
end

---Let the main loop run what was scheduled.
local function tick()
  vim.wait(50, function()
    return false
  end)
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

---@param buf integer
---@param text string
---@return integer|nil
local function row_of(buf, text)
  for i, line in ipairs(lines(buf)) do
    if line == text then
      return i
    end
  end
end

---Every highlight in the overlay's namespace on a buffer, as `row:group` over its text.
local function marks(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.NS, 0, -1, { details = true })) do
    local d = m[4]
    if d.hl_group then
      local text = vim.api.nvim_buf_get_text(buf, m[2], m[3], m[2], d.end_col, {})[1]
      out[#out + 1] = { row = m[2] + 1, text = text, hl = d.hl_group }
    end
  end
  return out
end

---The margin windows in a tab page, found by their buffer rather than asked of the module.
---@param tab integer
---@return integer[]
local function margins_in(tab)
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "codereview-overlay" then
      out[#out + 1] = w
    end
  end
  return out
end

---The margin stands immediately to the right of `win`, on its top row.
---@param m CROverlayMargin
---@param win integer
local function beside(m, win)
  local code, side = vim.fn.win_screenpos(win), vim.fn.win_screenpos(m.win)
  assert.equal(code[1], side[1])
  -- One column for the separator between them.
  assert.equal(code[2] + vim.api.nvim_win_get_width(win) + 1, side[2])
end

---One window holding the long file.
---@return integer win
local function code_window()
  vim.cmd("silent! tabonly")
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, LONG)))
  vim.cmd("normal! gg")
  return vim.api.nvim_get_current_win()
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

describe("the margin", function()
  after_each(reset)

  it("moves beside another split when the cursor enters it, with that file's cards", function()
    queued(LONG, 2, "about the long file")
    queued(MAIN, 1, "about main")
    local a = code_window()
    on()
    local m = margin()
    local id = m.win
    assert.equal(a, m.code)
    assert.equal(3, row_of(m.buf, BAR .. " about the long file"))

    vim.cmd("vsplit " .. MAIN)
    local b = vim.api.nvim_get_current_win()
    tick()
    m = margin()
    assert.equal(b, m.code)
    beside(m, b)
    assert.equal(2, row_of(m.buf, BAR .. " about main"))
    assert.is_nil(row_of(m.buf, BAR .. " about the long file"))

    vim.api.nvim_set_current_win(a)
    m = margin()
    assert.equal(a, m.code)
    beside(m, a)
    assert.equal(3, row_of(m.buf, BAR .. " about the long file"))
    assert.is_nil(row_of(m.buf, BAR .. " about main"))
    -- Moved, not closed and opened again, and at the configured width still.
    assert.equal(id, m.win)
    assert.equal(40, vim.api.nvim_win_get_width(m.win))
    assert.equal(1, #margins_in(0))
  end)

  -- The float holds a file with cards of its own, so a margin that followed it would read
  -- differently.
  it("stays where it was while a floating window opens and closes", function()
    queued(LONG, 2, "about the long file")
    queued(MAIN, 1, "about main")
    local a = code_window()
    on()
    local before = lines(margin().buf)
    local buf = vim.fn.bufadd(vim.fs.joinpath(fixture, MAIN))
    vim.fn.bufload(buf)
    local float = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 2, col = 2, width = 30, height = 5 })
    tick()
    assert.equal(a, margin().code)
    assert.same(before, lines(margin().buf))
    vim.api.nvim_win_close(float, true)
    tick()
    assert.equal(a, margin().code)
    assert.same(before, lines(margin().buf))
  end)

  it("follows nothing new when the cursor enters it", function()
    queued(LONG, 2, "about the long file")
    local a = code_window()
    on()
    local m = margin()
    local before = lines(m.buf)
    vim.api.nvim_set_current_win(m.win)
    tick()
    assert.equal(m.win, vim.api.nvim_get_current_win())
    assert.equal(a, margin().code)
    assert.same(before, lines(margin().buf))
    vim.api.nvim_set_current_win(a)
  end)

  -- A help split entered and left: the cursor passing through a window that holds no file
  -- does not take the margin from the code.
  it("stays beside the code while the cursor is in a help split", function()
    queued(LONG, 2, "about the long file")
    local a = code_window()
    on()
    vim.cmd("help help")
    local help = vim.api.nvim_get_current_win()
    assert.are_not.equal(a, help)
    tick()
    assert.equal(a, margin().code)
    assert.equal(3, row_of(margin().buf, BAR .. " about the long file"))
  end)
end)

describe("beside a file with no card", function()
  after_each(reset)

  local function quiet_line()
    local m = margin()
    assert.same(
      { EMPTY },
      vim.tbl_filter(function(l)
        return l ~= ""
      end, lines(m.buf))
    )
    assert.same({ { row = 1, text = EMPTY, hl = "CodeReviewOverlayEmpty" } }, marks(m.buf))
  end

  -- Each reading is taken over a margin that held a card a moment before.
  it("the margin stays open with one quiet line: unannotated, another checkout, no checkout", function()
    queued(LONG, 2, "about the long file")
    local a = code_window()
    on()
    assert.equal(3, row_of(margin().buf, BAR .. " about the long file"))

    vim.cmd("edit " .. PLAIN)
    assert.equal(a, margin().code)
    quiet_line()

    vim.cmd("edit " .. LONG)
    assert.equal(3, row_of(margin().buf, BAR .. " about the long file"))
    local other = repository("-other")
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(other, LONG)))
    assert.equal(a, margin().code)
    quiet_line()

    vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, LONG)))
    assert.equal(3, row_of(margin().buf, BAR .. " about the long file"))
    local loose = vim.fn.tempname() .. "-loose.lua"
    vim.fn.writefile({ "local x = 1" }, loose)
    vim.cmd("edit " .. vim.fn.fnameescape(loose))
    assert.equal(a, margin().code)
    quiet_line()
  end)
end)

describe("a buffer that is not a file in the followed window", function()
  after_each(reset)

  -- `:help` opens a split of its own unless the current window already holds help, so the
  -- window is made one first: that is the help page *in* the followed window.
  it("closes the margin, and a file coming back reopens it with the toggle still on", function()
    queued(LONG, 2, "about the long file")
    local a = code_window()
    on()
    assert.equal(1, #margins_in(0))
    vim.cmd("enew")
    vim.bo.buftype = "help"
    vim.cmd("help help")
    assert.equal(a, vim.api.nvim_get_current_win())
    assert.equal("help", vim.bo.buftype)
    assert.is_nil(overlay.margin())
    assert.same({}, margins_in(0))
    assert.is_true(overlay.enabled())

    vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, LONG)))
    local m = margin()
    assert.equal(a, m.code)
    beside(m, a)
    assert.equal(3, row_of(m.buf, BAR .. " about the long file"))
  end)

  it("a terminal does the same", function()
    local a = code_window()
    on()
    assert.equal(1, #margins_in(0))
    vim.cmd("terminal")
    assert.equal(a, vim.api.nvim_get_current_win())
    assert.same({}, margins_in(0))
    assert.is_true(overlay.enabled())
    vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, LONG)))
    assert.equal(1, #margins_in(0))
  end)
end)

describe("closing the margin by hand", function()
  after_each(reset)

  it("turns the overlay off, and a later scroll does not reopen it", function()
    queued(LONG, 2, "about the long file")
    local a = code_window()
    on()
    local said, restore = h.capture_notify()
    vim.api.nvim_set_current_win(margin().win)
    vim.cmd("quit")
    -- The close itself lands the cursor in the code window, and that entry reopens nothing.
    assert.equal(a, vim.api.nvim_get_current_win())
    assert.same({}, margins_in(0))
    vim.wait(500, function()
      return not overlay.enabled()
    end)
    restore()
    assert.is_false(overlay.enabled())
    assert.is_true(h.notified(said, "Overlay off"), vim.inspect(said))
    vim.cmd("normal! 10\5")
    overlay.paint()
    tick()
    assert.same({}, margins_in(0))
    assert.is_nil(overlay.margin())
  end)

  -- `:tabclose` closes the margin before the window it follows, in a moment that looks
  -- exactly like the reviewer closing it.
  it("is not what closing its tab page is", function()
    queued(LONG, 2, "about the long file")
    local a = code_window()
    on()
    vim.cmd("tabedit " .. MAIN)
    assert.equal(1, #margins_in(0))
    vim.cmd("tabclose")
    tick()
    assert.is_true(overlay.enabled())
    assert.equal(a, margin().code)
    assert.equal(3, row_of(margin().buf, BAR .. " about the long file"))
  end)
end)

describe("the followed window closing", function()
  after_each(reset)

  it("hands the margin to the window the cursor lands in, with the toggle on", function()
    queued(LONG, 2, "about the long file")
    queued(MAIN, 1, "about main")
    local a = code_window()
    on()
    vim.cmd("vsplit " .. MAIN)
    tick()
    local b = vim.api.nvim_get_current_win()
    assert.equal(b, margin().code)
    vim.cmd("close")
    tick()
    assert.is_true(overlay.enabled())
    assert.equal(a, vim.api.nvim_get_current_win())
    local m = margin()
    assert.equal(a, m.code)
    beside(m, a)
    assert.equal(3, row_of(m.buf, BAR .. " about the long file"))
    assert.equal(1, #margins_in(0))
  end)

  -- Closing the margin from the code window's `WinClosed` would abort the quit with E855.
  it("by :q, beside nothing but its margin, closes the tab page as it would without one", function()
    code_window()
    on()
    vim.cmd("tabedit " .. LONG)
    local tabs = #vim.api.nvim_list_tabpages()
    assert.equal(1, #margins_in(0))
    local ok, err = pcall(vim.cmd, "quit")
    assert.is_true(ok, tostring(err))
    tick()
    assert.equal(tabs - 1, #vim.api.nvim_list_tabpages())
    assert.is_true(overlay.enabled())
    assert.equal(1, #margins_in(0))
  end)
end)

describe("a file opened from the diff", function()
  after_each(function()
    reset()
    if view.current() then
      view.close()
    end
  end)

  it("gets a margin in its new tab, and the review's windows get none", function()
    queued(MAIN, 1, "about main")
    code_window()
    on()
    view.open("branch")
    local v = assert(view.current(), "the review did not open")
    local review_tab = vim.api.nvim_get_current_tabpage()
    tick()
    assert.same({}, margins_in(review_tab))

    local row = assert(h.line_row(v, MAIN), "no diff row for " .. MAIN)
    vim.api.nvim_set_current_win(v.win)
    vim.api.nvim_win_set_cursor(v.win, { row, 0 })
    view.open_file()
    tick()
    local file_win = vim.api.nvim_get_current_win()
    assert.are_not.equal(review_tab, vim.api.nvim_get_current_tabpage())
    local m = margin()
    assert.equal(file_win, m.code)
    beside(m, file_win)
    assert.is_not_nil(row_of(m.buf, BAR .. " about main"))
    assert.same({}, margins_in(review_tab))
    vim.cmd("tabclose")
  end)
end)

-- Last, because it points the queue at another checkout; it points it back before it ends.
describe("a checkout this session has never read", function()
  local fresh = repository("-fresh")
  local run = vim
    .system({
      vim.v.progpath,
      "--clean",
      "--headless",
      "-l",
      vim.fs.joinpath(h.root, "tests", "codereview", "overlay_restore_child.lua"),
    }, {
      text = true,
      env = {
        XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
        CHECKOUT = fresh,
        GIT_CONFIG_GLOBAL = "/dev/null",
        GIT_CONFIG_SYSTEM = "/dev/null",
      },
    })
    :wait(60000)

  it("shows its stored cards on the margin's first paint there", function()
    local said = (run.stdout or "") .. (run.stderr or "")
    assert.equal(0, run.code, said)
    assert.is_truthy(said:find("queued=1", 1, true), said)

    code_window()
    on()
    vim.cmd("tabnew")
    vim.cmd("tcd " .. vim.fn.fnameescape(fresh))
    vim.cmd("edit " .. LONG)
    local m = margin()
    assert.equal(3, row_of(m.buf, BAR .. " ✗ bug 3"))
    assert.equal(4, row_of(m.buf, BAR .. " stored in another checkout"))

    -- Closed first: `tabonly` in the reset keeps the current tab page, and that is the one
    -- rooted in the other checkout.
    vim.cmd("tabclose")
    reset()
    state.ensure_queue()
    assert.equal(root, state.current_checkout())
  end)
end)
