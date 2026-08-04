-- Whether an archived entry's file has been touched since its batch was dispatched, and
-- the tally of the ones that have not.
--
-- The fixture carries a file the agent changed *and* one it did not, deliberately: with
-- everything touched, every assertion here passes with the blob comparison deleted. Same
-- trap as "a filter test needs a fixture only that filter can reject".
--
-- Everything is asserted through what a reviewer can see -- the winbar, the text of a
-- virtual line, the highlight *group* it is drawn in -- or through what the reconciliation
-- returns. Never a colour, and never the JSON behind the archive.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")
local root = assert(vim.uv.fs_realpath(fixture))

local codereview = require("codereview")
local queue = require("codereview.queue")
local render = require("codereview.render")
local state = require("codereview.state")
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
    -- Never the group staleness draws in: one colour for both is the merge the rule refuses.
    assert.is_nil(groups.CodeReviewStale, vim.inspect(vim.tbl_keys(groups)))
  end)

  it("links those groups into the colorscheme rather than defining colours", function()
    for _, group in ipairs({ "CodeReviewTouched", "CodeReviewUntouched" }) do
      local def = vim.api.nvim_get_hl(0, { name = group })
      assert.is_truthy(def.link, ("%s is not a link: %s"):format(group, vim.inspect(def)))
      assert.is_truthy(vim.api.nvim_get_hl(0, { name = def.link }), ("%s links nowhere"):format(group))
    end
  end)

  it("tallies the untouched ones on the winbar", function()
    assert.is_truthy(vim.wo[V.win].winbar:find("1 untouched", 1, true), vim.wo[V.win].winbar)
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
    assert.is_truthy(vim.wo[V.win].winbar:find("1 untouched", 1, true), vim.wo[V.win].winbar)
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
    assert.is_nil(vim.wo[V.win].winbar:find("untouched", 1, true), vim.wo[V.win].winbar)
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
    assert.is_truthy(vim.wo[V.win].winbar:find("0 untouched", 1, true), vim.wo[V.win].winbar)
  end)
end)

describe("the configuration flag", function()
  local config = require("codereview.config")
  local V = assert(view.current())

  config.get().archived = false
  view.refresh()

  it("takes the tally with the entries", function()
    assert.is_nil(vim.wo[V.win].winbar:find("untouched", 1, true), vim.wo[V.win].winbar)
  end)

  it("judges nothing, so nothing is spent deciding", function()
    assert.same({}, V.touched)
    assert.is_nil(V.untouched)
  end)

  config.get().archived = true
  view.refresh()

  it("brings both back together", function()
    assert.is_truthy(vim.wo[V.win].winbar:find("0 untouched", 1, true), vim.wo[V.win].winbar)
  end)
end)
