-- Returning to a **checkout** reopens the **scope** it was last reviewed in.
--
-- The reviewed marks a reviewer earns are kept per scope, so which scope a return opens
-- decides which marks come back. A return that always opened the branch scope left the marks
-- made anywhere else sitting in the document, unused and invisible.
--
-- What is asserted here is what a reviewer can see: which scope the review is on, which
-- files it draws, which marks came back, what was said on the way, and -- across a genuine
-- restart -- that the answer was on the disk rather than in this process's memory.
--
-- Three rules are pinned that the acceptance criteria did not carry, and each of them is a
-- refusal this feature could introduce rather than a behaviour it adds:
--
--   * **What is recorded is the spec that resolved the scope, not the scope's name.** A
--     revspec's name is the literal string "revspec", which resolves to nothing, so an
--     implementation recording `scope.name` fails exactly the case the ticket names.
--   * **A remembered scope is a default, and a default must never turn an open into a
--     refusal.** One that no longer resolves, and one that resolves to nothing, both fall
--     back to the branch scope rather than leaving the reviewer with no review at all.
--     That is a different rule from the one `switch_spec` pins, where a checkout whose
--     *branch* scope is empty is declined rather than opened: there the reviewer asked for
--     that scope, here nobody did.
--   * **A return is a switch, and not every open.** `:CodeReview` with no argument still
--     means the branch review, because the front door's meaning must not drift across
--     sessions.
--
-- Single process, except for the last block. Leaving a checkout and coming back is one
-- session moving between checkouts; what needs a genuine restart is that the scope reached
-- the document, and that has a child of its own.
local h = require("tests.helpers")

h.ui(110, 40)

-- Three checkouts of one repository. Realpathed once: `git rev-parse --show-toplevel`
-- answers resolved, and on macOS a temporary directory is a symlink into /private.
local base = assert(vim.uv.fs_realpath(h.fixture("mkcheckouts")))
local A = vim.fs.joinpath(base, "agent-a")
local B = vim.fs.joinpath(base, "agent-b")

local codereview = require("codereview")
local git = require("codereview.git")
local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

-- The checkout the reviewer is standing in. Nothing below moves it until the last block,
-- which reaches a second repository entirely.
vim.cmd("cd " .. vim.fn.fnameescape(A))

---Run git somewhere, for the histories this file builds on top of the shared fixture.
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

---The files the review is drawing, in the order it drew them.
---@return string[]
local function drawn()
  return vim.tbl_map(function(f)
    return f.path
  end, current().files)
end

---The paths marked reviewed in the scope the review is on.
---@return string[]
local function marked()
  local paths = vim.tbl_keys(current().reviewed)
  table.sort(paths)
  return paths
end

---Mark a file reviewed in the open view, in whichever scope it is on.
---@param path string
local function mark_reviewed(path)
  local V = current()
  local index = assert(h.file_index(V, path), path .. " is not in this scope")
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index], 0 })
  view.toggle_reviewed()
end

--- The switch, through the adapter -----------------------------------------------

-- Stubbed exactly as `switch_spec` stubs it, and for the same reason: the **switch** is the
-- public entry point every case here drives through, and the adapter is the seam that makes
-- it answerable without a picker. No test-only door is opened anywhere below.
local note, chosen = "unset", nil
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, note)
  end,
  pick_checkout = function(_, cb)
    cb(chosen)
  end,
})

---Switch the review to a checkout, through the public entry point.
---@param path string
local function switch_to(path)
  chosen = path
  codereview.switch()
end

--- A checkout no review has ever been opened in ----------------------------------

-- The floor this whole feature stands on: with nothing recorded there is nothing to reopen,
-- and the answer is the one every review has always opened with.
describe("a switch to a checkout nothing has ever been reviewed in", function()
  -- Read before the switch, because the switch is what creates the document.
  local had_store = vim.fn.filereadable(state.path(B))

  switch_to(B)

  it("really is a checkout with nothing stored, so the case is not vacuous", function()
    assert.same(0, had_store)
  end)

  it("opens at the default scope", function()
    assert.same("branch", current().scope.name)
  end)
end)

--- Leaving a checkout in a scope, and coming back to it ---------------------------

-- The headline. The marks belong to the scope and not to the checkout, so a return that
-- opens the wrong scope hands back the wrong marks -- or, as here, none at all.
describe("a return to a checkout left in a scope of its own", function()
  switch_to(A)

  -- A mark in the scope the checkout is *not* left in, so "the marks that came back" cannot
  -- be satisfied by handing back whatever the document holds.
  mark_reviewed("src/main.lua")
  local at_branch = marked()

  view.set_scope("worktree")
  mark_reviewed("src/config.lua")
  local at_worktree = marked()

  it("really is two scopes with different marks and different diffs", function()
    assert.same({ "src/main.lua" }, at_branch)
    assert.same({ "src/config.lua" }, at_worktree)
    assert.same({ "src/config.lua" }, drawn())
  end)

  switch_to(B)

  it("leaves for a checkout that is genuinely somewhere else", function()
    assert.same(B, current().root)
    assert.same("branch", current().scope.name)
  end)

  switch_to(A)

  it("reopens the scope that checkout was last reviewed in", function()
    assert.same(A, current().root)
    assert.same("worktree", current().scope.name)
  end)

  -- Without this, "the review is on that scope" is satisfied by a name on a field. The two
  -- scopes of this checkout draw different files, and only one of them is what was read.
  it("draws that scope's diff and not the default's", function()
    assert.same({ "src/config.lua" }, drawn())
  end)

  it("gives back the marks that belong to that scope", function()
    assert.same({ "src/config.lua" }, marked())
  end)
end)

--- A scope whose name is not a spec ----------------------------------------------

-- The case the naive implementation fails. Every named scope is its own spec, so recording
-- `scope.name` is right for four scopes out of five and resolves to nothing for the fifth --
-- and a reviewer who left a checkout on a revspec is exactly who the ticket describes.
describe("a return to a checkout left on a revspec", function()
  view.set_scope("HEAD~1")

  it("really is a scope whose own name resolves to nothing", function()
    assert.same("revspec", current().scope.name)
    local resolved = git.resolve_scope(current().scope.name, A)
    assert.is_nil(resolved)
  end)

  switch_to(B)
  switch_to(A)

  it("comes back on the revspec, and not on the default", function()
    assert.same("revspec", current().scope.name)
  end)

  -- Which revspec, and not merely that one was resolved: the label is the only thing on the
  -- view that names the spec the reviewer typed.
  it("comes back on the revspec it was left on", function()
    assert.same("vs HEAD~1", current().scope.label)
  end)
end)

--- The door the memory is behind -------------------------------------------------

-- A **return** is a switch. `:CodeReview` with no argument is the front door and it still
-- means the branch review: a command whose meaning drifts across sessions is a worse trade
-- than a restart not being a return.
describe("an argument-less open in a checkout that remembers a scope", function()
  codereview.open()

  it("opens the branch review, not the scope the checkout was left in", function()
    assert.same(A, current().root)
    assert.same("branch", current().scope.name)
  end)

  switch_to(B)
  switch_to(A)

  it("records what it opened, so a return then finds that", function()
    assert.same("branch", current().scope.name)
  end)
end)

--- A remembered scope that no longer resolves -------------------------------------

-- A revspec is resolved against the repository as it stands, and a branch can go while the
-- reviewer is away. Implemented as the criteria are written, the return warns and opens
-- nothing at all -- where the same gesture, before this feature existed, always opened.
describe("a return to a checkout left on a scope that no longer resolves", function()
  git_at(A, { "branch", "scratch", "HEAD~1" })
  view.set_scope("scratch")

  it("really is a review on that scope, with something in it", function()
    assert.same("revspec", current().scope.name)
    assert.is_true(#current().files > 0)
  end)

  switch_to(B)
  git_at(A, { "branch", "-D", "scratch" })

  local msgs, restore = h.capture_notify()
  switch_to(A)
  restore()

  it("opens the review all the same", function()
    assert.same(A, current().root)
  end)

  it("opens it at the default", function()
    assert.same("branch", current().scope.name)
    assert.same({ "src/config.lua", "src/main.lua" }, vim.fn.sort(drawn()))
  end)

  -- A default that fell back is not an error a reviewer did anything about. What they would
  -- see is a branch review, which is what they would have seen before this feature existed.
  it("says nothing about the scope it could not resolve", function()
    assert.is_false(h.notified(msgs, "not a valid revision"), vim.inspect(msgs))
  end)
end)

--- A remembered scope that resolves and is empty -----------------------------------

-- The same refusal through the other door. A reviewer who left a checkout on `staged` and
-- then committed the index comes back to a scope that resolves perfectly and holds nothing,
-- and an open with nothing in scope declines.
--
-- Not the rule `switch_spec` pins on a checkout whose branch scope is empty. There the
-- scope is the one the reviewer asked for and the honest answer is to say so; here nobody
-- asked for it in this session at all.
describe("a return to a checkout left on a scope that has since emptied", function()
  git_at(B, { "add", "src/config.lua" })
  switch_to(B)
  view.set_scope("staged")

  it("really is a review on that scope, with something in it", function()
    assert.same("staged", current().scope.name)
    assert.same({ "src/config.lua" }, drawn())
  end)

  switch_to(A)
  git_at(B, { "reset", "-q" })

  it("really has emptied that scope while the reviewer was away", function()
    assert.same({}, h.git_lines(B, { "diff", "--cached", "--name-only" }))
  end)

  local msgs, restore = h.capture_notify()
  switch_to(B)
  restore()

  it("opens the review at the default rather than declining to move", function()
    assert.same(B, current().root)
    assert.same("branch", current().scope.name)
  end)

  it("does not report an empty scope nobody asked for", function()
    assert.is_false(h.notified(msgs, "No changes in scope"), vim.inspect(msgs))
  end)
end)

--- A document written before any of this ------------------------------------------

-- Every reviewer already has one. It carries reviewed marks and a queue and no record of a
-- scope, and it has to go on opening -- at the default, with everything else in it intact.
describe("a return to a checkout whose document predates the recorded scope", function()
  mark_reviewed("src/main.lua")

  -- The document as an earlier version of the plugin left it: whatever is in there now,
  -- minus the one key this ticket adds.
  local doc = state.load(B)
  doc.last_scope = nil
  state.save(B, doc)

  it("really is a document with marks in it and no scope recorded", function()
    local written = state.load(B)
    assert.is_nil(written.last_scope)
    assert.is_truthy(next(written.scopes), "nothing was stored to come back")
  end)

  switch_to(A)
  switch_to(B)

  it("still opens", function()
    assert.same(B, current().root)
  end)

  it("opens at the default", function()
    assert.same("branch", current().scope.name)
  end)

  -- Without this, "it still opens" is satisfied by a document that was discarded on the way
  -- past. What predates the key has to be read, not merely survived.
  it("gives back what that document already held", function()
    assert.same({ "src/main.lua" }, marked())
  end)
end)

--- What a return reports ------------------------------------------------------------

-- Returning to a checkout is the widest staleness window there is: nothing was watching the
-- files while the reviewer was somewhere else. It is reported in the wording the queue
-- already has, by the reconciliation every read-back goes through, and it adds no sentence
-- of its own.
describe("a return holding an annotation whose file moved while the reviewer was away", function()
  switch_to(A)

  -- Captured from an ordinary buffer, in a tab of its own so the review window keeps the
  -- diff it is drawing. A capture-path entry is judged against the file on disk at any
  -- scope, which is the comparison this window is about.
  note = "about a file that is about to move"
  vim.cmd("tabnew " .. vim.fn.fnameescape(vim.fs.joinpath(A, "src/config.lua")))
  codereview.annotate("bug")
  vim.cmd("tabclose")

  it("really has one annotation queued for that checkout", function()
    assert.same(1, #queue.all())
    assert.same("about a file that is about to move", queue.all()[1].note)
  end)

  switch_to(B)
  vim.fn.writefile({ 'return { port = 9090, agent = "agent-a" }' }, vim.fs.joinpath(A, "src/config.lua"))

  local msgs, restore = h.capture_notify()
  switch_to(A)
  restore()

  it("reports it in the queue's own wording", function()
    assert.is_true(h.notified(msgs, queue.stale_phrase(1)), vim.inspect(msgs))
  end)

  it("says it once, and adds no sentence of its own", function()
    local said = 0
    for _, m in ipairs(msgs) do
      if type(m) == "string" and m:find("stale", 1, true) then
        said = said + 1
      end
    end
    assert.same(1, said, vim.inspect(msgs))
  end)
end)

--- Across a genuine restart ---------------------------------------------------------

-- The claim no single-process case can make. Every case above is green against an
-- implementation that keeps the answer in a module-level table, because a checkout's state
-- never leaves memory once this session has visited it. A second session is the only reader
-- that has to have got it off the disk.
describe("a checkout last reviewed by the session before this one", function()
  -- A repository of its own: this process has opened a review in both checkouts of the
  -- shared fixture, and its own record would be what a return found there.
  local second = assert(vim.uv.fs_realpath(h.fixture("mkcheckouts")))
  local A2 = vim.fs.joinpath(second, "agent-a")

  -- The child shares this process's throwaway XDG_STATE_HOME and nothing else. It runs with
  -- `--clean` so no user config, and no minimal_init, can hand it a different one.
  local cmd = {
    vim.v.progpath,
    "--clean",
    "-l",
    vim.fs.joinpath(h.root, "tests", "codereview", "last_scope_child.lua"),
  }
  local proc = vim.system(cmd, {
    cwd = second,
    text = true,
    env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = second },
  })
  local child = proc:wait(60000)

  it("exits cleanly", function()
    assert.same(0, child.code, (child.stderr or "") .. (child.stdout or ""))
  end)

  -- Without this the case below is vacuous: "the scope did not come back" would be satisfied
  -- by there being no channel between the two sessions at all.
  it("leaves a store behind, so the two sessions really do share one", function()
    assert.same(1, vim.fn.filereadable(state.path(A2)), "no state at " .. state.path(A2) .. (child.stderr or ""))
  end)

  -- Reached with no review open and from the checkout itself, so the listing this switch is
  -- offered is that repository's rather than the shared fixture's.
  codereview.close()
  vim.cmd("cd " .. vim.fn.fnameescape(A2))
  switch_to(A2)

  it("reopens the scope that session was reviewing", function()
    assert.same(A2, current().root)
    assert.same("worktree", current().scope.name)
  end)

  it("draws that scope's diff", function()
    assert.same({ "src/config.lua" }, drawn())
  end)

  -- The whole point of reopening it: the marks earned in that scope are the ones that come
  -- back, and they were earned in another process.
  it("gives back the marks that session earned in it", function()
    assert.same({ "src/config.lua" }, marked())
  end)
end)
