-- Configuring the annotation types.
--
-- `opts.types` replaces the default set outright. Only `name` and `key` are required, so
-- adding a type costs two fields rather than six -- and a list that is wrong fails at
-- setup() naming the entry that caused it, rather than later as a nil `label` in the
-- composer or a keymap that silently shadows another.
local h = require("tests.helpers")

local types = require("codereview.types")
local config = require("codereview.config")

describe("normalizing a type list", function()
  it("leaves a fully specified type alone", function()
    local out = types.normalize({
      { name = "bug", key = "b", icon = "!", hl = "MyBug", label = "Blockers", directive = "fix" },
    })
    assert.same({
      { name = "bug", key = "b", icon = "!", hl = "MyBug", label = "Blockers", directive = "fix" },
    }, out)
  end)

  it("accepts the shipped defaults unchanged", function()
    assert.same(types.defaults, types.normalize(types.defaults))
  end)

  it("does not mutate the list it was given", function()
    local input = { { name = "question", key = "q" } }
    types.normalize(input)
    assert.same({ { name = "question", key = "q" } }, input)
  end)

  it("fills label, icon and hl from the name alone", function()
    local t = types.normalize({ { name = "question", key = "q" } })[1]
    assert.same("Questions", t.label)
    assert.same("CodeReviewQuestion", t.hl)
    assert.same("●", t.icon)
  end)

  it("takes the default icon from the configured icons", function()
    local t = types.normalize({ { name = "question", key = "q" } }, { icon = "◆" })[1]
    assert.same("◆", t.icon)
  end)

  -- An empty string is truthy in Lua, so `t.icon or default` never fired on one: a type
  -- configured with `icon = ""` drew a hole wherever a glyph belongs, and the documented
  -- fallback was reachable only by leaving the field out entirely. Absent and empty say
  -- the same thing -- *this type has no glyph of its own* -- so they get the same answer.
  it("treats an empty icon as absent rather than as a glyph", function()
    local t = types.normalize({ { name = "question", key = "q", icon = "" } }, { icon = "◆" })[1]
    assert.same("◆", t.icon)
  end)

  -- Rejecting it instead would refuse a host who cleared a glyph on purpose. They asked
  -- for no glyph of their own, which is what the annotated mark already means.
  it("does not reject an empty icon", function()
    assert.same("●", types.normalize({ { name = "question", key = "q", icon = "" } })[1].icon)
  end)

  -- The same hole on the two fields beside `icon` that derive the same way. One rule over
  -- the four optional fields rather than one exception for the glyph: an empty `label`
  -- printed `##  (2)` as a payload heading, and an empty `hl` asked the render to draw in a
  -- highlight group with no name.
  it("treats an empty label and an empty hl as absent too", function()
    local t = types.normalize({ { name = "needs-info", key = "N", label = "", hl = "" } })[1]
    assert.same("Needs Infos", t.label)
    assert.same("CodeReviewNeedsInfo", t.hl)
  end)

  -- A directive is optional, so an empty one was never given -- and a group with nothing to
  -- instruct takes a bare heading rather than a heading with a dash and nothing after it.
  it("treats an empty directive as none", function()
    assert.is_nil(types.normalize({ { name = "question", key = "q", directive = "" } })[1].directive)
  end)

  it("title-cases a multi-word name for the label and the group", function()
    local t = types.normalize({ { name = "needs-info", key = "N" } })[1]
    assert.same("Needs Infos", t.label)
    assert.same("CodeReviewNeedsInfo", t.hl)
  end)

  -- Naive pluralization, minus the worst case. Anything English declines irregularly
  -- wants an explicit `label`, which is why one is easy to give.
  it("does not double an s on a name that is already plural", function()
    assert.same("Notes", types.normalize({ { name = "notes", key = "N" } })[1].label)
  end)

  it("leaves directive unset when it was not given", function()
    assert.is_nil(types.normalize({ { name = "question", key = "q" } })[1].directive)
  end)
end)

-- The glyphs the five shipped types carry.
--
-- Three surfaces already draw an annotation type's icon, and on an **archived** entry the
-- glyph is the only thing left: that entry gives up its type's color on purpose -- the
-- color says how much a finding matters, which is an instruction to act, and this one has
-- been acted on -- so an empty glyph left it saying nothing about what kind of finding it
-- was.
describe("the glyphs the shipped types carry", function()
  it("gives every one of them a glyph", function()
    for _, t in ipairs(types.defaults) do
      assert.is_true(t.icon ~= nil and t.icon ~= "", ("%s carries no glyph"):format(t.name))
    end
  end)

  -- Against every glyph the plugin already draws, not merely against each other. A type
  -- drawing `○` would say *unreviewed* on the row above it, and a reviewer meeting one
  -- glyph with two meanings cannot tell which of them a row means.
  it("spends a glyph nothing else the plugin draws already spends", function()
    local seen = { [types.UNTYPED.icon] = "the untyped mark" }
    for name, glyph in pairs(config.defaults.icons) do
      seen[glyph] = name
    end
    for _, t in ipairs(types.defaults) do
      assert.is_nil(seen[t.icon], ("%s draws %q, which is already %s"):format(t.name, t.icon, tostring(seen[t.icon])))
      seen[t.icon] = t.name
    end
  end)

  -- The width Neovim measures here, which protects more than the look of a row: the marker
  -- in front of a note is what that row's columns are counted past, so a glyph two columns
  -- wide would move the prose, the wrap budget, and the indent of every row a note that
  -- does not fit continues onto.
  it("spends exactly one display column on each", function()
    for _, t in ipairs(types.defaults) do
      assert.same(1, vim.fn.strdisplaywidth(t.icon), ("%s draws %q"):format(t.name, t.icon))
    end
  end)

  -- Plain Unicode: nothing the plugin draws may need a patched font, which is the rule the
  -- icon table itself states. A patched font puts its glyphs in a private use area, where
  -- an unpatched one draws a hollow box -- so that is where a glyph must not come from.
  -- The code point and not the byte count, because a plain glyph can be four bytes too.
  it("asks for no patched font", function()
    for _, t in ipairs(types.defaults) do
      local cp = vim.fn.char2nr(t.icon)
      local private = (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0xF0000 and cp <= 0x10FFFD)
      assert.is_false(private, ("%s draws U+%X, which no unpatched font has"):format(t.name, cp))
    end
  end)
end)

describe("rejecting a type list", function()
  local function err(list)
    local ok, msg = pcall(types.normalize, list)
    assert.is_false(ok, "expected normalize to reject this list")
    return msg
  end

  it("names the offending index", function()
    assert.same("codereview.setup: types[2] has no `key`", err({ { name = "bug", key = "b" }, { name = "question" } }))
  end)

  it("rejects a missing name", function()
    assert.is_truthy(err({ { key = "q" } }):find("types[1] has no `name`", 1, true))
  end)

  it("rejects an empty name or key", function()
    assert.is_truthy(err({ { name = "", key = "q" } }):find("has no `name`", 1, true))
    assert.is_truthy(err({ { name = "question", key = "" } }):find("has no `key`", 1, true))
  end)

  it("rejects a duplicate name, pointing at both", function()
    local msg = err({ { name = "bug", key = "b" }, { name = "bug", key = "g" } })
    assert.same('codereview.setup: types[1] and types[2] are both named "bug"', msg)
  end)

  it("rejects a duplicate key, pointing at both", function()
    local msg = err({ { name = "bug", key = "b" }, { name = "question", key = "b" } })
    assert.same('codereview.setup: types[1] and types[2] both use key "b"', msg)
  end)

  -- `aa` opens the type picker, so a type keyed "a" would shadow it.
  it("rejects a key that collides with the type picker", function()
    assert.is_truthy(err({ { name = "question", key = "a" } }):find("type picker", 1, true))
  end)

  it("rejects a field of the wrong type", function()
    assert.is_truthy(err({ { name = "question", key = "q", directive = 7 } }):find("not a string", 1, true))
    assert.is_truthy(err({ { name = "question", key = "q", icon = {} } }):find("not a string", 1, true))
  end)

  it("rejects an entry that is not a table", function()
    assert.is_truthy(err({ "bug" }):find("types[1] is a string, not a table", 1, true))
  end)

  it("rejects an empty list", function()
    assert.is_truthy(err({}):find("non-empty", 1, true))
  end)

  it("rejects a map, which would have no order", function()
    assert.is_truthy(err({ bug = { key = "b" } }):find("not a map", 1, true))
  end)

  -- Ordering is the payload's ordering, so silently accepting a shape without one would
  -- make the most actionable group land wherever pairs() felt like putting it.
  it("surfaces the failure through setup()", function()
    local ok, msg = pcall(config.setup, { types = { { name = "question" } } })
    assert.is_false(ok)
    assert.same("codereview.setup: types[1] has no `key`", msg)
  end)
end)

-- One helper, shared by the queue float and the payload renderer, which used to carry a
-- copy of this loop each. Pure: a plain list in, groups out, no queue and no view.
describe("grouping annotations", function()
  local list = {
    { name = "bug", key = "b", label = "Bugs" },
    { name = "nitpick", key = "n", label = "Nitpicks" },
  }

  ---@param groups table[]
  local function shape(groups)
    return vim.tbl_map(function(g)
      return ("%s:%d"):format(g.type.label, #g.items)
    end, groups)
  end

  -- Groups follow the configured type order, not the order notes were captured, so a
  -- reviewer reads bugs before nitpicks however they were written.
  it("buckets by type, in the configured order", function()
    local groups = types.group({ { type = "nitpick" }, { type = "bug" }, { type = "bug" } }, list)
    assert.same({ "Bugs:2", "Nitpicks:1" }, shape(groups))
  end)

  it("keeps capture order inside a group", function()
    local first, second = { type = "bug", note = "one" }, { type = "bug", note = "two" }
    assert.same({ first, second }, types.group({ first, second }, list)[1].items)
  end)

  it("omits a type nothing was annotated with", function()
    assert.same({ "Bugs:1" }, shape(types.group({ { type = "bug" } }, list)))
  end)

  it("groups nothing when there is nothing to group", function()
    assert.same({}, types.group({}, list))
  end)

  it("collects annotations with no type into a group of their own, last", function()
    local groups = types.group({ {}, { type = "bug" }, {} }, list)
    assert.same({ "Bugs:1", "Untyped:2" }, shape(groups))
  end)

  -- A queue persisted before a host dropped a type from its list restores entries naming
  -- one that no longer exists. They are still annotations someone wrote; the group with no
  -- directive is where an entry the type list cannot account for belongs.
  it("treats a type the list no longer configures as untyped", function()
    assert.same({ "Untyped:1" }, shape(types.group({ { type = "retired" } }, list)))
  end)

  it("leaves the untyped group without a directive", function()
    local group = types.group({ {} }, list)[1]
    assert.is_nil(group.type.directive)
    assert.is_nil(group.type.name)
  end)
end)

describe("a custom type end to end", function()
  h.ui(110, 40)
  h.cd_fixture("mkfixture")

  require("codereview").setup({
    syntax = false,
    compose = function(_, on_accept, _)
      on_accept(nil, "why?")
    end,
    types = {
      -- `bug` derives hl = CodeReviewBug, which hl.lua already links by name. Included so
      -- the fallback below has something to collide with: without a type whose group is
      -- also a built-in, the ordering assertion cannot fail however hl.apply is written.
      { name = "bug", key = "b", directive = "diagnose and fix these" },
      { name = "blocker", key = "B", directive = "stop and fix" },
      { name = "question", key = "q" },
    },
  })

  local view = require("codereview.view")
  local queue = require("codereview.queue")
  local annotate = require("codereview.annotate")
  local payload = require("codereview.payload")

  view.open("branch")
  local V = view.current()
  queue.clear()

  it("defines a highlight group for a type the plugin never heard of", function()
    local hl = vim.api.nvim_get_hl(0, { name = "CodeReviewQuestion" })
    assert.same("DiagnosticInfo", hl.link)
  end)

  -- `bug` is configured here *and* linked by name in hl.lua. The neutral fallback must
  -- lose that race, or every built-in type flattens to DiagnosticInfo -- which is only
  -- true because nvim_set_hl with `default = true` never overrides an existing
  -- definition, so whichever loop runs first in hl.apply wins.
  it("leaves a built-in type's severity mapping alone", function()
    assert.same("DiagnosticError", vim.api.nvim_get_hl(0, { name = "CodeReviewBug" }).link)
  end)

  it("binds a keymap per configured type, and nothing for the defaults", function()
    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(V.buf, "n")) do
      lhs[m.lhs] = true
    end
    assert.is_true(lhs["ab"], "ab was not bound")
    assert.is_true(lhs["aB"], "aB was not bound")
    assert.is_true(lhs["aq"], "aq was not bound")
    assert.is_true(lhs["aa"], "the type picker was not bound")
    assert.is_nil(lhs["an"], "an is a default type and should be gone")
  end)

  it("annotates with a type that only gave a name and a key", function()
    vim.api.nvim_win_set_cursor(V.win, { assert(h.line_row(V, "src/fresh.lua")), 0 })
    annotate.annotate("question")
    assert.same(1, queue.count())
    assert.same("question", queue.all()[1].type)
  end)

  it("renders it as virtual lines under its derived group", function()
    view.paint()
    assert.same(1, #h.virt_marks(V))
  end)

  it("groups it in the payload under the derived label", function()
    vim.api.nvim_win_set_cursor(V.win, { assert(h.line_row(V, "src/gone.lua")), 0 })
    annotate.annotate("blocker")

    local text = payload.render(queue.all(), V.root, { types = config.get().types })
    assert.is_truthy(text:find("## Blockers (1) — stop and fix", 1, true))
    -- No directive, so no dash: the heading stops after the count.
    assert.is_truthy(text:find("## Questions (1)\n", 1, true))
  end)

  it("orders groups by the configured order", function()
    local text = payload.render(queue.all(), V.root, { types = config.get().types })
    assert.is_true(text:find("## Blockers", 1, true) < text:find("## Questions", 1, true))
  end)

  -- The picker's labels are built from the configured list, so a host who replaced the
  -- vocabulary meets their own types and their own keys in it. Read once and asserted
  -- twice: both cases ask the picker the same question, and stubbing `vim.ui.select` a
  -- second time would only assert the stub.
  local offered
  do
    local orig = vim.ui.select
    vim.ui.select = function(items, _, _)
      offered = items
    end
    annotate.pick_type(config.get().types, function() end)
    vim.ui.select = orig
  end

  it("offers the host's own types with their own keys", function()
    assert.same(#config.get().types + 1, #offered, vim.inspect(offered))
    for i, t in ipairs(config.get().types) do
      assert.is_truthy(offered[i]:find(t.name, 1, true), offered[i])
      -- Through `types.PREFIX` rather than a literal `"a"`, so what the picker prints and
      -- what `keymaps.lua` binds stay one fact under the test as well as under the code.
      assert.is_truthy(offered[i]:find(types.PREFIX .. t.key, 1, true), offered[i])
      -- The host's own directive, not a shipped type's. `blocker` is what makes this able
      -- to fail: it is in no default set, so a label reading `types.defaults` instead of
      -- the configured list has nothing to print for it.
      if t.directive then
        assert.is_truthy(offered[i]:find(t.directive, 1, true), offered[i])
      end
    end
    -- Nothing the host dropped is still on offer, keys included.
    for _, label in ipairs(offered) do
      assert.is_nil(label:find("nitpick", 1, true), label)
    end
  end)

  -- `question` carries no directive, and then the row stops at its key. A blank column
  -- would say the type has a directive and that the directive is empty.
  it("offers a type with no directive without one", function()
    local label = offered[3]
    assert.is_truthy(label:find("question", 1, true), label)
    assert.same(types.PREFIX .. "q", label:match("(%S+)%s*$"), label)
  end)

  it("titles the composer from the type", function()
    local seen
    config.setup({
      syntax = false,
      compose = function(ctx, on_accept, _)
        seen = ctx.label
        on_accept(nil, "n")
      end,
      types = { { name = "question", key = "q" } },
    })
    vim.api.nvim_win_set_cursor(V.win, { assert(h.line_row(V, "src/fresh.lua")), 0 })
    annotate.annotate("question")
    assert.same("Question · src/fresh.lua:1", seen)
  end)
end)

-- The columns are the picker's whole argument: a reviewer looking for one type reads down a
-- column rather than along a row. Two things break that, and the shipped five can see
-- neither -- their glyphs are all present and all one cell wide.
describe("the picker's columns", function()
  local annotate = require("codereview.annotate")

  ---The rows the picker would offer for a type list, without a view or a queue behind it.
  ---@param list table
  ---@param opts table|nil Passed to `normalize`, which is where a fallback glyph comes from
  ---@return string[]
  local function offered(list, opts)
    local rows
    local orig = vim.ui.select
    vim.ui.select = function(items, _, _)
      rows = items
    end
    annotate.pick_type(types.normalize(list, opts), function() end)
    vim.ui.select = orig
    return rows
  end

  -- `icons = { annotated = "" }` is how a host asks for no glyph at all, and a type that
  -- names no icon of its own inherits it. The empty-icon rule covers a *type's* own field,
  -- not the table it falls back to, so an empty glyph reaches a row -- and a row trimmed at
  -- both ends then loses the leading columns every other row keeps.
  it("keeps a directive-less row's leading columns when the glyph is empty", function()
    local rows = offered({
      { name = "bug", key = "b", directive = "fix it" },
      { name = "question", key = "q" },
    }, { icon = "" })
    assert.same(rows[1]:find("bug", 1, true), rows[2]:find("question", 1, true), vim.inspect(rows))
  end)

  -- A host's glyph is theirs and `normalize` takes whatever they give it, so the glyph is a
  -- column like the others. One two-cell glyph on one type otherwise moves every name in the
  -- menu, which is the one thing the columns are there to prevent.
  it("lines the names up when one host's glyph is wider than another's", function()
    local rows = offered({
      { name = "bug", key = "b", icon = "🐛", directive = "fix it" },
      { name = "nit", key = "n", icon = "▫", directive = "later" },
    })
    assert.same(
      vim.fn.strdisplaywidth(rows[1]:match("^(.-)bug")),
      vim.fn.strdisplaywidth(rows[2]:match("^(.-)nit")),
      vim.inspect(rows)
    )
  end)

  -- Declining shares the glyph column -- it has a mark, and the mark is a glyph -- and
  -- declines every column after it, because no key reaches it and it instructs nothing.
  it("lines the untyped mark's name up with the types' names", function()
    local rows = offered({ { name = "bug", key = "b", icon = "🐛", directive = "fix it" } })
    assert.same(
      vim.fn.strdisplaywidth(rows[1]:match("^(.-)bug")),
      vim.fn.strdisplaywidth(rows[2]:match("^(.-)no type")),
      vim.inspect(rows)
    )
  end)
end)
