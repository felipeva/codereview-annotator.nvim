-- Turning a queue into the text an agent receives, and the submit path that delivers it.
--
-- The interesting decision is per entry: an `@path#Lline` reference is worth far more to
-- the reader than a pasted snippet, but it is only honest when the target can resolve it
-- and the line still means what it meant. Everything else has to carry its own diff.
local h = require("tests.helpers")

h.ui(110, 40)
h.cd_fixture("mkfixture")

local sent = {}
require("codereview").setup({
  compose = function(ctx, on_accept, _)
    on_accept(nil, ctx.note_override or ("re: " .. ctx.label))
  end,
  send = function(text, target)
    sent[#sent + 1] = { text = text, target = target }
  end,
  pick_target = function(cb)
    cb({ short = "janus · api", pane_id = "wV:p3", cwd = "/somewhere/else" })
  end,
})

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")
local payload = require("codereview.payload")
local config = require("codereview.config")

view.open("branch")
local V = view.current()
queue.clear()

local function at(row)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
end

describe("relative_to", function()
  it("relativises a path inside the root", function()
    assert.same("b/c.lua", payload.relative_to("/a/b/c.lua", "/a"))
  end)

  it("tolerates a trailing slash on the root", function()
    assert.same("b/c.lua", payload.relative_to("/a/b/c.lua", "/a/"))
  end)

  it("refuses a path outside the root", function()
    assert.is_nil(payload.relative_to("/x/c.lua", "/a"))
  end)

  -- `/about` starts with `/a` as a string but is not under it. A plain prefix match emits
  -- refs the target cannot resolve.
  it("refuses a sibling that merely shares a prefix", function()
    assert.is_nil(payload.relative_to("/about/c.lua", "/a"))
  end)
end)

describe("rendering a mixed queue in-tree", function()
  at(assert(h.line_row(V, "src/fresh.lua")))
  annotate.annotate("bug")
  at(assert(h.line_row(V, "src/gone.lua")))
  annotate.annotate("suggestion")
  at(V.render.file_rows[1])
  annotate.annotate("nitpick")
  at(assert(h.row_of(V, "src/main.lua", function(a)
    return a.kind == "hunk"
  end)))
  annotate.annotate("bug")

  local text = payload.render(queue.all(), V.root, {
    types = config.get().types,
    scope_label = V.scope.label,
    files = #V.files,
    reviewed = 0,
  })

  it("queued four annotations", function()
    assert.same(4, queue.count())
  end)

  it("heads the payload with the count and the scope", function()
    assert.is_truthy(
      text:match(("^Code review — 4 annotations on branch vs master %%(%d files, 0 reviewed%%)"):format(#V.files))
    )
  end)

  it("leads each group with its directive", function()
    assert.is_truthy(text:find("## Bugs (2) — diagnose and fix these", 1, true))
    assert.is_truthy(text:find("## Suggestions (1) — evaluate; apply if sound", 1, true))
  end)

  it("orders groups by type, not by capture order", function()
    assert.is_true(text:find("## Bugs", 1, true) < text:find("## Suggestions", 1, true))
  end)

  -- Assert on heading content, not entry number: numbering follows group order, so the
  -- indices shift whenever a type is added or reordered.
  it("emits a bare @ref for an added line", function()
    assert.is_truthy(text:find("@src/fresh.lua#L1\n", 1, true))
  end)

  it("emits @path for a whole-file note", function()
    assert.is_truthy(text:match("### %d+%. @src/fresh%.lua\n"))
  end)

  it("inlines a deleted line rather than referencing it", function()
    assert.is_truthy(text:match("### %d+%. src/gone%.lua:1 %(deleted%)"))
    assert.is_truthy(text:find("```diff\n-local gone = true\n```", 1, true))
    assert.is_nil(text:find("@src/gone.lua", 1, true))
  end)

  it("inlines a hunk", function()
    assert.is_truthy(text:match("### %d+%. src/main%.lua:1%-3 %(change%)"))
  end)

  it("numbers entries continuously across groups", function()
    local ns = {}
    for n in text:gmatch("### (%d+)%.") do
      ns[#ns + 1] = tonumber(n)
    end
    assert.same({ 1, 2, 3, 4 }, ns)
  end)

  it("never repeats an @ref as a second line", function()
    assert.is_nil(text:find("#L1\n@src", 1, true))
  end)
end)

describe("rendering for an out-of-tree target", function()
  -- The reader's cwd is somewhere else entirely, so `@src/...` would resolve against
  -- their tree, not ours. Every ref has to degrade to an absolute path plus the code.
  local text = payload.render(queue.all(), "/somewhere/else", { types = config.get().types })

  it("emits no @refs at all", function()
    assert.is_nil(text:find("@src/", 1, true))
  end)

  it("uses absolute paths instead", function()
    assert.is_truthy(text:find(V.root .. "/src/fresh.lua", 1, true))
  end)

  it("inlines the code an @ref would have carried", function()
    assert.is_truthy(text:find("+local function fresh() end", 1, true))
  end)
end)

describe("rendering a stale entry", function()
  queue.all()[1].stale = true
  local text = payload.render(queue.all(), V.root, { types = config.get().types })

  -- The prose is still worth sending; only the line anchor is untrustworthy.
  it("loses its @ref", function()
    assert.is_nil(text:find("@src/fresh.lua#L1", 1, true))
  end)

  it("says the anchor may be wrong", function()
    assert.is_truthy(text:find("line numbers may be stale", 1, true))
  end)

  it("inlines its code instead", function()
    assert.is_truthy(text:find("+local function fresh() end", 1, true))
  end)

  queue.all()[1].stale = nil
end)

describe("submitting to a routed target", function()
  view.pick_target()

  it("shows it in the winbar", function()
    assert.is_truthy(vim.wo[V.win].winbar:find("→ janus · api", 1, true))
  end)

  view.submit()

  it("calls the send adapter once, with the routed target", function()
    assert.same(1, #sent)
    assert.same("wV:p3", sent[1].target.pane_id)
  end)

  -- The refs are resolved against where the *reader* is, not where we are.
  it("resolves refs against the target's cwd", function()
    assert.is_nil(sent[1].text:find("@src/", 1, true))
  end)

  it("clears the queue", function()
    assert.same(0, queue.count())
  end)

  it("repaints the view with no notes left", function()
    assert.same(0, #h.virt_marks(V))
  end)
end)

describe("submitting locally", function()
  -- Cleared the way a user clears it: the picker's own "local" entry answers with nil.
  -- Reaching in to blank a field stopped working when the target moved off the view, and
  -- the field was never the interface anyway.
  require("codereview.config").get().pick_target = function(cb)
    cb(nil)
  end
  view.pick_target()

  at(assert(h.line_row(V, "src/fresh.lua")))
  annotate.annotate("fix")
  view.submit()

  it("sends with no target", function()
    assert.same(2, #sent)
    assert.is_nil(sent[2].target)
  end)

  it("uses @refs because the reader shares our tree", function()
    assert.is_truthy(sent[2].text:find("@src/fresh.lua#L1", 1, true))
  end)
end)

describe("submitting with no send adapter", function()
  config.setup({
    compose = function(_, on_accept, _)
      on_accept(nil, "x")
    end,
  })
  at(assert(h.line_row(V, "src/fresh.lua")))
  annotate.annotate("bug")
  view.submit()

  -- Nothing consumed the batch, so dropping it would lose the review.
  it("keeps the queue", function()
    assert.same(1, queue.count())
  end)

  it("falls back to the clipboard", function()
    assert.is_truthy(vim.fn.getreg("+"):find("Code review", 1, true))
  end)
end)

describe("the queue float", function()
  view.review_queue()
  local qwin = vim.api.nvim_get_current_win()
  local qbuf = vim.api.nvim_win_get_buf(qwin)
  local qlines = vim.api.nvim_buf_get_lines(qbuf, 0, -1, false)

  it("lists the rendered groups", function()
    assert.is_truthy(qlines[1]:find("## Bugs", 1, true))
  end)

  it("counts the queue in its title", function()
    local cfg = vim.api.nvim_win_get_config(qwin)
    assert.is_truthy(tostring(cfg.title[1][1]):find("1 annotation", 1, true))
  end)

  it("drops the entry under the cursor with `x`", function()
    vim.api.nvim_win_set_cursor(qwin, { 2, 0 })
    vim.api.nvim_feedkeys("x", "x", false)
    assert.same(0, queue.count())
  end)

  it("closes itself once nothing is left", function()
    assert.is_false(vim.api.nvim_win_is_valid(qwin))
  end)
end)
