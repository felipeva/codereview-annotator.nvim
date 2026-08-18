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

---The commits with these subjects, as the set a trim takes out — wherever they sit.
---@param ... string
---@return string[] skipped
local function taken_out(...)
  local skipped = {}
  for _, subject in ipairs({ ... }) do
    local commit = commit_named(subject)
    skipped[#skipped + 1] = commit.sha
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

---How much of a file the review draws, in git's own two numbers.
---
---A path alone cannot tell the change one kept commit made to a file from the whole of that
---file arriving with the commit that added it: both are the same name in the same list. The
---counts are where a pre-image built from the wrong commits shows.
---@param files CRFile[]
---@param path string
---@return string "+N -M", or a sentence when the review does not hold that file
local function counts_of(files, path)
  for _, f in ipairs(files) do
    if f.path == path then
      return ("+%d -%d"):format(f.added, f.removed)
    end
  end
  return "not in the review at all"
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

--- A trim with a hole in it -------------------------------------------------------

-- The commits taken out no longer have to be the ones at the start of the branch, so the
-- review reads from a tree that never existed as a commit and has to be built. What is
-- asserted here is the **delta** and never a tree object's identity: a comparison of tree
-- oids passes against a tree assembled the wrong way for as long as the expectation was
-- assembled the same wrong way. Which files the review draws, and how much of each, is what
-- a reviewer can see and the only thing that can catch a pre-image built from the wrong
-- commits.
--
-- Every case is set through the store and read back through resolution, which is the seam
-- the block above already uses. The builder gets no seam of its own.

describe("a commit taken out of the middle", function()
  -- The commit that added `src/config_spec.lua`, with the commit older than it left in.
  local files, scope = under_trim(taken_out("test: cover the config reader"))

  it("keeps the commit older than it in the review", function()
    assert.same("M", status_of(files, "src/config.lua"), vim.inspect(paths(files)))
  end)

  -- The teeth. The file the skipped commit *added* is still in the review, because a kept
  -- commit changed it afterwards — but only that change is left. Read from the merge base
  -- instead and the same path is there as an addition of the whole file, so a comparison of
  -- names alone passes against a pre-image that took nothing out at all.
  it("shows the file it added as the one line a kept commit changed in it", function()
    assert.same("M", status_of(files, "src/config_spec.lua"), vim.inspect(paths(files)))
    assert.same("+1 -1", counts_of(files, "src/config_spec.lua"))
  end)

  it("holds nothing else the skipped commit did", function()
    assert.same({ "README.md", "src/config.lua", "src/config_spec.lua", "src/lexer.lua" }, paths(files))
  end)

  it("says N of M in its label, which is the shape this reading has", function()
    assert.is_truthy(scope.label:find(("%d of %d"):format(#commits - 1, #commits), 1, true), scope.label)
  end)

  it("still names the branch it is a review of", function()
    assert.is_truthy(scope.label:find("branch vs ", 1, true), scope.label)
  end)

  -- The field a narrowed review's progress is read back under. It does not move with the
  -- pre-image, and a synthesized pre-image is the furthest the two have ever been apart.
  it("keeps the identity at the merge base", function()
    assert.same(base, scope.identity)
    assert.are_not.same(scope.before, scope.identity)
  end)
end)

describe("two commits taken out that are not next to each other", function()
  -- The oldest commit and the merge are kept, and they sit between the two taken out.
  local files, scope = under_trim(taken_out("test: cover the config reader", "docs: write the readme"))

  it("leaves out what both of them did", function()
    assert.same({ "src/config.lua", "src/config_spec.lua", "src/lexer.lua" }, paths(files))
  end)

  it("keeps the work of every commit between them", function()
    assert.same("+1 -0", counts_of(files, "src/config.lua"))
    assert.same("+2 -1", counts_of(files, "src/lexer.lua"))
  end)

  it("counts what is left in its label", function()
    assert.is_truthy(scope.label:find(("%d of %d"):format(#commits - 2, #commits), 1, true), scope.label)
  end)
end)

-- The case that caught the first design. Accumulating every skipped commit from the merge
-- base refuses this one — the merge's own diff adds what the side branch brought while the
-- base already holds it — and it is the shipped `gc` flow on any branch with a merge in it.
-- Anchored, it assembles nothing at all and reads what it has always read.
describe("a trim reaching past the merge", function()
  local merge = commit_named("Merge branch 'lexer' into feature")
  local files, scope = under_trim(taken_out_below("test: assert the host as well"))

  it("reads from the merge itself, so nothing was assembled", function()
    assert.same(merge.sha, scope.before)
  end)

  it("draws exactly what the shipped trim drew for that reading", function()
    local expected = h.git_lines(fixture, { "diff", "--name-status", merge.sha })
    assert.same(
      expected,
      vim.tbl_map(function(f)
        return ("%s\t%s"):format(f.status, f.path)
      end, files)
    )
  end)

  it("says last N, because that is the shape this reading has", function()
    assert.is_truthy(scope.label:find(("last %d"):format(#commits - 3), 1, true), scope.label)
  end)
end)

-- The other case that caught it, and for the same reason: from the merge base this collides
-- on the merge, and anchored it is the whole branch's newest commit and nothing is built.
describe("every commit taken out", function()
  local everything = vim.tbl_map(function(c)
    return c.sha
  end, commits)
  local files, scope = under_trim(everything)

  it("reads from the branch's own tip", function()
    assert.same(full("HEAD"), scope.before)
  end)

  it("leaves a review of the reviewer's uncommitted work, which is nothing here", function()
    assert.same({}, paths(files))
  end)

  it("says it holds none of them", function()
    assert.is_truthy(scope.label:find(("0 of %d"):format(#commits), 1, true), scope.label)
  end)
end)

--- A merge, on either side of the rule ---------------------------------------------

-- One merge, on one branch, in three selections -- because no one selection can state this
-- rule. Taken off the *start* of the branch it is inside the leading run: it assembles nothing
-- and reads what a trim past a merge has always read, which is the block two above this one
-- and the shipped `gc` flow on any branch with a merge in it. Taken out with a commit older
-- than it left in, it is refused before any merge is attempted: its first-parent diff adds
-- everything the side branch brought while the anchor already holds it, and what it brought is
-- outside the review in the first place. Taken off the start with a commit above it taken out
-- as well, it is inside the run *and* the trim has a hole, which is the only selection that
-- can tell "where the merge sits" from "the set holds a merge".
--
-- What resolution can show of a refusal is only that it did not narrow the review. The
-- sentence a reviewer reads is at the pick, in the view half of this file.
describe("the merge taken out of the middle", function()
  -- Resolution has no reviewer in front of it, so a refused set does here what every set that
  -- cannot be built does: it gives the whole branch back.
  local files, scope = under_trim(taken_out("Merge branch 'lexer' into feature"))

  it("gives the whole branch back rather than a reading it refused to build", function()
    assert.same({ "README.md", "src/config.lua", "src/config_spec.lua", "src/lexer.lua" }, paths(files))
  end)

  it("says nothing about a trim it refused", function()
    assert.is_nil(scope.label:find("last", 1, true), scope.label)
    assert.is_nil(scope.label:find(" of ", 1, true), scope.label)
  end)
end)

-- The rule is about where the merge sits and never about the set holding one, and this is the
-- case that can tell those two apart. The merge is inside the run, so it merges nothing --
-- and a commit above the run is taken out beside it, so a tree really is assembled. A rule
-- written as "refuse a set with a merge in it" passes every other block in this file and reds
-- this one.
describe("a hole above a merge the trim takes off the start", function()
  local merge = commit_named("Merge branch 'lexer' into feature")
  -- Everything up to and including the merge, and the newest commit as well. What is left in
  -- the review is the one commit between them.
  local skipped = taken_out_below("test: assert the host as well")
  vim.list_extend(skipped, taken_out("docs: write the readme"))
  local files, scope = under_trim(skipped)

  it("refuses nothing, and holds only the commit it kept", function()
    assert.same({ "src/config_spec.lua" }, paths(files))
    assert.same("+1 -1", counts_of(files, "src/config_spec.lua"))
  end)

  -- The teeth against an anchor that stopped at the merge and applied nothing above it: the
  -- readme the newest commit wrote is out of this review, and only a built tree takes it out.
  it("built a tree, so the pre-image is no commit on this branch", function()
    assert.are_not.same(merge.sha, scope.before)
    assert.same({ "commit" }, h.git_lines(fixture, { "cat-file", "-t", scope.before }))
    assert.same({}, h.git_lines(fixture, { "branch", "--contains", scope.before }))
  end)

  it("counts the one commit it kept", function()
    assert.is_truthy(scope.label:find(("1 of %d"):format(#commits), 1, true), scope.label)
  end)
end)

-- **A branch with no merge on its first-parent line is untouched by the rule**, and the
-- history this spec reads cannot say so on its own: every listing of it holds the merge. So a
-- second copy of the fixture, and a branch cut off master's tip with three ordinary commits
-- on it -- a first-parent line the rule has nothing to fire on. A hole in the middle of it is
-- built and drawn exactly as it was before the rule existed.
--
-- Its own repository throughout, so nothing here can be answered out of what the blocks above
-- did to the fixture they share, and nothing here reaches them.
describe("a hole on a branch with no merge in it", function()
  local flat = h.fixture("mkcommits")
  local flat_root = assert(vim.uv.fs_realpath(flat))
  h.git_lines(flat, { "checkout", "-q", "-b", "flat", "master" })

  ---@param name string
  ---@param body string[]
  ---@param subject string
  local function commit(name, body, subject)
    vim.fn.writefile(body, vim.fs.joinpath(flat, name))
    h.git_lines(flat, { "add", "-A" })
    h.git_lines(flat, { "commit", "-q", "-m", subject })
  end

  commit("src/flat_one.lua", { "local one = 1" }, "feat: write the first file")
  commit("src/flat_two.lua", { "local two = 2" }, "feat: write the second file")
  commit("src/flat_one.lua", { "local one = 1", "local three = 3" }, "feat: write the first file again")

  local flat_base = assert(h.git_lines(flat, { "merge-base", "master", "HEAD" })[1], "no merge base")
  local listed = assert(git.branch_commits(flat_root, flat_base))
  -- The middle row: the only hole a three-commit branch has.
  local middle = listed[2]

  it("lists a first-parent line with no merge on it", function()
    assert.same(3, #listed, vim.inspect(listed))
    for _, c in ipairs(listed) do
      assert.is_false(c.merge, c.subject)
    end
  end)

  state.set_trim(flat_root, { middle.id })
  local scope = assert(git.resolve_scope("branch", flat_root))
  local files = assert(git.collect(scope, flat_root, {}))

  it("refuses nothing", function()
    assert.is_nil(git.trim_refusal(flat_root, flat_base, { middle.id }))
  end)

  it("draws the two commits it kept and not the one it took out", function()
    assert.same({ "src/flat_one.lua" }, paths(files))
    assert.same("+2 -0", counts_of(files, "src/flat_one.lua"))
  end)

  it("counts what is left in its label", function()
    assert.is_truthy(scope.label:find("2 of 3", 1, true), scope.label)
  end)

  state.set_trim(flat_root, nil)
end)

-- A skip that cannot be built, at the seam where nothing can be said about it: resolution
-- has no reviewer in front of it. The refusal a reviewer reads is at the pick, in the view
-- half of this file.
describe("a commit whose work a kept commit rewrote", function()
  local files, scope = under_trim(taken_out("test: assert the host as well"))

  it("gives the whole branch back rather than a reading nothing could assemble", function()
    assert.same({ "README.md", "src/config.lua", "src/config_spec.lua", "src/lexer.lua" }, paths(files))
  end)

  it("says nothing about a trim it could not read", function()
    assert.is_nil(scope.label:find("last", 1, true), scope.label)
    assert.is_nil(scope.label:find(" of ", 1, true), scope.label)
  end)
end)

describe("the commit it depends on taken out beside it", function()
  local files, scope = under_trim(taken_out("test: cover the config reader", "test: assert the host as well"))

  -- Both commits that ever touched that file are out, so the file is in the pre-image
  -- exactly as the working tree has it and the review says nothing about it. A pre-image
  -- that stopped at the first of the two would draw it, which is the whole difference
  -- between applying the set and reading from one commit in it.
  it("takes the file both of them touched out of the review", function()
    assert.same({ "README.md", "src/config.lua", "src/lexer.lua" }, paths(files))
  end)

  it("counts what is left in its label", function()
    assert.is_truthy(scope.label:find(("%d of %d"):format(#commits - 2, #commits), 1, true), scope.label)
  end)
end)

-- The synthesized commit is unreachable on purpose, which is the exposure the **snapshot**
-- mechanism already accepts. Nothing about building it may reach the reviewer's repository:
-- no ref to keep it alive, no index, no working tree.
describe("what building a pre-image must not touch", function()
  local refs = h.git_lines(fixture, { "for-each-ref", "--format=%(refname) %(objectname)" })
  local head = full("HEAD")
  local _, scope = under_trim(taken_out("test: cover the config reader", "docs: write the readme"))

  it("built a commit this repository really holds", function()
    assert.same({ "commit" }, h.git_lines(fixture, { "cat-file", "-t", scope.before }))
  end)

  it("wrote no ref for it", function()
    assert.same(refs, h.git_lines(fixture, { "for-each-ref", "--format=%(refname) %(objectname)" }))
    assert.same({}, h.git_lines(fixture, { "branch", "--contains", scope.before }))
  end)

  it("left the index and the working tree alone", function()
    assert.same({}, h.git_lines(fixture, { "status", "--porcelain" }))
  end)

  it("left HEAD where it was", function()
    assert.same(head, full("HEAD"))
  end)
end)

-- Cycling scopes and reopening a review both resolve again, and a reviewer who narrowed a
-- long branch pays the whole accumulation on each of them without a cache.
--
-- **A cache is invisible unless the clock moved between the two builds.** A commit object
-- carries the moment it was minted, so two accumulations inside one second mint the same
-- object and this case would hold with nothing cached at all — the trap that a filter test
-- needs a fixture only that filter can reject. The wait is what gives it teeth: measured,
-- removing the cache reds it and nothing else in the suite.
describe("the tree a hole builds, resolved a second time", function()
  local skipped = taken_out("test: cover the config reader", "docs: write the readme")
  local _, first = under_trim(skipped)
  vim.wait(1100)
  local _, again = under_trim(skipped)

  it("is the commit the first resolve built, not a second one", function()
    assert.same(first.before, again.before)
  end)
end)

state.set_trim(root, nil)

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

---What a box on the commit list says for a commit that is in the review.
---
---Learned from the first list this file opens, which is opened over a review with nothing
---taken out of it, rather than written down here: naming the character would be this file
---reciting the float's implementation back to itself. The column itself is
---`trim_float_spec`'s.
local IN

---Read the review from `subject` forward, through the keys a reviewer presses.
---
---Every commit carries a box on that list, so this leaves the boxes down to that row checked
---and unchecks every commit older than it -- which is the set a reviewer builds for the same
---reading -- and then applies them with `<CR>`. "All commits" leaves every box checked, which
---is the whole branch.
---@param subject string "All commits" for the top row
---@return integer win The float's window, which the pick should have closed
local function trim_by_key(subject)
  vim.api.nvim_set_current_win(assert(view.current()).win)
  h.feed("gc")
  local win = vim.api.nvim_get_current_win()
  assert.are_not.same("", vim.api.nvim_win_get_config(win).relative, "gc opened no float")
  local buf = vim.api.nvim_win_get_buf(win)

  ---The box at the head of `row`, read as the column the top row's own text starts after.
  ---@param row integer
  ---@return string
  local function box(row)
    local rows = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local width = assert(rows[1]:find("All commits", 1, true), rows[1]) - 1
    return rows[row]:sub(1, width)
  end

  if not IN then
    assert(state.trim(root) == nil, "the first commit list has to be opened over a whole branch")
    IN = box(2)
  end

  local rows = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local at
  for i, row in ipairs(rows) do
    if row:find(subject, 1, true) then
      at = i
      break
    end
  end
  assert(at, subject .. " is on no row: " .. table.concat(rows, "\n"))

  for i = 2, #rows do
    local wanted = at == 1 or i <= at
    if (box(i) == IN) ~= wanted then
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      h.feed("<Space>")
    end
  end
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

--- A pick that cannot be built ------------------------------------------------------

-- Taking one commit out can need a commit that is staying, and such a pick is refused
-- rather than approximated — at the moment it is applied, before anything is stored. What
-- the reviewer can see is the sentence, a store still holding the trim they had, and the
-- review on screen unchanged.
--
-- Applied through `view.trim_to`, which is the one entry point a pick goes through. No key
-- reaches a set with a hole in it yet: the float still picks a start.
describe("a commit whose work a kept commit rewrote, picked", function()
  local W = assert(view.current())
  local was_paths = paths(W.files)
  local was_label = W.scope.label
  local was_trim = vim.deepcopy(assert(state.trim(root), "this review is not trimmed, so nothing can be untouched"))

  local dependent = commit_named("test: assert the host as well")
  local dependency = commit_named("test: cover the config reader")
  local short = assert(h.git_lines(fixture, { "rev-parse", "--short", dependent.sha })[1])

  local msgs, restore = h.capture_notify()
  view.trim_to({ dependent.sha })
  restore()

  it("names the commit it refused", function()
    assert.is_true(h.notified(msgs, short), vim.inspect(msgs))
    assert.is_true(h.notified(msgs, dependent.subject), vim.inspect(msgs))
  end)

  it("names the file it conflicts in", function()
    assert.is_true(h.notified(msgs, "src/config_spec.lua"), vim.inspect(msgs))
  end)

  -- Which kept commit introduced the conflicting region takes a heuristic that can name the
  -- wrong commit confidently, so the message names none. The commit this one really does
  -- depend on is the one the message must not claim to have found.
  it("names no commit it might have depended on", function()
    local short_dependency = assert(h.git_lines(fixture, { "rev-parse", "--short", dependency.sha })[1])
    assert.is_false(h.notified(msgs, short_dependency), vim.inspect(msgs))
    assert.is_false(h.notified(msgs, dependency.subject), vim.inspect(msgs))
  end)

  it("leaves the store holding the trim the reviewer already had", function()
    assert.same(was_trim, state.trim(root))
  end)

  it("leaves the review that was on screen exactly as it was", function()
    local X = assert(view.current(), "the review view closed")
    assert.same(was_paths, paths(X.files))
    assert.same(was_label, X.scope.label)
  end)
end)

describe("the commit it depends on picked beside it", function()
  local dependent = commit_named("test: assert the host as well")
  local dependency = commit_named("test: cover the config reader")
  local listed = assert(git.branch_commits(root, base))

  local msgs, restore = h.capture_notify()
  view.trim_to({ dependency.sha, dependent.sha })
  restore()
  local W = assert(view.current())

  it("refuses nothing", function()
    assert.is_false(h.notified(msgs, "conflicts"), vim.inspect(msgs))
  end)

  it("draws the review the two of them are out of", function()
    assert.same({
      "README.md",
      "src/config.lua",
      "src/config_spec.lua",
      "src/late.lua",
      "src/lexer.lua",
      "src/loose.lua",
    }, paths(W.files))
  end)

  it("counts what is left on the winbar", function()
    local bar = h.winbar(W.win)
    assert.is_truthy(bar:find(("%d of %d"):format(#listed - 2, #listed), 1, true), bar)
  end)

  it("stored it, so the next resolve reads the same review", function()
    assert.same({ dependency.sha, dependent.sha }, state.trim(root))
  end)
end)

-- The merge picked out of the middle, which is the one refusal that is not about files. What
-- the reviewer is told is that the merge brings this review nothing: merging the default
-- branch moves the merge base forward, so what it brought is already outside the reading.
-- Naming the files it would have collided in would answer a question they did not ask with a
-- list they did not write and cannot act on.
describe("the merge picked out of the middle", function()
  local W = assert(view.current())
  local was_paths = paths(W.files)
  local was_label = W.scope.label
  local was_trim = vim.deepcopy(assert(state.trim(root), "this review is not trimmed, so nothing can be untouched"))

  local merge = commit_named("Merge branch 'lexer' into feature")
  local short = assert(h.git_lines(fixture, { "rev-parse", "--short", merge.sha })[1])

  local msgs, restore = h.capture_notify()
  view.trim_to({ merge.sha })
  restore()

  it("says a merge brings nothing the review does not already read", function()
    assert.is_true(h.notified(msgs, "brings nothing the review does not already read"), vim.inspect(msgs))
  end)

  it("names the merge it refused", function()
    assert.is_true(h.notified(msgs, short), vim.inspect(msgs))
  end)

  -- A merge is called `Merge remote-tracking branch 'X' into Y`: sixty characters that say
  -- nothing the word *merge* does not, in front of the only part a reviewer can act on.
  it("names no subject, because a merge's subject says nothing the word merge does not", function()
    assert.is_false(h.notified(msgs, merge.subject), vim.inspect(msgs))
  end)

  -- The teeth against the sentence going back to reading `Taking out <sha> <subject> ...`: a
  -- surface that shows one line truncates the tail, so a reason built last is a reason a
  -- reviewer never reads. What truncation is allowed to cost is the sha, which is on the row
  -- their cursor is on.
  it("says why before it says which, so a truncated line still carries the reason", function()
    local said = vim.tbl_filter(function(m)
      return m:find("brings nothing", 1, true) ~= nil
    end, msgs)
    assert.same(1, #said, vim.inspect(msgs))
    assert.same(1, said[1]:find("A merge brings nothing"), said[1])
  end)

  -- The teeth against a rule that attempts the merge and rewords what `merge-tree` said: that
  -- is the same answer with better prose, and it names every file the side branch brought.
  it("names no file it would have collided in", function()
    for _, path in ipairs({ "README.md", "src/config.lua", "src/config_spec.lua", "src/lexer.lua" }) do
      assert.is_false(h.notified(msgs, path), vim.inspect(msgs))
    end
    assert.is_false(h.notified(msgs, "conflicts in"), vim.inspect(msgs))
  end)

  it("leaves the store holding the trim the reviewer already had", function()
    assert.same(was_trim, state.trim(root))
  end)

  it("leaves the review that was on screen exactly as it was", function()
    local X = assert(view.current(), "the review view closed")
    assert.same(was_paths, paths(X.files))
    assert.same(was_label, X.scope.label)
  end)
end)

-- The same row, taken off the start of the branch: every commit older than the merge goes out
-- with it, so it is inside the leading run and merges nothing. This is the shipped `gc` flow
-- on any branch with a merge in it, and it is the half of the rule a reviewer meets most.
describe("the same merge picked off the start of the branch", function()
  local merge = commit_named("Merge branch 'lexer' into feature")
  local listed = assert(git.branch_commits(root, base))

  local msgs, restore = h.capture_notify()
  view.trim_to(taken_out_below("test: assert the host as well"))
  restore()
  local W = assert(view.current())

  it("refuses nothing", function()
    assert.is_false(h.notified(msgs, "is not needed"), vim.inspect(msgs))
    assert.is_false(h.notified(msgs, "conflicts in"), vim.inspect(msgs))
  end)

  it("reads from the merge itself, so nothing was assembled", function()
    assert.same(merge.sha, W.scope.before)
  end)

  -- Against `git diff` alone, so the comparison is with the reading this trim gave before any
  -- of this existed. The untracked file left in the tree further up this file is in the review
  -- and in no `git diff`, so it is held out of the comparison rather than dropped from the
  -- claim -- that it survives every trim is asserted where it is written and again below.
  it("draws exactly what the shipped trim drew for that reading", function()
    local tracked = {}
    for _, f in ipairs(W.files) do
      if f.status ~= "U" then
        tracked[#tracked + 1] = ("%s\t%s"):format(f.status, f.path)
      end
    end
    assert.same(h.git_lines(fixture, { "diff", "--name-status", merge.sha }), tracked)
  end)

  it("says last N on the winbar, because that is the shape this reading has", function()
    local bar = h.winbar(W.win)
    assert.is_truthy(bar:find(("last %d"):format(#listed - 3), 1, true), bar)
  end)
end)

-- The maximal trim: the review is the work the reviewer has not committed, which is what
-- the file left uncommitted and untracked several blocks above.
describe("every commit taken out, in the review", function()
  local listed = assert(git.branch_commits(root, base))
  view.trim_to(vim.tbl_map(function(c)
    return c.id
  end, listed))
  local W = assert(view.current())

  it("holds the reviewer's uncommitted and untracked work and nothing else", function()
    assert.same({ "src/config_spec.lua", "src/loose.lua" }, paths(W.files))
  end)

  it("still keeps the untracked file as untracked work", function()
    assert.same("U", status_of(W.files, "src/loose.lua"), vim.inspect(paths(W.files)))
  end)

  it("says on the winbar that it holds none of the branch's commits", function()
    local bar = h.winbar(W.win)
    assert.is_truthy(bar:find(("0 of %d"):format(#listed), 1, true), bar)
  end)
end)

state.set_trim(root, nil)
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
