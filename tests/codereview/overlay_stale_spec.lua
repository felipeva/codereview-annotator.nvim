-- The **stale** flag on a **card**, judged again on a paint: a capture from the buffer whose
-- file changed since the restore says so without a restart, and a review-path entry keeps
-- what the review view last judged.
--
-- A spec of its own and not more of overlay_spec, because every case here rewrites a file on
-- disk, and overlay_spec's cases share one file they expect as it was written.
--
-- The paint is called by hand after each change, as overlay_spec does after a scroll: the
-- scroll event never fires in a spec case (see overlay_scroll_child), and what is under test
-- is what a paint judges, not what raises it.
--
-- The cost is counted in git processes, around `vim.system`, as count_spec counts the
-- queued count's: the process is what the gate exists to save, so the process is what is
-- counted. Every zero is read straight after a one, from the same counter.
local h = require("tests.helpers")

h.ui(80, 24)
local fixture = h.cd_fixture("mkfixture")

-- Two files of this checkout, untracked, which a capture hashes from disk all the same.
local FILE, OTHER = "src/judged.lua", "src/other.lua"
local function body(n, tail)
  local lines = {}
  for i = 1, n do
    lines[i] = ("local l%d = %d"):format(i, i)
  end
  if tail then
    lines[#lines + 1] = tail
  end
  return lines
end
local ORIGINAL = body(60)
vim.fn.writefile(ORIGINAL, vim.fs.joinpath(fixture, FILE))
vim.fn.writefile(body(10), vim.fs.joinpath(fixture, OTHER))

require("codereview").setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "queued from the buffer")
  end,
})

local codereview = require("codereview")
local config = require("codereview.config")
local overlay = require("codereview.overlay")
local queue = require("codereview.queue")
local state = require("codereview.state")

local BAR = config.get().icons.change_bar
local root = assert(vim.uv.fs_realpath(fixture))

state.ensure_queue()

---The blob git gives a file of this checkout as it is on disk now.
---@param rel string
---@return string
local function hash(rel)
  return h.git_lines(root, { "hash-object", "--", rel })[1]
end

---The file in the only window, at the top, as the reviewer reads it.
---@return integer buf
local function code_window()
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, FILE)))
  vim.cmd("normal! gg")
  return vim.api.nvim_get_current_buf()
end

---Change the file in its buffer below its sixtieth line and write it, as a reviewer does.
---
---Below every anchor rather than over the whole buffer: replacing every line takes each
---anchor's extmark to the top with it, and the card would leave the row a case reads.
---@param buf integer
---@param tail string[] What follows line 60; empty for the original file
local function save(buf, tail)
  vim.api.nvim_buf_set_lines(buf, 60, -1, false, tail)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent write!")
  end)
end

local function on()
  assert(not overlay.enabled(), "a case before this one left the overlay on")
  local _, restore = h.capture_notify()
  assert.is_true(codereview.overlay())
  restore()
end

local function off()
  if overlay.enabled() then
    assert.is_false(codereview.overlay())
  end
end

---@return string[]
local function margin_lines()
  local m = assert(overlay.margin(), "no margin is open")
  return vim.api.nvim_buf_get_lines(m.buf, 0, -1, false)
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

---@param id integer
---@return CRAnnotation
local function entry(id)
  for _, item in ipairs(queue.all()) do
    if item.id == id then
      return item
    end
  end
  error("no entry " .. id)
end

-- Each case captures its own entry and measures from a state it can tell apart from the
-- failure's: a flag that is to go is seen set first, in the same case.
describe("a capture from the buffer, on a paint after its file changed", function()
  after_each(off)

  ---A fresh capture on line 3 of the file, with the overlay on.
  ---@return integer buf, integer id
  local function captured()
    queue.clear()
    local buf = code_window()
    on()
    codereview.annotate("bug", { first = 3, last = 3 })
    return buf, queue.all()[1].id
  end

  it("shows stale without a restart, for one git process", function()
    local buf, id = captured()
    assert.equal(BAR .. " ✗ bug 3", margin_lines()[3])

    save(buf, { "-- a line the capture did not see" })
    local runs = git_runs(overlay.paint)
    assert.equal(BAR .. " ✗ bug 3 ⚠ stale", margin_lines()[3])
    assert.is_true(entry(id).stale)
    assert.equal(1, #runs)
    assert.same({ "hash-object", "--", FILE }, runs[1])

    -- A scroll with nothing changed on disk, read from the counter that just read one.
    h.feed("5<C-e>")
    runs = git_runs(overlay.paint)
    assert.equal(0, #runs)
    h.feed("5<C-y>")
    overlay.paint()
    assert.equal(BAR .. " ✗ bug 3 ⚠ stale", margin_lines()[3])
    save(buf, {})
  end)

  it("drops the flag once the file's content is back", function()
    local buf, id = captured()
    save(buf, { "-- a line the capture did not see" })
    overlay.paint()
    assert.is_true(entry(id).stale)
    assert.equal(BAR .. " ✗ bug 3 ⚠ stale", margin_lines()[3])

    save(buf, {})
    overlay.paint()
    assert.equal(BAR .. " ✗ bug 3", margin_lines()[3])
    assert.is_nil(entry(id).stale)
  end)

  it("is judged again when the change came from outside Neovim", function()
    local _, id = captured()
    vim.fn.writefile(body(61), vim.fs.joinpath(fixture, FILE))
    overlay.paint()
    assert.is_true(entry(id).stale)
    vim.fn.writefile(ORIGINAL, vim.fs.joinpath(fixture, FILE))
    overlay.paint()
    assert.is_nil(entry(id).stale)
  end)
end)

describe("a review-path entry on the painted file", function()
  after_each(off)

  -- Both directions, and beside a buffer capture on the same file whose flag does move, so
  -- the paint is known to have judged the file: with no capture there the gate would skip
  -- the rehash altogether, and nothing below could have failed.
  it("keeps the flag its last reconcile set, either way", function()
    queue.clear()
    local buf = code_window()
    local before = hash(FILE)
    on()
    codereview.annotate("bug", { first = 2, last = 2 })
    local captured = queue.all()[1].id
    local changed = { "-- written after the review judged it" }
    vim.fn.writefile(vim.list_extend(vim.deepcopy(ORIGINAL), changed), vim.fs.joinpath(fixture, FILE))
    local after = hash(FILE)
    vim.fn.writefile(ORIGINAL, vim.fs.joinpath(fixture, FILE))

    local base = { kind = "line", path = FILE, abs_path = vim.fs.joinpath(root, FILE), note = "from the review" }
    -- Judged not stale against a blob the file is about to leave.
    local fresh = queue.add(vim.tbl_extend("force", base, {
      type = "fix",
      key = FILE .. ":n:10",
      first = 10,
      last = 10,
      blob = before,
    })).id
    -- Judged stale against the blob the file is about to become.
    local stale = queue.add(vim.tbl_extend("force", base, {
      type = "suggestion",
      key = FILE .. ":n:20",
      first = 20,
      last = 20,
      blob = after,
      stale = true,
    })).id

    save(buf, changed)
    overlay.paint()
    assert.is_true(entry(captured).stale)
    assert.is_nil(entry(fresh).stale)
    assert.is_true(entry(stale).stale)
    local rows = margin_lines()
    assert.is_nil(rows[10]:find("stale", 1, true))
    assert.truthy(rows[20]:find("⚠ stale", 1, true))
    save(buf, {})
  end)
end)

describe("a paint of one file", function()
  after_each(off)

  -- Both files changed, so the paint has a reason to judge each and the gate cannot be what
  -- leaves the other one alone.
  it("judges that file's captures and no other file's", function()
    queue.clear()
    local buf = code_window()
    on()
    codereview.annotate("bug", { first = 4, last = 4 })
    local here = queue.all()[1].id
    local there = queue.add({
      type = "bug",
      kind = "line",
      path = OTHER,
      abs_path = vim.fs.joinpath(root, OTHER),
      key = OTHER .. ":n:1",
      first = 1,
      last = 1,
      note = "about the other file",
      blob = hash(OTHER),
      worktree = true,
    }).id

    vim.fn.writefile(body(11), vim.fs.joinpath(fixture, OTHER))
    save(buf, { "-- changed beside the other" })
    local runs = git_runs(overlay.paint)
    assert.is_true(entry(here).stale)
    assert.is_nil(entry(there).stale)
    local hashed = vim.tbl_filter(function(args)
      return args[1] == "hash-object"
    end, runs)
    assert.same({ { "hash-object", "--", FILE } }, hashed)
    save(buf, {})
  end)
end)
