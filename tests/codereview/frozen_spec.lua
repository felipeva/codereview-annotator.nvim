-- A **checkout** deleted underneath an open review.
--
-- **This file is where ADR-0008 is proved, and it is the only place it can be.** Inside a
-- review tab `getcwd()` answers the `:tcd` the open just set, so an implementation that
-- reads the tab's working directory instead of the review's root passes every case
-- `switch_spec` is able to write. `switch_spec` says so itself and leaves the proof here.
--
-- The two answers come apart in one place: the review's checkout is deleted, and the tab
-- silently adopts the global working directory. Measured on this platform, with the tab's
-- own directory deleted:
--
--   * nothing at all fires at the moment of deletion;
--   * while the reviewer stays in the tab, `getcwd()` is `""` and `vim.uv.cwd()` is nil;
--   * leaving the tab fires `DirChanged` at *global* scope, describing the other tab;
--   * coming back fires `DirChangedPre` at *tabpage* scope and **no** `DirChanged`, and
--     from then on `getcwd()` answers the global directory while `getcwd(0, 0)` and
--     `haslocaldir()` both still insist the deleted directory is the tab's.
--
-- Both halves are needed here and they need different tab states, which is why this file
-- is in two acts.
--
-- **Act one, never having left the tab.** `vim.uv.cwd()` is nil, and that is what makes
-- the review unreadable today: `syntax.lua` hands a *repository-relative* path to
-- `vim.filetype.match`, which absolutises it through `vim.fs.abspath` -- an
-- `assert(vim.uv.cwd())`. Every paint and every cursor move raises, and none of that path
-- touches git. So "only what needs git is switched off" is not the rule; "the review
-- remains usable" is, and switching git off is one part of it.
--
-- **Act two, having left the tab and come back.** `getcwd()` now answers `main`, which is
-- a *live* checkout of the same repository: a working-directory read resolves, succeeds,
-- and is wrong. That is the state the assertions about resolution are made in, and the
-- state the mutation at the end of the file is run in. Asserted in act one instead, a
-- working-directory read would answer `""` and fail loudly -- the mutation would die for
-- the wrong reason and prove nothing about the review's root.
--
-- Single process, and one review throughout: what is being asserted is what one session
-- can still do with a review whose checkout went out from under it.
local h = require("tests.helpers")

h.ui(110, 40)

-- Three checkouts of one repository. Realpathed once: `git rev-parse --show-toplevel`
-- answers resolved, and on macOS a temporary directory is a symlink into /private.
local base = assert(vim.uv.fs_realpath(h.fixture("mkcheckouts")))
local MAIN = vim.fs.joinpath(base, "main")
local A = vim.fs.joinpath(base, "agent-a")
local B = vim.fs.joinpath(base, "agent-b")

local codereview = require("codereview")
local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

-- The checkout the reviewer is standing in, for the whole file, and never moved.
--
-- It has to be a checkout that is *alive* and is *not* the one being reviewed. That is the
-- whole trap: once the review's tab falls back to this directory, a working-directory read
-- names a real repository with a real `src/main.lua` in it, so it does not fail -- it
-- answers about the wrong checkout. A reviewer standing outside every checkout would make
-- every case below pass under a reading this file exists to catch.
vim.cmd("cd " .. vim.fn.fnameescape(MAIN))
local reviewer_tab = vim.api.nvim_get_current_tabpage()

-- The sentence every door says. One fragment shared by the announcement and by each
-- refusal, because it is one fact: a reviewer who meets it twice should recognise it, and
-- a second phrasing would be a second rule to keep true.
local GONE = "checkout under this review is gone"

local note = "unset"
local picked, offered = nil, nil

-- **Syntax is left at its default, deliberately.** `switch_spec` turns it off; this file
-- must not, because the pass that reads the working directory *is* the syntax pass. A spec
-- asserting the review is still readable with the one thing that breaks it removed would
-- assert nothing.
codereview.setup({
  compose = function(_, on_accept)
    on_accept(nil, note)
  end,
  -- Stubbed exactly as the send, target and compose adapters are stubbed throughout the
  -- suite. What it is *offered* is asserted too: the listing is the half of a switch that a
  -- deleted checkout breaks, so a stub that only answered would hide it.
  pick_checkout = function(checkouts, on_choice)
    offered = checkouts
    on_choice(picked)
  end,
})

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

---The queued entry carrying a note, so a flag written onto it can be read back.
---@param needle string
---@return table
local function entry_named(needle)
  for _, e in ipairs(queue.all()) do
    if e.note == needle then
      return e
    end
  end
  error("no queued entry says " .. needle .. ": " .. vim.inspect(queued_notes()))
end

---The notes a checkout's store holds, queued and archived alike.
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
---@param checkouts table[]
---@return string[]
local function paths_of(checkouts)
  local paths = vim.tbl_map(function(c)
    return c.path
  end, checkouts or {})
  table.sort(paths)
  return paths
end

---Everything `vim.notify` was handed while `fn` ran.
---@param fn fun()
---@return string[]
local function said(fn)
  local msgs, restore = h.capture_notify()
  local ok, err = pcall(fn)
  restore()
  assert(ok, tostring(err))
  return msgs
end

---The review's whole after pane as one string.
---@return string
local function on_screen()
  return table.concat(vim.api.nvim_buf_get_lines(current().buf, 0, -1, false), "\n")
end

--- The review, before anything happens to it -------------------------------------

assert(view.open(nil, A), "the review did not open on agent-a")
local review_tab = current().tab
local painted_before = #h.syntax_marks(current())

-- One annotation about a file of this checkout, captured the way a reviewer captures one --
-- through the review's own key rather than written into the store. What is being asserted
-- later is that the reviewer does not lose work they were in the middle of, so the work has
-- to have been made the way they make it.
local NOTE = "about agent-a, written while its checkout was still there"

-- And one captured from the file itself rather than from the diff, because only that shape
-- carries a **working-tree** blob. A diff annotation is judged against the blob the scope
-- already holds in memory, which no deletion can move; a working-tree one is judged against
-- the disk, and the disk is what goes. It is the only entry shape that a reconcile run
-- against a checkout that is gone can be *falsely* judged -- so it is what gives the
-- refusal below something to fail on.
local WORKTREE_NOTE = "about a file of agent-a, captured from the file"

describe("a review opened on a checkout that is about to go", function()
  it("is on that checkout, with a diff drawn and highlighted", function()
    assert.same(A, current().root)
    assert.is_true(#current().files > 0, "the review has no files")
    assert.is_true(painted_before > 0, "nothing was highlighted before the deletion")
  end)

  it("takes an annotation into that checkout's queue", function()
    note = NOTE
    local row = assert(h.line_row(current(), "src/main.lua"), "no diff row for src/main.lua")
    vim.api.nvim_set_current_win(current().win)
    vim.api.nvim_win_set_cursor(current().win, { row, 0 })
    require("codereview.annotate").annotate("bug")
    assert.is_true(vim.tbl_contains(queued_notes(), NOTE), vim.inspect(queued_notes()))
  end)

  -- In a tab of its own, because editing the file in the review tab would put it over the
  -- diff. Dismissed again immediately: what this case is for is the entry, not the window.
  it("takes an annotation captured from a file of it, carrying a working-tree blob", function()
    note = WORKTREE_NOTE
    vim.cmd("tabnew " .. vim.fn.fnameescape(vim.fs.joinpath(A, "src/config.lua")))
    codereview.annotate("bug")
    vim.cmd("tabclose")
    vim.cmd("tabnext " .. vim.api.nvim_tabpage_get_number(review_tab))
    assert.is_true(entry_named(WORKTREE_NOTE).worktree, "the capture carries no working-tree blob")
  end)
end)

--- The checkout goes ------------------------------------------------------------

-- Deleted with the review tab current, which is the reviewer's own position: an agent
-- prunes its worktree while they are reading the diff of it. That is what leaves the
-- *process* working directory inside a directory that no longer exists, and it is the
-- state act one is about.
vim.fn.delete(A, "rf")

--- Act one: still standing in the tab ---------------------------------------------

describe("the tab a deleted checkout leaves behind", function()
  -- The guard that makes every case below what it claims to be. Not "the working directory
  -- is different" -- there is no working directory at all, and every implicit
  -- absolutisation Neovim does has nothing to work from.
  it("has no working directory, and no process directory either", function()
    assert.same("", vim.fn.getcwd())
    assert.is_nil(vim.uv.cwd())
  end)

  -- Nothing announced it. This is the finding ADR-0008 rests on, asserted where the review
  -- it happens to is on screen rather than only against a bare tab in `count_spec`.
  it("still names the deleted checkout as its own", function()
    assert.same(A, vim.fn.getcwd(0, 0))
    assert.is_nil(vim.uv.fs_stat(A))
  end)
end)

describe("a review whose checkout was deleted underneath it", function()
  it("is still open", function()
    assert.is_not_nil(view.current())
  end)

  -- The case the whole ticket turns on, and it has nothing to do with git. `syntax.lua`
  -- hands `vim.filetype.match` a repository-relative path, which Neovim absolutises against
  -- a working directory that is gone. **This reds the moment that path goes back to being
  -- relative**, which is what it is here for.
  it("repaints without raising", function()
    local ok, err = pcall(view.paint)
    assert.is_true(ok, tostring(err))
  end)

  -- A repaint runs on a resize; a cursor move runs on every keystroke a reviewer holds. If
  -- either raises, the review is not readable in any sense a reviewer would accept.
  it("takes a cursor move without raising", function()
    local ok, err = pcall(view.cursor_moved)
    assert.is_true(ok, tostring(err))
  end)

  -- A third gesture, and one a reviewer makes constantly. Summoned and dismissed in one
  -- case because the pair is symmetric: the review is left exactly as it was found, so
  -- nothing below reads a surface this case rearranged.
  it("summons and dismisses the file tree without raising", function()
    local first, err = pcall(view.toggle_panel)
    local back, berr = pcall(view.toggle_panel)
    assert.is_true(first, tostring(err))
    assert.is_true(back, tostring(berr))
  end)

  -- Without this, "the review stayed open" is satisfied by a tab holding an empty buffer,
  -- and the freeze behaviour is satisfied by the review having closed.
  it("still draws its diff", function()
    assert.is_truthy(on_screen():find("src/main.lua", 1, true), on_screen())
  end)

  -- The captures behind the highlighting were harvested before the deletion and are held in
  -- memory, so a repaint replays them and needs no directory to do it. This reds both ways
  -- that path can be got wrong: it reds on the raise, and it reds on a `pcall` that
  -- swallows the raise and returns no language, which would leave the replay unreached.
  it("still carries the syntax highlighting it was drawn with", function()
    assert.is_true(#h.syntax_marks(current()) > 0, "the diff lost its highlighting")
  end)

  it("still draws the annotation queued before the deletion", function()
    assert.is_true(#h.virt_marks(current()) > 0, "no annotation is drawn")
  end)
end)

describe("the queue of a review whose checkout is gone", function()
  it("still holds what was captured before the deletion", function()
    assert.is_true(vim.tbl_contains(queued_notes(), NOTE), vim.inspect(queued_notes()))
    assert.is_true(vim.tbl_contains(queued_notes(), WORKTREE_NOTE), vim.inspect(queued_notes()))
    assert.same(2, codereview.count())
  end)

  it("can still be read", function()
    view.review_queue()
    local win = assert(current().queue_win, "no queue float opened")
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    vim.api.nvim_win_close(win, true)
    assert.is_truthy(text:find(NOTE, 1, true), text)
  end)
end)

--- What the review will not do without its checkout -------------------------------

describe("the operations that need the checkout", function()
  -- Refused rather than narrated, and this is the case that says why. `hash_worktree`
  -- `fs_stat`s each path before it runs git; under a gone checkout every stat fails, it
  -- returns nothing *without spawning git at all*, and every worktree-captured annotation
  -- compares "no hash" against its capture blob and is flagged **stale**. The reviewer is
  -- then told a number that is a lie, and `persist` writes the flag into the store. An
  -- implementation that warns and reconciles anyway satisfies "refused with a clear reason"
  -- and destroys information.
  it("refuse to reconcile, and leave the queue's staleness alone", function()
    local msgs = said(view.reconcile)
    assert.is_true(h.notified(msgs, GONE), vim.inspect(msgs))
    assert.is_false(h.notified(msgs, "stale"), vim.inspect(msgs))
    assert.is_nil(entry_named(WORKTREE_NOTE).stale)
  end)

  it("refuse to change scope, and leave the review reading what it was reading", function()
    local msgs = said(function()
      view.set_scope("worktree")
    end)
    assert.is_true(h.notified(msgs, GONE), vim.inspect(msgs))
    assert.same("branch", current().scope.name)
  end)

  it("refuse to re-read the diff", function()
    local msgs = said(view.refresh)
    assert.is_true(h.notified(msgs, GONE), vim.inspect(msgs))
  end)

  -- Said as a fact about the checkout and not about the file. "src/main.lua does not exist
  -- in the working tree" is what this answers today, and it sends a reviewer looking for a
  -- deleted file when what went is everything around it.
  it("refuse to open the real file, and open no tab", function()
    local row = assert(h.line_row(current(), "src/main.lua"), "no diff row for src/main.lua")
    vim.api.nvim_set_current_win(current().win)
    vim.api.nvim_win_set_cursor(current().win, { row, 0 })
    local tabs = #vim.api.nvim_list_tabpages()
    local msgs = said(view.open_file)
    assert.is_true(h.notified(msgs, GONE), vim.inspect(msgs))
    assert.same(tabs, #vim.api.nvim_list_tabpages())
  end)

  it("refuse to list the commits", function()
    local msgs = said(view.commit_list)
    assert.is_true(h.notified(msgs, GONE), vim.inspect(msgs))
  end)
end)

--- Being told ---------------------------------------------------------------------

-- Nothing fires when the directory dies, so there is no moment to announce it at except
-- the two a reviewer makes themselves: the operation they ask for, and coming back to the
-- review. The refusals above are the first door; this is the second, and it is the only
-- free one that exists.
--
-- This is also the crossing into act two: entering the tab is what makes Neovim adopt the
-- global directory, and every case after it is asserted in that state.
describe("coming back to the review tab", function()
  it("says the checkout is gone", function()
    local msgs = said(function()
      vim.cmd("tabnext " .. vim.api.nvim_tabpage_get_number(reviewer_tab))
      vim.cmd("tabnext " .. vim.api.nvim_tabpage_get_number(review_tab))
    end)
    assert.is_true(h.notified(msgs, GONE), vim.inspect(msgs))
  end)
end)

--- Act two: the tab has adopted a live checkout ------------------------------------

describe("the working directory a returning review tab reads", function()
  -- The trap this whole file exists for, pinned rather than assumed. Every assertion below
  -- names `agent-a`, and `agent-a` is the one answer a working-directory read cannot give.
  it("names a live sibling checkout, not the deleted one and not nothing", function()
    assert.same(MAIN, vim.fn.getcwd())
    assert.is_not_nil(vim.uv.fs_stat(MAIN))
    assert.is_not_nil(vim.uv.fs_stat(vim.fs.joinpath(MAIN, "src/main.lua")))
  end)

  -- The other half of the trap: the tab-local read is no better. It answers the directory
  -- that is gone, so an implementation reaching for `getcwd(0, 0)` to be careful is wrong
  -- in the other direction.
  it("keeps claiming the deleted checkout as the tab's own", function()
    assert.same(A, vim.fn.getcwd(0, 0))
    assert.same(1, vim.fn.haslocaldir(-1, 0))
  end)
end)

describe("the checkout a review with no directory resolves against", function()
  it("is the checkout it was opened on", function()
    assert.same(A, current().root)
  end)

  -- ADR-0008 in one call. With a review open this answers the review's root, and the
  -- working directory beside it now names something else that exists.
  it("is what everything else resolves against too", function()
    assert.same(A, state.current_checkout())
  end)

  it("is the store the annotation captured in it reaches", function()
    view.persist()
    assert.is_true(vim.tbl_contains(stored_notes(A), NOTE), vim.inspect(stored_notes(A)))
    assert.is_false(vim.tbl_contains(stored_notes(MAIN), NOTE), vim.inspect(stored_notes(MAIN)))
  end)

  -- The same refusal as above, asked again in the state where the working directory has an
  -- answer. A guard reading the working directory finds `main`, finds it alive, and refuses
  -- nothing -- so this case reds under exactly the implementation act one cannot catch.
  it("is what decides that the operations needing it are still refused", function()
    local msgs = said(view.reconcile)
    assert.is_true(h.notified(msgs, GONE), vim.inspect(msgs))
  end)
end)

--- The mutation ------------------------------------------------------------------

-- **The proof this file owes ADR-0008, executed rather than described.**
--
-- Every case above is satisfied by an implementation that reads the tab and happens to
-- agree, unless the disagreement is demonstrated. So it is demonstrated: the review's root
-- is replaced by a working-directory read, in the one state where the two differ, and the
-- behaviour asserted above has to collapse.
--
-- What it collapses into is not a failure. It is the review quietly opening a file out of a
-- live, unrelated checkout as though it were the file the diff is about -- which is the
-- exact wrongness ADR-0008 was written to forbid, and the reason "it would have worked
-- anyway" is not an argument.
describe("the review's root replaced by a working-directory read", function()
  local opened, msgs

  it("stops refusing, and reaches into the wrong checkout", function()
    local v = current()
    local row = assert(h.line_row(v, "src/main.lua"), "no diff row for src/main.lua")
    vim.api.nvim_set_current_win(v.win)
    vim.api.nvim_win_set_cursor(v.win, { row, 0 })

    v.root = vim.fn.getcwd() -- the mutation, and the whole of it
    msgs = said(view.open_file)
    opened = vim.api.nvim_buf_get_name(0)

    -- Put it back before anything is asserted, so a failing assertion cannot leave the
    -- rest of the file running against a mutated review.
    vim.cmd("tabclose")
    vim.cmd("tabnext " .. vim.api.nvim_tabpage_get_number(review_tab))
    v.root = A

    assert.is_false(h.notified(msgs, GONE), vim.inspect(msgs))
    assert.is_truthy(opened:find(MAIN, 1, true), "opened " .. opened)
  end)

  it("leaves the review the review again once it is undone", function()
    assert.same(A, current().root)
    assert.same(A, state.current_checkout())
  end)
end)

--- Leaving ------------------------------------------------------------------------

-- A reviewer who cannot switch out of a review whose checkout is gone is stranded: the
-- listing is built by asking git from the review's own checkout, and that is the directory
-- that went. `:CodeReview` is no way out either -- it resolves the working directory, which
-- is `""` for as long as the reviewer stays in the tab.
--
-- Last in the file because a switch rebuilds the review, and everything above is about the
-- one that was open.
describe("switching out of a review whose checkout is gone", function()
  it("offers the checkouts that are still there", function()
    picked = MAIN
    local msgs = said(codereview.switch)
    assert.is_false(h.notified(msgs, "no checkout of this repository can be opened"), vim.inspect(msgs))
    assert.same({ B, MAIN }, paths_of(offered))
  end)

  it("opens the review on the one that was chosen", function()
    assert.same(MAIN, current().root)
  end)

  -- The work left behind is the checkout's, not the reviewer's position's. It was written
  -- to `agent-a`'s store while `agent-a` was already gone, and switching away does not move
  -- it: sweeping orphaned state is #178's, and this slice must not do any of it.
  it("leaves the annotation in the store of the checkout it was about", function()
    assert.is_true(vim.tbl_contains(stored_notes(A), NOTE), vim.inspect(stored_notes(A)))
    assert.is_false(vim.tbl_contains(stored_notes(MAIN), NOTE), vim.inspect(stored_notes(MAIN)))
  end)
end)
