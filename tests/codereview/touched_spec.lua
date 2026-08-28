-- Whether an archived entry's file has been touched since its batch was dispatched, and
-- the tally of the ones that have not.
--
-- The fixture carries a file the agent changed *and* one it did not, deliberately: with
-- everything touched, every assertion here passes with the blob comparison deleted. Same
-- trap as "a filter test needs a fixture only that filter can reject".
--
-- Everything is asserted through what a reviewer can see -- the winbar, the text of a
-- virtual line, the highlight *group* it is drawn in -- or through what the reconciliation
-- returns. Never a color, and never the JSON behind the archive.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")
local root = assert(vim.uv.fs_realpath(fixture))

local codereview = require("codereview")
local queue = require("codereview.queue")
local render = require("codereview.render")
local state = require("codereview.state")

-- The **checkout** this session is in, resolved before anything is queued. It is what the
-- capture path does first, and what the entries built by hand below stand in for: a queue
-- belongs to a checkout, so an entry added before one is resolved joins the queue of
-- nowhere. Harmless here beyond that -- nothing is on disk yet to be read back.
state.ensure_queue()

local view = require("codereview.view")

-- The two files this whole spec turns on. Both are modified on the feature branch, so both
-- are in the branch scope from the start, and neither is the renamed one: `git diff -M`
-- names a rename by its *pre-image* path once the post-image is gone, so deleting
-- `src/newname.lua` would take it out of scope instead of marking it touched.
local CHANGED = "src/main.lua"
local UNCHANGED = "src/nonl.md"

codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "composed")
  end,
  -- Reports nothing, which is a dispatch: the one condition that empties the queue and
  -- writes the archive.
  send = function() end,
})

local icons = require("codereview.config").get().icons

---The tally as the **sticky header** spells it: the configured glyph, and the number on it.
---
---A glyph rather than the word, because three counts sit side by side on that bar and each
---needs one of its own. Every assertion about it reads `h.winbar`, which is the bar as
---Neovim draws it: the option holds highlight markers, and a tally that had gone missing
---from behind one would be found all the same.
---@param n integer
---@return string
local function tally(n)
  return ("%s%d"):format(icons.untouched, n)
end

---Queue one whole-file annotation, as the review path would have left it.
---@param path string
---@param note string
---@param stale boolean|nil
---@return CRAnnotation
local function queue_file(path, note, stale)
  return queue.add({
    type = "bug",
    kind = "file",
    path = path,
    abs_path = vim.fs.joinpath(root, path),
    key = render.file_key(path),
    note = note,
    stale = stale or nil,
  })
end

---The virtual lines drawn on a file's header row in the open view.
---@param path string
---@return table[]
local function drawn_on(path)
  local V = assert(view.current())
  local row = V.render.file_rows[assert(h.file_index(V, path), path .. " is not in scope")]
  for _, m in ipairs(h.virt_marks(V)) do
    if m[2] == row - 1 then
      return m[4].virt_lines
    end
  end
  return {}
end

---@param line table[]
---@return string
local function text_of(line)
  local out = {}
  for _, chunk in ipairs(line) do
    out[#out + 1] = chunk[1]
  end
  return table.concat(out)
end

---The one virtual line drawn on a file's header, as text.
---@param path string
---@return string
local function only_line_on(path)
  local virt = drawn_on(path)
  assert(#virt == 1, ("%s carries %d virtual lines: %s"):format(path, #virt, vim.inspect(virt)))
  return text_of(virt[1])
end

--- The dispatch everything below is judged against -----------------------------

-- A bare note goes out with them, so that "a bare note is never marked either way" is a
-- claim about a batch that actually held one.
queue_file(CHANGED, "the agent will edit this file")
-- Carries a staleness flag into the archive on purpose: it is persisted with the entry, and
-- the whole point of the two rules being separate is that this one must not be drawn once
-- the entry has gone.
queue_file(UNCHANGED, "the agent will leave this file alone", true)
queue.add({ type = "issue", kind = "note", note = "a thought with no file behind it" })

local dispatched_ids = {}
for _, item in ipairs(queue.all()) do
  dispatched_ids[item.note] = item.id
end

local _, restore = h.capture_notify()
codereview.submit()
restore()

describe("the dispatch this spec is judged against", function()
  it("emptied the queue, so nothing below is reading one", function()
    assert.same(0, queue.count())
  end)

  it("archived the two entries with a repository behind them", function()
    local batch = assert(state.archive(root)[1], "nothing was archived")
    assert.same({ CHANGED, UNCHANGED }, { batch.entries[1].path, batch.entries[2].path })
  end)

  it("minted a snapshot to judge them against", function()
    assert.is_truthy(state.archive(root)[1].snapshot)
  end)

  it("routed the bare note to the store that needs no root", function()
    assert.same(1, #state.global_archive()[1].entries)
  end)
end)

-- The agent's work: one of the two files moves, and the other is left exactly as it went.
-- Written after the dispatch, so the snapshot genuinely predates it.
local changed_abs = vim.fs.joinpath(root, CHANGED)
vim.fn.writefile(vim.list_extend(vim.fn.readfile(changed_abs), { "-- the agent was here" }), changed_abs)

describe("the fixture the rest of this spec depends on", function()
  it("moved one of the two files and not the other", function()
    local moved = h.git_lines(root, { "diff", "--name-only", state.archive(root)[1].snapshot })
    assert.is_true(vim.tbl_contains(moved, CHANGED), vim.inspect(moved))
    assert.is_false(vim.tbl_contains(moved, UNCHANGED), vim.inspect(moved))
  end)
end)

--- What the reconciliation makes of it ------------------------------------------

describe("the reconciliation behind the tally", function()
  local V = { files = {} }
  for _, path in ipairs({ CHANGED, UNCHANGED }) do
    V.files[#V.files + 1] = { path = path }
  end
  local touched, untouched = state.reconcile_archive(root, V.files)

  it("marks the file the agent edited", function()
    assert.is_true(touched[dispatched_ids["the agent will edit this file"]])
  end)

  it("marks the file it did not, and counts it", function()
    assert.is_false(touched[dispatched_ids["the agent will leave this file alone"]])
    assert.same(1, untouched)
  end)

  it("never marks a bare note either way", function()
    assert.is_nil(touched[dispatched_ids["a thought with no file behind it"]])
  end)

  -- Absence from a scope is not evidence that anything changed, which is the rule the
  -- reviewed-mark reconciliation already holds. Nothing judged means nothing to tally, so
  -- the winbar has no segment to draw rather than a zero to misread.
  it("leaves an entry whose file the scope does not cover unjudged", function()
    local only_one, count = state.reconcile_archive(root, { { path = UNCHANGED } })
    assert.is_nil(only_one[dispatched_ids["the agent will edit this file"]])
    assert.same(1, count)
    local none, nothing = state.reconcile_archive(root, { { path = "src/routes.lua" } })
    assert.same({}, none)
    assert.is_nil(nothing)
  end)

  -- Staleness is the same primitive against a different blob, judged over a different set
  -- of entries. Running one must not have run the other, in either direction.
  local queued = queue_file(CHANGED, "queued after the dispatch")
  -- A working-tree capture, judged against the file on disk at any scope, and against a
  -- blob nothing will ever hash to.
  queued.worktree = true
  queued.blob = ("0"):rep(40)
  local before = vim.deepcopy(queued)
  state.reconcile_archive(root, V.files)

  it("leaves a queued entry exactly as it found it, field for field", function()
    assert.same(before, queued)
  end)

  local staled = state.reconcile_queue(root)

  it("has not stopped the staleness rule reaching that entry", function()
    assert.same(1, staled)
    assert.is_true(queued.stale)
  end)

  queue.clear()
end)

--- What a reviewer sees ---------------------------------------------------------

describe("an archived entry on the diff", function()
  codereview.open("branch")
  local V = assert(view.current())

  it("says so on the file the agent changed", function()
    assert.is_truthy(only_line_on(CHANGED):find("file changed", 1, true), only_line_on(CHANGED))
  end)

  it("says so on the file it did not", function()
    assert.is_truthy(only_line_on(UNCHANGED):find("file unchanged", 1, true), only_line_on(UNCHANGED))
  end)

  -- The word is *touched*, not *addressed*: the plugin knows the file moved, not that
  -- anyone read the note, agreed with it or acted on it.
  it("claims nothing about the note itself", function()
    for _, path in ipairs({ CHANGED, UNCHANGED }) do
      local text = only_line_on(path)
      for _, word in ipairs({ "addressed", "resolved", "handled", "done", "fixed" }) do
        assert.is_nil(text:find(word, 1, true), ("%s says %q"):format(path, word))
      end
    end
  end)

  -- The flag the entry was dispatched carrying. It means "this file had moved since the
  -- annotation was captured", which is a fact about a queue that no longer exists -- and
  -- against the code now it would read as a claim nothing has checked.
  it("does not draw the staleness it went out with", function()
    assert.is_true(state.archive(root)[1].entries[2].stale, "the fixture archived no stale entry")
    assert.is_nil(only_line_on(UNCHANGED):find("stale", 1, true), only_line_on(UNCHANGED))
  end)

  it("draws the two answers in groups of their own", function()
    local groups = h.virt_groups(V)
    assert.is_true(groups.CodeReviewTouched or false, vim.inspect(vim.tbl_keys(groups)))
    assert.is_true(groups.CodeReviewUntouched or false, vim.inspect(vim.tbl_keys(groups)))
    -- Never the group staleness draws in: one color for both is the merge the rule refuses.
    assert.is_nil(groups.CodeReviewStale, vim.inspect(vim.tbl_keys(groups)))
  end)

  it("links those groups into the colorscheme rather than defining colors", function()
    for _, group in ipairs({ "CodeReviewTouched", "CodeReviewUntouched" }) do
      local def = vim.api.nvim_get_hl(0, { name = group })
      assert.is_truthy(def.link, ("%s is not a link: %s"):format(group, vim.inspect(def)))
      assert.is_truthy(vim.api.nvim_get_hl(0, { name = def.link }), ("%s links nowhere"):format(group))
    end
  end)

  it("tallies the untouched ones on the winbar", function()
    assert.is_truthy(h.winbar(V.win):find(tally(1), 1, true), h.winbar(V.win))
  end)

  -- The same group the entries themselves are drawn in, two rows below. One color, one
  -- meaning: the tally is the count of what is drawn in that color on the diff.
  it("draws the tally in the group those entries carry on the diff", function()
    assert.same("CodeReviewUntouched", h.winbar_group(V.win, tally(1)))
  end)
end)

-- A queued entry's staleness and an archived entry's touchedness are drawn from the same
-- slot, and both have to survive the other being there.
describe("a stale queued entry beside them", function()
  local V = assert(view.current())
  local queued = queue_file(CHANGED, "still to send")
  queued.worktree = true
  queued.blob = ("0"):rep(40)
  view.reconcile()
  view.paint()

  it("is flagged stale, exactly as it was before touchedness existed", function()
    local virt = drawn_on(CHANGED)
    assert.same(2, #virt, vim.inspect(virt))
    assert.is_truthy(text_of(virt[1]):find("⚠ stale", 1, true), text_of(virt[1]))
  end)

  it("does not take the archived entry's flag, nor give it its own", function()
    local virt = drawn_on(CHANGED)
    assert.is_nil(text_of(virt[1]):find("file changed", 1, true), text_of(virt[1]))
    assert.is_truthy(text_of(virt[2]):find("file changed", 1, true), text_of(virt[2]))
    assert.is_nil(text_of(virt[2]):find("stale", 1, true), text_of(virt[2]))
  end)

  it("leaves the tally where it was", function()
    assert.is_truthy(h.winbar(V.win):find(tally(1), 1, true), h.winbar(V.win))
  end)

  queue.clear()
  view.paint()
end)

describe("a scope that covers neither file", function()
  local V = assert(view.current())
  view.set_scope("staged")

  it("shows only the staged file, so both archived entries are out of it", function()
    assert.same(
      { "src/routes.lua" },
      vim.tbl_map(function(f)
        return f.path
      end, V.files)
    )
  end)

  it("tallies nothing rather than nothing-untouched", function()
    assert.is_nil(h.winbar(V.win):find(icons.untouched, 1, true), h.winbar(V.win))
  end)

  it("judges nothing", function()
    assert.same({}, V.touched)
    assert.is_nil(V.untouched)
  end)

  view.set_scope("branch")
end)

-- The lines the note named are gone, which is at least as touched as a rewrite.
describe("a file deleted since the dispatch", function()
  local V = assert(view.current())
  vim.fn.delete(vim.fs.joinpath(root, UNCHANGED))
  view.refresh()

  it("is still in scope, so absence from one is not what is being measured", function()
    assert.is_truthy(
      h.file_index(V, UNCHANGED),
      vim.inspect(vim.tbl_map(function(f)
        return f.path
      end, V.files))
    )
  end)

  it("counts as touched", function()
    assert.is_truthy(only_line_on(UNCHANGED):find("file changed", 1, true), only_line_on(UNCHANGED))
  end)

  it("leaves nothing untouched, and says so rather than going quiet", function()
    assert.is_truthy(h.winbar(V.win):find(tally(0), 1, true), h.winbar(V.win))
  end)
end)

describe("the configuration flag", function()
  local config = require("codereview.config")
  local V = assert(view.current())

  config.get().archived = false
  view.refresh()

  it("takes the tally with the entries", function()
    assert.is_nil(h.winbar(V.win):find(icons.untouched, 1, true), h.winbar(V.win))
  end)

  it("judges nothing, so nothing is spent deciding", function()
    assert.same({}, V.touched)
    assert.is_nil(V.untouched)
  end)

  config.get().archived = true
  view.refresh()

  it("brings both back together", function()
    assert.is_truthy(h.winbar(V.win):find(tally(0), 1, true), h.winbar(V.win))
  end)
end)

-- The key that overrides that flag for the session inherits its coarseness whole: the
-- display never tallies what it does not draw, and it spends no git deciding a number it
-- will not print. Asserted here rather than in `render_spec`, which owns what the diff
-- draws: this half is the sticky header's.
describe("the key beside it", function()
  local config = require("codereview.config")
  local V = assert(view.current())

  vim.api.nvim_set_current_win(V.win)
  h.feed("gA")

  it("takes the tally with the entries", function()
    assert.is_nil(h.winbar(V.win):find(icons.untouched, 1, true), h.winbar(V.win))
  end)

  it("judges nothing, so nothing is spent deciding", function()
    assert.same({}, V.touched)
    assert.is_nil(V.untouched)
  end)

  it("leaves the configured value where the host set it", function()
    assert.is_true(config.get().archived)
  end)

  h.feed("gA")

  it("brings both back together, without re-reading the diff", function()
    assert.is_truthy(h.winbar(V.win):find(tally(0), 1, true), h.winbar(V.win))
  end)
end)

-- Which blob touchedness is judged against, and the only fixture that can tell.
--
-- Everything above is clean at HEAD when its batch goes, so the blob the entry was
-- *captured* with, the blob the batch was *dispatched* with and the blob at HEAD are one
-- object -- and any of the three passes every assertion above. That is precisely the choice
-- this slice exists to get right: staleness judges a queued entry against its capture blob,
-- touchedness judges an archived entry against the dispatch blob, and a refactor swapping
-- one for the other has to red something.
--
-- So: a file the reviewer annotates, keeps working on, and only then submits -- the work in
-- flight #67 says `since-batch` must exclude -- which the agent afterwards never opens. Only
-- the snapshot reports it untouched. The capture blob and HEAD both report touched, which is
-- the plugin claiming an agent has been in a file it has never seen.
--
-- A second dispatch, and last in the file for that reason: it becomes the newest batch, and
-- everything above has already been judged against the one it displaces.
describe("a file the reviewer edited between annotating and submitting", function()
  local git = require("codereview.git")
  local V = assert(view.current())
  local IN_FLIGHT = "src/fresh.lua"
  local abs = vim.fs.joinpath(root, IN_FLIGHT)

  -- Three distinct contents, so the three reference points are three distinct blobs rather
  -- than two that happen to differ. HEAD carries what the branch committed; the reviewer had
  -- already moved on from it before annotating, and moves on again before submitting.
  local at_head = assert(git.blob(IN_FLIGHT, "HEAD", root))
  vim.fn.writefile({ "local function fresh() end", "-- mine, before I annotated it" }, abs)

  local entry = queue_file(IN_FLIGHT, "annotated while I was still working on this")
  entry.worktree = true
  entry.blob = assert(git.blob(IN_FLIGHT, nil, root))

  vim.fn.writefile({ "local function fresh() end", "-- mine, and still in flight when I sent" }, abs)

  local _, done = h.capture_notify()
  codereview.submit()
  done()
  view.refresh()

  local snapshot = assert(state.archive(root)[1].snapshot, "the second batch archived no snapshot")
  local at_dispatch = assert(git.blob(IN_FLIGHT, snapshot, root))

  -- Without this the case stops measuring the first time the fixture moves: two reference
  -- points that name one blob agree about everything, and the assertion below would then
  -- hold whichever of them the implementation reached for.
  it("has three genuinely different blobs to be judged against", function()
    assert.are_not.same(at_head, entry.blob, "HEAD and the capture blob are the same object")
    assert.are_not.same(entry.blob, at_dispatch, "the capture blob and the snapshot are the same object")
    assert.are_not.same(at_head, at_dispatch, "HEAD and the snapshot are the same object")
  end)

  it("was left exactly as it was dispatched, which is what makes it untouched", function()
    assert.same(at_dispatch, git.blob(IN_FLIGHT, nil, root))
  end)

  it("is untouched, because the agent never opened it", function()
    assert.is_truthy(only_line_on(IN_FLIGHT):find("file unchanged", 1, true), only_line_on(IN_FLIGHT))
  end)

  it("counts as untouched on the winbar", function()
    assert.is_truthy(h.winbar(V.win):find(tally(1), 1, true), h.winbar(V.win))
  end)

  -- The reviewer's own edits are not the agent's work, and the entry carries the blob that
  -- would say they were.
  it("does not read the reviewer's own work as the agent's", function()
    local touched = state.reconcile_archive(root, V.files)
    assert.is_false(touched[entry.id], "an in-flight edit was counted as the agent's")
  end)

  -- Only the newest batch is judged: an older one went out against an older snapshot, and
  -- "has this moved since the last dispatch" is not a question about it.
  it("leaves the batch it displaced unjudged", function()
    local touched = state.reconcile_archive(root, V.files)
    assert.is_nil(touched[dispatched_ids["the agent will edit this file"]])
    assert.same({ [entry.id] = false }, touched)
  end)
end)

-- The **sticky header** with one more segment on it than a review usually has, on a pane
-- that cannot hold them all. `render_spec` owns the fitting rule; what only this file can
-- reach is the rule fitting a summary the tally is *in*, because this segment is the one
-- that comes and goes.
--
-- Last in this file: it narrows the pane, which nothing below it would survive.
describe("the tally on a pane that has to choose", function()
  local V = assert(view.current())

  vim.api.nvim_win_set_width(V.win, 45)
  view.paint()
  local index = assert(h.file_index(V, "src/newname.lua"))
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index] + 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })

  local function bar()
    return h.winbar(V.win)
  end

  -- Guards the block: with no tally on the bar this is `render_spec`'s narrow-pane case
  -- again, and every case below would pass without the segment it is about being there.
  it("really is fitting a bar the tally is on", function()
    assert.same(1, V.untouched)
    assert.same(45, vim.api.nvim_win_get_width(V.win))
    assert.is_truthy(bar():find(tally(1), 1, true), bar())
  end)

  -- The order is unchanged by the extra segment: the review's line totals are what the file
  -- beside them says twice, so they go first and the counts that only the summary can give
  -- stay. In words this bar had room for one of them; in glyphs it has room for both.
  it("sheds what the file says twice and keeps both counts", function()
    local added, removed = require("codereview.diff").totals(V.files)
    assert.is_nil(bar():find(("+%d -%d"):format(added, removed), 1, true), bar())
    assert.is_truthy(bar():find(("%s0/%d"):format(icons.reviewed, #V.files), 1, true), bar())
  end)

  -- The path still gives up its head rather than its tail, tally or no tally.
  it("keeps the file's own name at the end of the path", function()
    assert.is_truthy(bar():find("src/newname.lua", 1, true), bar())
    assert.is_truthy(bar():find("…", 1, true), bar())
  end)
end)
