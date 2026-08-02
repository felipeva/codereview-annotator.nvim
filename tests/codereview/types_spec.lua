-- Configuring the annotation types.
--
-- `opts.types` replaces the default set outright. Only `name` and `key` are required, so
-- adding a type costs two fields rather than six -- and a list that is wrong fails at
-- setup() naming the entry that caused it, rather than later as a nil `label` in the
-- composer or a keymap that silently shadows another.
local h = require("tests.helpers")

local types = require("codereview.types")
local config = require("codereview.config")

describe("normalising a type list", function()
  it("leaves a fully specified type alone", function()
    local out = types.normalise({
      { name = "bug", key = "b", icon = "!", hl = "MyBug", label = "Blockers", directive = "fix" },
    })
    assert.same({
      { name = "bug", key = "b", icon = "!", hl = "MyBug", label = "Blockers", directive = "fix" },
    }, out)
  end)

  it("accepts the shipped defaults unchanged", function()
    assert.same(types.defaults, types.normalise(types.defaults))
  end)

  it("does not mutate the list it was given", function()
    local input = { { name = "question", key = "q" } }
    types.normalise(input)
    assert.same({ { name = "question", key = "q" } }, input)
  end)

  it("fills label, icon and hl from the name alone", function()
    local t = types.normalise({ { name = "question", key = "q" } })[1]
    assert.same("Questions", t.label)
    assert.same("CodeReviewQuestion", t.hl)
    assert.same("●", t.icon)
  end)

  it("takes the default icon from the configured icons", function()
    local t = types.normalise({ { name = "question", key = "q" } }, { icon = "◆" })[1]
    assert.same("◆", t.icon)
  end)

  it("title-cases a multi-word name for the label and the group", function()
    local t = types.normalise({ { name = "needs-info", key = "N" } })[1]
    assert.same("Needs Infos", t.label)
    assert.same("CodeReviewNeedsInfo", t.hl)
  end)

  -- Naive pluralisation, minus the worst case. Anything English declines irregularly
  -- wants an explicit `label`, which is why one is easy to give.
  it("does not double an s on a name that is already plural", function()
    assert.same("Notes", types.normalise({ { name = "notes", key = "N" } })[1].label)
  end)

  it("leaves directive unset when it was not given", function()
    assert.is_nil(types.normalise({ { name = "question", key = "q" } })[1].directive)
  end)
end)

describe("rejecting a type list", function()
  local function err(list)
    local ok, msg = pcall(types.normalise, list)
    assert.is_false(ok, "expected normalise to reject this list")
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
