-- The header of the plugin's own **payload** with `sync` set and with no `sync`.
--
-- With `sync` set, the header is the one the **queue owner** writes, `Annotations — N
-- items`, so that the agent reads the same message for the same entries on both paths.
-- First no queue owner listens: the socket is a path that nobody binds, and the plugin
-- renders every payload itself. Last the fake queue owner listens, for the copy to a
-- register, which the plugin renders also while connected. A connected submit is rendered
-- by the queue owner, so it is not a case here.
--
-- Every payload is read through the surfaces a reviewer uses: a copy to the `+` register,
-- `<C-s>` and `<C-a>` in the diff, and an immediate send. A review is open for each copy, so that the scope and the
-- file counts are available to the header and their absence with `sync` set is a result.
local h = require("tests.helpers")
local fake = require("tests.fake_queue_owner")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local codereview = require("codereview")
local queue = require("codereview.queue")

-- Nobody binds it, so every connect fails and the plugin keeps its own queue.
local socket = vim.fn.tempname() .. ".sock"

local sent = {}

---The note of the next capture, when a case needs one of its own.
---@type string|nil
local next_note = nil

---U+3000, a space that the queue owner trims from a note and `vim.trim` does not.
local IDEO = "\227\128\128"

---@param socket_path string|nil The socket of `sync`, or nil for no `sync`
local function setup(socket_path)
  codereview.setup({
    syntax = false,
    send = function(text)
      sent[#sent + 1] = text
    end,
    -- One stub for both composers: a note repeats the label of its entry, so the same
    -- capture gives the same text with and without `sync`.
    compose = function(ctx, on_accept)
      on_accept(nil, ctx.preamble and "read the bugs first" or next_note or ("re: " .. ctx.label))
    end,
    sync = socket_path and {
      socket = socket_path,
      target = function()
        return { tool = "custom", address = "agent", cwd = fixture }
      end,
    } or nil,
  })
end

---Capture one line of `src/main.lua` from an ordinary buffer, with no review open.
---@param type_name string
---@param line integer
local function capture(type_name, line)
  codereview.close()
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
  codereview.annotate(type_name, { first = line, last = line })
end

---The batch as `:CodeReviewCopy` leaves it, copied with the branch review open.
---@return string[] lines
local function copied()
  codereview.open("branch")
  vim.fn.setreg("+", "")
  codereview.copy()
  return vim.split(vim.fn.getreg("+"), "\n")
end

---The header today, with the scope and the file counts of the open review.
---@param annotations string
---@return string
local function scoped(annotations)
  return ("Code review — %s on branch vs master (%d files, 0 reviewed)"):format(
    annotations,
    #require("codereview.view").current().files
  )
end

---@param lines string[]
---@param from integer
---@return string
local function after(lines, from)
  return table.concat(vim.list_slice(lines, from), "\n")
end

local one, several

describe("with sync set and no queue owner", function()
  setup(socket)
  queue.clear()
  capture("bug", 1)
  one = copied()

  it("heads a copy of one entry with the queue owner's header", function()
    assert.same("Annotations — 1 item", one[1])
  end)

  capture("nitpick", 2)
  capture("bug", 3)
  several = copied()

  it("heads a copy of several entries with the queue owner's header", function()
    assert.same("Annotations — 3 items", several[1])
  end)

  local before = #sent
  h.feed("<C-s>")
  local submitted = vim.split(sent[#sent] or "", "\n")

  it("gives the send adapter the same header on a submit", function()
    assert.same(before + 1, #sent)
    assert.same("Annotations — 3 items", submitted[1])
  end)

  it("gives the send adapter the text that the copy gave", function()
    assert.same(table.concat(several, "\n"), sent[#sent])
  end)

  capture("bug", 1)
  codereview.open("branch")
  before = #sent
  h.feed("<C-a>")
  local covered = vim.split(sent[#sent] or "", "\n")

  it("writes the header under a preamble, with a blank line between them", function()
    assert.same(before + 1, #sent)
    assert.same({ "read the bugs first", "", "Annotations — 1 item" }, vim.list_slice(covered, 1, 3))
  end)

  it("changes nothing under the header of a preamble", function()
    assert.same(after(one, 2), after(covered, 4))
  end)

  -- A batch of one through the same renderer (ADR-0004), so the same header.
  codereview.close()
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
  before = #sent
  codereview.annotate("bug", { first = 1, last = 1 }, { immediate = true })

  it("heads an immediate send with the queue owner's header", function()
    assert.same(before + 1, #sent)
    assert.same("Annotations — 1 item", vim.split(sent[#sent], "\n")[1])
  end)

  queue.clear()
  next_note = "spaced" .. IDEO
  capture("bug", 1)
  next_note = nil
  local spaced = copied()

  it("trims a note as the queue owner trims it", function()
    assert.same("spaced", spaced[#spaced])
  end)
end)

describe("without sync", function()
  setup(nil)
  queue.clear()
  capture("bug", 1)
  local plain_one = copied()

  it("heads a copy of one entry with the scope and the file counts", function()
    assert.same(scoped("1 annotation"), plain_one[1])
  end)

  capture("nitpick", 2)
  capture("bug", 3)
  local plain = copied()

  it("heads a copy of several entries with the scope and the file counts", function()
    assert.same(scoped("3 annotations"), plain[1])
  end)

  -- The groups, the numbering and each entry's text. Only the first line may differ.
  it("renders the same groups, numbers and notes as with sync set", function()
    -- Or two empty bodies would be equal.
    assert.is_truthy(after(plain, 2):find("## Bugs (2)", 1, true), after(plain, 2))
    assert.is_truthy(after(plain, 2):find("### 3. ", 1, true), after(plain, 2))
    assert.same(after(several, 2), after(plain, 2))
    assert.same(after(one, 2), after(plain_one, 2))
  end)

  queue.clear()
  capture("bug", 1)
  codereview.open("branch")
  local header = scoped("1 annotation")
  local before = #sent
  h.feed("<C-a>")
  local covered = vim.split(sent[#sent] or "", "\n")

  it("writes today's header under a preamble", function()
    assert.same(before + 1, #sent)
    assert.same({ "read the bugs first", "", header }, vim.list_slice(covered, 1, 3))
  end)

  queue.clear()
  next_note = "spaced" .. IDEO
  capture("bug", 1)
  next_note = nil
  local spaced = copied()

  it("writes a note as it is", function()
    assert.same("spaced" .. IDEO, spaced[#spaced])
  end)

  queue.clear()
end)

describe("with sync set and a queue owner listening", function()
  local owner = fake.start()
  setup(owner.path)
  capture("bug", 1)
  -- The entry reached the queue owner, so the copy below is made while it listens.
  vim.wait(3000, function()
    return vim.tbl_contains(owner:ops(), "keep")
  end, 10)
  vim.wait(200)
  local connected = copied()

  -- Another tool empties the note. The plugin takes the note as the queue owner sends it.
  local emptied = vim.deepcopy(owner.queue)
  emptied[1].note = ""
  owner:push_queue(emptied)
  vim.wait(3000, function()
    return queue.entries()[1] ~= nil and queue.entries()[1].note == ""
  end, 10)
  local empty = copied()
  owner:stop()

  it("gave the entry to the queue owner", function()
    assert.is_true(vim.tbl_contains(owner:ops(), "keep"), vim.inspect(owner:ops()))
  end)

  it("heads a copy with the queue owner's header", function()
    assert.same("Annotations — 1 item", connected[1])
  end)

  -- The entry ends at its heading, as the queue owner writes it: no blank line, no empty one.
  it("leaves an empty note out of a copy", function()
    assert.same("", queue.entries()[1].note)
    assert.same({ "## Bugs (1) — diagnose and fix these", "", "### 1. @src/main.lua#L1" }, vim.list_slice(empty, 3))
  end)
end)
