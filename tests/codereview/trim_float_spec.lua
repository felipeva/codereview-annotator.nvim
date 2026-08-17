-- The float that lists the commits on the branch: its rows, its boxes, its keys, and where
-- the cursor opens.
--
-- What is asserted is what a reviewer can see -- which rows are there, what a row says, which
-- boxes are checked, what sentence was shown -- and never the shape of the git invocation
-- behind them. The rows are compared against what git itself reports for the same range,
-- because a hardcoded list of subjects says nothing about the *rule* that produced them, and
-- the box is read as a column rather than as a character for the same reason.
--
-- What a pick *resolves to* is `trim_spec`'s, at the seam where the ref arithmetic is. What
-- is here is the surface: the row a reviewer moves to, the box they toggle, and the key they
-- press.
--
-- The fixture is `mkcommits`, whose history is the whole point of it: a branch of five
-- commits, one of them a merge, over a merge base that is not the oldest commit's parent, and
-- one commit that rewrites the line an earlier one introduced. Every rule this file pins is
-- invisible without it -- see the script's own header.
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

---The commit that cannot leave the review on its own, and the one it depends on. Named by
---subject here and guarded below, because the whole refusal half of this file is about these
---two and a fixture that lost either of them would leave it asserting nothing.
local DEPENDENT = "test: assert the host as well"
local DEPENDENCY = "test: cover the config reader"
---A commit that only adds a file, so it can leave the review from the middle of the branch.
local FREE = "docs: write the readme"

---@param commits { subject: string }[]
---@return string[]
local function subjects(commits)
  return vim.tbl_map(function(c)
    return c.subject
  end, commits)
end

---The commit git reports under this subject.
---@param subject string
---@return { sha: string, when: string, subject: string }
local function commit_named(subject)
  for _, c in ipairs(first_parent) do
    if c.subject == subject then
      return c
    end
  end
  error(subject .. " is on no commit: " .. vim.inspect(subjects(first_parent)))
end

--- Reading the float ------------------------------------------------------------

---@param buf integer
---@return string[]
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---The rows that stand for a commit: everything below the row that takes the whole branch in
---or out.
---@param buf integer
---@return string[]
local function commit_rows(buf)
  local all = lines(buf)
  return vim.list_slice(all, 2, #all)
end

---Where the sha starts on a commit row, which is how wide the box column is drawn.
---
---Measured off a row rather than assumed, so nothing here says how many columns the float
---spends on it.
---@param buf integer
---@return integer
local function box_width(buf)
  local row = lines(buf)[2]
  return assert(row:find(first_parent[1].sha, 1, true), row) - 1
end

---The box at the head of `row`, as the string that column holds.
---
---The column and not the glyph: what is being claimed is that the two states differ and
---which rows carry which, and naming the character would be this file reciting the
---implementation back to itself.
---@param buf integer
---@param row integer 1-based
---@return string
local function box(buf, row)
  return lines(buf)[row]:sub(1, box_width(buf))
end

---What the box says on a row that is in the review.
---
---Learned from a float opened with the whole branch in it, in the first block below, rather
---than written down here.
local IN

---The rows whose box says that commit is in the review, as 1-based row numbers.
---@param buf integer
---@return integer[]
local function checked(buf)
  local out = {}
  for i, row in ipairs(lines(buf)) do
    if row:sub(1, #IN) == IN then
      out[#out + 1] = i
    end
  end
  return out
end

---The row the commit with this subject is drawn on.
---@param buf integer
---@param subject string `ALL`'s own text for the top row
---@return integer
local function row_of(buf, subject)
  local rows = lines(buf)
  for i, row in ipairs(rows) do
    if row:find(subject, 1, true) then
      return i
    end
  end
  error(subject .. " is on no row: " .. table.concat(rows, "\n"))
end

---Move to a row and toggle the box on it, which is what a reviewer does.
---@param win integer
---@param row integer
local function toggle(win, row)
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  h.feed("<Space>")
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

---@param files CRFile[]
---@return string[]
local function paths(files)
  return vim.tbl_map(function(f)
    return f.path
  end, files)
end

--- The fixture the rest of this file leans on -----------------------------------

-- Every claim below is a claim about a *rule*, and each of these is what makes the
-- corresponding rule observable at all. Without the guards, a listing that dropped
-- `--first-parent` and a listing that kept it are the same listing.
describe("the history this spec reads", function()
  it("puts five commits on the branch's own line of work", function()
    assert.same(5, #first_parent, vim.inspect(subjects(first_parent)))
  end)

  it("holds one more commit than that in the same range", function()
    assert.same(6, #everything, vim.inspect(subjects(everything)))
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

  -- The three commits the boxes are toggled on further down. A refusal needs a commit that
  -- can be refused, and a hole needs one that cannot -- see the fixture script's header.
  it("carries the two commits a refusal is made of, and one that can leave on its own", function()
    for _, subject in ipairs({ DEPENDENT, DEPENDENCY, FREE }) do
      assert.is_true(vim.tbl_contains(subjects(first_parent), subject), subject)
    end
  end)
end)

--- The rows --------------------------------------------------------------------

describe("gc inside a branch review", function()
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  local rows = commit_rows(buf)
  -- What a checked box says, taken from a float over a review that has taken nothing out.
  IN = box(buf, 2)

  it("draws one row per commit on the branch's own line of work", function()
    assert.same(#first_parent, #rows, table.concat(rows, "\n"))
  end)

  -- The row that gives the whole branch back. It sits above the commits rather than below
  -- them because it is the state the review opens in, and a reviewer widening a narrowed
  -- review back out should not have to walk a long branch to reach it.
  it("puts the row that takes the whole branch in or out above them all", function()
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
  -- the claim is that a row holds the box and those three facts and nothing else, and
  -- reproducing the arithmetic that lays them out would assert the implementation against
  -- itself.
  it("carries nothing else beside the box", function()
    local width = box_width(buf)
    for i, c in ipairs(first_parent) do
      local rest = rows[i]:sub(width + 1)
      assert.same((c.sha .. c.subject .. c.when):gsub("%s+", ""), (rest:gsub("%s+", "")), rows[i])
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

  -- The whole branch is in the review, so every box says so -- the commits' and the top
  -- row's alike. Which spelling means *in* is the one row 2 carries, and the teeth are in
  -- the blocks below, where some rows have to carry the other one.
  it("checks every row while the whole branch is in the review", function()
    local all = {}
    for i = 1, #lines(buf) do
      all[i] = i
    end
    assert.same(all, checked(buf), table.concat(lines(buf), "\n"))
  end)

  -- With no trim in play the review is the whole branch, which is what the top row says --
  -- so that is where the cursor belongs. The row it opens on with a trim *set* is the case
  -- with teeth, and it is below.
  it("opens the cursor on the row that takes the whole branch in or out", function()
    assert.same(1, vim.api.nvim_win_get_cursor(win)[1])
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

  it("advertises the key that toggles a box, the key that applies, and the key that closes", function()
    local win = commits_by_key(review.win)
    local footer = chrome(win, "footer")
    h.feed("q")
    assert.is_truthy(footer:find("Space", 1, true), footer)
    assert.is_truthy(footer:find("⏎", 1, true), footer)
    assert.is_truthy(footer:find("q close", 1, true), footer)
  end)

  -- The other half of the same claim: the footer names what the float has, and the float has
  -- nothing the footer does not name. `<Esc>` is the one key beside those three, and `close`
  -- is what it does.
  it("binds those keys and no others", function()
    local win, buf = commits_by_key(review.win)
    local lhs = bound(buf)
    h.feed("q")
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.same({
      [vim.keycode("<CR>")] = true,
      [vim.keycode("<Esc>")] = true,
      [vim.keycode("<Space>")] = true,
      q = true,
    }, lhs)
  end)

  codereview.close()
end)

--- Toggling a box ---------------------------------------------------------------

describe("<Space> on a commit row", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  local at = row_of(buf, FREE)

  toggle(win, at)
  local once = box(buf, at)
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  toggle(win, at)
  local twice = box(buf, at)

  it("takes the commit out of the review", function()
    assert.are_not.same(IN, once, lines(buf)[at])
  end)

  it("puts it back on a second press, so the toggle is a toggle both ways", function()
    assert.same(IN, twice, lines(buf)[at])
  end)

  it("leaves the cursor on the row it was pressed on", function()
    assert.same(at, cursor)
  end)

  it("touches no other row", function()
    local rows = {}
    for i = 1, #lines(buf) do
      rows[i] = i
    end
    assert.same(rows, checked(buf), table.concat(lines(buf), "\n"))
  end)

  -- Toggling is not applying. Nothing reaches the store until `<CR>`, so a float closed on
  -- boxes a reviewer changed their mind about leaves the review reading what it read.
  it("stores nothing, so closing the float discards it", function()
    local label = assert(view.current()).scope.label
    toggle(win, at)
    h.feed("q")
    assert.is_nil(state.trim(root))
    assert.same(label, assert(view.current()).scope.label)

    local _, rebuf = commits_by_key(assert(view.current()).win)
    assert.same(IN, box(rebuf, at), lines(rebuf)[at])
    h.feed("q")
  end)

  codereview.close()
end)

--- Applying the boxes -----------------------------------------------------------

-- What a pick *resolves to* is `trim_spec`'s. What is here is that the keys reach it: the
-- boxes the reviewer left, the float closing, and the review behind it reading them.
describe("<CR> with the oldest commit unchecked", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local before = review.scope.label
  local files_before = #review.files

  local win, buf = commits_by_key(review.win)
  -- The oldest commit, which is the last row of a listing drawn newest first.
  toggle(win, #lines(buf))
  h.feed("<CR>")

  it("closes the float", function()
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("leaves the review open, and on the branch", function()
    assert.same("branch", assert(view.current()).scope.name)
  end)

  -- The trim is applied after the float closes, because applying it repaints the review and
  -- puts the cursor back in it. A float still on screen would take that focus straight back
  -- off it, and the reviewer would land nowhere.
  it("lands the cursor back in the review", function()
    assert.same(assert(view.current()).win, vim.api.nvim_get_current_win())
  end)

  it("draws the diff again, narrower than it was", function()
    assert.is_true(#assert(view.current()).files < files_before)
  end)

  it("says on the label that the review is trimmed", function()
    assert.are_not.same(before, assert(view.current()).scope.label)
    assert.is_truthy(assert(view.current()).scope.label:find("last 4", 1, true))
  end)
end)

-- A prefix taken off the start of the branch, which is the reading the trim has always had:
-- four boxes unchecked from the oldest up, and the label counts what is left.
describe("<CR> with every commit but the newest unchecked", function()
  state.set_trim(root, nil)
  codereview.close()
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  for row = 3, #lines(buf) do
    toggle(win, row)
  end
  h.feed("<CR>")

  it("reads the last commit alone", function()
    assert.is_truthy(assert(view.current()).scope.label:find("last 1", 1, true))
  end)

  -- The merge is in that prefix, and taking it off the start of the branch is exactly what
  -- the shipped trim does. Nothing about it is refused.
  it("took the merge out with everything older than it", function()
    assert.same(#first_parent - 1, #assert(state.trim(root)))
  end)
end)

-- The row the reviewer's reading opens on. A fresh window already puts the cursor on row
-- one, so the case is made from a trim that is *not* the top row: asserted from anywhere
-- else it passes against a float that places the cursor nowhere. The oldest kept commit is
-- deeper still in the block that puts a hole in the set, further down.
describe("the float opened with a trim already set", function()
  local review = assert(view.current(), "the review closed")
  local win, buf = commits_by_key(review.win)
  local kept = row_of(buf, first_parent[1].subject)

  it("really is trimmed to a row other than the first", function()
    assert.is_true(kept > 1, "the reading under this block is the one a fresh window opens on")
  end)

  it("checks the commit that is in the review, and only that one", function()
    assert.same({ kept }, checked(buf), table.concat(lines(buf), "\n"))
  end)

  it("leaves the top row unchecked, because the whole branch is not in the review", function()
    assert.are_not.same(IN, box(buf, 1), lines(buf)[1])
  end)

  it("opens the cursor on the oldest commit still in the review", function()
    assert.same(kept, vim.api.nvim_win_get_cursor(win)[1])
  end)

  h.feed("q")
end)

--- The row that takes the whole branch in or out ---------------------------------

describe("<Space> on the top row of a narrowed review", function()
  local review = assert(view.current(), "the review closed")
  local win, buf = commits_by_key(review.win)
  toggle(win, 1)
  local widened = checked(buf)
  h.feed("<CR>")
  local after = assert(view.current())

  it("checks every row, so one key widens a narrowed review back out", function()
    local all = {}
    for i = 1, #first_parent + 1 do
      all[i] = i
    end
    assert.same(all, widened)
  end)

  it("gives the whole branch back", function()
    assert.is_nil(after.scope.label:find("last", 1, true), after.scope.label)
    assert.is_nil(after.scope.label:find(" of ", 1, true), after.scope.label)
  end)

  it("removed the trim rather than storing an empty one", function()
    assert.is_nil(state.trim(root))
  end)
end)

-- The other direction from the same row. Taking every commit out is a real reading -- the
-- reviewer's own uncommitted work -- so the label counts it rather than calling it the last
-- of anything.
describe("<Space> on the top row of a whole-branch review", function()
  local review = assert(view.current(), "the review closed")
  vim.fn.writefile({ "local loose = true" }, vim.fs.joinpath(fixture, "src/loose.lua"))

  local win, buf = commits_by_key(review.win)
  toggle(win, 1)
  local emptied = checked(buf)
  h.feed("<CR>")
  local after = assert(view.current())

  it("unchecks every row", function()
    assert.same({}, emptied)
  end)

  it("leaves a review of the reviewer's uncommitted work", function()
    assert.same({ "src/loose.lua" }, paths(after.files))
  end)

  it("labels it for the count it has, and not as the last of anything", function()
    assert.is_truthy(after.scope.label:find(("0 of %d"):format(#first_parent), 1, true), after.scope.label)
    assert.is_nil(after.scope.label:find("last", 1, true), after.scope.label)
  end)

  it("opens the float back on the top row, which is what that reading says", function()
    local reopened, rebuf = commits_by_key(after.win)
    assert.same(1, vim.api.nvim_win_get_cursor(reopened)[1])
    assert.same({}, checked(rebuf), table.concat(lines(rebuf), "\n"))
    h.feed("q")
  end)

  vim.fn.delete(vim.fs.joinpath(fixture, "src/loose.lua"))
  state.set_trim(root, nil)
  codereview.close()
end)

--- A hole in the set ------------------------------------------------------------

-- The reading this whole feature exists for: one commit out, with the commits older than it
-- left in. The review then reads from a tree that never existed as a commit.
describe("<CR> with one commit unchecked and the older ones left in", function()
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  toggle(win, row_of(buf, FREE))
  h.feed("<CR>")
  local after = assert(view.current())

  it("takes that one commit out and no other", function()
    local stored = assert(state.trim(root))
    local sha = commit_named(FREE).sha
    assert.same(
      { sha },
      vim.tbl_map(function(id)
        return id:sub(1, #sha)
      end, stored)
    )
  end)

  it("takes the file that commit added out of the review", function()
    assert.is_nil(h.file_index(after, "README.md"), vim.inspect(paths(after.files)))
  end)

  it("keeps the files the commits it left in changed", function()
    assert.is_number(h.file_index(after, "src/config.lua"), vim.inspect(paths(after.files)))
  end)

  it("labels a reading that is not a run of commits by what it holds", function()
    local label = after.scope.label
    assert.is_truthy(label:find(("%d of %d"):format(#first_parent - 1, #first_parent), 1, true), label)
    assert.is_nil(label:find("last", 1, true), label)
  end)

  -- The oldest commit on the branch is still in this reading, so the cursor belongs on the
  -- last row of the listing -- the furthest it can be from where a fresh window puts it.
  it("opens the float back on that reading, with the one row unchecked", function()
    local reopened, rebuf = commits_by_key(after.win)
    local out = row_of(rebuf, FREE)
    assert.are_not.same(IN, box(rebuf, out), lines(rebuf)[out])
    assert.same(#first_parent - 1, #checked(rebuf), table.concat(lines(rebuf), "\n"))
    assert.same(#lines(rebuf), vim.api.nvim_win_get_cursor(reopened)[1])
    h.feed("q")
  end)

  state.set_trim(root, nil)
  codereview.close()
end)

--- A pick that cannot be built ---------------------------------------------------

-- Taking one commit out can need a commit that is staying. That is intrinsic -- the reviewer
-- is asking for a tree that never existed -- so it is refused rather than approximated, and
-- refused where the reviewer can still act on it.
describe("<CR> on a commit that cannot leave on its own", function()
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local label = review.scope.label
  local files = paths(review.files)

  local win, buf = commits_by_key(review.win)
  local at = row_of(buf, DEPENDENT)
  toggle(win, at)

  local msgs, restore = h.capture_notify()
  h.feed("<CR>")
  restore()

  it("leaves the float open", function()
    assert.is_true(vim.api.nvim_win_is_valid(win))
  end)

  it("leaves the cursor on the row, so fixing the pick is the next keystroke", function()
    assert.same(at, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it("leaves that box unchecked, so the reviewer sees what was refused", function()
    assert.are_not.same(IN, box(buf, at), lines(buf)[at])
  end)

  it("names the commit it could not take out", function()
    assert.is_true(h.notified(msgs, DEPENDENT), vim.inspect(msgs))
  end)

  it("names the file it conflicts in", function()
    assert.is_true(h.notified(msgs, "src/config_spec.lua"), vim.inspect(msgs))
  end)

  it("stores nothing", function()
    assert.is_nil(state.trim(root))
  end)

  it("leaves the review behind it exactly as it was", function()
    local now = assert(view.current())
    assert.same(label, now.scope.label)
    assert.same(files, paths(now.files))
  end)

  -- The way forward from a refusal: take out the commit the refused one was built on as
  -- well, and the two apply in turn. This is also the guard that the refusal above is about
  -- the dependency and not about every pick this fixture can make.
  it("applies once the commit it was built on is unchecked too", function()
    toggle(win, row_of(buf, DEPENDENCY))
    h.feed("<CR>")
    assert.is_false(vim.api.nvim_win_is_valid(win))
    local now = assert(view.current())
    assert.same(2, #assert(state.trim(root)))
    assert.is_truthy(
      now.scope.label:find(("%d of %d"):format(#first_parent - 2, #first_parent), 1, true),
      now.scope.label
    )
  end)

  state.set_trim(root, nil)
  codereview.close()
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
-- want, which is the neighboring surface this key exists beside.
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

--- One row each, at a width that has to give something up ------------------------

-- The box column takes its columns from somewhere, and the subject is what gives them up. A
-- row that outgrew the float would wrap onto a second line, and a reviewer counting rows
-- against commits would find one too many.
describe("a float too narrow for the rows to fit whole", function()
  h.ui(60, 40)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  local rows = commit_rows(buf)
  local width = vim.api.nvim_win_get_width(win)

  -- Without this the two claims below are made by rows that never had to give anything up,
  -- and every one of them passes against a float that fits its rows by luck.
  it("is narrow enough that a subject really has to be cut", function()
    local whole = vim.tbl_filter(function(i)
      return rows[i]:find(first_parent[i].subject, 1, true) ~= nil
    end, vim.tbl_keys(rows))
    assert.is_true(#whole < #rows, table.concat(rows, "\n"))
  end)

  it("still draws one row per commit", function()
    assert.same(#first_parent, #rows, table.concat(rows, "\n"))
  end)

  it("fits every row inside the float", function()
    for _, row in ipairs(lines(buf)) do
      assert.is_true(vim.fn.strdisplaywidth(row) <= width, ("%d columns: %s"):format(#row, row))
    end
  end)

  it("keeps the sha and the date whole, because the subject is what gives way", function()
    for i, c in ipairs(first_parent) do
      assert.is_truthy(rows[i]:find(c.sha, 1, true), rows[i])
      assert.is_truthy(rows[i]:find(c.when, 1, true), rows[i])
    end
  end)

  h.feed("q")
  codereview.close()
  h.ui(110, 40)
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
