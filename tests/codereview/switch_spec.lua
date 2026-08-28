-- Moving the review from one **checkout** to another, in place.
--
-- The corruption #173 removed was reachable by changing directory. This slice gives the
-- reviewer a gesture that does the same journey without that change, and the whole of the
-- difference is where a review's checkout comes from: the review's own root, handed to it
-- when it opens, rather than the working directory it happened to be opened in (ADR-0008).
--
-- What this file can and cannot say about that ADR is worth stating once, because the gap
-- is not obvious. Inside the review tab `getcwd()` answers with the `:tcd` a switch has
-- just set, so an implementation that reads the tab's directory instead of the review's
-- root passes every case below. The case that separates them is a checkout deleted under
-- an open review, where Neovim silently resets that tab to the global directory and fires
-- no event -- and that is #177's to pin, not this file's. What is asserted here is what a
-- switch can be caught getting wrong today:
--
--   * the **global** working directory never moves, and the tab the reviewer started in
--     keeps its own -- which is what kills "change directory, then reopen";
--   * the review's tab carries the chosen checkout, set after that tab exists;
--   * the queue, the store each entry reaches and the id a new annotation takes are the
--     review's checkout's -- asked from a tab whose directory is a *different* checkout,
--     which is where a working-directory read is still visible.
--
-- Single process. Every claim here is about one session moving between checkouts, which is
-- what a switch is; what needs a genuine restart is in `checkout_restart_spec` and stays
-- there.
local h = require("tests.helpers")

h.ui(110, 40)

-- Three checkouts of one repository. Realpathed once: `git rev-parse --show-toplevel`
-- answers resolved, and on macOS a temporary directory is a symlink into /private.
local base = assert(vim.uv.fs_realpath(h.fixture("mkcheckouts")))
local MAIN = vim.fs.joinpath(base, "main")
local A = vim.fs.joinpath(base, "agent-a")
local B = vim.fs.joinpath(base, "agent-b")

local codereview = require("codereview")
local git = require("codereview.git")
local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

-- The checkout the reviewer is standing in, for the whole file. Nothing below ever changes
-- it, and half the cases here are about that: a switch that moved it would satisfy every
-- assertion about which checkout the review is on and destroy the one guarantee that a
-- reviewer can always get back to where they started.
vim.cmd("cd " .. vim.fn.fnameescape(A))

---Run git somewhere, for the fixtures this file builds on top of the shared one.
---@param cwd string
---@param args string[]
local function git_at(cwd, args)
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait(60000)
  assert(res.code == 0, table.concat(args, " ") .. ": " .. (res.stderr or ""))
end

---@return CRView
local function current()
  return assert(view.current(), "no review view open")
end

---The notes the queue holds right now.
---@return string[]
local function queued_notes()
  return vim.tbl_map(function(e)
    return e.note
  end, queue.all())
end

---The notes a checkout's store holds, queued and archived alike.
---
---Both halves, because "this checkout's store did not receive that entry" is a claim about
---the document: a dispatch moves an entry from one key to the other, so reading the queue
---alone would go quiet the moment a batch went out.
---@param checkout string
---@return string[]
local function stored_notes(checkout)
  local doc = state.load(checkout)
  local notes = {}
  for _, entry in ipairs(doc.queue or {}) do
    notes[#notes + 1] = entry.note
  end
  for _, batch in ipairs(doc.archive or {}) do
    for _, entry in ipairs(batch.entries or {}) do
      notes[#notes + 1] = entry.note
    end
  end
  table.sort(notes)
  return notes
end

---The paths a listing names, sorted so the assertion is about the set and not the order.
---
---Ordering is the **trail**'s (#176), which this slice does not build: there is nothing yet
---that could put one checkout before another, so asserting an order here would pin git's.
---@param checkouts table[]
---@return string[]
local function paths_of(checkouts)
  local paths = vim.tbl_map(function(c)
    return c.path
  end, checkouts or {})
  table.sort(paths)
  return paths
end

--- What a checkout is left holding before any of this ---------------------------

-- Unsent work and a dispatched batch left in the second checkout by an earlier session.
-- Written through the store's own accessors rather than as a file, so it carries whatever a
-- document carries.
--
-- The archive is here for the id counter, and its ids are deliberately far above anything
-- this session can issue: the counter is one counter for every checkout and it is seeded
-- per checkout as each is read back, so only *this* checkout's archive being read can keep
-- an annotation made after a switch clear of the entries already drawn on its diff. The
-- stored queue cannot do it -- id 7 is below both -- which is what stops the case passing
-- with the seeding deleted.
local ARCHIVED_IDS = { 40, 41 }

-- An entry with no repository behind it, left by an earlier session. It belongs to no
-- checkout, so it rides along in whichever one the reviewer is in -- including one they
-- arrive in by switching, which is a checkout this session has never read back. Stored
-- before any switch, because a checkout's store is read once per session: it can only be
-- picked up by the read-back a first arrival makes.
local LOOSE = "a thought with no repository behind it"
state.save_global({ { id = 3, type = "issue", kind = "note", key = "note:0", note = LOOSE } })

do
  local left = state.load(B)
  left.queue = {
    {
      id = 7,
      type = "fix",
      kind = "file",
      path = "src/main.lua",
      abs_path = vim.fs.joinpath(B, "src/main.lua"),
      key = "src/main.lua:f:0",
      inline = false,
      note = "left unsent in agent-b",
    },
  }
  left.archive = {
    {
      at = os.time(),
      target = "local",
      entries = {
        {
          id = ARCHIVED_IDS[1],
          type = "bug",
          kind = "file",
          path = "src/main.lua",
          abs_path = vim.fs.joinpath(B, "src/main.lua"),
          key = "src/main.lua:f:0",
          inline = false,
          note = "dispatched from agent-b long ago",
        },
        {
          id = ARCHIVED_IDS[2],
          type = "bug",
          kind = "file",
          path = "src/config.lua",
          abs_path = vim.fs.joinpath(B, "src/config.lua"),
          key = "src/config.lua:f:0",
          inline = false,
          note = "also dispatched from agent-b long ago",
        },
      },
    },
  }
  state.save(B, left)
end

--- The listing ------------------------------------------------------------------

-- No adapter is wired yet, and that is deliberate: what the plugin builds for itself has to
-- be asserted by a process that has not yet been handed a replacement for it. The same
-- ordering `open_diff_spec` runs in, for the same reason.
local note = "unset"
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, note)
  end,
})

describe("the checkouts the plugin builds a list from", function()
  it("names every checkout of the repository the reviewer is in", function()
    assert.same({ A, B, MAIN }, paths_of(git.checkouts(A)))
  end)

  it("names the branch each one is on", function()
    local branches = {}
    for _, c in ipairs(git.checkouts(A)) do
      branches[c.path] = c.branch
    end
    assert.same({ [A] = "agent-a", [B] = "agent-b", [MAIN] = "master" }, branches)
  end)

  it("says which one the reviewer is already in", function()
    local mine = {}
    for _, c in ipairs(git.checkouts(A)) do
      if c.current then
        mine[#mine + 1] = c.path
      end
    end
    assert.same({ A }, mine)
  end)

  -- A store's file name is a base name plus a hash of the *full path*, so a listed path
  -- that differs from what `git rev-parse --show-toplevel` answers by one symlink gives
  -- that checkout a second store and hides the queue left in the first. git resolved these
  -- paths itself on the machine this was written on, so this is a guard rather than a
  -- discriminator -- it is what fails on a platform where it does not.
  it("names each one as its own git names it, so a checkout cannot get a second store", function()
    for _, c in ipairs(git.checkouts(A)) do
      assert.same(c.path, git.root(c.path))
      assert.same(state.path(c.path), state.path(assert(git.root(c.path))))
    end
  end)

  -- Registered, listed by git as `prunable`, and impossible to open. Added after the case
  -- above rather than by the fixture script, so "names every checkout" is asserted against
  -- a listing that has never held anything but real ones.
  it("leaves out a checkout whose directory is gone", function()
    local gone = vim.fs.joinpath(base, "gone")
    git_at(A, { "worktree", "add", "-q", "-b", "gone", gone })
    vim.fn.delete(gone, "rf")
    assert.same({ A, B, MAIN }, paths_of(git.checkouts(A)))
  end)

  -- A bare repository is in its own `worktree list` and has no working tree at all, so
  -- there is no diff to review in it and nothing to set a tab's directory to. Its own
  -- repository, because the shared fixture's is not bare and turning it into one would
  -- take every other case in this file with it.
  it("leaves out a bare repository", function()
    local bare = vim.fs.joinpath(base, "bare.git")
    local attached = vim.fs.joinpath(base, "bare-checkout")
    git_at(base, { "clone", "-q", "--bare", MAIN, bare })
    git_at(bare, { "worktree", "add", "-q", attached, "master" })
    assert.same({ assert(vim.uv.fs_realpath(attached)) }, paths_of(git.checkouts(attached)))
  end)
end)

--- The picker the plugin ships ---------------------------------------------------

-- What the shipped picker was offered, and the path it answers with. Replaced for the whole
-- file: nothing here reaches the annotation type picker, which is the only other surface in
-- the plugin that asks through `vim.ui.select`.
local ui_offered, ui_choice, ui_calls = nil, nil, 0
vim.ui.select = function(items, _opts, on_choice)
  ui_calls = ui_calls + 1
  ui_offered = items
  local picked = nil
  for _, item in ipairs(items) do
    if type(item) == "table" and item.path == ui_choice then
      picked = item
    end
  end
  on_choice(picked)
end

describe("a switch with no adapter wired", function()
  it("puts the repository's checkouts in front of the reviewer", function()
    ui_choice = nil
    codereview.switch()
    assert.same({ A, B, MAIN }, paths_of(ui_offered))
  end)

  it("opens nothing when the reviewer chooses none of them", function()
    assert.is_nil(view.current())
  end)
end)

--- The adapter that replaces it --------------------------------------------------

-- Stubbed exactly as the send, target and compose adapters are stubbed throughout this
-- suite. It is the one new seam this work adds, and it is a product decision rather than a
-- test affordance: no test-only door is opened anywhere below.
local offered, chosen = nil, nil
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, note)
  end,
  pick_checkout = function(checkouts, cb)
    offered = checkouts
    cb(chosen)
  end,
})

---Switch the review to a checkout, through the public entry point and the host's adapter.
---@param path string
local function switch_to(path)
  chosen = path
  codereview.switch()
end

describe("a host's own checkout picker", function()
  it("is handed the list the shipped one would have shown", function()
    local before = ui_calls
    switch_to(nil)
    assert.same({ A, B, MAIN }, paths_of(offered))
    assert.same(before, ui_calls)
  end)
end)

--- A switch with no review open ---------------------------------------------------

-- Which is how a reviewer opens a review somewhere else in the first place: there is simply
-- nothing to close first.
describe("a switch made with no review open", function()
  it("opens a review in the chosen checkout", function()
    assert.is_nil(view.current())
    switch_to(B)
    assert.same(B, current().root)
  end)

  -- Without this, "the review is on that checkout" is satisfied by a root field set to a
  -- path nothing was read from. The two checkouts hold `src/main.lua` at the same
  -- repository-relative path and differ only in what that file says.
  it("draws that checkout's own work and not another's", function()
    local text = table.concat(vim.api.nvim_buf_get_lines(current().buf, 0, -1, false), "\n")
    assert.is_truthy(text:find('from = "agent-b"', 1, true), text:sub(1, 400))
    assert.is_nil(text:find('from = "agent-a"', 1, true))
  end)

  -- The guarantee at the bottom of everything: a reviewer can always get back to the
  -- checkout Neovim started in, because a switch never moves it.
  it("leaves the global working directory where it was", function()
    assert.same(A, vim.fn.getcwd(-1, -1))
  end)

  it("leaves the tab the reviewer started in with no directory of its own", function()
    assert.same(0, vim.fn.haslocaldir(-1, 1))
    assert.same(A, vim.fn.getcwd(-1, 1))
  end)

  -- The `:tcd` is for the **host** -- the LSP root, the diff-sign base, a relative `:e` --
  -- and nothing in the plugin reads it back (ADR-0008). It is still owed, and it is owed on
  -- the tab the review lives in rather than on the one the switch was asked from, which is
  -- what "after that tab exists, not before" buys.
  it("gives the review's own tab the chosen checkout", function()
    local nr = vim.api.nvim_tabpage_get_number(current().tab)
    assert.same(1, vim.fn.haslocaldir(-1, nr))
    assert.same(B, vim.fn.getcwd(-1, nr))
  end)
end)

--- A switch with a review already open --------------------------------------------

describe("a switch made with a review open", function()
  it("moves the review rather than opening a second one", function()
    local before = #vim.api.nvim_list_tabpages()
    local was = current().tab
    switch_to(A)
    assert.same(A, current().root)
    assert.same(before, #vim.api.nvim_list_tabpages())
    assert.is_false(vim.api.nvim_tabpage_is_valid(was), "the review it moved from is still on screen")
  end)

  it("still leaves the global working directory alone", function()
    assert.same(A, vim.fn.getcwd(-1, -1))
    assert.same(0, vim.fn.haslocaldir(-1, 1))
  end)

  -- The checkout switched to is the one the reviewer is standing in here, so the *path* a
  -- tab reports would be right whatever this did. What cannot be right by accident is the
  -- tab having a directory of its own at all: without the `:tcd` it would be following the
  -- global one, and it is the following that ADR-0008 says can resume with no event.
  it("gives the new review's tab a directory of its own", function()
    local nr = vim.api.nvim_tabpage_get_number(current().tab)
    assert.same(1, vim.fn.haslocaldir(-1, nr))
    assert.same(A, vim.fn.getcwd(-1, nr))
  end)
end)

--- The queue the switch arrives at -------------------------------------------------

describe("the queue a review opened by a switch is showing", function()
  it("is the queue that checkout was left holding", function()
    switch_to(B)
    assert.is_true(vim.tbl_contains(queued_notes(), "left unsent in agent-b"), vim.inspect(queued_notes()))
  end)

  -- Arriving in a checkout for the first time is a first read of that checkout, and it owes
  -- everything a first read owes -- not just the queue filed under it. Without this the open
  -- can swap the stored queue in on its own and the loose entry is left on the disk until
  -- something else happens to resolve a checkout, which is a restore with a quieter rule
  -- beside the real one.
  it("brings what belongs to no checkout along with it", function()
    assert.is_true(vim.tbl_contains(queued_notes(), LOOSE), vim.inspect(queued_notes()))
  end)

  -- The number a statusline reads, against the checkout the review is on rather than
  -- against the whole queue -- which the count is built from, so comparing the two would
  -- be true of any checkout the pointer happened to be left on. #179 makes the count
  -- resolve a checkout for itself, and the two together have to keep saying this.
  it("is what the public count counts", function()
    assert.same(queue.count_in(current().root) + queue.loose_count(), codereview.count())
  end)
end)

--- What a review resolves against, asked from somewhere else ------------------------

-- The discriminating case for "the review's root is what everything resolves against". Asked
-- from inside the review tab, the working directory answers with the `:tcd` a switch has
-- just set, so a working-directory read looks correct there and this file could not tell the
-- two apart. Asked from the tab the reviewer is still working in, it answers with a
-- different checkout entirely.

---Ask something while standing in the tab the reviewer never left.
---@generic T
---@param fn fun(): T
---@return T
local function from_the_reviewers_tab(fn)
  local here = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
  local ok, result = pcall(fn)
  vim.api.nvim_set_current_tabpage(here)
  assert(ok, result)
  return result
end

describe("what a review resolves against, asked from a tab in another checkout", function()
  -- The guard: without a working directory that really does name another checkout, every
  -- case below passes whichever of the two the plugin read.
  it("is the review's checkout, and not the one the tab is in", function()
    assert.same(A, from_the_reviewers_tab(vim.fn.getcwd))
    assert.same(B, from_the_reviewers_tab(state.current_checkout))
  end)

  it("keeps the queue on the review's checkout", function()
    from_the_reviewers_tab(state.ensure_queue)
    assert.is_true(vim.tbl_contains(queued_notes(), "left unsent in agent-b"), vim.inspect(queued_notes()))
  end)

  -- The half a reviewer would actually see. `gb` and `:CodeReviewLastBatch` read the newest
  -- batch out of a checkout, and with a review open that checkout is the review's.
  it("reads the last batch out of the review's checkout too", function()
    local text = from_the_reviewers_tab(function()
      local before = vim.api.nvim_get_current_win()
      codereview.last_batch()
      local win = vim.api.nvim_get_current_win()
      if win == before then
        -- Nothing opened, which is itself an answer: it said there was no batch to read.
        return ""
      end
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
      vim.api.nvim_win_close(win, true)
      return table.concat(lines, "\n")
    end)
    assert.is_truthy(text:find("dispatched from agent-b long ago", 1, true), text)
  end)
end)

--- Annotating inside a switched review ---------------------------------------------

describe("an annotation made in a review a switch opened", function()
  local NOTE = "queued in agent-b, from a session standing in agent-a"

  it("joins the queue of the checkout the review is on", function()
    note = NOTE
    local row = assert(h.line_row(current(), "src/main.lua"), "no diff row for src/main.lua")
    vim.api.nvim_set_current_win(current().win)
    vim.api.nvim_win_set_cursor(current().win, { row, 0 })
    require("codereview.annotate").annotate("bug")
    assert.is_true(vim.tbl_contains(queued_notes(), NOTE), vim.inspect(queued_notes()))
  end)

  it("is filed in that checkout's store", function()
    assert.is_true(vim.tbl_contains(stored_notes(B), NOTE), vim.inspect(stored_notes(B)))
  end)

  it("never reaches the store of the checkout the reviewer is standing in", function()
    assert.is_false(vim.tbl_contains(stored_notes(A), NOTE), vim.inspect(stored_notes(A)))
  end)

  -- `checkout_restart_spec` pins this collision for a session that reaches a second
  -- checkout by changing directory. A switch is a second route to the same place, and it
  -- reaches it with the counter having heard about one checkout only -- so the archive of
  -- the checkout being *switched to* is the only thing that can lift it clear.
  it("takes an id above every id that checkout's archive holds", function()
    local queued = nil
    for _, e in ipairs(queue.all()) do
      if e.note == NOTE then
        queued = e
      end
    end
    assert.is_not_nil(queued, vim.inspect(queued_notes()))
    assert.is_true(queued.id > ARCHIVED_IDS[2], ("%d is not above %s"):format(queued.id, vim.inspect(ARCHIVED_IDS)))
  end)
end)

--- Leaving a checkout, and coming back ---------------------------------------------

describe("a switch away from a checkout with a pending queue", function()
  local msgs, restore

  it("does not ask, and says nothing about the queue it is leaving", function()
    assert.is_true(codereview.count() > 0, "nothing was pending")
    msgs, restore = h.capture_notify()
    switch_to(A)
    restore()
    assert.is_false(h.notified(msgs, "queue"), vim.inspect(msgs))
    assert.is_false(h.notified(msgs, "pending"), vim.inspect(msgs))
    assert.is_false(h.notified(msgs, "unsent"), vim.inspect(msgs))
  end)

  it("leaves the queue it was showing in that checkout's own store", function()
    local left = stored_notes(B)
    assert.is_true(vim.tbl_contains(left, "left unsent in agent-b"), vim.inspect(left))
    assert.is_true(vim.tbl_contains(left, "queued in agent-b, from a session standing in agent-a"), vim.inspect(left))
  end)

  it("shows the checkout it arrived in its own queue instead", function()
    assert.is_false(vim.tbl_contains(queued_notes(), "left unsent in agent-b"), vim.inspect(queued_notes()))
  end)

  it("gives the whole of it back on the way back", function()
    switch_to(B)
    local back = queued_notes()
    assert.is_true(vim.tbl_contains(back, "left unsent in agent-b"), vim.inspect(back))
    assert.is_true(vim.tbl_contains(back, "queued in agent-b, from a session standing in agent-a"), vim.inspect(back))
  end)
end)

--- A tab spawned out of the review --------------------------------------------------

-- So the reviewer's LSP, their diff signs and a relative `:e` agree with the diff they were
-- reading. A tab that merely inherited the review tab's directory would satisfy the path
-- assertion alone, which is why the tab is asked whether the directory is its own.
describe("a tab opened on a real file out of a review", function()
  it("is rooted in the review's checkout", function()
    local review_tab = current().tab
    local row = assert(h.line_row(current(), "src/main.lua"), "no diff row for src/main.lua")
    vim.api.nvim_set_current_win(current().win)
    vim.api.nvim_win_set_cursor(current().win, { row, 0 })

    view.open_file()
    local spawned = vim.api.nvim_get_current_tabpage()
    assert.are_not.same(review_tab, spawned)

    local nr = vim.api.nvim_tabpage_get_number(spawned)
    assert.same(1, vim.fn.haslocaldir(-1, nr))
    assert.same(B, vim.fn.getcwd(-1, nr))

    vim.cmd("tabclose")
    vim.api.nvim_set_current_tabpage(review_tab)
  end)
end)

--- The command and the key ------------------------------------------------------------

describe("the surface a switch is reached through", function()
  ---Normal-mode mappings bound to a buffer, as a set. Through `vim.keycode` on both sides:
  ---the API reports a key in its own notation rather than the one it was bound with.
  ---@param buf integer
  ---@return table<string, boolean>
  local function bound(buf)
    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      lhs[vim.keycode(m.lhs)] = true
    end
    return lhs
  end

  it("is a command, because a switch has to work with no review open", function()
    assert.is_true(vim.tbl_contains(vim.fn.getcompletion("CodeReviewSwitch", "cmdline"), "CodeReviewSwitch"))
  end)

  it("is `gS` in the diff", function()
    assert.is_true(bound(current().buf)["gS"])
  end)

  -- In the tree as well, as `gp`, `gl`, `gb`, `gc` and `gA` all are: which surface a
  -- reviewer happens to be in decides what a key acts on, never whether it works.
  it("is `gS` in the file tree", function()
    assert.is_true(bound(assert(current().panel_buf, "no file tree"))["gS"])
  end)

  it("switches the review when it is pressed", function()
    vim.api.nvim_set_current_win(current().win)
    chosen = A
    h.feed("gS")
    assert.same(A, current().root)
  end)

  it("switches the review when the command is run", function()
    chosen = B
    vim.cmd("CodeReviewSwitch")
    assert.same(B, current().root)
  end)
end)

--- A checkout with nothing to review -------------------------------------------------

-- `main` sits on the branch every other checkout is reviewed against, so its branch scope
-- is empty -- which is the one checkout in this fixture that can say so. A switch is an
-- open, and an open with nothing in scope reports it and stops before it closes anything:
-- landing a reviewer on an empty review, having taken away the one they were reading, would
-- be a worse answer than declining to move.
describe("a switch to a checkout with nothing in the branch scope", function()
  local msgs, restore

  it("says so, in the wording an ordinary open uses", function()
    msgs, restore = h.capture_notify()
    switch_to(MAIN)
    restore()
    assert.is_true(h.notified(msgs, "No changes in scope"), vim.inspect(msgs))
  end)

  it("leaves the review the reviewer was reading exactly where it was", function()
    assert.same(B, current().root)
    local nr = vim.api.nvim_tabpage_get_number(current().tab)
    assert.same(B, vim.fn.getcwd(-1, nr))
  end)

  it("moves no directory on its way to saying nothing happened", function()
    assert.same(A, vim.fn.getcwd(-1, -1))
    assert.same(0, vim.fn.haslocaldir(-1, 1))
  end)
end)
