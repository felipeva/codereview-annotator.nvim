-- Going back along the **checkout** trail.
--
-- A **switch** is not a one-way trip. What this file pins is the history behind it: the
-- checkout the reviewer came from, ordered first in the list they are offered, so going
-- back is the gesture they already know rather than a second one to learn.
--
-- The trail has no surface of its own, deliberately -- a reviewer never handles it, which
-- is why the parent spec gave it no term. So every claim about it here is read through the
-- **picker's ordering**, which is the one place it is visible and is where the rule was
-- written: the trail holds each checkout once, most recent first, and that ordering is the
-- picker's. Nothing below asserts how the trail is stored.
--
-- Two rules in one function, and they are not the same rule, which is the trap this file is
-- shaped around:
--
--   * a checkout whose **directory is gone** is skipped, named, and the walk continues --
--     skipping consumes the entry on purpose;
--   * a checkout that is **there and refuses to open** -- an empty branch scope, which is
--     the ordinary end state of an agent worktree once its branch is merged -- consumes
--     nothing. The reviewer stays where they are and the entry is still there to try again.
--     An implementation that pops before it opens loses that checkout permanently, and no
--     gesture in the plugin restores it: there is no forward, by design.
--
-- Single process, except for the one claim a single process cannot make. Every switch here
-- is one session moving between checkouts, which is what a switch is.
local h = require("tests.helpers")

h.ui(110, 40)

-- Three checkouts of one repository. Realpathed once: `git rev-parse --show-toplevel`
-- answers resolved, and on macOS a temporary directory is a symlink into /private.
local base = assert(vim.uv.fs_realpath(h.fixture("mkcheckouts")))
local MAIN = vim.fs.joinpath(base, "main")
local A = vim.fs.joinpath(base, "agent-a")
local B = vim.fs.joinpath(base, "agent-b")

-- Checkouts this file adds to the fixture, each for one rule and each named for what it is
-- for. Built inside the cases that need them rather than by the fixture script, so the
-- ordering asserted before they exist is asserted against a listing that has only ever held
-- real ones.
local THIRD = vim.fs.joinpath(base, "third") -- a third openable checkout; later made to refuse
local PRUNED = vim.fs.joinpath(base, "pruned") -- deleted under one entry of the trail
local PRUNED_A = vim.fs.joinpath(base, "pruned-a") -- and two of them, above the start
local PRUNED_B = vim.fs.joinpath(base, "pruned-b")

local codereview = require("codereview")
local git = require("codereview.git")
local view = require("codereview.view")

-- The checkout Neovim started in, for the whole file. Nothing below ever changes it: it is
-- what `back` has to be able to reach at the bottom of everything, and a case that moved it
-- would be asserting that guarantee against a directory it had arranged.
vim.cmd("cd " .. vim.fn.fnameescape(A))

---Run git somewhere, for the checkouts this file builds on top of the shared fixture.
---@param cwd string
---@param args string[]
local function git_at(cwd, args)
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait(60000)
  assert(res.code == 0, table.concat(args, " ") .. ": " .. (res.stderr or ""))
end

---Add a linked checkout of the fixture repository, on a branch of its own.
---
---Branched from `agent-a`'s HEAD, so it carries that checkout's commit over master and its
---branch scope has something in it -- a checkout with an empty branch scope cannot be
---opened at all, so it could never be entered and could never reach the trail.
---@param path string
local function add_checkout(path)
  git_at(A, { "worktree", "add", "-q", "-b", vim.fn.fnamemodify(path, ":t"), path })
end

---@return CRView
local function current()
  return assert(view.current(), "no review view open")
end

--- The seam ---------------------------------------------------------------------

-- The `pick_checkout` adapter, stubbed exactly as the send, target and compose adapters are
-- stubbed throughout this suite. It is the one seam this work has, it is the same one
-- `switch_spec` drives, and no test-only door is opened anywhere below.
local offered, chosen = nil, nil
codereview.setup({
  syntax = false,
  pick_checkout = function(checkouts, cb)
    offered = checkouts
    cb(chosen)
  end,
})

---Switch the review to a checkout, through the public entry point and the adapter.
---@param path string|nil
local function switch_to(path)
  chosen = path
  codereview.switch()
end

---The order the picker offers, read by opening it and declining.
---
---Declining moves nothing and pushes nothing, so this can be asked between any two cases
---without disturbing what they are about. It is the only reading of the trail there is.
---@return string[]
local function offered_order()
  offered, chosen = nil, nil
  codereview.switch()
  return vim.tbl_map(function(c)
    return c.path
  end, assert(offered, "the picker was never offered a list"))
end

---Every checkout git still lists, sorted -- the set the picker's order must be a permutation
---of. Sorted because this one is about the set and not the order.
---@return string[]
local function listed()
  local paths = vim.tbl_map(function(c)
    return c.path
  end, git.checkouts(A))
  table.sort(paths)
  return paths
end

---@param paths string[]
---@return string[] sorted copy
local function sorted(paths)
  local copy = vim.deepcopy(paths)
  table.sort(copy)
  return copy
end

--- The trail does not survive the process ------------------------------------------

-- First in the file, and it has to be: the claim is about a process that has not switched
-- anything, and every block below switches. The child does the switching, in a session of
-- its own that shares this one's state directory -- so this process looks for its trail with
-- that session's stores sitting on the disk in front of it. If a trail were ever written,
-- that is where it would be.
describe("a session after the one that switched", function()
  local cmd = {
    vim.v.progpath,
    "--clean",
    "-l",
    vim.fs.joinpath(h.root, "tests", "codereview", "trail_child.lua"),
  }
  local proc = vim.system(cmd, {
    cwd = base,
    text = true,
    env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = base },
  })
  local child = proc:wait(60000)

  -- The guard. The child asserts its own half -- that it reached the second checkout and
  -- that it got back -- so a child that never built a trail cannot leave this block
  -- asserting that nothing came back from nothing.
  it("built a trail and went back along it before it exited", function()
    assert.same(0, child.code, (child.stderr or "") .. (child.stdout or ""))
  end)

  it("has no trail of its own, and says so rather than going nowhere quietly", function()
    local msgs, restore = h.capture_notify()
    codereview.back()
    restore()
    assert.is_true(h.notified(msgs, "No checkout to go back to"), vim.inspect(msgs))
  end)

  it("opens nothing on its way to saying it", function()
    assert.is_nil(view.current())
  end)
end)

--- Going back ---------------------------------------------------------------------

describe("going back after one switch", function()
  it("arrives in the checkout that was chosen", function()
    switch_to(B)
    assert.same(B, current().root)
  end)

  it("returns to the checkout the reviewer came from", function()
    codereview.back()
    assert.same(A, current().root)
  end)

  -- The whole of criterion 2, and the reason there is no key for going back: the gesture is
  -- the one the reviewer already used to leave.
  it("puts the checkout it came from first in the list it offers next", function()
    assert.same({ B, MAIN, A }, offered_order())
  end)
end)

-- "There is no forward" is a negative over the whole surface and no case can assert it.
-- What can be asserted is the thing that makes a forward gesture unnecessary, which is what
-- the parent spec actually argues: after going back, going forward again is the same single
-- keystroke, because the checkout just left is the first entry the picker offers.
describe("going back again, which is what stands in for a forward", function()
  it("returns to the checkout that was just left", function()
    codereview.back()
    assert.same(B, current().root)
  end)

  it("offers the checkout it just left first, so forward costs one keystroke", function()
    assert.same({ A, MAIN, B }, offered_order())
  end)
end)

--- The trail holds each checkout once ------------------------------------------------

-- The case the issue says is easy to omit, and it is easy to omit because the reading that
-- catches it is not the obvious one. After eight switches between two checkouts, "the
-- previous checkout is first" is true of a trail that appended blindly as well -- the head
-- is the checkout just left either way. What separates them is everything below the head: a
-- trail that kept every visit holds the checkout the reviewer is standing in, and orders it
-- above a checkout they have never been to.
describe("switching between two checkouts, over and over", function()
  it("moves between them eight times and lands back where it began", function()
    for _ = 1, 4 do
      switch_to(A)
      switch_to(B)
    end
    switch_to(A)
    assert.same(A, current().root)
  end)

  it("offers exactly what one switch would have left, and in the same order", function()
    assert.same({ B, MAIN, A }, offered_order())
  end)
end)

--- Three checkouts, which is the fewest that can show the ordering ----------------------

-- Two cannot. With two, a trail that removes the checkout being arrived at and one that
-- merely de-duplicates its pushes produce the same list at every step. The third is what
-- makes "most recent first" a claim with an order in it, and it is why the fixture builds
-- three rather than two.
describe("the order a third checkout puts the list in", function()
  it("walks the three of them and comes back to the first", function()
    add_checkout(THIRD)
    switch_to(B)
    switch_to(THIRD)
    switch_to(A)
    assert.same(A, current().root)
  end)

  it("offers the two it has been to, most recent first", function()
    assert.same({ THIRD, B, MAIN, A }, offered_order())
  end)

  -- Stated on its own because it is the half the de-duplication rule is really about. The
  -- checkout the reviewer is standing in is not somewhere they have been, so it cannot
  -- outrank a checkout they have never opened.
  it("does not rank the checkout it is standing in above one never visited", function()
    local order = offered_order()
    local at = {}
    for i, path in ipairs(order) do
      at[path] = i
    end
    assert.is_true(at[MAIN] < at[A], vim.inspect(order))
  end)

  -- An ordering is a permutation. Prepending the trail to the list it was ordering would
  -- offer a checkout twice, and the picker would answer with a row the reviewer did not
  -- believe they were choosing.
  it("offers every checkout git lists, each exactly once", function()
    assert.same(listed(), sorted(offered_order()))
  end)
end)

--- A destination that is where you already are -------------------------------------------

-- The picker offers the current checkout on purpose, marked, and reopening it is a
-- legitimate thing to ask for. What it must not do is make the reviewer's own position the
-- checkout they came from: the picker's first entry would then be the row marked
-- `(current)`, and going back would go nowhere.
describe("reopening the checkout the review is already on", function()
  it("reopens it", function()
    switch_to(A)
    assert.same(A, current().root)
  end)

  it("leaves the trail exactly as it was", function()
    assert.same({ THIRD, B, MAIN, A }, offered_order())
  end)
end)

--- A switch that is refused ------------------------------------------------------------

-- `main` is the branch every other checkout here is reviewed against, so its branch scope is
-- empty and opening it is declined -- the review the reviewer was reading stays where it
-- was. A push that happens on the switch rather than on the open leaves the trail naming a
-- checkout that was never left, which is the checkout they are standing in.
describe("a switch to a checkout that declines to open", function()
  local msgs, restore

  it("says so, and leaves the review where it was", function()
    msgs, restore = h.capture_notify()
    switch_to(MAIN)
    restore()
    assert.is_true(h.notified(msgs, "No changes in scope"), vim.inspect(msgs))
    assert.same(A, current().root)
  end)

  it("puts nothing on the trail on its way to saying nothing happened", function()
    assert.same({ THIRD, B, MAIN, A }, offered_order())
  end)
end)

--- Going back onto a checkout that is there and declines ----------------------------------

-- The asymmetry. A checkout whose branch was merged has an empty branch scope and will not
-- open, and it is still there -- so there is nothing to skip and nothing to name. Going back
-- onto it must cost the reviewer nothing at all, because a pop that has already happened
-- cannot be undone by any gesture the plugin has.
describe("going back onto a checkout whose scope has emptied", function()
  local msgs, restore

  it("is declined in the wording an ordinary open uses", function()
    git_at(THIRD, { "reset", "--hard", "master" })
    msgs, restore = h.capture_notify()
    codereview.back()
    restore()
    assert.is_true(h.notified(msgs, "No changes in scope"), vim.inspect(msgs))
  end)

  it("leaves the review where it was", function()
    assert.same(A, current().root)
  end)

  it("keeps it on the trail, so the reviewer has not lost it", function()
    assert.same({ THIRD, B, MAIN, A }, offered_order())
  end)

  -- Asked twice, because "the entry survives" and "the entry survives once" are different
  -- claims and only the second one is worth anything.
  it("says the same thing the second time, and still has not moved", function()
    local again, stop = h.capture_notify()
    codereview.back()
    stop()
    assert.is_true(h.notified(again, "No changes in scope"), vim.inspect(again))
    assert.same(A, current().root)
    assert.same({ THIRD, B, MAIN, A }, offered_order())
  end)
end)

--- Going back over a checkout that is gone -------------------------------------------------

describe("going back over one checkout whose directory is gone", function()
  local msgs, restore

  it("walks through it and deletes it underneath the trail", function()
    add_checkout(PRUNED)
    switch_to(PRUNED)
    switch_to(B)
    assert.same(B, current().root)
    vim.fn.delete(PRUNED, "rf")
  end)

  it("names the checkout it skipped", function()
    msgs, restore = h.capture_notify()
    codereview.back()
    restore()
    assert.is_true(h.notified(msgs, "no longer exist"), vim.inspect(msgs))
    assert.is_true(h.notified(msgs, PRUNED), vim.inspect(msgs))
  end)

  -- Skipping is not stopping. Without this the case is satisfied by a `back` that names what
  -- it found and gives up on the spot.
  it("carries on to the one underneath it", function()
    assert.same(A, current().root)
  end)
end)

describe("going back with every checkout above the start gone", function()
  local msgs, restore

  it("walks through two of them and deletes them both", function()
    add_checkout(PRUNED_A)
    add_checkout(PRUNED_B)
    switch_to(PRUNED_A)
    switch_to(PRUNED_B)
    switch_to(B)
    assert.same(B, current().root)
    vim.fn.delete(PRUNED_A, "rf")
    vim.fn.delete(PRUNED_B, "rf")
  end)

  it("names both of them, in the order it walked over them", function()
    msgs, restore = h.capture_notify()
    codereview.back()
    restore()
    assert.is_true(h.notified(msgs, PRUNED_B), vim.inspect(msgs))
    assert.is_true(h.notified(msgs, PRUNED_A), vim.inspect(msgs))
  end)

  -- Criterion 5, stated the way the guarantee is stated rather than as a path: the reviewer
  -- lands in the checkout Neovim started in, which is the one a switch never moves.
  it("still lands in the checkout Neovim started in", function()
    assert.same(vim.fn.getcwd(-1, -1), current().root)
  end)
end)

--- The surface -------------------------------------------------------------------------

describe("the surface going back is reached through", function()
  it("is a command, because going back has to work with no review open", function()
    assert.is_true(vim.tbl_contains(vim.fn.getcompletion("CodeReviewBack", "cmdline"), "CodeReviewBack"))
  end)

  -- The other half of "there is no forward", and the half a future contributor would trip
  -- over rather than argue with.
  it("has no forward beside it", function()
    assert.same(
      {},
      vim.tbl_filter(function(name)
        return name:find("Forward", 1, true) ~= nil
      end, vim.fn.getcompletion("CodeReview", "cmdline"))
    )
  end)
end)

--- A trail that empties while it is being walked --------------------------------------------

-- Last, because it deletes checkouts the blocks above need.
--
-- The parent spec says skipping always terminates because the checkout Neovim started in is
-- never switched away from and stays reachable. The first half is true and the second does
-- not follow: that checkout is an ordinary entry, pushed because it was left, with nothing
-- keeping its directory alive. Skipping terminates because the trail is finite and every
-- skip consumes an entry -- so the bottom of it is reachable, and what happens there has to
-- be said rather than left as a press that does nothing.
describe("going back with nothing left on the trail that still exists", function()
  local msgs, restore

  it("is standing in the checkout Neovim started in, with two live checkouts behind it", function()
    assert.same(A, current().root)
    assert.same({ B, THIRD, MAIN, A }, offered_order())
  end)

  it("names both of them once they are gone, and says there is nowhere left to go", function()
    vim.fn.delete(B, "rf")
    vim.fn.delete(THIRD, "rf")
    msgs, restore = h.capture_notify()
    codereview.back()
    restore()
    assert.is_true(h.notified(msgs, B), vim.inspect(msgs))
    assert.is_true(h.notified(msgs, THIRD), vim.inspect(msgs))
    assert.is_true(h.notified(msgs, "No checkout to go back to"), vim.inspect(msgs))
  end)

  it("leaves the reviewer where they were rather than moving them nowhere", function()
    assert.same(A, current().root)
  end)
end)
