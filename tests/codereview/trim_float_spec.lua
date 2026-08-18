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
-- commits, one of them a merge with commits older than it, over a merge base that is not the
-- oldest commit's parent, and one commit that rewrites the line an earlier one introduced.
-- Every rule this file pins is invisible without it -- see the script's own header.
--
-- The size on a row arrives on a later tick: the float opens on the listing, and git answers
-- after it. So every case here says which of the two it is reading -- the rows taken as the
-- float opened, or the rows `filled_rows` has waited for the answer on.
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
---The merge on the branch's own line of work. A **merge** cannot start a hole, so this row is
---the one whose refusal is about no file at all.
local MERGE = "Merge branch 'lexer' into feature"
---The one commit whose subject is not ASCII.
---
---Found rather than written down, and what it is wanted for is the property rather than the
---text: its subject is a different number of bytes and of columns wide, which is the only
---thing that tells a column placed by counting bytes from one placed by counting columns. A
---spec naming the string would keep passing on a fixture that went back to plain ASCII.
local WIDE
for _, c in ipairs(first_parent) do
  if #c.subject ~= vim.fn.strdisplaywidth(c.subject) then
    WIDE = c
  end
end

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

---What git says changed between two commits, as `{ files, added, deleted }`.
---@param from string
---@param to string
---@return { files: integer, added: integer, deleted: integer }
local function size_between(from, to)
  local at = { files = 0, added = 0, deleted = 0 }
  for _, l in ipairs(h.git_lines(fixture, { "diff", "--numstat", from, to })) do
    local added, deleted = l:match("^(%S+)\t(%S+)\t")
    if added then
      at.files = at.files + 1
      -- A binary file prints `-` for both counts: a file the commit touched, and no lines
      -- anybody wrote.
      at.added = at.added + (tonumber(added) or 0)
      at.deleted = at.deleted + (tonumber(deleted) or 0)
    end
  end
  return at
end

---What git says one commit changed.
---
---`<sha>^` is that commit's first parent whatever kind of commit it is, so this asks a merge
---the same question it asks every other row -- and a merge's first-parent diff is exactly the
---change the review reads for it. Counted from git's own output rather than taken from
---anything the plugin produced: what a row claims is judged against git, never against
---itself.
---@param sha string
---@return { files: integer, added: integer, deleted: integer }
local function size_of(sha)
  return size_between(sha .. "^", sha)
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

---What a row says its commit changed, read back off it as three numbers.
---
---The one place the size's spelling is written down, exactly as `box` is the one place the
---box is read as a column. What the cases compare is git's numbers against the row's, and a
---case matching `+1 -0` at every assertion would leave this file asserting the float's
---format against itself.
---@param row string
---@return { files: integer, added: integer, deleted: integer }|nil nil while the row carries none
local function stat_on(row)
  local files, added, deleted = row:match("(%d+)f%s+%+(%d+)%s+%-(%d+)")
  if not files then
    return nil
  end
  return { files = tonumber(files), added = tonumber(added), deleted = tonumber(deleted) }
end

---The commit rows once git's answer has been drawn onto them.
---
---The float opens on the listing alone and fills the size columns when git answers, which is
---a later tick -- so every case about a figure comes through here, and every case about the
---float *opening* reads the rows taken at the open instead.
---@param buf integer
---@return string[]
local function filled_rows(buf)
  local ok = vim.wait(5000, function()
    return stat_on(commit_rows(buf)[1] or "") ~= nil
  end, 5)
  assert(ok, "no size ever reached a row: " .. table.concat(commit_rows(buf), "\n"))
  return commit_rows(buf)
end

---The text the float's own extmarks cover on a row, for one highlight group, in order.
---
---Read as the byte range each mark holds, applied to the line it is on -- which is the whole
---reason to read a mark here at all. A subject is free to be any number of bytes wide at a
---given number of columns, so a count placed by counting *columns* covers the bytes before
---itself on the one row whose subject is not ASCII, and the number it is coloring is not the
---number underneath it.
---@param buf integer
---@param row integer 1-based
---@param group string
---@return string[]
local function marked(buf, row, group)
  local text = lines(buf)[row]
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    if m[2] == row - 1 and m[4].hl_group == group and m[4].end_col then
      out[#out + 1] = vim.trim(text:sub(m[3] + 1, m[4].end_col))
    end
  end
  return out
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

---Draw a run of rows in visual mode and press the key once on it.
---
---Drawn from `from` to `to` and never from the top of the run down: which end the reviewer
---began on is what decides the direction, and a helper that always started at the higher row
---could not press a run drawn upward at all. The keys and the press go in together, because
---the float reads where the run started while the selection is still live -- `'<` and `'>`
---are not written until visual mode is left, which is the recorded trap the review path's own
---visual capture walked into.
---@param win integer
---@param from integer The row the run starts at
---@param to integer The row it ends at
local function toggle_run(win, from, to)
  vim.api.nvim_win_set_cursor(win, { from, 0 })
  local rows = math.abs(to - from)
  h.feed("V" .. (rows > 0 and rows .. (to > from and "j" or "k") or "") .. "<Space>")
end

---The row the cursor is on, which is what every key that moves it is judged by.
---@param win integer
---@return integer
local function cursor_row(win)
  return vim.api.nvim_win_get_cursor(win)[1]
end

---@param win integer
---@param field "title"|"footer"
---@return string
local function chrome(win, field)
  local value = vim.api.nvim_win_get_config(win)[field]
  return value and tostring(value[1][1]) or ""
end

---@param buf integer
---@param mode? string The mode to read, normal by default
---@return table<string, boolean> Every left-hand side bound in it
local function bound(buf, mode)
  local lhs = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode or "n")) do
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

  -- What makes a refused merge reachable from a box at all. A merge is refused only while a
  -- commit older than it stays in the review, so a fixture whose merge is the oldest row
  -- could not put one there and the block that presses that row would assert nothing.
  it("puts the merge on the listing with commits older than it", function()
    local at
    for i, c in ipairs(first_parent) do
      if c.subject == MERGE then
        at = i
      end
    end
    assert.is_true(at ~= nil and at < #first_parent, vim.inspect(subjects(first_parent)))
  end)

  -- What makes a column's offset measurable at all. Every column right of the subject is
  -- placed by measuring back from the end of the row in bytes, and across five ASCII
  -- subjects that lands in the same place as measuring in display columns -- so an assertion
  -- over either passes whichever ruler the float used.
  it("carries one subject that is not ASCII", function()
    assert.is_truthy(WIDE, vim.inspect(subjects(first_parent)))
    assert.are_not.same(#WIDE.subject, vim.fn.strdisplaywidth(WIDE.subject), WIDE.subject)
  end)

  -- What makes the merge row's size measurable. The review reads a merge's first-parent
  -- diff, and a row reporting the other one is only visible while the two are different
  -- sizes -- on a merge that brought nothing of its own they are one answer.
  it("gives the merge two diffs of different sizes to be read from", function()
    local merge = commit_named(MERGE)
    assert.are_not.same(size_between(merge.sha .. "^2", merge.sha), size_of(merge.sha))
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

  -- A short branch keeps a small float however much room the terminal has. A listing of five
  -- rows in a window most of which is blank gives away the same room the row cap gave away,
  -- from the other end -- and a listing a reviewer can see whole is a listing that needs no
  -- more rows than it has. The height *rule* is read against the terminal at the foot of this
  -- file, on a branch long enough to fill one.
  it("opens no taller than the listing it holds", function()
    local height = vim.api.nvim_win_get_config(win).height
    assert.same(#lines(buf), height)
    assert.is_true(height * 2 < vim.o.lines, ("%d rows of %d"):format(height, vim.o.lines))
  end)

  it("leaves the review it was pressed in on screen", function()
    assert.same(review, view.current())
    assert.is_true(vim.api.nvim_win_is_valid(review.win))
  end)

  it("is bound in the diff and in the file tree", function()
    assert.is_true(bound(review.buf)[vim.keycode("gc")] == true, "gc is not bound in the diff")
    assert.is_true(bound(assert(review.panel_buf))[vim.keycode("gc")] == true, "gc is not bound in the tree")
  end)

  --- The size on a row ---------------------------------------------------------

  -- `rows` was taken as the float opened, and it is the whole listing with no figure on it:
  -- the float draws the rows it has and waits for nothing. A float that asked for the sizes
  -- first would have them here, because it could not have drawn a row until it did.
  it("opens on the listing alone, with no size on it yet", function()
    for _, row in ipairs(rows) do
      assert.is_nil(stat_on(row), row)
    end
  end)

  local filled = filled_rows(buf)

  it("fills in what each commit changed once git answers", function()
    for i, c in ipairs(first_parent) do
      assert.same(size_of(c.sha), stat_on(filled[i]), filled[i])
    end
  end)

  -- The listing is `--first-parent`, so a merge is one row and one change: what it brought
  -- onto this branch. A row carrying the size of everything under the merge would be
  -- claiming a size the review it belongs to does not have.
  it("gives the merge row the size the review reads for it", function()
    local at = row_of(buf, MERGE) - 1
    assert.same(size_of(commit_named(MERGE).sha), stat_on(filled[at]), filled[at])
  end)

  -- Two commits' sizes compare by eye or they compare by arithmetic. Measured in display
  -- columns, which is the ruler an eye reads down -- and on both edges of the size, because
  -- a column pinned only on its left is a column the date beside it can still push around.
  it("lines the sizes up down the listing", function()
    local starts, widths = {}, {}
    for _, row in ipairs(filled) do
      local at = assert(row:find("%d+f%s+%+%d"), row)
      starts[#starts + 1] = vim.fn.strdisplaywidth(row:sub(1, at - 1))
      widths[#widths + 1] = vim.fn.strdisplaywidth(row)
    end
    local function every(list)
      return vim.tbl_map(function()
        return list[1]
      end, list)
    end
    assert.same(every(starts), starts, table.concat(filled, "\n"))
    -- Every row ends on the same column as well, which is what keeps the date a column of
    -- its own: left to its own width it shortens the row it is on and nothing under it.
    assert.same(every(widths), widths, table.concat(filled, "\n"))
  end)

  it("carries nothing else beside the box and the size", function()
    local width = box_width(buf)
    for i, c in ipairs(first_parent) do
      local size = size_of(c.sha)
      local rest = filled[i]:sub(width + 1)
      local carried = ("%s%s%df+%d-%d%s"):format(c.sha, c.subject, size.files, size.added, size.deleted, c.when)
      assert.same((carried:gsub("%s+", "")), (rest:gsub("%s+", "")), filled[i])
    end
  end)

  it("names the author nowhere once the size is on the row", function()
    for _, row in ipairs(filled) do
      assert.is_nil(row:find("Fixture Author", 1, true), row)
    end
  end)

  -- The counts are colored where the counts are, read on the one row whose subject is not
  -- ASCII. Placed by counting display columns instead, every mark on the right of that row
  -- starts short of the figure it is for and ends inside it.
  it("colors the counts at byte offsets rather than at display columns", function()
    local at = row_of(buf, WIDE.subject)
    local size = size_of(WIDE.sha)
    assert.same({ ("+%d"):format(size.added) }, marked(buf, at, "CodeReviewStatAdd"), lines(buf)[at])
    assert.same({ ("-%d"):format(size.deleted) }, marked(buf, at, "CodeReviewStatDel"), lines(buf)[at])
    -- The file count and the date, in the quiet group both take: the two numbers on the row
    -- that are neither added nor deleted lines.
    assert.same({ ("%df"):format(size.files), WIDE.when }, marked(buf, at, "CodeReviewQueueState"), lines(buf)[at])
  end)

  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  codereview.close()
end)

--- The float closed before the answer -------------------------------------------

-- The ordinary end of a list opened to check one thing: `q` before git has answered. The
-- window goes and the buffer is wiped with it, and the answer then lands on a float that is
-- not there.
--
-- The close has to happen *inside* that window or the case measures nothing -- a float that
-- already has its figures has nothing left to write into a dead buffer -- so the block
-- asserts that it did rather than trusting that it did.
describe("a float closed before the figures arrive", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  local opened = commit_rows(buf)

  vim.cmd("messages clear")
  h.feed("q")

  -- Drained by opening the float again and waiting for *that* answer: the two ask git the
  -- same question about the same branch and this one asked second, so its figures arriving
  -- is what says the first one's answer has been delivered. A sleep would be a guess in both
  -- directions -- too short and the case passes because nothing was ever answered.
  local second, second_buf = commits_by_key(assert(view.current()).win)
  filled_rows(second_buf)
  local said = vim.fn.execute("messages")

  it("really did close before any figure was drawn", function()
    for _, row in ipairs(opened) do
      assert.is_nil(stat_on(row), row)
    end
  end)

  it("wiped the buffer the answer would have been drawn into", function()
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  -- Nothing is said and nothing is written. An answer painted into a wiped buffer or a
  -- closed window raises from the callback it arrives on, which is not a place any pcall of
  -- the caller's covers: it lands in the messages instead, named after the module it was
  -- thrown from.
  it("errors nowhere, and says nothing about it either", function()
    assert.is_nil(said:find("trim_float", 1, true), said)
    assert.is_nil(said:find("Invalid", 1, true), said)
  end)

  it("draws the float that is still open, so the answer went to the right one", function()
    assert.is_true(vim.api.nvim_win_is_valid(second))
    assert.is_truthy(stat_on(commit_rows(second_buf)[1]), commit_rows(second_buf)[1])
  end)

  h.feed("q")
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

  it("advertises the pair that moves between the commits that are checked", function()
    local win = commits_by_key(review.win)
    local footer = chrome(win, "footer")
    h.feed("q")
    assert.is_truthy(footer:find("]c", 1, true), footer)
    assert.is_truthy(footer:find("[c", 1, true), footer)
  end)

  -- The key that is not a key of its own: the same `<Space>`, pressed over rows a reviewer
  -- drew. A footer that named only the single press would leave the whole of this feature
  -- something a reviewer has to guess at.
  it("advertises that a run of rows can be pressed together", function()
    local win = commits_by_key(review.win)
    local footer = chrome(win, "footer")
    h.feed("q")
    assert.is_truthy(footer:find("v rows", 1, true), footer)
  end)

  -- The other half of the same claim: the footer names what the float has, and the float has
  -- nothing the footer does not name. `<Esc>` is the one key beside those the footer lists,
  -- and `close` is what it does.
  --
  -- It is also where the keys this float must *not* take are pinned at the table -- `/`, `n`,
  -- `N`, `gg` and `G` are absent from a set that is asserted whole. That is the weaker half
  -- of that guarantee and it is not what carries it: a mapping added in another file would
  -- have to reach this buffer to show up here at all. What carries it is the block that
  -- presses them.
  it("binds those keys and no others", function()
    local win, buf = commits_by_key(review.win)
    local lhs = bound(buf)
    h.feed("q")
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.same({
      [vim.keycode("<CR>")] = true,
      [vim.keycode("<Esc>")] = true,
      [vim.keycode("<Space>")] = true,
      ["]c"] = true,
      ["[c"] = true,
      q = true,
    }, lhs)
  end)

  -- And the same claim in the mode this float bound a key in second. A reviewer in visual
  -- mode still has every key visual mode gives them, `o` and `iw` and the operators included:
  -- the one key taken there is the one that presses the rows they drew.
  it("binds one key in visual mode, and it is the one that toggles", function()
    local win, buf = commits_by_key(review.win)
    local lhs = bound(buf, "x")
    h.feed("q")
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.same({ [vim.keycode("<Space>")] = true }, lhs)
  end)

  codereview.close()
end)

--- Moving between the commits that are checked ----------------------------------

-- The pair is judged by where the cursor lands, and every claim about it is pressed rather
-- than called: the keys are the whole feature, and a function asserted directly would pass
-- against a float that binds neither of them.
--
-- Both ends of the list and the empty set are here on purpose. A jump pressed in the middle
-- of a long run asserts the half nobody doubted -- what a pair like this gets wrong is the
-- last checked row, where a wrap looks like a working key, and a list with nothing to move
-- between, where the cheapest implementation moves the cursor to row one and says nothing.

describe("]c and [c with every commit checked", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  local last = #lines(buf)

  -- The state an untrimmed branch opens in, and the one the pair has to work in first: a
  -- reviewer reaches for `]c` before they have taken anything out, not after.
  it("really did open with every box checked", function()
    assert.same(last, #checked(buf), table.concat(lines(buf), "\n"))
  end)

  it("moves to the newest commit from the row the float opens on", function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    h.feed("]c")
    assert.same(2, cursor_row(win))
  end)

  it("walks down the listing one commit at a time", function()
    h.feed("]c")
    assert.same(3, cursor_row(win))
    h.feed("]c")
    assert.same(4, cursor_row(win))
  end)

  it("comes back up on [c", function()
    h.feed("[c")
    assert.same(3, cursor_row(win))
  end)

  it("says there is no next one at the last commit, and stays on it", function()
    vim.api.nvim_win_set_cursor(win, { last, 0 })
    local messages, restore = h.capture_notify()
    h.feed("]c")
    restore()
    assert.same(last, cursor_row(win))
    assert.is_true(h.notified(messages, "next"), vim.inspect(messages))
  end)

  -- The row above the newest commit is the one that takes the whole branch in or out, which
  -- is not a commit -- so the newest commit is the top of this pair's list.
  it("says there is no previous one at the newest commit, and stays on it", function()
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    local messages, restore = h.capture_notify()
    h.feed("[c")
    restore()
    assert.same(2, cursor_row(win))
    assert.is_true(h.notified(messages, "previous"), vim.inspect(messages))
  end)

  h.feed("q")
  codereview.close()
end)

describe("]c and [c over a set with holes in it", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  local last = #lines(buf)
  -- Two rows taken out, and not next to each other, so the rows left checked are 2, 4 and
  -- the last one. A run with no hole in it cannot tell "the next checked commit" from "the
  -- next row".
  toggle(win, 3)
  toggle(win, last - 1)

  it("really did leave the checked rows scattered", function()
    assert.same({ 2, 4, last }, checked(buf), table.concat(lines(buf), "\n"))
  end)

  it("skips the rows that are unchecked", function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    h.feed("]c")
    assert.same(2, cursor_row(win))
    h.feed("]c")
    assert.same(4, cursor_row(win))
    h.feed("]c")
    assert.same(last, cursor_row(win))
  end)

  it("skips them going back up as well", function()
    h.feed("[c")
    assert.same(4, cursor_row(win))
    h.feed("[c")
    assert.same(2, cursor_row(win))
  end)

  it("reaches the end of the set rather than the end of the list", function()
    vim.api.nvim_win_set_cursor(win, { last, 0 })
    local messages, restore = h.capture_notify()
    h.feed("]c")
    restore()
    assert.same(last, cursor_row(win))
    assert.is_true(h.notified(messages, "next"), vim.inspect(messages))
  end)

  h.feed("q")
  codereview.close()
end)

describe("]c and [c with nothing checked", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  -- One press on the top row of a whole-branch review takes every commit out, which is the
  -- reading this pair has nothing to move between.
  toggle(win, 1)
  local at = 3
  vim.api.nvim_win_set_cursor(win, { at, 0 })

  it("really did leave every box unchecked", function()
    assert.same({}, checked(buf), table.concat(lines(buf), "\n"))
  end)

  it("says so on ]c rather than moving", function()
    local messages, restore = h.capture_notify()
    h.feed("]c")
    restore()
    assert.same(at, cursor_row(win))
    assert.is_true(h.notified(messages, "checked"), vim.inspect(messages))
  end)

  it("says so on [c rather than moving", function()
    local messages, restore = h.capture_notify()
    h.feed("[c")
    restore()
    assert.same(at, cursor_row(win))
    assert.is_true(h.notified(messages, "checked"), vim.inspect(messages))
  end)

  h.feed("q")
  codereview.close()
end)

--- The keys the float leaves alone ----------------------------------------------

-- What is claimed here is not behaviour this float built. It is an ordinary buffer in an
-- ordinary window, so searching it and reaching its ends are Neovim's, and the guarantee is
-- that nothing was mapped over them.
--
-- Every case presses the key. Asserting that the mapping table holds no entry for `/` would
-- read the one file that is allowed to bind on this buffer and pass against a mapping added
-- later somewhere else -- which is the entire failure the guarantee exists to prevent.
describe("searching the commit list", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  -- Two rows carry this and no other row does, which is what makes `n` and `N` observable at
  -- all: a needle matching one row is reached by `/` alone, and repeating it would land back
  -- where the search already was whether or not the key works.
  local REPEATED = "test: "
  local first, second = row_of(buf, DEPENDENT), row_of(buf, DEPENDENCY)

  it("has two rows to repeat a search over, and no more", function()
    local hits = {}
    for i, row in ipairs(lines(buf)) do
      if row:find(REPEATED, 1, true) then
        hits[#hits + 1] = i
      end
    end
    assert.same({ first, second }, hits, table.concat(lines(buf), "\n"))
  end)

  it("reaches a commit by its subject", function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    h.feed("/" .. REPEATED .. "<CR>")
    assert.same(first, cursor_row(win))
  end)

  it("repeats that search on n", function()
    h.feed("n")
    assert.same(second, cursor_row(win))
  end)

  it("goes back on N", function()
    h.feed("N")
    assert.same(first, cursor_row(win))
  end)

  it("reaches the oldest commit on G", function()
    h.feed("G")
    assert.same(#lines(buf), cursor_row(win))
  end)

  it("reaches the top of the list on gg", function()
    h.feed("gg")
    assert.same(1, cursor_row(win))
  end)

  h.feed("q")
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

--- What the title counts --------------------------------------------------------

-- Every count below is read **before** anything is applied, which is the whole of what this
-- block is for. A title read after a pick agrees with the review's own label -- the two spell
-- the same `N of M` -- so it would agree just as well on a float that counted nothing until
-- `<CR>`. The store is asserted beside each read for the same reason: what is being claimed
-- is that the title moved while the set was still only boxes.
describe("the title while a set is being built", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local label = review.scope.label
  local win, buf = commits_by_key(review.win)

  -- The whole branch, which is what a review with no trim on it reads.
  local whole = chrome(win, "title")

  -- One commit taken out, and the store read at that moment rather than at the end: the
  -- title has to be counting boxes, and boxes are all there is to count yet.
  toggle(win, row_of(buf, FREE))
  local some = chrome(win, "title")
  local stored_while_building = state.trim(root)

  -- The top row makes every box the same, so pressing it here checks them all back in and
  -- pressing it again takes them all out. Two presses, two readings, nothing applied.
  toggle(win, 1)
  local again = chrome(win, "title")
  toggle(win, 1)
  local empty = chrome(win, "title")

  it("names the branch's own count while every commit is checked", function()
    assert.is_truthy(whole:find(tostring(#first_parent), 1, true), whole)
  end)

  -- The reading a review opens in says nothing extra by spelling out that every commit is
  -- still in it, so the whole branch falls back to the single count this float always had.
  it("reads as the whole branch rather than as a set taken out of it", function()
    assert.is_nil(whole:find(" of ", 1, true), whole)
  end)

  it("counts the checked commits against the branch as soon as one is taken out", function()
    assert.is_truthy(some:find(("%d of %d"):format(#first_parent - 1, #first_parent), 1, true), some)
  end)

  -- The teeth. Nothing had been applied when `some` was read, so no label could have told
  -- the float that number and nothing but a recount on the toggle could have produced it.
  it("counted it with nothing applied and nothing stored", function()
    assert.are_not.same(whole, some)
    assert.is_nil(stored_while_building)
    assert.same(label, assert(view.current()).scope.label)
  end)

  it("falls back to the single count when the whole branch is checked again", function()
    assert.same(whole, again)
  end)

  -- The reading where the review is the reviewer's uncommitted work and no commit at all.
  -- Legible here, before `<CR>`, which is the only place it can be acted on cheaply.
  it("says that nothing is checked, in a word rather than as a zero", function()
    assert.is_truthy(empty:lower():find("none", 1, true), empty)
    assert.is_truthy(empty:find(tostring(#first_parent), 1, true), empty)
  end)

  -- Refused on the record rather than merely absent: the per-commit figures are on the rows
  -- already, so summing them is cheap -- and two commits that both touch one file count it
  -- twice, which overstates exactly when the set is large enough to be worth reading.
  it("carries no running total of what the checked commits add up to", function()
    for _, title in ipairs({ whole, some, again, empty }) do
      assert.is_nil(title:find("%+%d"), title)
      assert.is_nil(title:find("%-%d"), title)
      assert.is_nil(title:find("%d+ ?f"), title)
      assert.is_nil(title:lower():find("file", 1, true), title)
    end
  end)

  it("applied none of it, so the review behind the float never moved", function()
    h.feed("q")
    assert.is_nil(state.trim(root))
    assert.same(label, assert(view.current()).scope.label)
  end)

  codereview.close()
end)

--- One press, three surfaces ----------------------------------------------------

-- The title is this slice's, and the footer and the jump pair arrived with the one before
-- it. Each half was asserted alone, and what nothing asserted is that one `<Space>` leaves
-- all three agreeing: the count on the title, the keys named on the footer, and where `]c`
-- goes next. Every reading below is taken off the same float after the same single press.
--
-- The footer is the one that looks like it cannot fail. The title is written again on every
-- toggle through `nvim_win_set_config`, with a table holding the title and nothing else; a
-- table holding the whole config would take the footer off the border and say nothing about
-- it -- no error, no other case red, and a float that stops naming its keys after the first
-- press a reviewer makes.
describe("one press, the title, the footer and the jump pair", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)

  -- Where the pair went under the set the float opened with, so where it goes after the press
  -- is a change rather than a coincidence: from the top row, the newest commit is the next
  -- checked one.
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  h.feed("]c")
  local was = cursor_row(win)
  local footer_before = chrome(win, "footer")

  -- The press. Everything below is read without another one.
  local out = row_of(buf, first_parent[1].subject)
  toggle(win, out)
  local title = chrome(win, "title")
  local footer = chrome(win, "footer")
  local stored = state.trim(root)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  h.feed("]c")
  local now = cursor_row(win)

  it("really did take the row the pair used to land on", function()
    assert.same(out, was)
    assert.are_not.same(IN, box(buf, out), lines(buf)[out])
  end)

  it("counts the set the press left on the title", function()
    assert.is_truthy(title:find(("%d of %d"):format(#first_parent - 1, #first_parent), 1, true), title)
  end)

  it("still names the pair that moves between checked commits on the footer", function()
    assert.is_truthy(footer:find("]c", 1, true), footer)
    assert.is_truthy(footer:find("[c", 1, true), footer)
  end)

  -- Byte for byte, whatever the footer says: what is claimed is that writing the title back
  -- left the rest of the window's own config alone, and that has to hold through a footer
  -- rewritten by somebody else.
  it("leaves the footer exactly the string it was before the press", function()
    assert.are_not.same("", footer)
    assert.same(footer_before, footer)
  end)

  it("jumps past the row the press took out, rather than to it", function()
    assert.same(out + 1, now)
    assert.are_not.same(was, now)
  end)

  it("did all of that with nothing applied", function()
    assert.is_nil(stored)
  end)

  h.feed("q")
  codereview.close()
end)

--- A run of rows in one press ---------------------------------------------------

-- Every run pressed below is **mixed** -- some of its rows checked and some not -- and that
-- is the whole of what these blocks measure. Over a run that is uniform, "make them all the
-- same" and "flip each of them" produce the same rows, so a block that drew its run over an
-- untouched listing would pass against either rule and assert nothing about the one this key
-- exists for.
--
-- The direction is the other half. A run drawn downward from a checked row and one drawn
-- upward from an unchecked row answer differently, and only the second can tell "follows the
-- row the run started at" from "follows the row nearest the top of the list" -- which is the
-- same reading on every run drawn the easy way.

describe("a run of rows drawn downward over a mixed set", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  local last = #lines(buf)

  -- Two rows out of the four the run will cover, and not next to each other: the run the
  -- press meets holds checked rows and unchecked rows in the middle of it.
  toggle(win, 3)
  toggle(win, 5)
  local before = checked(buf)

  -- Where the jump pair went under that set, so where it goes after the press is a change
  -- rather than a coincidence.
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  h.feed("]c")
  local was = cursor_row(win)

  -- The press. From row 2, which is checked, down to row 5: every row in the run follows row
  -- 2 out of the review, including the two that were already out.
  toggle_run(win, 2, 5)
  local after = checked(buf)
  local title = chrome(win, "title")
  local mode = vim.api.nvim_get_mode().mode
  local still_open = vim.api.nvim_win_is_valid(win)
  local stored = state.trim(root)

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  h.feed("]c")
  local now = cursor_row(win)

  it("really did press over a run that was already mixed", function()
    assert.same({ 2, 4, last }, before, table.concat(lines(buf), "\n"))
  end)

  -- The teeth. Flipping each row instead would have put rows 3 and 5 back in and taken rows
  -- 2 and 4 out, which is a set with the same number of boxes in it and a different set.
  it("makes every row in the run the same rather than flipping each of them", function()
    assert.same({ last }, after, table.concat(lines(buf), "\n"))
  end)

  it("leaves the row below the run alone", function()
    assert.same(IN, box(buf, last), lines(buf)[last])
  end)

  it("counts what the press left on the title", function()
    assert.is_truthy(title:find(("%d of %d"):format(1, #first_parent), 1, true), title)
  end)

  -- The pair reads the boxes the press left, and not the ones the float opened on. It landed
  -- on row 2 before the press, and row 2 is one of the rows the press took out.
  it("moves the jump pair onto the set the press left", function()
    assert.same(2, was)
    assert.same(last, now)
  end)

  -- Visual mode is left behind, and `<Esc>` is what leaves it -- which is also this float's
  -- own key for closing. A press that let that mapping run would close the float on the
  -- reviewer the moment they pressed it.
  it("leaves the reviewer in normal mode, on a float that is still open", function()
    assert.same("n", mode)
    assert.is_true(still_open)
  end)

  it("did all of that with nothing applied", function()
    assert.is_nil(stored)
  end)

  h.feed("q")
  codereview.close()
end)

describe("a run of rows drawn upward over a mixed set", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  local last = #lines(buf)

  -- The two oldest rows out, so the run is mixed again -- and this time the row the run
  -- starts at is one of the unchecked ones, sitting at the *bottom* of it.
  toggle(win, last)
  toggle(win, last - 1)
  local before = checked(buf)

  -- From the oldest row up to row 3. The run starts unchecked, so every row in it is checked
  -- back in.
  toggle_run(win, last, 3)
  local after = checked(buf)
  local title = chrome(win, "title")
  local stored = state.trim(root)

  it("really did press over a run that was already mixed", function()
    assert.same({ 2, 3, 4 }, before, table.concat(lines(buf), "\n"))
  end)

  -- The teeth for *which* row decides. Reading the direction off the top of the run instead
  -- -- row 3, which is checked -- would have taken all four rows out. Flipping each of them
  -- would have left rows 3 and 4 out and rows 5 and 6 in.
  it("follows the row the run started at rather than the row nearest the top", function()
    local every = {}
    for row = 1, last do
      every[row] = row
    end
    assert.same(every, after, table.concat(lines(buf), "\n"))
  end)

  -- And the top row's own box answers for the listing again, which is the reading the title
  -- falls back to its single count on.
  it("puts the whole branch back in, as the title says with one count", function()
    assert.same(IN, box(buf, 1), lines(buf)[1])
    assert.is_nil(title:find(" of ", 1, true), title)
    assert.is_truthy(title:find(tostring(#first_parent), 1, true), title)
  end)

  it("did all of that with nothing applied", function()
    assert.is_nil(stored)
  end)

  h.feed("q")
  codereview.close()
end)

describe("a run that reaches the row above the commits", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  local last = #lines(buf)

  -- One row out of the three commits the run will cover.
  toggle(win, 4)
  local before = checked(buf)

  -- Drawn from the top row down, which is the run a reviewer draws with `gg` and a motion.
  -- The top row is not a commit, so the direction is read from row 2 -- the first row in the
  -- run that the press can act on.
  toggle_run(win, 1, 4)
  local after = checked(buf)
  local stored = state.trim(root)

  it("really did press over a run that was already mixed", function()
    assert.same({ 2, 3, 5, last }, before, table.concat(lines(buf), "\n"))
  end)

  -- The teeth, and both of them are in this one set. Treating the top row as a commit would
  -- have taken the whole branch out, rows 5 and 6 included -- a set far larger than the four
  -- rows the reviewer drew. Reading the direction off that row rather than off the first
  -- commit under it would have checked the run back in instead.
  it("leaves that row alone and treats the commits under it normally", function()
    assert.same({ 5, last }, after, table.concat(lines(buf), "\n"))
  end)

  it("did all of that with nothing applied", function()
    assert.is_nil(stored)
  end)

  h.feed("q")
  codereview.close()
end)

-- A run of one row is a press on that row, in both places a press can mean something: a
-- commit, and the row that answers for all of them. Read as the whole box column off two
-- floats rather than as one row off one, so a visual press that moved some *other* row is a
-- case that reds.
describe("one row drawn in visual mode", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")

  ---Every box on a float of its own, after `press` has been made on it.
  ---@param press fun(win: integer)
  ---@return string[]
  local function boxes_after(press)
    local win, buf = commits_by_key(review.win)
    press(win)
    local out = {}
    for row = 1, #lines(buf) do
      out[row] = box(buf, row)
    end
    h.feed("q")
    return out
  end

  -- Nothing is stored until `<CR>`, so all four floats below open on the same boxes as this
  -- one and each press is read against it.
  local opened = boxes_after(function() end)
  local visual_row = boxes_after(function(win)
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    h.feed("v<Space>")
  end)
  local normal_row = boxes_after(function(win)
    toggle(win, 3)
  end)
  local visual_top = boxes_after(function(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    h.feed("v<Space>")
  end)
  local normal_top = boxes_after(function(win)
    toggle(win, 1)
  end)

  -- Without this, two floats that both did nothing agree with each other and every case
  -- below passes against a key that is not bound at all.
  it("really did move a box on each of those floats", function()
    assert.are_not.same(opened, visual_row, table.concat(visual_row, " "))
    assert.are_not.same(opened, visual_top, table.concat(visual_top, " "))
  end)

  it("takes the commit out exactly as a press in normal mode does", function()
    assert.same(normal_row, visual_row)
  end)

  it("means every box on the top row, exactly as a press in normal mode does", function()
    assert.same(normal_top, visual_top)
  end)

  codereview.close()
end)

-- What the store is handed after a run, read off the boxes rather than off the press. A run
-- that painted correctly and tracked something else would look right on the screen and
-- review the wrong commits, which is the one failure here a reviewer cannot see.
describe("<CR> after a run", function()
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local files_before = #review.files
  local win, buf = commits_by_key(review.win)
  local last = #lines(buf)

  -- The three oldest rows, drawn from the newest of them down: a prefix off the start of the
  -- branch, which is a set that can always be built -- the refusals are `<CR>`'s own claim
  -- and they are pinned elsewhere in this file.
  toggle_run(win, 4, last)

  -- What the boxes say, taken off the screen before the key that applies them, and resolved
  -- through git rather than through anything the float produced.
  local out = {}
  for row = 2, last do
    if box(buf, row) ~= IN then
      out[#out + 1] = assert(h.git_lines(fixture, { "rev-parse", lines(buf)[row]:match("%x+") })[1])
    end
  end
  h.feed("<CR>")
  local stored = vim.deepcopy(state.trim(root))
  table.sort(out)
  if stored then
    table.sort(stored)
  end

  it("really did leave three rows unchecked and the rest in", function()
    assert.same(3, #out)
  end)

  it("applies exactly the commits the boxes left unchecked", function()
    assert.same(out, stored)
  end)

  it("says on the label what the run left in the review", function()
    assert.is_truthy(assert(view.current()).scope.label:find("last 2", 1, true))
  end)

  it("draws the diff again, narrower than it was", function()
    assert.is_true(#assert(view.current()).files < files_before)
  end)

  state.set_trim(root, nil)
  codereview.close()
end)

-- The footer names one more key than it did, and it is drawn on a border it has to fit
-- inside: a footer wider than the float is clipped from the left, silently, taking the keys
-- with it. Measured against the window rather than against a number written here, and at the
-- narrowest this float is ever drawn -- which is where the room runs out.
describe("the footer on the narrowest float this opens", function()
  ---The float's width and what its border says, on a terminal of `columns` columns.
  ---@param columns integer
  ---@return { columns: integer, width: integer, footer: string }
  local function opened_on(columns)
    h.ui(columns, 40)
    state.set_trim(root, nil)
    codereview.open()
    local review = assert(view.current(), "no review view opened")
    local win = commits_by_key(review.win)
    local at = {
      columns = vim.o.columns,
      width = vim.api.nvim_win_get_width(win),
      footer = chrome(win, "footer"),
    }
    h.feed("q")
    codereview.close()
    return at
  end

  -- Two terminals two columns apart, both too narrow for a share of the screen to reach the
  -- width this float refuses to go under. A share alone would draw them apart, so their being
  -- one width is the floor and can be nothing else -- and the floor is the case the footer
  -- has to survive.
  local narrow = opened_on(62)
  local narrower = opened_on(60)
  h.ui(110, 40)

  it("really did open at the width this float stops shrinking at", function()
    assert.same(narrow.columns - 2, narrower.columns)
    assert.same(
      narrow.width,
      narrower.width,
      ("%d columns on %d, %d on %d"):format(narrow.width, narrow.columns, narrower.width, narrower.columns)
    )
  end)

  it("keeps every key it names inside the border it is drawn on", function()
    local drawn = vim.fn.strdisplaywidth(narrow.footer)
    assert.is_true(drawn <= narrow.width, ("%d columns of footer on %d: %s"):format(drawn, narrow.width, narrow.footer))
  end)

  -- And that the keys are all still on it at that width, which is what being clipped takes
  -- away first.
  it("still names every key the float has", function()
    for _, key in ipairs({ "Space", "v rows", "]c", "[c", "⏎", "q close" }) do
      assert.is_truthy(narrow.footer:find(key, 1, true), narrow.footer)
    end
  end)
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

  -- The title keeps counting the boxes that are on screen, which after a refusal are the
  -- boxes the reviewer is still holding -- one commit short of the branch, and none of it
  -- applied. A title that had moved on to the set the pick tried to store would be describing
  -- a review nothing built.
  it("leaves the title counting the boxes the reviewer still has", function()
    local shown = chrome(win, "title")
    assert.is_truthy(shown:find(("%d of %d"):format(#first_parent - 1, #first_parent), 1, true), shown)
    -- The top row is unchecked with them, because the whole branch is not in the set, so
    -- what the count on the title has to agree with is the commit rows alone.
    assert.same(#first_parent - 1, #checked(buf), table.concat(lines(buf), "\n"))
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

--- The merge row ----------------------------------------------------------------

-- The one row whose refusal is about no file at all. A **merge** above the leading run
-- collides with everything the side branch brought -- files the reviewer neither wrote nor
-- asked about -- so the rule refuses it before any merge is attempted and gives them the
-- reason instead.
--
-- The pairing is what this block exists for, and neither slice that built it could make the
-- claim alone: `trim_spec` asserts the rule where the pre-image is built, with the set handed
-- straight to the store, and this file's other refusal never presses a merge row. What is
-- asserted here is that the box a reviewer can now check reaches that rule, and the four
-- things that have to hold at once when it does.
describe("<Space> on the merge row, with a commit older than it left in", function()
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)

  -- A trim already in place before the press, so "the store still holds what it held" is a
  -- claim about a set rather than about emptiness: a pick that stored the merge and a pick
  -- that dropped the trim both red against it, and against nil only the first would.
  toggle(win, row_of(buf, FREE))
  h.feed("<CR>")
  local was = vim.deepcopy(assert(state.trim(root), "the pick that sets this block up stored no trim"))
  local narrowed = assert(view.current(), "the review closed")

  local reopened, rebuf = commits_by_key(narrowed.win)
  local at = row_of(rebuf, MERGE)
  toggle(reopened, at)

  local msgs, restore = h.capture_notify()
  h.feed("<CR>")
  restore()

  -- Without this the press is a merge taken off the *start* of the branch, which is inside
  -- the run, assembles nothing and is refused by nothing -- and every claim below would then
  -- be made against a pick that was never refused for being a merge.
  it("really did leave a commit older than the merge in the review", function()
    local older = vim.tbl_filter(function(row)
      return row > at
    end, checked(rebuf))
    assert.is_true(#older > 0, table.concat(lines(rebuf), "\n"))
  end)

  it("is told that a merge brings the review nothing it does not already read", function()
    assert.is_true(h.notified(msgs, "brings nothing the review does not already read"), vim.inspect(msgs))
  end)

  it("is told which merge", function()
    local merge = commit_named(MERGE)
    assert.is_true(h.notified(msgs, merge.sha), vim.inspect(msgs))
  end)

  -- Pressed from the float the sentence is the same one, and it is here that its length is
  -- worst: the merge a reviewer meets on a real branch is `Merge remote-tracking branch
  -- 'origin/master' into <branch>`, and carrying that subject pushed the reason past the end
  -- of a one-line notification.
  it("is told the reason before the sha, and no subject at all", function()
    local merge = commit_named(MERGE)
    assert.is_false(h.notified(msgs, merge.subject), vim.inspect(msgs))
    local said = vim.tbl_filter(function(m)
      return m:find("brings nothing", 1, true) ~= nil
    end, msgs)
    assert.same(1, #said, vim.inspect(msgs))
    assert.same(1, said[1]:find("A merge brings nothing"), said[1])
  end)

  -- The teeth against a rule that attempts the merge and rewords whatever the merge reported:
  -- that is the file-collision sentence with better prose, and it names every file the side
  -- branch brought.
  it("is told no file, because the files are not what a reviewer can act on", function()
    for _, path in ipairs({ "README.md", "src/config.lua", "src/config_spec.lua", "src/lexer.lua" }) do
      assert.is_false(h.notified(msgs, path), vim.inspect(msgs))
    end
    assert.is_false(h.notified(msgs, "conflicts in"), vim.inspect(msgs))
  end)

  it("leaves the float open", function()
    assert.is_true(vim.api.nvim_win_is_valid(reopened))
  end)

  it("leaves the cursor on the merge row, so unchecking it again is the next keystroke", function()
    assert.same(at, vim.api.nvim_win_get_cursor(reopened)[1])
  end)

  it("leaves the store holding exactly the trim that was there", function()
    assert.same(was, state.trim(root))
  end)

  h.feed("q")
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

  -- And again with the size on the rows, which is the state that has the least room of any
  -- this float draws in. The subject pays for that column too.
  local filled = filled_rows(buf)

  it("still draws one row per commit with the size on it", function()
    assert.same(#first_parent, #filled, table.concat(filled, "\n"))
    for _, row in ipairs(lines(buf)) do
      assert.is_true(vim.fn.strdisplaywidth(row) <= width, ("%d columns: %s"):format(vim.fn.strdisplaywidth(row), row))
    end
  end)

  it("keeps the size and the date whole as well", function()
    for i, c in ipairs(first_parent) do
      assert.same(size_of(c.sha), stat_on(filled[i]), filled[i])
      assert.is_truthy(filled[i]:find(c.when, 1, true), filled[i])
    end
  end)

  it("took the room out of the subject", function()
    local whole = vim.tbl_filter(function(i)
      return filled[i]:find(first_parent[i].subject, 1, true) ~= nil
    end, vim.tbl_keys(filled))
    assert.is_true(#whole < #filled, table.concat(filled, "\n"))
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

  local filled = filled_rows(buf)

  -- One answer covers the whole branch however long it is, and it is keyed by commit: the
  -- filler commits are empty, so a row saying they changed something is a row wearing
  -- another commit's figures. The newest row is one of them.
  it("sizes every row on a branch this long, the empty commits included", function()
    local sized = vim.tbl_filter(function(row)
      return stat_on(row) ~= nil
    end, filled)
    assert.same(#filled, #sized, table.concat(filled, "\n"))
    assert.same({ files = 0, added = 0, deleted = 0 }, stat_on(filled[1]), filled[1])
  end)

  h.feed("q")
  codereview.close()
end)

--- The height, read against the terminal's own rows -----------------------------

-- One terminal size cannot tell a cap from a share. The cap this replaced was twenty-eight
-- rows and these specs run on a terminal of forty, where a share of the screen comes to the
-- same number -- so a float measured only there passes whichever rule it followed. Every
-- number below is compared against `vim.o.lines` as it stood when that float opened, and
-- never against a number written here.
--
-- Last in the file, and reading the branch the block above grew: a share of a tall terminal
-- is only visible on a listing long enough to fill one, and a five-commit branch opens the
-- same small float at every size -- which is itself a rule, and the one asserted first.
describe("the height the float opens at", function()
  ---What the window was given, on a terminal of `rows` rows.
  ---
  ---The terminal's own size comes back with it, so every assertion reads the two together
  ---and nothing below has to remember which size produced which float.
  ---@param rows integer
  ---@return { lines: integer, columns: integer, height: integer, width: integer, row: integer, col: integer, border: string, listed: integer }
  local function opened_on(rows)
    h.ui(110, rows)
    codereview.open()
    local review = assert(view.current(), "no review view opened")
    local win, buf = commits_by_key(review.win)
    local config = vim.api.nvim_win_get_config(win)
    local at = {
      lines = vim.o.lines,
      columns = vim.o.columns,
      height = config.height,
      width = config.width,
      row = config.row,
      col = config.col,
      border = type(config.border) == "table" and config.border[1] or tostring(config.border),
      listed = #lines(buf),
    }
    h.feed("q")
    codereview.close()
    return at
  end

  local short = opened_on(24)
  local tall = opened_on(48)
  -- Two terminals one row apart, both too short to give the float a share worth having. A
  -- share alone would draw them one row apart as well, so their being the same float is the
  -- floor and can be nothing else.
  local cramped = opened_on(12)
  local barely = opened_on(13)
  h.ui(110, 40)

  -- Without these two the block below is measuring one terminal twice, or measuring a float
  -- that stopped at the end of its listing rather than at the end of the screen.
  it("really did open on two terminals, one twice the height of the other", function()
    assert.same(short.lines * 2, tall.lines)
  end)

  it("read a branch longer than the tallest of those floats", function()
    assert.is_true(tall.listed > tall.height, ("%d rows in a float of %d"):format(tall.listed, tall.height))
  end)

  it("takes most of the rows a short terminal has", function()
    assert.is_true(short.height * 2 > short.lines, ("%d of %d rows"):format(short.height, short.lines))
  end)

  it("takes most of the rows a tall terminal has", function()
    assert.is_true(tall.height * 2 > tall.lines, ("%d of %d rows"):format(tall.height, tall.lines))
  end)

  -- The claim a cap cannot make: doubling the terminal doubles the float. A cap gives the
  -- same number twice, and a share gives the same *share* twice, which is what is read here
  -- -- off the two floats rather than off the constant either of them was drawn from.
  it("grows with the terminal rather than stopping where a cap would", function()
    assert.is_true(tall.height > short.height, ("%d then %d"):format(short.height, tall.height))
    assert.is_true(
      math.abs(tall.height - short.height * 2) <= 1,
      ("%d rows of %d, then %d of %d"):format(short.height, short.lines, tall.height, tall.lines)
    )
  end)

  -- Not full-screen, at either size: a float that left no review around it would be a
  -- different class of surface, and `gc` would read as leaving the review rather than as
  -- adjusting it. The two rows are the border's own.
  it("leaves the review on screen above it and below it", function()
    for _, at in ipairs({ short, tall }) do
      assert.is_true(at.row >= 1, ("row %d on %d lines"):format(at.row, at.lines))
      assert.is_true(
        at.row + at.height + 2 < at.lines,
        ("row %d, %d rows and a border on %d lines"):format(at.row, at.height, at.lines)
      )
    end
  end)

  it("stays centered, and bordered", function()
    for _, at in ipairs({ short, tall }) do
      assert.are_not.same("none", at.border, at.border)
      assert.same(math.floor((at.columns - at.width) / 2), at.col)
      local below = at.lines - at.row - at.height - 2
      assert.is_true(math.abs(at.row - below) <= 2, ("%d above, %d below"):format(at.row, below))
    end
  end)

  -- Height is what this changed. The width follows the columns, which neither float moved.
  it("is no wider on one terminal than on the other", function()
    assert.same(short.width, tall.width)
  end)

  -- Where the float stops following the terminal down. Read as two short terminals drawing
  -- the same float rather than as the number itself: a floor asserted against the constant
  -- behind it is this file reciting the rule back to the module.
  it("keeps a floor, so a terminal too short for a share stops shrinking the float", function()
    assert.same(cramped.lines + 1, barely.lines)
    assert.same(
      cramped.height,
      barely.height,
      ("%d rows on %d lines, %d on %d"):format(cramped.height, cramped.lines, barely.height, barely.lines)
    )
  end)

  -- And that what the floor leaves is worth opening: enough rows to read a listing in, and
  -- still a float that fits on the screen it opened on. Eight is a judgment about reading a
  -- list, not the number the code holds.
  it("leaves a float a listing can be read in, and one that fits the terminal", function()
    assert.is_true(cramped.height >= 8, ("%d rows on %d lines"):format(cramped.height, cramped.lines))
    assert.is_true(
      cramped.height + 2 <= cramped.lines,
      ("%d rows and a border on %d lines"):format(cramped.height, cramped.lines)
    )
  end)
end)

--- A jump the float has to scroll for -------------------------------------------

-- The pair's arithmetic is buffer rows, and it was written and pressed on a float tall
-- enough to hold the branch it was pressed on. The height above is what takes that away: on
-- a terminal short enough for the floor, most of a long listing is off screen, and the row
-- `]c` names is a row the window has to move to before a reviewer can see it.
--
-- Read as the viewport and not as the cursor alone. A cursor sitting on a row the window
-- never scrolled to is a jump that landed where nobody can see it, and the row number is the
-- same either way.
--
-- Last, with the block above: this needs the branch that block grew, and a float shorter
-- than its listing needs a listing longer than any float.
describe("]c on a float too short to hold the branch", function()
  h.ui(110, 12)
  state.set_trim(root, nil)
  codereview.open()
  local review = assert(view.current(), "no review view opened")
  local win, buf = commits_by_key(review.win)
  local height = vim.api.nvim_win_get_config(win).height

  ---The first and the last row the float is showing.
  ---@return integer[]
  local function viewport()
    return vim.api.nvim_win_call(win, function()
      return { vim.fn.line("w0"), vim.fn.line("w$") }
    end)
  end

  -- Every box out, then two back in, far enough down the listing that neither is on screen
  -- from the top of it. A checked row inside the viewport is reached by a jump that never
  -- had to scroll at all, which is the case this block is not about.
  toggle(win, 1)
  local FAR, FARTHER = 30, 50
  toggle(win, FAR)
  toggle(win, FARTHER)

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  local from_top = viewport()
  local messages, restore = h.capture_notify()
  h.feed("]c")
  restore()
  local landed, showing = cursor_row(win), viewport()
  h.feed("]c")
  local farther, showing_farther = cursor_row(win), viewport()
  h.feed("[c")
  local back, showing_back = cursor_row(win), viewport()

  it("opened on a float well short of the listing it holds", function()
    assert.is_true(height < #lines(buf), ("%d rows for a listing of %d"):format(height, #lines(buf)))
  end)

  it("really did leave both checked rows below the rows on screen", function()
    assert.same({ FAR, FARTHER }, checked(buf), table.concat(lines(buf), "\n"))
    assert.is_true(from_top[2] < FAR, ("showing %d to %d"):format(from_top[1], from_top[2]))
  end)

  it("lands on the checked row rather than on the last row it could see", function()
    assert.same(FAR, landed)
  end)

  it("scrolled the float onto it", function()
    assert.is_true(
      showing[1] <= FAR and FAR <= showing[2],
      ("row %d, showing %d to %d"):format(landed, showing[1], showing[2])
    )
  end)

  it("reaches the one below it on a second press, and scrolls again", function()
    assert.same(FARTHER, farther)
    assert.is_true(
      showing_farther[1] <= FARTHER and FARTHER <= showing_farther[2],
      ("row %d, showing %d to %d"):format(farther, showing_farther[1], showing_farther[2])
    )
  end)

  it("comes back up on [c, and scrolls back with it", function()
    assert.same(FAR, back)
    assert.is_true(
      showing_back[1] <= FAR and FAR <= showing_back[2],
      ("row %d, showing %d to %d"):format(back, showing_back[1], showing_back[2])
    )
  end)

  -- The other way a jump can fail on a short float: reporting that there is nothing to move
  -- to, because everything it could see was unchecked.
  it("moved rather than reported that there was nowhere to go", function()
    assert.is_false(h.notified(messages, "checked"), vim.inspect(messages))
  end)

  h.feed("q")
  codereview.close()
  h.ui(110, 40)
end)
