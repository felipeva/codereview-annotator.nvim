-- The since-batch scope inside a review view: the claim that nothing about it is second
-- class.
--
-- Every case here asserts a behaviour some *other* spec owns for every other scope --
-- syntax, navigation, collapse, reviewed marks, both layouts, capture -- because the way
-- this scope fails is not by throwing: it is by being special-cased somewhere in the
-- render or the view until it renders a little less than the others do.
--
-- The batch is dispatched through `submit`, which is the one thing that archives, and the
-- fixture is edited *afterwards*, so what is on screen is the answer to the batch and not
-- the work that was already in flight when it went.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")
local root = assert(vim.uv.fs_realpath(fixture))

local annotate = require("codereview.annotate")
local codereview = require("codereview")
local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

local NOTE = "a note about the agent's own work"

codereview.setup({
  compose = function(_, on_accept)
    on_accept(nil, NOTE)
  end,
  -- Reports nothing, which delivery reads as a dispatch -- and a dispatch is what archives.
  send = function() end,
})

--- The dispatch, and the agent's answer to it ------------------------------------

describe("a repository nothing has been dispatched from", function()
  it("has an empty archive to start from", function()
    assert.same({}, state.archive(root))
  end)

  it("does not offer the scope to `gs`", function()
    assert.is_false(vim.tbl_contains(require("codereview.git").cycle(root), "since-batch"))
  end)

  it("still offers it by name, on the command line", function()
    assert.is_true(vim.tbl_contains(vim.fn.getcompletion("CodeReview ", "cmdline"), "since-batch"))
  end)
end)

-- Dirty when the batch goes: `src/routes.lua` is staged and unstaged in the fixture, which
-- is what makes "work in flight does not appear" an assertion rather than a coincidence.
local in_flight = h.git_lines(fixture, { "diff", "--name-only", "HEAD" })

queue.add({
  type = "bug",
  kind = "file",
  path = "src/main.lua",
  abs_path = vim.fs.joinpath(root, "src/main.lua"),
  key = "src/main.lua:f:0",
  note = "have a look at this",
})
local msgs, restore = h.capture_notify()
codereview.submit()
restore()

-- The agent's response: one line added to a file it was asked about, after the batch went.
vim.fn.writefile({
  'local app = require("app")',
  "local cfg = load_config()",
  "cfg.validate()",
  "app.listen(cfg.port)",
}, vim.fs.joinpath(fixture, "src/main.lua"))

describe("the dispatch the rest of this spec reads back", function()
  it("was dispatched at all", function()
    assert.is_true(h.notified(msgs, "Submitted 1 annotation"), vim.inspect(msgs))
  end)

  it("left a batch in the archive to diff against", function()
    assert.same(1, #state.archive(root))
    assert.is_string(state.archive(root)[1].snapshot)
  end)

  it("went out of a working tree that had work in it already", function()
    assert.is_true(vim.tbl_contains(in_flight, "src/routes.lua"), vim.inspect(in_flight))
  end)
end)

--- The review view it opens ------------------------------------------------------

view.open("since-batch")
local V = assert(view.current(), "the review view did not open")

---The row of the one line the agent added, in whichever pane holds it.
---@param rendered CRRender
---@return integer|nil
local function added_row(rendered)
  for row, a in pairs(rendered.anchors) do
    local file = V.files[a.file]
    if a.kind == "line" and file.path == "src/main.lua" then
      local ln = file.hunks[a.hunk].lines[a.line]
      if ln.side == "add" then
        return row
      end
    end
  end
end

describe("the review view it opens", function()
  it("names what it is showing, so the winbar is unambiguous", function()
    assert.is_truthy(vim.wo[V.win].winbar:find("since the last batch", 1, true), vim.wo[V.win].winbar)
  end)

  it("shows the file the agent changed after the batch went", function()
    assert.is_number(h.file_index(V, "src/main.lua"))
  end)

  it("leaves out the work that was in flight before it", function()
    assert.is_nil(h.file_index(V, "src/routes.lua"))
  end)

  it("carries a file that was untracked at dispatch, as any other scope does", function()
    assert.is_number(h.file_index(V, "src/untracked.lua"))
  end)

  it("highlights it with treesitter like any other scope", function()
    local marks = h.syntax_marks(V)
    assert.is_true(#marks > 0)
  end)

  it("navigates by file", function()
    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    view.jump("file", true)
    assert.same(V.render.file_rows[2], vim.api.nvim_win_get_cursor(V.win)[1])
  end)

  it("navigates by hunk", function()
    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    view.jump("hunk", true)
    assert.same("hunk", V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]].kind)
  end)
end)

describe("marking a file reviewed in it", function()
  local fi = assert(h.file_index(V, "src/main.lua"))
  local rows_before = #V.render.lines
  vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
  view.toggle_reviewed()

  it("records the blob it was reviewed against", function()
    assert.same(V.files[fi].blob, V.reviewed["src/main.lua"])
  end)

  it("collapses the file", function()
    assert.is_true(#V.render.lines < rows_before)
  end)

  it("restores the rows when unmarked", function()
    view.toggle_reviewed()
    assert.same(rows_before, #V.render.lines)
  end)

  -- Per scope, and keyed by the snapshot the scope resolved to: the next batch is a
  -- different before-image, so a file marked done against this one says nothing about it.
  it("saves the mark under this scope's own key", function()
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    view.toggle_reviewed()
    view.persist()
    local saved = state.load(root).scopes["since-batch:" .. V.scope.before]
    assert.same(V.files[fi].blob, saved.reviewed["src/main.lua"])
    view.toggle_reviewed()
  end)
end)

describe("the split layout", function()
  view.toggle_layout()
  local split = assert(view.current())

  it("draws a before pane", function()
    assert.is_true(split.before_win ~= nil and vim.api.nvim_win_is_valid(split.before_win))
  end)

  it("keeps the two panes row for row", function()
    assert.same(#split.render.lines, #split.before_render.lines)
  end)

  it("names the snapshot as the image the before pane is showing", function()
    assert.is_truthy(vim.wo[split.before_win].winbar:find(split.scope.before, 1, true))
  end)

  it("holds the line the agent added in the after pane", function()
    assert.is_number(added_row(split.render))
  end)

  it("goes back to unified", function()
    view.toggle_layout()
    assert.same("unified", view.current().layout)
  end)
end)

--- Capture, and the cycle --------------------------------------------------------

-- Captured from the same line in two scopes, which is the whole of "no trace of which
-- scope captured it": the two entries have to be identical bar the id they were issued.
-- `src/main.lua` differs from the snapshot and from HEAD by exactly that line, so the same
-- anchor exists in both scopes.
queue.clear()
vim.api.nvim_win_set_cursor(V.win, { assert(added_row(V.render), "the added line is not on screen"), 0 })
annotate.annotate("bug")
local from_since = vim.deepcopy(assert(queue.all()[1], "nothing was captured"))

view.set_scope("worktree")
local W = assert(view.current())
queue.clear()
vim.api.nvim_win_set_cursor(W.win, { assert(added_row(W.render), "the added line is not on screen"), 0 })
annotate.annotate("bug")
local from_worktree = vim.deepcopy(assert(queue.all()[1], "nothing was captured"))

describe("annotating inside it", function()
  it("captures the line it was aimed at", function()
    assert.same({ "bug", "line", "src/main.lua", NOTE }, {
      from_since.type,
      from_since.kind,
      from_since.path,
      from_since.note,
    })
  end)

  -- Ids apart, because they are issued in order and nothing else about an entry is.
  it("produces the entry that line produces in any other scope", function()
    from_since.id, from_worktree.id = nil, nil
    assert.same(from_worktree, from_since)
  end)
end)

describe("cycling with something in the archive", function()
  it("is where `gs` goes after worktree", function()
    assert.same("worktree", view.current().scope.name)
    view.set_scope(nil)
    assert.same("since-batch", view.current().scope.name)
  end)

  it("cycles back out of it, to the first scope", function()
    view.set_scope(nil)
    assert.same("branch", view.current().scope.name)
  end)
end)
