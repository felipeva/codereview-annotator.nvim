-- A **pane** without focus is **muted**. The file tree never is.
--
-- The tree keeps the other half of the rule: focus landing in it still mutes the panes, so
-- "the muted window is the one I am not in" stays true of the panes and says nothing about
-- the tree.
--
-- Asserted at the altitude a reviewer's editor actually holds it: the highlight namespace
-- each review window is drawing through, and its `cursorline`. Never the functions that set
-- them -- focus is moved with an ordinary window-switch key as readily as with the plugin's
-- own `<Tab>`, because what is being pinned down is the autocommand wiring and not one code
-- path that happens to call the right helper.
--
-- One level lower, and only where there is no higher way to say it, the namespace's own
-- contents are read: that a variant is derived from the theme that is active now, and that a
-- group this plugin cannot know about has none. The namespace holds a link to the group that
-- holds the colour, so `muted_hl` below reads the colour through it. Read the namespace alone
-- and you stop at a name, which says nothing about what a cell will show.
--
-- Lower still, the cells the reviewer's screen really holds. Those are in `muted_child.lua`,
-- one process per reading, because `nvim__inspect_cell` tells the truth only on the first
-- call a process makes -- see the header there.
local h = require("tests.helpers")

h.ui(120, 45)
local fixture = h.cd_fixture("mkfixture")

local config = require("codereview.config")
local queue = require("codereview.queue")
local syntax = require("codereview.syntax")
local view = require("codereview.view")

-- The plugin's own namespace, by name: `nvim_create_namespace` hands back the id a name
-- already has, so this is a lookup rather than a second namespace.
local MUTED = vim.api.nvim_create_namespace("codereview_muted")

-- Colours with even channels, so a blend halfway to a black background has no rounding in
-- it and the numbers below can be read at a glance.
vim.o.termguicolors = true
vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x004400 })
-- A group this plugin cannot know about: not one of its own, and not one the treesitter
-- replay resolves. Defined up here, before any review has built a namespace, so that an
-- implementation which enumerated every group the editor knows would sweep it up and the
-- case below would notice.
vim.api.nvim_set_hl(0, "MutedSpecStranger", { fg = 0x00ee00 })

---What a window is drawing through, in words.
---@param win integer|nil
---@return string|nil
local function drawing(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  local ns = vim.api.nvim_get_hl_ns({ winid = win })
  if ns == MUTED then
    return "muted"
  end
  return ns == 0 and "bright" or "untouched"
end

---Every review window at once, named, so a failure says which one is wrong.
---@return table<string, string|nil>
local function arrangement()
  local V = assert(view.current(), "no review view open")
  return { after = drawing(V.win), before = drawing(V.before_win), tree = drawing(V.panel_win) }
end

---@return table<string, boolean|nil>
local function cursorlines()
  local V = assert(view.current(), "no review view open")
  local out = {}
  for name, win in pairs({ after = V.win, before = V.before_win, tree = V.panel_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      out[name] = vim.wo[win].cursorline
    end
  end
  return out
end

---What a muted window really draws `group` in.
---
---One hop, because the namespace names a group and that group holds the colour. Reading the
---namespace alone stops at the name, which says nothing about what a cell will show.
---@param group string
---@return table
local function muted_hl(group)
  local entry = vim.api.nvim_get_hl(MUTED, { name = group })
  if not entry.link then
    return entry
  end
  return vim.api.nvim_get_hl(0, { name = entry.link, link = false })
end

---@param rgb integer
---@return integer[]
local function channels(rgb)
  return { math.floor(rgb / 65536) % 256, math.floor(rgb / 256) % 256, rgb % 256 }
end

--- A file parsed after its pane lost focus ---------------------------------------
--
-- First in the file, and it has to be: the set of capture groups the replay has resolved is
-- module-level and only ever grows, so once any block below has opened a review over the
-- whole branch there is no group left in this process that a later parse could be the first
-- to reach. This one starts in a scope holding one Lua file and widens to one holding
-- Markdown as well, from the tree, with both panes muted throughout.

require("codereview").setup({ layout = "split", syntax = true })
view.open("staged")

describe("a file whose syntax is parsed only after its pane lost focus", function()
  local V = assert(view.current(), "no review view open")

  it("starts with both panes bright behind the tree", function()
    view.toggle_focus()
    assert.same({ after = "muted", before = "muted", tree = "bright" }, arrangement())
  end)

  local seen = {}
  for _, group in pairs(syntax.resolved_groups()) do
    seen[group] = true
  end

  it("has resolved nothing about the file it cannot see yet", function()
    local files = {}
    for _, file in ipairs(V.files) do
      files[#files + 1] = file.path
    end
    assert.is_false(vim.tbl_contains(files, "src/nonl.md"), table.concat(files, ", "))
  end)

  view.set_scope("branch")

  it("never took focus out of the tree to do it", function()
    assert.same(V.panel_win, vim.api.nvim_get_current_win())
    assert.same({ after = "muted", before = "muted", tree = "bright" }, arrangement())
  end)

  -- The guard the case below is worth nothing without: with no group newly resolved, "every
  -- new group has a variant" holds over an empty set.
  local fresh = {}
  for _, group in pairs(syntax.resolved_groups()) do
    if not seen[group] then
      fresh[#fresh + 1] = group
    end
  end

  it("resolves capture groups the review had never drawn before", function()
    assert.is_true(#fresh > 0, "the wider scope parsed nothing new")
  end)

  it("mutes every one of them", function()
    local bright = {}
    for _, group in ipairs(fresh) do
      local def = vim.api.nvim_get_hl(0, { name = group, link = false })
      -- A group the theme gives no colour of its own is deliberately left without a
      -- variant; it is the case below, not a miss here.
      if (def.fg or def.bg) and vim.tbl_isempty(vim.api.nvim_get_hl(MUTED, { name = group })) then
        bright[#bright + 1] = group
      end
    end
    assert.same({}, bright)
  end)
end)

--- Which window is bright --------------------------------------------------------

describe("a review in the split layout with the tree open", function()
  local V = assert(view.current(), "no review view open")
  vim.api.nvim_set_current_win(V.win)

  it("is on by default", function()
    assert.is_true(config.get().muted.enabled)
  end)

  it("leaves the focused pane bright and mutes the other one", function()
    assert.same({ after = "bright", before = "muted", tree = "bright" }, arrangement())
  end)

  it("lights one row in the panes, in the one that has focus", function()
    assert.same({ after = true, before = false, tree = true }, cursorlines())
  end)

  it("moves the brightness with focus, from one pane to the other", function()
    vim.api.nvim_set_current_win(V.before_win)
    assert.same({ after = "muted", before = "bright", tree = "bright" }, arrangement())
    assert.same({ after = false, before = true, tree = true }, cursorlines())
  end)

  it("moves it between a pane and the tree, in both directions", function()
    vim.api.nvim_set_current_win(V.panel_win)
    assert.same({ after = "muted", before = "muted", tree = "bright" }, arrangement())
    vim.api.nvim_set_current_win(V.win)
    assert.same({ after = "bright", before = "muted", tree = "bright" }, arrangement())
  end)
end)

--- The tree, under every focus ----------------------------------------------------

-- Each of the three windows in turn rather than the one a mistake is most likely to be made
-- in: what is claimed is about the tree and not about which pane is bright.
describe("the file tree", function()
  local V = assert(view.current(), "no review view open")
  local windows = { after = V.win, before = V.before_win, tree = V.panel_win }

  it("is never muted, whichever window has focus", function()
    local drawn = {}
    for name, win in pairs(windows) do
      vim.api.nvim_set_current_win(win)
      drawn[name] = arrangement().tree
    end
    assert.same({ after = "bright", before = "bright", tree = "bright" }, drawn)
  end)

  it("keeps a lit row, whichever window has focus", function()
    local lit = {}
    for name, win in pairs(windows) do
      vim.api.nvim_set_current_win(win)
      lit[name] = cursorlines().tree
    end
    assert.same({ after = true, before = true, tree = true }, lit)
  end)

  -- The half of the rule the tree keeps. A tree taken out of the rule whole would leave this
  -- one arrangement unreachable, and muting nothing at all in the unified layout.
  it("still mutes both panes of the split layout when focus lands in it", function()
    vim.api.nvim_set_current_win(V.win)
    assert.same({ after = "bright", before = "muted", tree = "bright" }, arrangement())
    vim.api.nvim_set_current_win(V.panel_win)
    assert.same({ after = "muted", before = "muted", tree = "bright" }, arrangement())
    assert.same({ after = false, before = false, tree = true }, cursorlines())
  end)
end)

describe("focus moved with an ordinary window-switch key", function()
  local V = assert(view.current(), "no review view open")

  -- Fed rather than called, and positional rather than cyclic: the tree, the before pane
  -- and the after pane sit left to right in that order. A rule wired to the plugin's own
  -- navigation instead of to the events would leave this one untouched.
  it("mutes the pane it leaves and brightens the one it enters", function()
    vim.api.nvim_set_current_win(V.win)
    h.feed("<C-w>h")
    assert.same(V.before_win, vim.api.nvim_get_current_win())
    assert.same({ after = "muted", before = "bright", tree = "bright" }, arrangement())
  end)

  it("reaches the tree the same way", function()
    h.feed("<C-w>h")
    assert.same(V.panel_win, vim.api.nvim_get_current_win())
    assert.same({ after = "muted", before = "muted", tree = "bright" }, arrangement())
  end)

  it("leaves the review in the state the plugin's own key leaves it in", function()
    local by_key = arrangement()
    -- `<Tab>` from the tree is the plugin's own way back to the diff; take it there and back
    -- so the two are compared on the same window.
    view.toggle_focus()
    view.toggle_focus()
    assert.same(by_key, arrangement())
    assert.same(V.panel_win, vim.api.nvim_get_current_win())
  end)
end)

--- Floats change nothing ----------------------------------------------------------

describe("a float taking focus", function()
  local V = assert(view.current(), "no review view open")
  local annotate = require("codereview.annotate")

  ---The floating window in this tab, if there is one. Found by being floating rather than
  ---by a handle the plugin hands out: asking the composer where it is would pass against a
  ---composer that never appeared.
  ---@return integer|nil
  local function floating()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        return win
      end
    end
  end

  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { assert(h.line_row(V, "src/fresh.lua")), 0 })
  local was = arrangement()

  it("has a bright pane to lose", function()
    assert.same("bright", was.after)
  end)

  -- The shipped composer, with no `compose` adapter injected: a real float, entered, that
  -- stays open until it is dismissed.
  annotate.annotate("bug")
  local composer = floating()

  it("opens a composer that takes focus", function()
    assert.is_truthy(composer, "no floating window was opened")
    assert.same(composer, vim.api.nvim_get_current_win())
  end)

  it("leaves every review window exactly as it was", function()
    assert.same(was, arrangement())
    assert.same({ after = true, before = false, tree = true }, cursorlines())
  end)

  if composer and vim.api.nvim_win_is_valid(composer) then
    vim.api.nvim_win_close(composer, true)
  end

  -- And the queue float, which needs something queued: a composer that answers by itself.
  require("codereview").setup({
    layout = "split",
    syntax = true,
    compose = function(_, on_accept)
      on_accept(nil, "a note about the muted window")
    end,
    send = function()
      return true
    end,
  })
  vim.api.nvim_set_current_win(V.win)
  annotate.annotate("bug")
  view.review_queue()
  local float = floating()

  it("opens a queue float over the review", function()
    assert.is_truthy(float, "no queue float was opened")
    assert.same(1, queue.count())
  end)

  it("leaves every review window exactly as it was, again", function()
    assert.same(was, arrangement())
    assert.same({ after = true, before = false, tree = true }, cursorlines())
  end)

  if float and vim.api.nvim_win_is_valid(float) then
    vim.api.nvim_win_close(float, true)
    view.release_queue_float(float)
  end

  -- And the archive float, which needs a batch to have gone.
  vim.api.nvim_set_current_win(V.win)
  view.submit()
  require("codereview.archive").open()
  local archive = floating()

  it("opens an archive float over the review", function()
    assert.is_truthy(archive, "no archive float was opened")
  end)

  it("leaves every review window exactly as it was, a third time", function()
    assert.same(was, arrangement())
    assert.same({ after = true, before = false, tree = true }, cursorlines())
  end)

  if archive and vim.api.nvim_win_is_valid(archive) then
    vim.api.nvim_win_close(archive, true)
  end
  queue.clear()
end)

--- Windows the review builds again ------------------------------------------------

describe("a layout toggle", function()
  local V = assert(view.current(), "no review view open")
  vim.api.nvim_set_current_win(V.win)
  view.toggle_layout()

  it("leaves the unified layout with one pane and the tree", function()
    assert.is_nil(V.before_win)
    assert.same({ after = "bright", before = nil, tree = "bright" }, arrangement())
  end)

  -- The unified layout is where the tree earns the half of the rule it keeps: with one pane
  -- beside it, a tree out of the rule whole would leave muting nothing to do here at all.
  it("mutes that one pane when focus lands in the tree", function()
    vim.api.nvim_set_current_win(V.panel_win)
    assert.same({ after = "muted", before = nil, tree = "bright" }, arrangement())
    assert.same({ after = false, tree = true }, cursorlines())
    vim.api.nvim_set_current_win(V.win)
    assert.same({ after = "bright", before = nil, tree = "bright" }, arrangement())
  end)

  view.toggle_layout()

  it("mutes the pane that comes back, without waiting for the next focus change", function()
    assert.is_truthy(V.before_win)
    assert.same({ after = "bright", before = "muted", tree = "bright" }, arrangement())
    assert.same({ after = true, before = false, tree = true }, cursorlines())
  end)
end)

describe("a tree dismissed and summoned again", function()
  local V = assert(view.current(), "no review view open")
  vim.api.nvim_set_current_win(V.win)
  view.toggle_panel()

  it("leaves the panes alone while it is gone", function()
    assert.is_nil(V.panel_win)
    assert.same({ after = "bright", before = "muted", tree = nil }, arrangement())
  end)

  view.toggle_panel()

  it("comes back bright, with its row lit, in a window built after the review opened", function()
    assert.is_truthy(V.panel_win)
    assert.same({ after = "bright", before = "muted", tree = "bright" }, arrangement())
    assert.same({ after = true, before = false, tree = true }, cursorlines())
  end)
end)

--- What the namespace holds -------------------------------------------------------

describe("a group the plugin cannot know about", function()
  it("is left out of the namespace deliberately, so it renders at full brightness", function()
    assert.same({}, vim.api.nvim_get_hl(MUTED, { name = "MutedSpecStranger" }))
  end)

  -- Nobody is to "fix" the case above by giving the namespace a palette of its own: a group
  -- with no variant falling back to its global definition is what keeps an unrecognised
  -- theme merely less muted instead of wrongly coloured. `muted_child.lua` reads the cell.
  it("keeps a group the plugin does know about muted beside it", function()
    local add = muted_hl("CodeReviewAdd")
    assert.is_truthy(add.bg, "CodeReviewAdd has no muted variant")
  end)
end)

describe("changing colorscheme", function()
  local before = muted_hl("CodeReviewAdd").bg
  local was = vim.api.nvim_get_hl(0, { name = "CodeReviewAdd", link = false }).bg

  vim.cmd("colorscheme blue")

  local now = vim.api.nvim_get_hl(0, { name = "CodeReviewAdd", link = false }).bg
  local backdrop = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg or 0x000000
  local after = muted_hl("CodeReviewAdd").bg

  -- Without this the case below passes on a theme that happens to paint a changed line the
  -- same colour the last one did, which would prove nothing about recomputing anything.
  it("is a change the theme really made", function()
    assert.is_true(was ~= now, ("both themes give a changed line %s"):format(tostring(now)))
  end)

  it("recomputes the muted colour against the theme that is active now", function()
    assert.is_true(before ~= after, "the muted colour is the one the old theme was blended into")
    assert.is_true(after ~= now, "the muted colour is the new theme's, unmuted")
    local theme, back, muted = channels(now), channels(backdrop), channels(after)
    for i = 1, 3 do
      local lo, hi = math.min(theme[i], back[i]), math.max(theme[i], back[i])
      assert.is_true(
        muted[i] >= lo and muted[i] <= hi,
        ("channel %d: %d is not between the theme's %d and the background's %d"):format(i, muted[i], theme[i], back[i])
      )
    end
  end)
end)

--- Nothing else on screen ---------------------------------------------------------

describe("a window that is not the review's", function()
  local V = assert(view.current(), "no review view open")
  vim.api.nvim_set_current_win(V.win)
  local was = arrangement()

  vim.cmd("tabnew")
  local outsider = vim.api.nvim_get_current_win()

  it("is left drawing through no namespace of the plugin's", function()
    assert.same("untouched", drawing(outsider))
  end)

  it("does not mute the review it took focus from", function()
    assert.same(was, arrangement())
  end)

  vim.cmd("tabclose")
  vim.api.nvim_set_current_win(V.win)
end)

--- With the switch off ------------------------------------------------------------

describe("a review opened with muting off", function()
  require("codereview").setup({ layout = "split", syntax = true, muted = { enabled = false } })
  view.close()
  view.open("branch")
  local V = assert(view.current(), "no review view open")

  it("attaches no namespace to any of its windows", function()
    assert.same({ after = "untouched", before = "untouched", tree = "untouched" }, arrangement())
  end)

  it("draws a cursorline in every one of them, as it did before muting existed", function()
    assert.same({ after = true, before = true, tree = true }, cursorlines())
  end)

  it("leaves them that way when focus moves", function()
    vim.api.nvim_set_current_win(V.panel_win)
    assert.same({ after = "untouched", before = "untouched", tree = "untouched" }, arrangement())
    assert.same({ after = true, before = true, tree = true }, cursorlines())
  end)
end)

--- The cells a reviewer's screen holds ---------------------------------------------

-- One child per reading, because `nvim__inspect_cell` is only honest on the first call a
-- process makes. Each opens the same review over this spec's fixture, in the unified layout
-- at 80x24, and reads the first token the treesitter replay painted on an *added* line --
-- one cell carrying a changed line's background under a foreground from a higher priority
-- band, which is the only shape that can tell muting that reaches the diff from muting that
-- reaches nothing but the empty space.
describe("the cell under a reviewer's eye", function()
  ---@param env table<string, string>
  ---@return string
  local function child(env)
    local run = vim
      .system({
        vim.v.progpath,
        "--clean",
        "-l",
        vim.fs.joinpath(h.root, "tests", "codereview", "muted_child.lua"),
      }, {
        cwd = fixture,
        text = true,
        env = vim.tbl_extend("force", {
          FIXTURE = fixture,
          XDG_STATE_HOME = vim.fn.tempname() .. "-state",
          GIT_CONFIG_GLOBAL = "/dev/null",
          GIT_CONFIG_SYSTEM = "/dev/null",
        }, env),
      })
      :wait(60000)
    -- `nvim -l` sends print to stderr, so read both streams rather than guessing.
    local out = (run.stdout or "") .. (run.stderr or "")
    assert(run.code == 0, out)
    return vim.trim(out)
  end

  local focused = child({ FOCUS = "diff", CELL = "token" })
  local muted = child({ FOCUS = "tree", CELL = "token" })
  local stranger = child({ FOCUS = "tree", CELL = "stranger" })
  local off = child({ FOCUS = "tree", CELL = "token", MUTED = "0" })

  it("carries the changed line's background and the replay's foreground while focused", function()
    assert.same("cell l fg=ee0000 bg=004400", (focused:gsub(" at %d+,%d+$", "")))
  end)

  -- The regression the `winhighlight`/`NormalNC` route would be: it changes a window's
  -- default colours, and neither of these two comes from those.
  it("mutes both of them once its pane loses focus", function()
    assert.same("cell l fg=770000 bg=002200", (muted:gsub(" at %d+,%d+$", "")))
  end)

  it("leaves a group with no variant at its global brightness on a muted background", function()
    assert.same("cell l fg=00ee00 bg=002200", (stranger:gsub(" at %d+,%d+$", "")))
  end)

  it("paints exactly what it painted before muting existed when the switch is off", function()
    assert.same("cell l fg=ee0000 bg=004400", (off:gsub(" at %d+,%d+$", "")))
  end)
end)

--- A configuration mistake --------------------------------------------------------

-- Last, because it deliberately leaves a bad value in the options: the switches beside this
-- one are bare booleans, so `muted = false` is the mistake worth catching loudly.
describe("the switch written the way the coarse ones are", function()
  local ok, err = pcall(require("codereview").setup, { muted = false })

  it("fails at setup rather than inside a window helper later", function()
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("muted = { enabled = false }", 1, true), tostring(err))
  end)

  require("codereview").setup({ layout = "split", syntax = true })
end)
