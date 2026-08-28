-- The queued count a statusline asks for: which **checkout** it is about, and what it costs.
--
-- `codereview.count()` is called on every redraw, so it may spend nothing that grows with
-- the number of redraws. Since the queue became per checkout it also has to decide which
-- checkout the number is about, and #173 answered that with a pointer the queue holds --
-- moved by whatever had just resolved a root for its own reasons. The recorded consequence,
-- and what this spec closes: after a directory change the count went on reporting the
-- checkout it was last pointed at, becoming right at the next capture, submit, copy or
-- queue float.
--
-- The count resolves for itself instead, through a memo keyed on the directory **string**.
-- Keyed on the string and never on `DirChanged`, which is the trap: a tab whose own
-- directory is deleted falls back to the global one and fires no such event, so a cache
-- hung on it goes stale in exactly the case it would exist for (ADR-0008). The last block
-- is that case, with the absence of the event asserted rather than assumed.
--
-- One case counts git *processes* rather than resolver calls, because a memo sits above the
-- process: counting `git.root` would pass for a memo that never hits, and counting nothing
-- at all would pass for a resolver that always answers nil.
--
-- **The intersection with the switch is the last block, and it belongs to neither slice
-- alone.** `state.current_checkout` answers the review's own root when a review is open and
-- falls through to the working directory only when there is none (ADR-0008). #174 built
-- that precedence and has no resolution of its own to disagree with it; this slice built the
-- resolution and had no switch to make the two answers differ. Their combination implies a
-- behaviour neither pinned: after a **switch**, the number a statusline shows is about the
-- checkout the review is on, read from a tab that is standing somewhere else.
--
-- That block is also where the honest thing about the memo gets said. With a review open the
-- count consults it **not at all** -- the review is already holding the answer, which is
-- cheaper than any memo -- so the blocks that count git processes are deliberately the ones
-- with no review open. The memo is the fall-through's, and only the fall-through's.
local h = require("tests.helpers")

h.ui(110, 40)

-- Three checkouts of one repository, plus what the last two blocks build for themselves.
-- Realpathed once: `git rev-parse --show-toplevel` answers resolved, and on macOS a
-- temporary directory is a symlink into /private.
local base = assert(vim.uv.fs_realpath(h.fixture("mkcheckouts")))
local A = vim.fs.joinpath(base, "agent-a")
local B = vim.fs.joinpath(base, "agent-b")
-- Untouched until the block that measures what a first resolution costs, which is the whole
-- of what it is for: a checkout no memo can already hold an answer for.
local MAIN = vim.fs.joinpath(base, "main")

local codereview = require("codereview")
local git = require("codereview.git")
local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

local note = "unset"
-- The checkout the picker answers with, set before each switch. Stubbed exactly as the send,
-- target and compose adapters are stubbed throughout this suite.
local chosen = nil
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, note)
  end,
  pick_checkout = function(_, cb)
    cb(chosen)
  end,
})

---Capture an annotation about a checkout's `src/main.lua`, from inside that checkout.
---@param checkout string
---@param text string
local function annotate_in(checkout, text)
  vim.cmd("cd " .. vim.fn.fnameescape(checkout))
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(checkout, "src/main.lua")))
  note = text
  codereview.annotate("bug")
end

---The notes the queue holds right now.
---@return string[]
local function queued_notes()
  return vim.tbl_map(function(e)
    return e.note
  end, queue.all())
end

---How many git processes a call spawns.
---
---Wrapped around `vim.system` rather than around `git.root`, and this is the point of the
---case that uses it: a memo sits above the process, so counting the resolver's own calls
---would be satisfied by a memo that never hits. The process is the cost being removed, so
---the process is what is counted.
---@param fn fun()
---@return integer
local function git_spawns(fn)
  local spawned = 0
  local orig = vim.system
  vim.system = function(cmd, ...)
    if type(cmd) == "table" and cmd[1] == "git" then
      spawned = spawned + 1
    end
    return orig(cmd, ...)
  end
  local ok, err = pcall(fn)
  vim.system = orig
  assert(ok, err)
  return spawned
end

describe("the fixture the rest of this spec depends on", function()
  it("resolves each checkout to itself", function()
    assert.same(A, git.root(A))
    assert.same(B, git.root(B))
  end)

  -- Two copies of a repository would satisfy everything below about separation and none of
  -- it about checkouts.
  it("makes them checkouts of one repository", function()
    local common = { "rev-parse", "--path-format=absolute", "--git-common-dir" }
    assert.same(h.git_lines(A, common), h.git_lines(B, common))
  end)
end)

-- The recorded limit, and the whole of the gesture that reaches it: the reviewer changes
-- directory and does nothing else. No capture, no submit, no copy and no queue float --
-- each of those resolves a root on its way and would move the pointer for the count.
describe("the count after a directory change with nothing else resolving a root", function()
  annotate_in(A, "about agent-a")
  annotate_in(A, "also about agent-a")

  -- The guard: without this the block below is satisfied by nothing having been captured.
  it("counts what was captured in the checkout it was captured in", function()
    assert.same(2, codereview.count())
  end)

  vim.cmd("cd " .. vim.fn.fnameescape(B))

  it("stops reporting the checkout the reviewer has left", function()
    assert.are_not.same(2, codereview.count())
  end)

  -- What the second checkout holds, which is nothing until something reads its store back.
  -- The count reads memory: a state file per redraw is the cost this number has never paid,
  -- and it reports what the queue holds for a checkout rather than what the disk does.
  it("reports the checkout the reviewer is in", function()
    assert.same(0, codereview.count())
  end)

  -- And the entries are still there, in the checkout they are about, for the moment
  -- something does resolve a root.
  it("gives them back on returning, with nothing but the directory changed", function()
    vim.cmd("cd " .. vim.fn.fnameescape(A))
    assert.same(2, codereview.count())
  end)
end)

local LOOSE = "a thought with no repository behind it"

-- An entry with no repository behind it belongs to no checkout and rides along in whichever
-- one the reviewer is in, so it is in the number everywhere. Counted with a checkout's own
-- entries and never instead of them: the count asked of the owned half alone reads 0 for a
-- reviewer holding a bare note, with unsent work in hand.
describe("a bare note in hand", function()
  state.save_global({ { id = 1, type = "issue", kind = "note", key = "note:0", note = LOOSE } })
  vim.cmd("cd " .. vim.fn.fnameescape(A))
  state.restore_queue(A)

  it("is in the number beside the checkout's own entries", function()
    assert.same(3, codereview.count())
  end)

  it("is still in it from another checkout, which holds nothing of its own", function()
    vim.cmd("cd " .. vim.fn.fnameescape(B))
    assert.same(1, codereview.count())
  end)
end)

-- What the redraw costs, on the path that costs anything: no review is open here, so
-- `current_checkout` falls through to the working directory and the memo is what answers.
-- Both halves are needed -- a memo that never hits fails the second case, and a resolver
-- that answers nil without asking anything fails the first. The review case is cheaper still
-- and is the last block's, where the number is asked with a review on screen.
describe("asking for the count over and over in one checkout", function()
  vim.cmd("cd " .. vim.fn.fnameescape(MAIN))

  local first, answer
  first = git_spawns(function()
    answer = codereview.count()
  end)

  local repeated = git_spawns(function()
    for _ = 1, 20 do
      codereview.count()
    end
  end)

  it("spawns a git process for a checkout it has never resolved", function()
    assert.is_true(first > 0, "the first count in " .. MAIN .. " spawned no git process")
  end)

  it("spawns none at all for the twenty after it", function()
    assert.same(0, repeated)
  end)

  it("answers the same both times, so the memo is not merely quiet", function()
    assert.same(1, answer)
    assert.same(1, codereview.count())
  end)
end)

-- The answer that is deliberately not remembered. A directory outside every checkout is
-- asked again every time, because the alternative is a `git init` under the reviewer's feet
-- that stays invisible for the life of the session -- they would make a repository and the
-- number would go on being about no checkout at all until Neovim restarted.
describe("a directory that is inside no checkout, and then is", function()
  local fresh = vim.fs.joinpath(base, "fresh")
  vim.fn.mkdir(fresh, "p")
  vim.cmd("cd " .. vim.fn.fnameescape(fresh))

  -- Entries filed under a checkout that is not one yet: invisible while the directory is a
  -- plain directory, and the number the moment it becomes a checkout. Seeded rather than
  -- captured, because a capture resolves a root on its way and would answer the question
  -- for the count.
  queue.replace(fresh, {
    {
      id = 90,
      type = "fix",
      kind = "file",
      path = "src/main.lua",
      abs_path = vim.fs.joinpath(fresh, "src/main.lua"),
      key = "src/main.lua:f:0",
      inline = false,
      note = "queued about a directory that was not a checkout yet",
    },
  })

  it("is inside no checkout to begin with", function()
    assert.is_nil(git.root(fresh), fresh .. " is inside a checkout")
  end)

  it("counts the bare note and nothing else while that is true", function()
    assert.same(1, codereview.count())
  end)

  -- The cost of refusing to remember a "no", stated here so that remembering one cannot be
  -- introduced without a case going red.
  it("asks git again each time, rather than remembering that answer", function()
    assert.is_true(git_spawns(function()
      codereview.count()
      codereview.count()
    end) >= 2, "an answer of 'no checkout' was remembered")
  end)

  h.git_lines(fresh, { "init", "-q", "-b", "master" })

  it("is about the new checkout the moment there is one", function()
    assert.same(2, codereview.count())
  end)
end)

-- The trap the memo's key exists for, and the reason it is not `DirChanged`.
--
-- A tab whose own directory is deleted reports no working directory at all, adopts the
-- global one when it is next entered, and fires no event for either. A count keyed on that
-- event is stale in precisely this case; a count keyed on the directory string reads the
-- global directory and is right straight away.
describe("a tab whose own directory was deleted underneath it", function()
  local doomed = vim.fs.joinpath(base, "doomed")
  h.git_lines(MAIN, { "worktree", "add", "-q", "-b", "doomed", doomed })

  -- The global directory, which is the one the tab falls back to.
  vim.cmd("cd " .. vim.fn.fnameescape(A))
  vim.cmd("tabnew")
  vim.cmd("tcd " .. vim.fn.fnameescape(doomed))

  it("counts the checkout the tab is in while that checkout exists", function()
    assert.same(1, codereview.count())
  end)

  -- Installed after the `tcd`, which fires the event legitimately. What is being asserted is
  -- that the deletion below fires nothing.
  local fired = 0
  local au = vim.api.nvim_create_autocmd("DirChanged", {
    callback = function()
      fired = fired + 1
    end,
  })
  vim.fn.delete(doomed, "rf")

  it("says nothing happened", function()
    assert.same(0, fired)
  end)

  -- The guard that makes this case what it claims to be: the working directory is not
  -- merely different, it is absent, and `git rev-parse` cannot be asked about it at all.
  it("reports no working directory of its own", function()
    assert.same("", vim.fn.getcwd())
  end)

  it("counts the global checkout, with no event having announced it", function()
    assert.same(3, codereview.count())
  end)

  vim.api.nvim_del_autocmd(au)
  vim.cmd("tabclose")
  vim.cmd("cd " .. vim.fn.fnameescape(A))
end)

-- The intersection neither slice owns: the **switch** and the resolution, together.
--
-- After a switch the review is on one checkout and the reviewer's own tab is still standing
-- in another -- deliberately, because the global working directory is never moved and that
-- is what guarantees they can get back to where Neovim started. The number a statusline
-- shows has to be about the review, not about where they are standing: it sits beside the
-- diff, and the queue it counts is the one a submit from that review would send.
--
-- Asked from the reviewer's own tab on purpose. The switch sets `:tcd` on the review's tab,
-- so inside that tab the working directory holds the right answer by coincidence and a
-- count reading it would pass. One tab over it does not, which is where the two readings
-- come apart.
describe("the count after a switch, read from the tab the reviewer is standing in", function()
  local WAITING = "left unsent in agent-b"
  local left = state.load(B)
  left.queue = {
    {
      id = 80,
      type = "fix",
      kind = "file",
      path = "src/main.lua",
      abs_path = vim.fs.joinpath(B, "src/main.lua"),
      key = "src/main.lua:f:0",
      inline = false,
      note = WAITING,
    },
  }
  state.save(B, left)

  -- The reviewer is standing in the first checkout, and never leaves it.
  vim.cmd("cd " .. vim.fn.fnameescape(A))
  local standing = codereview.count()

  chosen = B
  codereview.switch()

  local review = assert(view.current(), "the switch opened no review")
  -- Back to the tab the reviewer was in, which the switch did not move.
  vim.cmd("tabprev")

  it("switched the review to the other checkout", function()
    assert.same(B, review.root)
  end)

  it("left the reviewer standing where they were", function()
    assert.same(A, vim.fn.getcwd())
  end)

  -- Without this the case is vacuous: if the two checkouts held the same number, a count
  -- reading the working directory would pass while being about the wrong queue.
  it("has a different number to report for each of the two", function()
    assert.are_not.same(standing, codereview.count())
  end)

  it("reports the checkout the review is on", function()
    assert.same(2, codereview.count())
    assert.is_true(vim.tbl_contains(queued_notes(), WAITING), vim.inspect(queued_notes()))
  end)

  it("agrees with itself asked from inside the review tab", function()
    vim.cmd("tabnext")
    assert.same(2, codereview.count())
    vim.cmd("tabprev")
  end)

  -- Cheaper than the memo, and not because of it: the review is already holding its own
  -- root, so nothing is resolved and nothing is looked up. Stated here rather than folded
  -- into the cost block above, which is about the fall-through and has no review open.
  it("spawns no git process at all, the memo not being consulted", function()
    assert.same(
      0,
      git_spawns(function()
        for _ = 1, 20 do
          codereview.count()
        end
      end)
    )
  end)
end)
