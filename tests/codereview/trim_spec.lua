-- The **trim**: the commits taken out of a branch review.
--
-- Two halves, and the seams are the two that already exist. The first is scope resolution,
-- where the pre-image is worked out and where an error is invisible in a rendered diff --
-- every pick reads what that pick has always read, the oldest row means the merge base and
-- not a parent, and removing the trim gives the review back. The second is the review view,
-- where everything a reviewer can see is: which files the diff draws, what the label says,
-- which reviewed marks survived, what the queue still lists.
--
-- What is asserted is what a reviewer can observe. Never the shape of a git invocation, and
-- never the shape of what the trim is stored in: a trim is set through the state module and
-- read back through resolution, which is the same round trip `since-batch` makes through
-- the archive. A set of commits goes in because that is what a trim *is*, and what comes
-- back is compared against git's own answer for the same reading.
--
-- The fixture is `mkcommits`, whose history is the point: its merge base is a different
-- commit from its oldest listed commit's parent, so the oldest-row rule is observable at
-- all -- see the script's own header.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkcommits")
local root = assert(vim.uv.fs_realpath(fixture))

local annotate = require("codereview.annotate")
local codereview = require("codereview")
local git = require("codereview.git")
local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

local NOTE = "a note written while the review was trimmed"

codereview.setup({
  compose = function(_, on_accept)
    on_accept(nil, NOTE)
  end,
  send = function() end,
})

--- What git says, which is what the trim is judged against ----------------------

local UNIT = "\31"

local base = assert(h.git_lines(fixture, { "merge-base", "master", "HEAD" })[1], "no merge base")

---The branch's own line of work, newest first.
---@return { sha: string, subject: string }[]
local function branch_log()
  local out = {}
  local fmt = "--format=%H" .. UNIT .. "%s"
  for _, l in ipairs(h.git_lines(fixture, { "log", "--first-parent", fmt, base .. "..HEAD" })) do
    local sha, subject = l:match("^(%S+)" .. UNIT .. "(.*)$")
    out[#out + 1] = { sha = assert(sha, l), subject = subject }
  end
  return out
end

local commits = branch_log()

---@param rev string
---@return string
local function full(rev)
  return assert(h.git_lines(fixture, { "rev-parse", rev })[1], rev)
end

---@param rev string
---@return string
local function parent_of(rev)
  return full(rev .. "^")
end

---The commit with that subject, and how many commits are kept by a trim starting at it.
---
---By subject rather than by index: which row of the listing a commit sits on moves the
---moment anything below adds one, and every claim here is about a commit a reviewer would
---recognize by what it says.
---@param subject string
---@return { sha: string, subject: string } commit, integer kept
local function commit_named(subject)
  for i, c in ipairs(commits) do
    if c.subject == subject then
      return c, i
    end
  end
  error("no commit on this branch says " .. subject)
end

---The commits a reviewer takes out by starting their reading at that commit: every commit
---older than it, which is what the row they land on picks.
---@param subject string
---@return string[] skipped
local function taken_out_below(subject)
  local _, kept = commit_named(subject)
  local skipped = {}
  for i = kept + 1, #commits do
    skipped[#skipped + 1] = commits[i].sha
  end
  return skipped
end

--- Reading a scope back ----------------------------------------------------------

---Set the trim and resolve the branch scope through it, exactly as opening a review does.
---@param skipped string[]|nil nil is no trim; an empty set is a trim that takes nothing out
---@return CRFile[] files, CRScope scope
local function under_trim(skipped)
  state.set_trim(root, skipped)
  local scope = assert(git.resolve_scope("branch", root))
  local files = assert(git.collect(scope, root, {}))
  return files, scope
end

---@param files CRFile[]
---@return string[]
local function paths(files)
  return vim.tbl_map(function(f)
    return f.path
  end, files)
end

---@param files CRFile[]
---@param path string
---@return string|nil status nil when the scope does not hold that file at all
local function status_of(files, path)
  for _, f in ipairs(files) do
    if f.path == path then
      return f.status
    end
  end
end

--- The fixture the resolution rules lean on --------------------------------------

describe("the history this spec reads", function()
  it("puts five commits on the branch's own line of work", function()
    assert.same(5, #commits, vim.inspect(commits))
  end)

  -- The reason the fixture's side branch is cut from master's tip: resolving the oldest row
  -- is a rule about the merge base, and a history where the two are one commit cannot tell
  -- the right answer from the wrong one.
  it("keeps the merge base and the oldest commit's parent as different commits", function()
    assert.are_not.same(base, parent_of(commits[#commits].sha))
  end)

  -- What the block below compares against is `git diff` alone, so anything in the tree that
  -- git diff does not name would be a file the review holds and the expectation lacks.
  it("is a clean checkout at this point in the file", function()
    assert.same({}, h.git_lines(fixture, { "status", "--porcelain" }))
  end)
end)

--- What every pick resolves to ----------------------------------------------------

-- The claim the representation rests on: a reviewer presses the same key, picks the same
-- row, and reads the same diff. What each row is compared against is git's own answer for
-- the reading that row has always given -- the picked commit's own parent, and the merge
-- base on the oldest row -- so what is asserted is the reading and never the arithmetic
-- that produced it.
--
-- Every row rather than a chosen one, because the rows differ in kind: the merge row is
-- where a trim reaches past a merge, and the oldest row is where the merge base and the
-- oldest commit's parent are two different commits.
--
-- Statuses and not only paths. `src/lexer.lua` is in the review either way, and it is a
-- file the branch *modified* against the merge base and a file it *added* against the
-- oldest commit's parent -- so a comparison of names alone passes against the wrong ref.
describe("every commit a reviewer can pick", function()
  local listed = assert(git.branch_commits(root, base))

  it("offers one row per commit on the branch's own line of work", function()
    assert.same(#commits, #listed)
  end)

  ---@param files CRFile[]
  ---@return string[] One `status<TAB>path` per file, in git's own spelling
  local function as_git_says(files)
    return vim.tbl_map(function(f)
      return ("%s\t%s"):format(f.status, f.path)
    end, files)
  end

  for at, commit in ipairs(commits) do
    it(("reads what a review starting at %q has always read"):format(commit.subject), function()
      -- The ref a trim starting at this commit was stored as before a trim was a set.
      local shipped = at < #commits and parent_of(commit.sha) or base
      local files = under_trim(taken_out_below(commit.subject))
      assert.same(h.git_lines(fixture, { "diff", "--name-status", shipped }), as_git_says(files))
    end)
  end

  state.set_trim(root, nil)
end)

--- What a trim resolves to --------------------------------------------------------

describe("a trim starting at a commit part-way up the branch", function()
  local subject = "test: cover the config reader"
  local _, kept = commit_named(subject)
  local files, scope = under_trim(taken_out_below(subject))

  -- The commit picked added `src/config_spec.lua`; the one before it added the host line to
  -- `src/config.lua`. So the two files say which side of the pick each commit landed on.
  it("puts the picked commit's own work in the diff", function()
    assert.is_true(vim.tbl_contains(paths(files), "src/config_spec.lua"), vim.inspect(paths(files)))
  end)

  it("leaves the commit before it out", function()
    assert.is_false(vim.tbl_contains(paths(files), "src/config.lua"), vim.inspect(paths(files)))
  end)

  it("says in its label how many commits are left", function()
    assert.is_truthy(scope.label:find(("last %d"):format(kept), 1, true), scope.label)
  end)

  it("still names the branch it is a review of", function()
    assert.is_truthy(scope.label:find("branch vs ", 1, true), scope.label)
  end)
end)

-- The oldest row takes nothing out: there is no commit older than it to take. That is a
-- trim all the same -- the label counts the whole branch and the list marks the row -- and
-- it is the one pick whose set is empty, so it is also what says the store keeps an empty
-- set rather than losing it on the way to the disk and back.
describe("a trim starting at the oldest commit", function()
  local files, scope = under_trim({})

  it("reads from the merge base", function()
    assert.same(base, scope.before)
  end)

  it("is still a trim, and says so in its label", function()
    assert.is_truthy(scope.label:find(("last %d"):format(#commits), 1, true), scope.label)
  end)

  -- `src/lexer.lua` exists at the merge base and does not exist at the oldest commit's
  -- parent, so a trim resolved to that parent draws it as a file the branch added rather
  -- than as the change the branch made to it. The status is where the wrong ref shows.
  it("shows the branch's change to a file the merge base already had", function()
    assert.same("M", status_of(files, "src/lexer.lua"), vim.inspect(paths(files)))
  end)

  it("is the same review as the whole branch", function()
    local whole = under_trim(nil)
    assert.same(paths(whole), paths(files))
  end)
end)

describe("no trim at all", function()
  local files, scope = under_trim(nil)

  it("reads from the merge base", function()
    assert.same(base, scope.before)
  end)

  it("says nothing about a trim", function()
    assert.is_nil(scope.label:find("last", 1, true), scope.label)
  end)

  it("holds every file the branch changed", function()
    assert.same({ "README.md", "src/config.lua", "src/config_spec.lua", "src/lexer.lua" }, paths(files))
  end)
end)

describe("what a trim never moves", function()
  local _, trimmed = under_trim(taken_out_below("Merge branch 'lexer' into feature"))
  local _, whole = under_trim(nil)

  -- The one field the whole feature rests on. The pre-image moves under a trim and the
  -- identity does not, which is what leaves the reviewed marks where the reviewer left them.
  it("keeps the identity at the merge base, trimmed or not", function()
    assert.same(base, trimmed.identity)
    assert.same(whole.identity, trimmed.identity)
  end)

  it("really did move the pre-image, so that is a claim about two different refs", function()
    assert.are_not.same(trimmed.before, trimmed.identity)
  end)

  it("leaves the post-image the working tree", function()
    assert.is_nil(trimmed.after)
  end)

  it("keeps untracked work in the scope", function()
    assert.is_true(trimmed.untracked)
  end)
end)

describe("the scopes gs moves through", function()
  it("holds the five named scopes and no sixth", function()
    assert.same({ "branch", "staged", "unstaged", "worktree", "since-batch" }, git.SCOPES)
  end)

  it("is the same cycle under a trim as without one", function()
    state.set_trim(root, nil)
    local without = git.cycle(root)
    state.set_trim(root, taken_out_below(commits[1].subject))
    assert.same(without, git.cycle(root))
    state.set_trim(root, nil)
  end)
end)

--- The review a trim is applied inside --------------------------------------------

-- The work the reviewer has not read yet: one commit on top of the branch, changing a file
-- the branch's older commits had already changed. That overlap is what makes the two
-- reviewed-mark rules different claims -- one file the new commit moved, one it did not.
--
-- The marks are made *before* it is committed, so the blob a mark records is the blob the
-- commit then moves. A mark made afterwards would compare equal whatever the trim did.

state.set_trim(root, nil)
codereview.open()
local V = assert(view.current(), "the review view did not open")

---Mark the file at `path` reviewed in the open view.
---@param path string
local function toggle_reviewed_on(path)
  local W = assert(view.current(), "no review view open")
  local index = assert(h.file_index(W, path), path .. " is not in this scope")
  vim.api.nvim_win_set_cursor(W.win, { W.render.file_rows[index], 0 })
  view.toggle_reviewed()
end

toggle_reviewed_on("src/config.lua")
toggle_reviewed_on("src/lexer.lua")
local marked = { config = V.reviewed["src/config.lua"], lexer = V.reviewed["src/lexer.lua"] }

vim.fn.writefile({
  "local year = 2025",
  "local strict = false",
  "local depth = 3",
}, vim.fs.joinpath(fixture, "src/lexer.lua"))
h.git_lines(fixture, { "add", "-A" })
h.git_lines(fixture, { "commit", "-q", "-m", "fix: loosen the lexer" })

local UNREAD = "fix: loosen the lexer"

---Open the commit list from the diff, put the cursor on the row that says `subject`, and
---press `<CR>` -- which is the only way a reviewer ever applies a trim.
---@param subject string "All commits" for the top row
---@return integer win The float's window, which the pick should have closed
local function trim_by_key(subject)
  vim.api.nvim_set_current_win(assert(view.current()).win)
  h.feed("gc")
  local win = vim.api.nvim_get_current_win()
  assert.are_not.same("", vim.api.nvim_win_get_config(win).relative, "gc opened no float")
  local rows = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  local at
  for i, row in ipairs(rows) do
    if row:find(subject, 1, true) then
      at = i
      break
    end
  end
  vim.api.nvim_win_set_cursor(win, { assert(at, subject .. " is on no row: " .. table.concat(rows, "\n")), 0 })
  h.feed("<CR>")
  return win
end

describe("the review the trim is applied in", function()
  it("opened on the whole branch", function()
    assert.same("branch", V.scope.name)
    assert.same(4, #V.files, vim.inspect(paths(V.files)))
  end)

  it("recorded a mark against the blob each file had then", function()
    assert.is_string(marked.config)
    assert.is_string(marked.lexer)
  end)

  it("committed work that really did move one of those blobs and not the other", function()
    local now = git.hash_worktree({ "src/config.lua", "src/lexer.lua" }, root)
    assert.same(marked.config, now["src/config.lua"])
    assert.are_not.same(marked.lexer, now["src/lexer.lua"])
  end)
end)

describe("picking the commit the reviewer has not read", function()
  local float = trim_by_key(UNREAD)
  local W = assert(view.current(), "the review view closed")

  it("closes the float", function()
    assert.is_false(vim.api.nvim_win_is_valid(float))
  end)

  it("draws the diff again, from that commit forward", function()
    assert.same({ "src/lexer.lua" }, paths(W.files))
  end)

  it("says on the winbar that the review is trimmed", function()
    assert.is_truthy(h.winbar(W.win):find("last 1", 1, true), h.winbar(W.win))
  end)

  it("keeps the mark on the file the commit did not touch", function()
    assert.same(marked.config, W.reviewed["src/config.lua"])
  end)

  it("drops the mark on the file it did", function()
    assert.is_nil(W.reviewed["src/lexer.lua"])
  end)

  it("highlights the trimmed diff like any other review", function()
    assert.is_true(#h.syntax_marks(W) > 0)
  end)

  it("navigates by hunk inside it", function()
    vim.api.nvim_win_set_cursor(W.win, { 1, 0 })
    view.jump("hunk", true)
    assert.same("hunk", W.render.anchors[vim.api.nvim_win_get_cursor(W.win)[1]].kind)
  end)

  it("collapses a file inside it", function()
    local rows = #W.render.lines
    vim.api.nvim_win_set_cursor(W.win, { W.render.file_rows[1], 0 })
    view.toggle_expand()
    assert.is_true(#view.current().render.lines < rows)
    view.toggle_expand()
  end)

  it("draws it in the split layout too", function()
    view.toggle_layout()
    local split = assert(view.current())
    assert.is_true(split.before_win ~= nil and vim.api.nvim_win_is_valid(split.before_win))
    assert.same(#split.render.lines, #split.before_render.lines)
    view.toggle_layout()
    assert.same("unified", view.current().layout)
  end)
end)

-- The label is the only thing that stops a trim from being a trap, and the winbar it sits on
-- is width-constrained and cut by the fit rule -- so what the trim adds to it has to be
-- short enough to cost the bar nothing. The bar is padded to its pane by arithmetic, so a
-- label that no longer fits shows up as a bar that is not its pane's width.
describe("the label a trim adds", function()
  local W = assert(view.current())
  local was = vim.api.nvim_win_get_width(W.win)

  it("is drawn in full on a pane with room for it", function()
    local text, width = h.winbar(W.win)
    assert.is_truthy(text:find("branch vs ", 1, true), text)
    assert.is_truthy(text:find("last 1", 1, true), text)
    assert.same(was, width)
  end)

  it("still lays the bar out on a pane too narrow for all of it", function()
    vim.api.nvim_win_set_width(W.win, 50)
    view.paint()
    local narrow = vim.api.nvim_win_get_width(W.win)
    assert.is_true(narrow < was, ("the pane did not narrow: %d"):format(narrow))
    local _, width = h.winbar(W.win)
    assert.same(narrow, width)
    vim.api.nvim_win_set_width(W.win, was)
    view.paint()
  end)
end)

describe("uncommitted and untracked work under a trim", function()
  vim.fn.writefile(
    { "local cfg = require('config')", "assert(cfg.host)" },
    vim.fs.joinpath(fixture, "src/config_spec.lua")
  )
  vim.fn.writefile({ "local loose = true" }, vim.fs.joinpath(fixture, "src/loose.lua"))
  view.refresh()
  local W = assert(view.current())

  it("keeps the uncommitted change in the review", function()
    assert.is_number(h.file_index(W, "src/config_spec.lua"), vim.inspect(paths(W.files)))
  end)

  it("keeps the untracked file in the review", function()
    assert.same("U", status_of(W.files, "src/loose.lua"), vim.inspect(paths(W.files)))
  end)

  it("is still trimmed while it holds them", function()
    assert.is_truthy(W.scope.label:find("last 1", 1, true), W.scope.label)
  end)
end)

describe("annotating under a trim", function()
  queue.clear()
  local W = assert(view.current())
  local index = assert(h.file_index(W, "src/lexer.lua"))
  vim.api.nvim_win_set_cursor(W.win, { W.render.file_rows[index], 0 })
  annotate.annotate("bug")
  local trimmed = vim.deepcopy(assert(queue.all()[1], "nothing was captured under the trim"))

  it("captures what it was aimed at", function()
    assert.same({ "bug", "file", "src/lexer.lua", NOTE }, {
      trimmed.type,
      trimmed.kind,
      trimmed.path,
      trimmed.note,
    })
  end)

  -- Ids apart, because they are issued in order and nothing else about an entry is. An
  -- entry that recorded how the reviewer had narrowed their reading would differ here, and
  -- nothing weaker than a comparison of the whole entry would notice.
  it("produces the entry the same file produces with no trim at all", function()
    trim_by_key("All commits")
    queue.clear()
    local X = assert(view.current())
    local at = assert(h.file_index(X, "src/lexer.lua"))
    vim.api.nvim_win_set_cursor(X.win, { X.render.file_rows[at], 0 })
    annotate.annotate("bug")
    local whole = vim.deepcopy(assert(queue.all()[1], "nothing was captured with the trim removed"))
    trimmed.id, whole.id = nil, nil
    assert.same(whole, trimmed)
  end)
end)

describe("removing the trim", function()
  local W = assert(view.current())

  it("gives the whole branch back", function()
    assert.is_number(h.file_index(W, "src/config.lua"), vim.inspect(paths(W.files)))
  end)

  it("says nothing about a trim on the winbar", function()
    assert.is_nil(h.winbar(W.win):find("last", 1, true), h.winbar(W.win))
  end)

  -- The whole point of the identity: the mark was made before the trim, held through it,
  -- and is still here afterwards.
  it("still holds the mark the reviewer made before trimming", function()
    assert.same(marked.config, W.reviewed["src/config.lua"])
  end)

  it("draws that file collapsed, which is what a reviewer sees of it", function()
    assert.is_false(W.expanded["src/config.lua"])
  end)
end)

describe("the queue under a trim", function()
  queue.clear()
  local W = assert(view.current())
  local index = assert(h.file_index(W, "src/config.lua"))
  vim.api.nvim_win_set_cursor(W.win, { W.render.file_rows[index], 0 })
  annotate.annotate("bug")

  trim_by_key(UNREAD)
  local X = assert(view.current())

  local msgs, restore = h.capture_notify()
  view.review_queue()
  restore()
  local float = vim.api.nvim_get_current_win()
  local rows = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false)
  h.feed("q")

  it("really did take that file out of the review", function()
    assert.is_nil(h.file_index(X, "src/config.lua"), vim.inspect(paths(X.files)))
  end)

  it("still holds the annotation", function()
    assert.same(1, queue.count())
  end)

  it("still lists it in the float", function()
    assert.is_truthy(table.concat(rows, "\n"):find(NOTE, 1, true), table.concat(rows, "\n"))
  end)

  it("says nothing about it being out of scope", function()
    assert.is_false(h.notified(msgs, "scope"), vim.inspect(msgs))
    assert.is_false(h.notified(msgs, "stale"), vim.inspect(msgs))
  end)
end)

describe("cycling scope from a trimmed review", function()
  it("goes to the next scope, with no stop of its own", function()
    assert.same("branch", assert(view.current()).scope.name)
    view.set_scope(nil)
    assert.same("staged", assert(view.current()).scope.name)
  end)

  it("brings the trim back when the cycle returns to the branch", function()
    view.set_scope(nil)
    view.set_scope(nil)
    view.set_scope(nil)
    local W = assert(view.current())
    assert.same("branch", W.scope.name)
    assert.is_truthy(W.scope.label:find("last 1", 1, true), W.scope.label)
  end)
end)

-- A commit made after a trim is in the review the moment it is made, because a trim is the
-- commits it takes *out* and nobody took this one out. A trim that recorded the commits it
-- kept would leave the new one outside a review the reviewer never narrowed past it, and a
-- count remembered at pick time would keep saying the number it said then.
--
-- Last of this half, because it puts a sixth commit on the branch every block above counts.
describe("work committed after the trim was picked", function()
  vim.fn.writefile({ "local late = true" }, vim.fs.joinpath(fixture, "src/late.lua"))
  -- That file alone: the tree also holds work two blocks above left uncommitted, and this
  -- claim is about a commit rather than about what else is in the review beside it.
  h.git_lines(fixture, { "add", "src/late.lua" })
  h.git_lines(fixture, { "commit", "-q", "-m", "feat: commit after trimming" })
  -- The entry point `gs` back onto the branch and every open already go through, so the
  -- trim is read again and nothing about it was touched.
  view.set_scope("branch")
  local W = assert(view.current())

  it("holds the new commit's work", function()
    assert.is_number(h.file_index(W, "src/late.lua"), vim.inspect(paths(W.files)))
  end)

  it("still holds the commit the trim was picked at", function()
    assert.is_number(h.file_index(W, "src/lexer.lua"), vim.inspect(paths(W.files)))
  end)

  it("counts it, so the label grew by one", function()
    assert.is_truthy(W.scope.label:find("last 2", 1, true), W.scope.label)
  end)
end)

codereview.close()

--- The trim a session leaves behind -----------------------------------------------

-- Everything below is about what reached the disk, which no assertion made in the process
-- that wrote it can settle -- the same reason `state_spec` is two processes. `trim_child`
-- trims, exits, and this process reads the branch back.
--
-- A second copy of the fixture, because the one above has been committed into and trimmed
-- through by every block in this file: a claim about what a *fresh* repository's store
-- hands back must not be answerable out of what this process already did to it.
local kept = h.fixture("mkcommits")
local kept_root = assert(vim.uv.fs_realpath(kept))
local kept_base = assert(h.git_lines(kept, { "merge-base", "master", "HEAD" })[1], "no merge base")

-- The second branch, cut at the first one's tip: two readings of the same commits, which is
-- what "each branch keeps its own" needs and what neither branch in the fixture can offer.
-- `lexer` has one commit of its own, so every trim on it resolves to the merge base -- which
-- is the review it already was, and says nothing about anything.
h.git_lines(kept, { "branch", "second" })

-- The whole branch, as the fixture's own commits leave it. Written out rather than derived,
-- because it is what "the full branch opened" means below.
local WHOLE = { "README.md", "src/config.lua", "src/config_spec.lua", "src/lexer.lua" }

---Run a Neovim of its own over the kept fixture, sharing this process's throwaway
---`XDG_STATE_HOME` and nothing else. `--clean` so no user config, and no minimal_init, can
---hand it a state directory of another.
---@param mode "write"|"read"
---@return vim.SystemCompleted
local function spawn(mode)
  local proc = vim.system({
    vim.v.progpath,
    "--clean",
    "-l",
    vim.fs.joinpath(h.root, "tests", "codereview", "trim_child.lua"),
  }, {
    cwd = kept,
    text = true,
    env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = kept, MODE = mode },
  })
  return proc:wait(60000)
end

---Check a branch out and resolve the review over it again, which is what a reviewer coming
---back to a branch does.
---@param name string
local function checkout(name)
  h.git_lines(kept, { "checkout", "-q", name })
  view.set_scope("branch")
end

local writer = spawn("write")

describe("the process that trimmed two branches", function()
  it("exits cleanly", function()
    assert.same(0, writer.code, (writer.stderr or "") .. (writer.stdout or ""))
  end)
end)

vim.cmd("cd " .. vim.fn.fnameescape(kept))
codereview.open()

describe("a branch trimmed in the session before", function()
  local W = assert(view.current(), "the review view did not open on the kept fixture")

  it("opens where the reading stopped, and not on the whole branch", function()
    assert.same({ "README.md" }, paths(W.files))
  end)

  it("says on the winbar that the review is trimmed", function()
    assert.is_truthy(h.winbar(W.win):find("last 1", 1, true), h.winbar(W.win))
  end)
end)

describe("the other branch over the same commits", function()
  checkout("second")
  local W = assert(view.current())

  it("opens at its own trim and not at the first branch's", function()
    assert.same({ "README.md", "src/config_spec.lua", "src/lexer.lua" }, paths(W.files))
  end)

  it("counts its own commits on the winbar", function()
    assert.is_truthy(h.winbar(W.win):find("last 4", 1, true), h.winbar(W.win))
  end)
end)

describe("the first branch checked out again", function()
  checkout("feature")

  it("brings its own trim back, untouched by the branch beside it", function()
    assert.same({ "README.md" }, paths(assert(view.current()).files))
  end)
end)

-- A rebase, an amend and a force-push all end in one place: the commit the trim was picked
-- off is no longer in `HEAD`'s history. A squash is the shortest way to put a fixture there,
-- and it leaves the merge base where it was, so the full branch is the branch it always was.
describe("a branch whose commits were rewritten under its trim", function()
  h.git_lines(kept, { "checkout", "-q", "second" })
  h.git_lines(kept, { "reset", "--soft", kept_base })
  h.git_lines(kept, { "commit", "-q", "-m", "feat: the branch, rebased into one commit" })

  local msgs, restore = h.capture_notify()
  view.set_scope("branch")
  restore()
  local W = assert(view.current())

  it("opens the full branch", function()
    assert.same(WHOLE, paths(W.files))
  end)

  it("says the trim was lost", function()
    assert.is_true(h.notified(msgs, "trim was lost"), vim.inspect(msgs))
  end)

  it("says nothing about a trim on the winbar", function()
    assert.is_nil(h.winbar(W.win):find("last", 1, true), h.winbar(W.win))
  end)

  -- Scope resolution runs on every open, every scope change and every trim, and a sentence
  -- a reviewer meets on each of them is noise.
  it("says it once, and not again on the next resolve", function()
    local again, stop = h.capture_notify()
    view.set_scope("branch")
    stop()
    assert.is_false(h.notified(again, "trim was lost"), vim.inspect(again))
    assert.same(WHOLE, paths(assert(view.current()).files))
  end)
end)

describe("the branch beside the one that was rewritten", function()
  checkout("feature")

  it("kept its own trim through the other branch's rewrite", function()
    assert.same({ "README.md" }, paths(assert(view.current()).files))
  end)
end)

-- What a `git gc` after a rebase leaves behind, and the one case no session can reach on its
-- own: the commit was there when the trim was picked and this repository has nothing under
-- that name now. One fact for the reviewer, so one sentence -- the same one.
--
-- Set beside a commit the branch still holds, because a trim is a set and the rule is that
-- **any** failure takes all of it. A store that dropped the commit that failed and kept the
-- rest would leave the review narrowed by a selection the reviewer never made -- so the
-- surviving commit is one that narrows the review on its own, and the case above it is what
-- says so rather than assuming it.
describe("a stored trim holding a commit this repository does not have", function()
  local oldest = assert(h.git_lines(kept, { "rev-list", "--first-parent", "--reverse", kept_base .. "..HEAD" })[1])

  it("would narrow the review on its own, for the commit that survives the check", function()
    state.set_trim(kept_root, { oldest })
    view.set_scope("branch")
    assert.are_not.same(WHOLE, paths(assert(view.current()).files))
  end)

  local msgs, restore = h.capture_notify()
  state.set_trim(kept_root, { oldest, ("0"):rep(40) })
  view.set_scope("branch")
  restore()

  it("opens the full branch, so nothing of the set survived", function()
    assert.same(WHOLE, paths(assert(view.current()).files))
  end)

  it("says the trim was lost, in the sentence a rewritten commit says", function()
    assert.is_true(h.notified(msgs, "trim was lost"), vim.inspect(msgs))
  end)
end)

describe("a trim on a detached HEAD", function()
  -- Set from a known state rather than from whatever the block above left: this branch has
  -- no trim, so nothing below can be satisfied by one that was already there.
  state.set_trim(kept_root, nil)
  h.git_lines(kept, { "checkout", "-q", "--detach", "feature" })
  view.set_scope("branch")

  local msgs, restore = h.capture_notify()
  trim_by_key("docs: write the readme")
  restore()

  it("trims the review, so the feature is not simply absent", function()
    assert.same({ "README.md" }, paths(assert(view.current()).files))
  end)

  it("says the trim is not kept", function()
    assert.is_true(h.notified(msgs, "not kept"), vim.inspect(msgs))
  end)

  it("says it once, and not again on the next trim", function()
    local again, stop = h.capture_notify()
    trim_by_key("test: cover the config reader")
    stop()
    assert.is_false(h.notified(again, "not kept"), vim.inspect(again))
    assert.same({ "README.md", "src/config_spec.lua", "src/lexer.lua" }, paths(assert(view.current()).files))
  end)

  -- The claim a reviewer can see: the session after this one opens the whole branch.
  local reader = spawn("read")

  it("is gone in the session after it", function()
    local out = (reader.stdout or "") .. (reader.stderr or "")
    assert.is_truthy(out:find("paths: " .. table.concat(WHOLE, ","), 1, true), out)
  end)

  it("never became the trim of the branch that was checked out", function()
    checkout("feature")
    assert.same(WHOLE, paths(assert(view.current()).files))
  end)
end)

codereview.close()
