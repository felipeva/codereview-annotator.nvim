-- The float that lists the commits on the branch: its rows, its keys, and where the cursor
-- opens.
--
-- What is asserted is what a reviewer can see -- which rows are there, what a row says, what
-- sentence was shown -- and never the shape of the git invocation behind them. The rows are
-- compared against what git itself reports for the same range, because a hardcoded list of
-- subjects says nothing about the *rule* that produced them.
--
-- What a pick *resolves to* is `trim_spec`'s, at the seam where the ref arithmetic is. What
-- is here is the surface: the row a reviewer moves to, the row the float marks, and the key
-- they press.
--
-- The fixture is `mkcommits`, whose history is the whole point of it: a branch of four
-- commits, one of them a merge, over a merge base that is not the oldest commit's parent.
-- Both rules this file pins are invisible without it -- see the script's own header.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkcommits")
local root = assert(vim.uv.fs_realpath(fixture))

require("codereview").setup({ syntax = false })

local codereview = require("codereview")
local state = require("codereview.state")
local view = require("codereview.view")

--- What git says, which is what the float is judged against ---------------------

local UNIT = "\31"

---One `git log` line per commit, as `{ sha, when, subject }`.
---@param args string[] Appended to the log invocation
---@return { sha: string, when: string, subject: string }[]
local function log(args)
  local out = {}
  for _, l in ipairs(h.git_lines(fixture, vim.list_extend({ "log", "--format=%h%x1f%ar%x1f%s" }, args))) do
    local sha, when, subject = l:match("^(%S+)" .. UNIT .. "(.-)" .. UNIT .. "(.*)$")
    out[#out + 1] = { sha = assert(sha, l), when = when, subject = subject }
  end
  return out
end

local base = assert(h.git_lines(fixture, { "merge-base", "master", "HEAD" })[1], "no merge base")
---The branch's own line of work, newest first: what the float has to draw.
local first_parent = log({ "--first-parent", base .. "..HEAD" })
---Everything in the same range, which holds one more commit -- the one the merge brought in.
local everything = log({ base .. "..HEAD" })

---@param commits { subject: string }[]
---@return string[]
local function subjects(commits)
  return vim.tbl_map(function(c)
    return c.subject
  end, commits)
end

--- Reading the float ------------------------------------------------------------

---@param buf integer
---@return string[]
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---The rows that stand for a commit: everything below the row that removes the trim.
---@param buf integer
---@return string[]
local function commit_rows(buf)
  local all = lines(buf)
  return vim.list_slice(all, 2, #all)
end

---Which rows the float has marked, read off the column every row reserves for it.
---
---The column and not the glyph: what is being claimed is that one row is called out and the
---rest are not, and naming the character would be this file reciting the implementation
---back to itself.
---@param buf integer
---@return integer[] 1-based row numbers
local function marked(buf)
  local out = {}
  for i, row in ipairs(lines(buf)) do
    if row:sub(1, 1) ~= " " then
      out[#out + 1] = i
    end
  end
  return out
end

---@param win integer
---@param field "title"|"footer"
---@return string
local function chrome(win, field)
  local value = vim.api.nvim_win_get_config(win)[field]
  return value and tostring(value[1][1]) or ""
end

---@param buf integer
---@return table<string, boolean> Every left-hand side bound in normal mode
local function bound(buf)
  local lhs = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    lhs[vim.keycode(m.lhs)] = true
  end
  return lhs
end

---Press `gc` in `from` and hand back the float it opened.
---
---Guarded as a *float* rather than merely as another window: a key that is not bound at all
---leaves focus where it was, and "somewhere other than the diff" would then be satisfied by
---the file tree.
---@param from integer The window to press it in
---@return integer win, integer buf
local function commits_by_key(from)
  vim.api.nvim_set_current_win(from)
  h.feed("gc")
  local win = vim.api.nvim_get_current_win()
  assert.are_not.same(from, win, "gc opened no window of its own")
  assert.are_not.same("", vim.api.nvim_win_get_config(win).relative, "gc opened no float")
  return win, vim.api.nvim_win_get_buf(win)
end

--- The fixture the rest of this file leans on -----------------------------------

-- Every claim below is a claim about a *rule*, and each of these is what makes the
-- corresponding rule observable at all. Without the guards, a listing that dropped
-- `--first-parent` and a listing that kept it are the same listing.
describe("the history this spec reads", function()
  it("puts four commits on the branch's own line of work", function()
    assert.same(4, #first_parent, vim.inspect(subjects(first_parent)))
  end)

  it("holds one more commit than that in the same range", function()
    assert.same(5, #everything, vim.inspect(subjects(everything)))
  end)

  it("brought that one in through the merge, so first-parent listing can be seen at all", function()
    local merged = vim.tbl_filter(function(s)
      return not vim.tbl_contains(subjects(first_parent), s)
    end, subjects(everything))
    assert.same({ "fix: tighten the lexer" }, merged)
  end)

  -- Not asserted by anything here, and the reason the lexer branch is cut from master's tip
  -- rather than from the branch point: resolving the oldest row is a rule about the merge
  -- base, and a fixture where the two are one commit cannot tell the two answers apart.
  it("keeps the merge base and the oldest listed commit's parent as different commits", function()
    local oldest = first_parent[#first_parent].sha
    local parent = assert(h.git_lines(fixture, { "rev-parse", oldest .. "^" })[1])
    local merge_base = assert(h.git_lines(fixture, { "rev-parse", base })[1])
    assert.are_not.same(merge_base, parent)
  end)

  it("names an author no row is allowed to carry", function()
    assert.same("Fixture Author", h.git_lines(fixture, { "log", "-1", "--format=%an" })[1])
  end)
end)

--- The rows --------------------------------------------------------------------

describe("gc inside a branch review", function()
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  local rows = commit_rows(buf)

  it("draws one row per commit on the branch's own line of work", function()
    assert.same(#first_parent, #rows, table.concat(rows, "\n"))
  end)

  -- The row that gives the whole branch back. It sits above the commits rather than below
  -- them because it is the state the review opens in, and a reviewer removing a trim should
  -- not have to walk a long branch to reach it.
  it("puts the row that removes the trim above them all", function()
    assert.is_truthy(lines(buf)[1]:find("All commits", 1, true), lines(buf)[1])
  end)

  it("lists them newest first", function()
    local shas = vim.tbl_map(function(row)
      return row:match("%x+")
    end, rows)
    assert.same(
      vim.tbl_map(function(c)
        return c.sha
      end, first_parent),
      shas
    )
  end)

  -- The merge is one row and reads as the one change it was; what came in under it is the
  -- other branch's business.
  it("leaves out what arrived through the merge", function()
    local text = table.concat(rows, "\n")
    assert.is_truthy(text:find("Merge branch 'lexer'", 1, true), text)
    assert.is_nil(text:find("fix: tighten the lexer", 1, true), text)
  end)

  it("carries the short sha, the subject and the relative date on every row", function()
    for i, c in ipairs(first_parent) do
      local row = rows[i]
      assert.is_truthy(row:find(c.sha, 1, true), row)
      assert.is_truthy(row:find(c.subject, 1, true), row)
      assert.is_truthy(row:find(c.when, 1, true), row)
    end
  end)

  -- Whitespace is stripped from both sides rather than the padding being reproduced here:
  -- the claim is that a row holds those three facts and nothing else, and reproducing the
  -- arithmetic that lays them out would assert the implementation against itself.
  it("carries nothing else", function()
    for i, c in ipairs(first_parent) do
      assert.same((c.sha .. c.subject .. c.when):gsub("%s+", ""), (rows[i]:gsub("%s+", "")), rows[i])
    end
  end)

  it("names the author nowhere", function()
    for _, row in ipairs(rows) do
      assert.is_nil(row:find("Fixture Author", 1, true), row)
    end
  end)

  -- Relative rather than absolute: telling yesterday's work from last week's is what the
  -- date is on the row for, and the fixture's commits are days apart so the two spellings
  -- cannot be confused for each other.
  it("dates a row in words rather than as a stamp", function()
    for _, row in ipairs(rows) do
      assert.is_truthy(row:find("ago", 1, true), row)
    end
    assert.is_truthy(rows[#rows]:find("5 days ago", 1, true), rows[#rows])
  end)

  -- With no trim in play the review starts at the merge base, which is what the top row
  -- says -- so that is where the cursor belongs. The row it opens on with a trim *set* is
  -- the case with teeth, and it is below.
  it("opens the cursor on the row that removes the trim", function()
    assert.same(1, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it("marks no row while the whole branch is in the review", function()
    assert.same({}, marked(buf), table.concat(lines(buf), "\n"))
  end)

  it("says how many commits are listed", function()
    assert.is_truthy(chrome(win, "title"):find(tostring(#first_parent), 1, true), chrome(win, "title"))
  end)

  it("leaves the review it was pressed in on screen", function()
    assert.same(review, view.current())
    assert.is_true(vim.api.nvim_win_is_valid(review.win))
  end)

  it("is bound in the diff and in the file tree", function()
    assert.is_true(bound(review.buf)[vim.keycode("gc")] == true, "gc is not bound in the diff")
    assert.is_true(bound(assert(review.panel_buf))[vim.keycode("gc")] == true, "gc is not bound in the tree")
  end)

  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  codereview.close()
end)

--- The keys --------------------------------------------------------------------

describe("the keys on the float", function()
  codereview.open()
  local review = assert(view.current(), "no review view opened")

  it("closes on q", function()
    local win = commits_by_key(review.win)
    h.feed("q")
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("closes on <Esc>", function()
    local win = commits_by_key(review.win)
    h.feed("<Esc>")
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  -- Closing the float must not close the review behind it: `q` is the review's own key for
  -- that, and the float is on top of it.
  it("leaves the review open behind it", function()
    assert.same(review, view.current())
  end)

  -- Closing without applying: looking at the commit list has to be safe, so the two keys
  -- that close it leave the review reading exactly what it was reading.
  it("leaves the review on the scope it was on", function()
    local win = commits_by_key(review.win)
    local label = assert(view.current()).scope.label
    h.feed("q")
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.same(label, assert(view.current()).scope.label)
  end)

  it("advertises both the key that applies a trim and the key that closes it", function()
    local win = commits_by_key(review.win)
    local footer = chrome(win, "footer")
    h.feed("q")
    assert.is_truthy(footer:find("q close", 1, true), footer)
    assert.is_truthy(footer:find("⏎", 1, true), footer)
  end)

  codereview.close()
end)

--- Picking a row ----------------------------------------------------------------

-- What a pick *resolves to* is `trim_spec`'s. What is here is that the key reaches it: the
-- float closes, and the review behind it is reading something narrower than it was.
describe("<CR> on a commit", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local before = review.scope.label
  local files_before = #review.files

  local win = commits_by_key(review.win)
  -- The newest commit, which is the row directly under "All commits".
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  h.feed("<CR>")

  it("closes the float", function()
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("leaves the review open, and on the branch", function()
    assert.same("branch", assert(view.current()).scope.name)
  end)

  it("draws the diff again, narrower than it was", function()
    assert.is_true(#assert(view.current()).files < files_before)
  end)

  it("says on the label that the review is trimmed", function()
    assert.are_not.same(before, assert(view.current()).scope.label)
    assert.is_truthy(assert(view.current()).scope.label:find("last 1", 1, true))
  end)
end)

-- Finding the row the trim starts at is the whole reason the cursor is placed at all, and a
-- fresh window already opens on row one -- so this block sets a trim that is *not* the top
-- row before it looks. Asserted from anywhere else, the case passes against a float that
-- places the cursor nowhere.
describe("the float opened with a trim already set", function()
  local review = assert(view.current(), "the review closed")
  local at = #first_parent -- the oldest commit, which is the last row of the listing
  local win, buf = commits_by_key(review.win)
  vim.api.nvim_win_set_cursor(win, { at + 1, 0 })
  h.feed("<CR>")

  local reopened, rebuf = commits_by_key(assert(view.current()).win)

  it("really is trimmed to a row other than the first", function()
    assert.is_true(at > 1, "the fixture has too few commits for this claim")
    assert.is_truthy(assert(view.current()).scope.label:find(("last %d"):format(at), 1, true))
  end)

  it("marks the row the trim starts at, and only that one", function()
    assert.same({ at + 1 }, marked(rebuf), table.concat(lines(rebuf), "\n"))
  end)

  it("marks the commit the reviewer picked", function()
    local row = lines(rebuf)[at + 1]
    assert.is_truthy(row:find(first_parent[at].subject, 1, true), row)
  end)

  it("opens the cursor on it", function()
    assert.same(at + 1, vim.api.nvim_win_get_cursor(reopened)[1])
  end)

  h.feed("q")
end)

-- The top row and the last row mean the same review, and this is the surface a reviewer goes
-- back through to say so.
describe("<CR> on the row that removes the trim", function()
  local review = assert(view.current(), "the review closed")
  local win = commits_by_key(review.win)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  h.feed("<CR>")
  local after = assert(view.current())

  it("gives the whole branch back", function()
    assert.is_nil(after.scope.label:find("last", 1, true), after.scope.label)
  end)

  it("leaves nothing marked when the float is opened again", function()
    local reopened, rebuf = commits_by_key(after.win)
    assert.same({}, marked(rebuf), table.concat(lines(rebuf), "\n"))
    assert.same(1, vim.api.nvim_win_get_cursor(reopened)[1])
    h.feed("q")
  end)

  codereview.close()
  state.set_trim(root, nil)
end)

--- From the file tree -----------------------------------------------------------

-- The trim is reachable from wherever the cursor is, so the key answers the same way in
-- both of the review's windows.
describe("gc in the file tree", function()
  codereview.open()
  local review = assert(view.current(), "no review view opened")

  local win, buf = commits_by_key(review.win)
  local from_diff = lines(buf)
  h.feed("q")

  local tree_win, tree_buf = commits_by_key(assert(review.panel_win, "no file tree"))
  local from_tree = lines(tree_buf)
  h.feed("q")

  it("opens the same rows the diff opens", function()
    assert.same(from_diff, from_tree)
  end)

  it("really did read the tree's window, not the diff's", function()
    assert.are_not.same(win, tree_win)
  end)

  codereview.close()
end)

--- The two refusals -------------------------------------------------------------

-- A sentence rather than a surprise, which is what this plugin already prefers. Each one
-- says a different fact, so each gets its own answer.
--
-- A revspec rather than one of the working-tree scopes: the fixture is a clean checkout, so
-- `staged`, `unstaged` and `worktree` have nothing in them to open a review on -- and a
-- revspec is the scope a reviewer reaches for when they already know which commit they
-- want, which is the neighbouring surface this key exists beside.
describe("gc outside a branch review", function()
  codereview.open("HEAD~1")
  local review = assert(view.current(), "no review view opened")
  local before = vim.api.nvim_get_current_win()

  local msgs, restore = h.capture_notify()
  h.feed("gc")
  restore()
  local after = vim.api.nvim_get_current_win()

  it("is on a scope that is not the branch", function()
    assert.same("revspec", review.scope.name)
  end)

  it("opens nothing", function()
    assert.same(before, after)
    assert.same("", vim.api.nvim_win_get_config(after).relative)
  end)

  it("says where the commit list applies", function()
    assert.is_true(h.notified(msgs, "branch review"), vim.inspect(msgs))
  end)

  codereview.close()
end)

-- A branch whose `HEAD` is the merge base has no commits of its own, and a float holding no
-- row a reviewer could use is worse than the sentence that explains why there is none.
--
-- Its own repository, checked out on the default branch with work in the tree: a review has
-- to open before a key inside it can be pressed, and a *clean* checkout of the default
-- branch has nothing in scope to open one on.
describe("gc on a branch with no commits of its own", function()
  local flat = h.fixture("mkcommits")
  h.git_lines(flat, { "checkout", "-q", "master" })
  vim.fn.writefile({ "local port = 9090" }, vim.fs.joinpath(flat, "src/config.lua"))
  local here = vim.fn.getcwd()
  vim.cmd("cd " .. vim.fn.fnameescape(flat))

  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local before = vim.api.nvim_get_current_win()

  local msgs, restore = h.capture_notify()
  h.feed("gc")
  restore()
  local after = vim.api.nvim_get_current_win()

  it("is a branch review all the same", function()
    assert.same("branch", review.scope.name)
  end)

  it("really is a checkout whose HEAD is the merge base", function()
    local head = assert(h.git_lines(flat, { "rev-parse", "HEAD" })[1])
    assert.same(head, h.git_lines(flat, { "merge-base", "master", "HEAD" })[1])
  end)

  it("opens nothing", function()
    assert.same(before, after)
    assert.same("", vim.api.nvim_win_get_config(after).relative)
  end)

  it("says the branch carries no commits of its own", function()
    assert.is_true(h.notified(msgs, "no commits of its own"), vim.inspect(msgs))
  end)

  codereview.close()
  vim.cmd("cd " .. vim.fn.fnameescape(here))
end)

--- One answer to where the branch starts ---------------------------------------

-- The list is drawn against the review's own **scope** identity and never against a base
-- worked out a second time. The two agree until something moves the default branch, which a
-- `git fetch` in another window does -- and a list that re-derived would then be listing a
-- branch the diff behind it is not reading.
--
-- The ref is moved onto the branch's own line of work, which is what pulls the merge base
-- forward, and it is put back before the block ends.
describe("the default branch moving under an open review", function()
  local was = assert(h.git_lines(fixture, { "rev-parse", "master" })[1])
  local onto = first_parent[#first_parent - 1].sha

  codereview.open()
  local review = assert(view.current(), "no review view opened")
  h.git_lines(fixture, { "branch", "-f", "master", onto })

  local _, buf = commits_by_key(review.win)
  local rows = commit_rows(buf)
  h.feed("q")

  it("really did move the merge base out from under it", function()
    local now = h.git_lines(fixture, { "merge-base", "master", "HEAD" })[1]
    assert.are_not.same(base, now)
    assert.is_true(#log({ "--first-parent", now .. "..HEAD" }) < #first_parent)
  end)

  it("lists the commits the review is reading, and not the ones the moved ref would give", function()
    assert.same(#first_parent, #rows, table.concat(rows, "\n"))
  end)

  h.git_lines(fixture, { "branch", "-f", "master", was })
  codereview.close()
end)

--- No cap ----------------------------------------------------------------------

-- The oldest commits on a long branch have to stay reachable, which is the one thing this
-- float must never fail at -- so the branch is grown past any number a cap would plausibly
-- be set to and every commit is still expected on screen.
--
-- Last in the file, because it commits to the fixture every block above reads.
describe("a branch longer than a capped list would show", function()
  local FILLER = 60
  for i = 1, FILLER do
    h.git_lines(fixture, { "commit", "-q", "--allow-empty", "-m", ("chore: filler %d"):format(i) })
  end

  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  local rows = commit_rows(buf)

  it("grew the branch past any cap worth writing", function()
    assert.same(#first_parent + FILLER, #log({ "--first-parent", base .. "..HEAD" }))
  end)

  it("draws a row for every one of them", function()
    assert.same(#first_parent + FILLER, #rows)
  end)

  -- The failure a cap actually causes: not a short list, but the oldest commit on the
  -- branch being unreachable.
  it("still holds the oldest commit on the branch", function()
    assert.is_truthy(rows[#rows]:find(first_parent[#first_parent].subject, 1, true), rows[#rows])
  end)

  h.feed("q")
  codereview.close()
end)
