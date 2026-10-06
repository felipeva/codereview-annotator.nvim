-- The **tint**: the background the **overlay** draws on every line an **entry** covers, in
-- both styles, and the cursor row it leaves alone.
--
-- Groups on marks, as the sign bar is read in overlay_spec, and never a colour on screen --
-- with one exception the colour arithmetic earns, the colorscheme case, which reads the
-- group's definition. The cells a reviewer sees are read in overlay_tint_child, one per
-- process.
--
-- Every case runs once per style. The toggle and the style are module state and outlive every
-- case, and plenary runs each `it` as it reaches it, so every case turns the overlay off again.
local h = require("tests.helpers")

h.ui(80, 24)
local fixture = h.cd_fixture("mkfixture")

local LONG = "src/long.lua"
do
  local lines = {}
  for i = 1, 200 do
    lines[i] = ("local l%d = %d"):format(i, i)
  end
  vim.fn.writefile(lines, vim.fs.joinpath(fixture, LONG))
end

-- A tint is a background only a true-colour terminal can draw.
vim.o.termguicolors = true

require("codereview").setup({
  syntax = false,
  send = function()
    return true
  end,
})

local codereview = require("codereview")
local config = require("codereview.config")
local overlay = require("codereview.overlay")
local queue = require("codereview.queue")
local state = require("codereview.state")

local root = assert(vim.uv.fs_realpath(fixture))
local BUG = "CodeReviewTint.CodeReviewBug"
local FIX = "CodeReviewTint.CodeReviewFix"

state.ensure_queue()

---Queue an entry about the long file, by hand.
---@param over table
---@return CRAnnotation
local function queued(over)
  local first = over.first or 1
  return queue.add(vim.tbl_extend("force", {
    type = "bug",
    kind = "line",
    path = LONG,
    abs_path = vim.fs.joinpath(root, LONG),
    key = ("%s:n:%d"):format(LONG, first),
    first = first,
    last = first,
    note = "a note",
  }, over))
end

---One window, holding the long file as it is on disk, with the cursor on `line`.
---@param line integer|nil
---@return integer win, integer buf
local function code_window(line)
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, LONG)))
  vim.api.nvim_win_set_cursor(0, { line or 1, 0 })
  return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

---@param style "margin"|"inline"
local function on(style)
  assert(not overlay.enabled(), "a case before this one left the overlay on")
  local _, restore = h.capture_notify()
  codereview.overlay(style)
  restore()
  assert(overlay.enabled() and overlay.style() == style, "the overlay is not on in " .. style)
end

local function off()
  if overlay.enabled() then
    local _, restore = h.capture_notify()
    codereview.overlay()
    restore()
  end
end

---The tint group on each 1-based line of a buffer. A line whose tint is held off it, because
---the cursor is on it, carries none.
---@param buf integer
---@return table<integer, string>
local function tints(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.NS, 0, -1, { details = true })) do
    if m[4].line_hl_group then
      assert(out[m[2] + 1] == nil, "two tints on line " .. (m[2] + 1))
      out[m[2] + 1] = m[4].line_hl_group
    end
  end
  return out
end

---@param buf integer
---@return table<integer, string>
local function signs(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.NS, 0, -1, { details = true })) do
    if m[4].sign_text then
      out[m[2] + 1] = m[4].sign_hl_group
    end
  end
  return out
end

---Every mark in the overlay's namespace, as `id@row:col`, so a paint -- which clears the
---namespace and makes every mark anew -- reads as a change.
---@param buf integer
---@return string[]
local function ids(buf)
  return vim.tbl_map(function(m)
    return ("%d@%d:%d"):format(m[1], m[2], m[3])
  end, vim.api.nvim_buf_get_extmarks(buf, overlay.NS, 0, -1, {}))
end

---`group` on each of lines `from`..`to`, into `out`.
---@param out table<integer, string>
---@param from integer
---@param to integer
---@param group string
---@return table<integer, string>
local function span(out, from, to, group)
  for l = from, to do
    out[l] = group
  end
  return out
end

---Put the cursor on `line` and raise the event a reviewer's keystroke would. A spec case
---never reaches the main loop's check, so `nvim_win_set_cursor` alone raises nothing.
---@param win integer
---@param line integer
local function move_to(win, line)
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
end

---Every git command a call runs, as its arguments after `git`.
---@param fn fun()
---@return string[][]
local function git_runs(fn)
  local runs = {}
  local orig = vim.system
  vim.system = function(cmd, ...)
    if type(cmd) == "table" and cmd[1] == "git" then
      runs[#runs + 1] = vim.list_slice(cmd, 2)
    end
    return orig(cmd, ...)
  end
  local ok, err = pcall(fn)
  vim.system = orig
  assert(ok, err)
  return runs
end

for _, style in ipairs({ "margin", "inline" }) do
  describe(("the tint in the %s style"):format(style), function()
    before_each(queue.clear)
    after_each(off)

    it("tints every covered line in its type's group, and nothing for a whole-file entry", function()
      local _, buf = code_window(1)
      queued({ first = 3, last = 6 })
      queue.add({
        type = "fix",
        kind = "file",
        path = LONG,
        abs_path = vim.fs.joinpath(root, LONG),
        key = LONG .. ":f:0",
        tag = "whole file",
        note = "the whole thing",
      })
      on(style)
      assert.same(span({}, 3, 6, BUG), tints(buf))
      assert.is_not_nil(vim.api.nvim_get_hl(0, { name = BUG }).bg, "the tint group holds no background")
      assert.is_nil(vim.api.nvim_get_hl(0, { name = BUG }).fg, "a line-wide foreground flattens the row")
    end)

    -- The rule the file tree's mark follows: first in the declared order, whatever the queue's.
    -- The fix is queued first, so a tint drawn in queue order, or the last mark made winning,
    -- would read fix on the overlap.
    it("tints an overlap in the leading type, whichever entry was queued first", function()
      local _, buf = code_window(1)
      queued({ type = "fix", first = 5, last = 8 })
      queued({ type = "bug", first = 3, last = 6 })
      on(style)
      assert.same(span(span({}, 3, 6, BUG), 7, 8, FIX), tints(buf))
    end)

    it("tints nothing for an untyped entry, and keeps its sign", function()
      local _, buf = code_window(1)
      -- After the add: `tbl_extend` drops a nil, so it cannot be passed in.
      queued({ first = 3, last = 4 }).type = nil
      on(style)
      assert.same({}, tints(buf))
      assert.same({ [3] = "CodeReviewNote", [4] = "CodeReviewNote" }, signs(buf))
    end)

    it("leaves the cursor's row untinted, so the cursor line shows", function()
      local _, buf = code_window(4)
      queued({ first = 3, last = 6 })
      on(style)
      assert.same({ [3] = BUG, [5] = BUG, [6] = BUG }, tints(buf))
    end)

    -- The pre-state is a tinted row 5 and a bare row 4, so a handler that did nothing reads
    -- differently from one that moved the row. The capture is a buffer capture and the file's
    -- stat is moved before the cursor is, so a paint on that event would get through the
    -- rehash's gate and run `hash-object`: the spy can see one.
    it("moves the untinted row with the cursor, and paints and hashes nothing else", function()
      local win, buf = code_window(4)
      queued({ first = 3, last = 6, worktree = true })
      on(style)
      assert.same({ [3] = BUG, [5] = BUG, [6] = BUG }, tints(buf))
      local before = ids(buf)
      -- A time of its own per style: the gate remembers the last stat it let through, and the
      -- other style's case may have set this one within the same second.
      local later = os.time() + (style == "margin" and 60 or 120)
      vim.uv.fs_utime(vim.fs.joinpath(root, LONG), later, later)
      local runs = git_runs(function()
        move_to(win, 5)
      end)
      assert.same({ [3] = BUG, [4] = BUG, [6] = BUG }, tints(buf))
      assert.same(before, ids(buf), "a paint ran: the namespace's marks were made anew")
      assert.same({}, runs)
      -- Out of the range: every row tinted again, and still no paint.
      move_to(win, 10)
      assert.same(span({}, 3, 6, BUG), tints(buf))
      assert.same(before, ids(buf))
      -- And back in from outside, with no row held: the first move into a range has only a row
      -- to untint and none to give back.
      move_to(win, 3)
      assert.same({ [4] = BUG, [5] = BUG, [6] = BUG }, tints(buf))
      assert.same(before, ids(buf))
    end)

    it("draws no tint with the tint disabled, and keeps the signs", function()
      local _, buf = code_window(1)
      queued({ first = 3, last = 4 })
      config.get().overlay.tint.enabled = false
      local ok, err = pcall(on, style)
      config.get().overlay.tint.enabled = true
      assert(ok, err)
      assert.same({}, tints(buf))
      assert.same({ [3] = "CodeReviewBug", [4] = "CodeReviewBug" }, signs(buf))
    end)

    it("draws no tint without true colour, and keeps the signs", function()
      local _, buf = code_window(1)
      queued({ first = 3, last = 4 })
      vim.o.termguicolors = false
      local ok, err = pcall(on, style)
      vim.o.termguicolors = true
      assert(ok, err)
      assert.same({}, tints(buf))
      assert.same({ [3] = "CodeReviewBug", [4] = "CodeReviewBug" }, signs(buf))
    end)

    it("takes a dropped entry's tint away and leaves the other's", function()
      local _, buf = code_window(1)
      local dropped = queued({ first = 3, last = 4 })
      queued({ type = "fix", first = 10, last = 11 })
      on(style)
      assert.same(span(span({}, 3, 4, BUG), 10, 11, FIX), tints(buf))
      require("codereview.annotate").drop_entry(dropped)
      assert.same(span({}, 10, 11, FIX), tints(buf))
    end)

    it("takes every tint away when the overlay goes off", function()
      local _, buf = code_window(1)
      queued({ first = 3, last = 4 })
      on(style)
      assert.same(span({}, 3, 4, BUG), tints(buf))
      off()
      assert.same({}, tints(buf))
    end)

    it("moves the tint with the code after an edit above the range", function()
      local _, buf = code_window(1)
      queued({ first = 3, last = 4 })
      on(style)
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- one", "-- two" })
      assert.same(span({}, 5, 6, BUG), tints(buf))
      overlay.paint()
      assert.same(span({}, 5, 6, BUG), tints(buf))
    end)
  end)
end

describe("the tint across a colorscheme change", function()
  before_each(queue.clear)
  after_each(off)

  -- Even channels where it can be: 0xc8 is 200, and 12% of it is 24 with nothing to round.
  it("is computed again from the new theme", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
    vim.api.nvim_set_hl(0, "CodeReviewBug", { fg = 0xc80000 })
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    local _, buf = code_window(1)
    queued({ first = 3, last = 3 })
    on("inline")
    assert.same({ [3] = BUG }, tints(buf))
    assert.equal(0x180000, vim.api.nvim_get_hl(0, { name = BUG }).bg)
    -- 0x20 + (0xc8 - 0x20) * 0.12 = 52.16, and 0x20 - 0x20 * 0.12 = 28.16.
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x202020 })
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    assert.equal(0x341c1c, vim.api.nvim_get_hl(0, { name = BUG }).bg)
  end)
end)

--- The cells a reviewer sees -----------------------------------------------------

-- One child per reading, because `nvim__inspect_cell` is only honest on the first call a
-- process makes. See overlay_tint_child for the colours and why each reading is where it is.
describe("the cell under a reviewer's eye", function()
  ---@param env table<string, string>
  ---@return string
  local function child(env)
    local run = vim
      .system({
        vim.v.progpath,
        "--clean",
        "-l",
        vim.fs.joinpath(h.root, "tests", "codereview", "overlay_tint_child.lua"),
      }, {
        cwd = fixture,
        text = true,
        env = vim.tbl_extend("force", {
          FIXTURE = fixture,
          XDG_STATE_HOME = vim.fn.tempname() .. "-state",
          GIT_CONFIG_GLOBAL = "/dev/null",
          GIT_CONFIG_SYSTEM = "/dev/null",
        }, env),
      })
      :wait(60000)
    -- `nvim -l` sends print to stderr, so read both streams rather than guessing.
    local out = (run.stdout or "") .. (run.stderr or "")
    assert(run.code == 0, out)
    return vim.trim(out)
  end

  local bug = child({ CELL = "bug" })
  local fix = child({ CELL = "fix" })
  local cursor = child({ CELL = "cursor" })
  local plain = child({ CELL = "plain" })
  local mono = child({ CELL = "bug", TGC = "0" })

  -- Neither `Normal`'s black nor the cursor line's blue, and not each other's.
  it("paints a row inside a range in its type's tint", function()
    assert.same("cell l bg=180000", bug)
    assert.same("cell l bg=001800", fix)
  end)

  -- The control for the two above: the same window, a row no entry covers. `none` is the
  -- grid's default, which is `Normal`'s black: the cell carries no background of its own.
  it("leaves a row no entry covers on the normal background", function()
    assert.same("cell l bg=none", plain)
  end)

  it("shows the cursor line on the row the cursor moved to inside a range", function()
    assert.same("cell l bg=004488", cursor)
  end)

  it("draws no tint and defines no tint group without true colour, and keeps the signs", function()
    assert.same("tints=0 signs=7 group=0", mono)
  end)
end)

-- Last, because a failed setup leaves its options in place.
describe("the tint's setting", function()
  it("refuses a strength outside 0..1 at setup, with a message", function()
    local ok, err = pcall(config.setup, { overlay = { tint = { strength = 1.5 } } })
    assert.is_false(ok)
    assert.matches("`overlay.tint.strength` must be a number between 0 and 1", err)
  end)

  it("refuses a bare boolean, naming the table to write", function()
    local ok, err = pcall(config.setup, { overlay = { tint = false } })
    assert.is_false(ok)
    assert.matches("write `overlay.tint = { enabled = false }`", err, 1, true)
  end)
end)
