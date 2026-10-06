-- The **overlay**'s **captions** kept true where the reviewer is not looking: a queue change
-- made from anywhere repaints every loaded buffer that holds captions, and a write repaints
-- the written buffer and judges its **stale** flag again.
--
-- A spec of its own and not more of overlay_caption_spec, because the write cases rewrite
-- files on disk, and overlay_caption_spec's cases share one file they expect as it was
-- written. Not more of overlay_stale_spec either, which is the margin's.
--
-- `BufWritePost` is raised by `:write` itself, synchronously, so unlike the scroll and resize
-- events it fires inside a spec case: no paint is called by hand after a write here, and a
-- case that read a caption after one would fail if nothing listened.
--
-- The cost is counted in git processes around `vim.system`, as overlay_stale_spec counts
-- the margin's. The repaint of a buffer the reviewer is not in costs extmarks, and the
-- process is what it must not cost, so the process is what is counted. Each zero is read
-- where the change is seen on screen in the same case, so it cannot be the zero of a paint
-- that never ran.
local h = require("tests.helpers")

h.ui(80, 24)
local fixture = h.cd_fixture("mkfixture")

-- Two files of this checkout, untracked, which a capture hashes from disk all the same.
local HERE, THERE = "src/here.lua", "src/there.lua"
local function body(n)
  local lines = {}
  for i = 1, n do
    lines[i] = ("local l%d = %d"):format(i, i)
  end
  return lines
end
vim.fn.writefile(body(60), vim.fs.joinpath(fixture, HERE))
vim.fn.writefile(body(60), vim.fs.joinpath(fixture, THERE))

-- What the next composer answers with. Each case sets it before a capture or an edit.
local answer = "queued from the buffer"
require("codereview").setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, answer)
  end,
  send = function()
    return true
  end,
})

local annotate = require("codereview.annotate")
local codereview = require("codereview")
local config = require("codereview.config")
local overlay = require("codereview.overlay")
local queue = require("codereview.queue")
local state = require("codereview.state")

local CONNECTOR = config.get().icons.caption
local root = assert(vim.uv.fs_realpath(fixture))

state.ensure_queue()

---@param rel string
---@return string
local function abs(rel)
  return vim.fs.joinpath(fixture, rel)
end

---The file in the only window, at the top.
---@param rel string
---@return integer buf
local function only(rel)
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(abs(rel)))
  vim.cmd("normal! gg")
  return vim.api.nvim_get_current_buf()
end

local function on()
  assert(not overlay.enabled(), "a case before this one left the overlay on")
  local _, restore = h.capture_notify()
  assert.is_true(codereview.overlay("inline"))
  restore()
end

local function off()
  if overlay.enabled() then
    assert.is_false(codereview.overlay())
  end
end

---A capture from the current buffer, on one line, with this note.
---@param line integer
---@param note string
---@return integer id
local function capture(line, note)
  answer = note
  local _, restore = h.capture_notify()
  codereview.annotate("bug", { first = line, last = line })
  restore()
  local all = queue.all()
  return all[#all].id
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

---The rows of every caption above a line, as text, top to bottom.
---@param buf integer
---@param line integer
---@return string[]
local function rows_at(buf, line)
  local out = {}
  for _, ns in ipairs({ overlay.NS, overlay.NS_ANCHOR }) do
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { line - 1, 0 }, { line - 1, -1 }, { details = true })) do
      for _, row in ipairs(m[4].virt_lines or {}) do
        out[#out + 1] = table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, row))
      end
    end
  end
  return out
end

---Every caption row in a buffer, on any line.
---@param buf integer
---@return integer
local function caption_count(buf)
  local n = 0
  for line = 1, vim.api.nvim_buf_line_count(buf) do
    n = n + #rows_at(buf, line)
  end
  return n
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

---The `hash-object` runs among them: the stale rehash's process, and the one a repaint of
---an unchanged file must not spawn.
---@param runs string[][]
---@return string[][]
local function hashed(runs)
  return vim.tbl_filter(function(args)
    return args[1] == "hash-object"
  end, runs)
end

---Change the file in its buffer below its sixtieth line and write it, as a reviewer does.
---
---Below every anchor rather than over the whole buffer: replacing every line takes each
---anchor's extmark to the top with it, and the caption would leave the line a case reads.
---@param buf integer
---@param tail string[] What follows line 60; empty for the original file
local function save(buf, tail)
  vim.api.nvim_buf_set_lines(buf, 60, -1, false, tail)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent write!")
  end)
end

-- THERE is captured from and then left, so the change under test reaches a buffer the
-- reviewer is not in; HERE is the buffer they are in. Each case starts from THERE's caption
-- drawn, so the change is seen to move it.
describe("a queue change with captions in two loaded buffers", function()
  after_each(off)

  ---Captures on lines 5 and 9 of THERE, then HERE in the window the overlay follows.
  ---@param split boolean Leave THERE on screen in a split beside, rather than hidden
  ---@return integer here, integer there, integer dropped, integer kept
  local function two_buffers(split)
    queue.clear()
    local there = only(THERE)
    on()
    local first = capture(5, "first there")
    local second = capture(9, "second there")
    if split then
      vim.cmd("vsplit")
    end
    vim.cmd("edit " .. vim.fn.fnameescape(abs(HERE)))
    local here = vim.api.nvim_get_current_buf()
    capture(3, "here")
    assert.same({ CONNECTOR .. " ✗ first there" }, rows_at(there, 5))
    assert.same({ CONNECTOR .. " ✗ second there" }, rows_at(there, 9))
    return here, there, first, second
  end

  it("takes a dropped entry's caption out of a buffer on screen beside, with no git process", function()
    local here, there, dropped = two_buffers(true)
    assert.equal(here, vim.api.nvim_get_current_buf())
    assert.equal(1, #vim.fn.win_findbuf(there))
    require("codereview.view").review_queue()
    local float = vim.api.nvim_get_current_win()
    assert.is_true(vim.fn.search("first there") > 0, "the float does not list the entry")
    local runs = git_runs(function()
      h.feed("x")
    end)
    if vim.api.nvim_win_is_valid(float) then
      vim.api.nvim_win_close(float, true)
    end
    assert.is_false(pcall(entry, dropped))
    assert.same({}, rows_at(there, 5))
    assert.same({ CONNECTOR .. " ✗ second there" }, rows_at(there, 9))
    assert.same({ CONNECTOR .. " ✗ here" }, rows_at(here, 3))
    assert.same({}, hashed(runs))
  end)

  it("takes a dropped entry's caption out of a hidden buffer, with no git process", function()
    local here, there, dropped = two_buffers(false)
    assert.same({}, vim.fn.win_findbuf(there))
    assert.is_true(vim.api.nvim_buf_is_loaded(there))
    local runs = git_runs(function()
      annotate.drop_entry(entry(dropped))
    end)
    assert.same({}, rows_at(there, 5))
    assert.same({ CONNECTOR .. " ✗ second there" }, rows_at(there, 9))
    assert.equal(here, vim.api.nvim_get_current_buf())
    assert.same({}, hashed(runs))
  end)

  it("changes an edited note's caption in a buffer the reviewer is not in, with no git process", function()
    local _, there, _, kept = two_buffers(false)
    answer = "second there, edited"
    local runs = git_runs(function()
      annotate.edit_note(entry(kept))
    end)
    assert.equal("second there, edited", entry(kept).note)
    assert.same({ CONNECTOR .. " ✗ second there, edited" }, rows_at(there, 9))
    assert.same({}, hashed(runs))
  end)

  it("takes every caption out of every buffer that held one on a submit", function()
    local here, there = two_buffers(true)
    assert.is_true(caption_count(here) > 0)
    local _, restore = h.capture_notify()
    assert.is_true(require("codereview.delivery").submit())
    restore()
    assert.same({}, queue.all())
    assert.equal(0, caption_count(here))
    assert.equal(0, caption_count(there))
  end)
end)

describe("a write of a buffer with captions", function()
  after_each(off)

  ---A fresh capture on line 3 of HERE, with the overlay on, drawn without the flag.
  ---@return integer buf, integer id
  local function captured()
    queue.clear()
    local buf = only(HERE)
    on()
    local id = capture(3, "judged on a write")
    assert.same({ CONNECTOR .. " ✗ judged on a write" }, rows_at(buf, 3))
    return buf, id
  end

  it("shows stale after the write, for one git process", function()
    local buf, id = captured()
    local runs = git_runs(function()
      save(buf, { "-- a line the capture did not see" })
    end)
    assert.is_true(entry(id).stale)
    assert.same({ CONNECTOR .. " ✗ ⚠ stale judged on a write" }, rows_at(buf, 3))
    assert.same({ { "hash-object", "--", HERE } }, runs)
    save(buf, {})
  end)

  -- The gate is the file's stat, so "no content change" is what the stat says: a real
  -- `:write` of the same text moves the mtime and is judged again, one process. What runs
  -- none is a write whose stat the gate has seen. The note is changed behind the queue's
  -- back first, so the repaint is seen to have run: a zero from a handler that never ran
  -- would read the same.
  it("runs no git process on a second write the file's stat says changed nothing", function()
    local buf, id = captured()
    save(buf, { "-- a line the capture did not see" })
    assert.same({ CONNECTOR .. " ✗ ⚠ stale judged on a write" }, rows_at(buf, 3))
    entry(id).note = "repainted"
    local runs = git_runs(function()
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
    end)
    assert.same({ CONNECTOR .. " ✗ ⚠ stale repainted" }, rows_at(buf, 3))
    assert.same({}, runs)
    save(buf, {})
  end)

  it("drops the flag when the content is back and written", function()
    local buf, id = captured()
    save(buf, { "-- a line the capture did not see" })
    assert.same({ CONNECTOR .. " ✗ ⚠ stale judged on a write" }, rows_at(buf, 3))
    save(buf, {})
    assert.is_nil(entry(id).stale)
    assert.same({ CONNECTOR .. " ✗ judged on a write" }, rows_at(buf, 3))
  end)

  -- Beside a buffer capture whose flag does move, so the write is known to have judged the
  -- file: with no capture there the rehash has nothing to do, and nothing below could fail.
  it("leaves a review-path entry's caption with the flag its last reconcile set", function()
    local buf, captured_id = captured()
    local base = { kind = "line", path = HERE, abs_path = vim.fs.joinpath(root, HERE) }
    local before = h.git_lines(root, { "hash-object", "--", HERE })[1]
    -- Judged not stale against a blob the file is about to leave.
    queue.add(vim.tbl_extend("force", base, {
      type = "fix",
      key = HERE .. ":n:10",
      first = 10,
      last = 10,
      blob = before,
      note = "fresh",
    }))
    -- Judged stale against a blob the file never had.
    queue.add(vim.tbl_extend("force", base, {
      type = "suggestion",
      key = HERE .. ":n:20",
      first = 20,
      last = 20,
      blob = ("0"):rep(40),
      stale = true,
      note = "stale",
    }))
    overlay.paint()
    assert.same({ CONNECTOR .. " ✎ fresh" }, rows_at(buf, 10))
    assert.same({ CONNECTOR .. " ✦ ⚠ stale stale" }, rows_at(buf, 20))

    save(buf, { "-- written after the review judged it" })
    assert.is_true(entry(captured_id).stale)
    assert.same({ CONNECTOR .. " ✎ fresh" }, rows_at(buf, 10))
    assert.same({ CONNECTOR .. " ✦ ⚠ stale stale" }, rows_at(buf, 20))
    save(buf, {})
  end)
end)
