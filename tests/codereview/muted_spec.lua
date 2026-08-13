-- A **pane** without focus is **muted**. The file tree never is.
--
-- The tree keeps the other half of the rule: focus landing in it still mutes the panes, so
-- "the muted window is the one I am not in" stays true of the panes and says nothing about
-- the tree.
--
-- Every pane lights the row its cursor is on. The pane with focus lights it at full
-- strength; a muted pane lights a **counterpart row**, in a group of its own.
--
-- Asserted at the altitude a reviewer's editor actually holds it: the highlight namespace
-- each review window is drawing through, and the group it lights its row in. Never the
-- functions that set them -- focus is moved with an ordinary window-switch key as readily as
-- with the plugin's own `<Tab>`, because what is being pinned down is the autocommand wiring
-- and not one code path that happens to call the right helper.
--
-- One level lower, and only where there is no higher way to say it, the namespace's own
-- contents are read: that a variant is derived from the theme that is active now, and that a
-- group this plugin cannot know about has none. The namespace holds a link to the group that
-- holds the color, so `muted_hl` below reads the color through it. Read the namespace alone
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

-- Colors with even channels, so a blend halfway to a black background has no rounding in
-- it and the numbers below can be read at a glance.
vim.o.termguicolors = true
vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x004400 })
-- The row a pane lights. Its channels divide by four, so the muting's half and the
-- counterpart row's quarter are both exact and the two cannot be mistaken for each other.
vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x004488 })
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

---The group a window lights its row in, in words.
---
---`cursorline` reading `true` says that a row is lit and nothing about what a reviewer sees:
---the window draws that row through whatever namespace it is attached to, and a namespace
---can carry `CursorLine` all the way down to the muting's own blend -- which is the one
---answer a **counterpart row** must never have. So the group is named as well, and naming it
---needs the namespace's own contents; there is no higher way to say it. The cells
---`muted_child.lua` reads are what prove those names are colors.
---@param win integer
---@return string
local function lit(win)
  if not vim.wo[win].cursorline then
    return "unlit"
  end
  if vim.api.nvim_get_hl_ns({ winid = win }) ~= MUTED then
    return "focused"
  end
  local entry = vim.api.nvim_get_hl(MUTED, { name = "CursorLine" })
  if entry.link == "CodeReviewCounterpart.CursorLine" then
    return "counterpart"
  end
  -- A group the namespace does not name falls back to its global definition, so a muted pane
  -- with no entry for `CursorLine` lights its row exactly as a focused one does.
  return entry.link and "muted" or "focused"
end

---@return table<string, string|nil>
local function lit_rows()
  local V = assert(view.current(), "no review view open")
  local out = {}
  for name, win in pairs({ after = V.win, before = V.before_win, tree = V.panel_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      out[name] = lit(win)
    end
  end
  return out
end

---What a muted window really draws `group` in.
---
---One hop, because the namespace names a group and that group holds the color. Reading the
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
      -- A group the theme gives no color of its own is deliberately left without a
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

  it("lights a row in both panes, and the counterpart row in the muted one", function()
    assert.same({ after = "focused", before = "counterpart", tree = "focused" }, lit_rows())
  end)

  it("moves the brightness with focus, from one pane to the other", function()
    vim.api.nvim_set_current_win(V.before_win)
    assert.same({ after = "muted", before = "bright", tree = "bright" }, arrangement())
    assert.same({ after = "counterpart", before = "focused", tree = "focused" }, lit_rows())
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

  it("keeps a lit row of its own, whichever window has focus", function()
    local rows = {}
    for name, win in pairs(windows) do
      vim.api.nvim_set_current_win(win)
      rows[name] = lit_rows().tree
    end
    assert.same({ after = "focused", before = "focused", tree = "focused" }, rows)
  end)

  -- The half of the rule the tree keeps. A tree taken out of the rule whole would leave this
  -- one arrangement unreachable, and muting nothing at all in the unified layout.
  it("still mutes both panes of the split layout when focus lands in it", function()
    vim.api.nvim_set_current_win(V.win)
    assert.same({ after = "bright", before = "muted", tree = "bright" }, arrangement())
    vim.api.nvim_set_current_win(V.panel_win)
    assert.same({ after = "muted", before = "muted", tree = "bright" }, arrangement())
  end)

  -- The arrangement the **counterpart row** exists for the reviewer to read from: no pane
  -- has focus, so neither may hold the focused variant, and both say where their cursor is.
  it("leaves both panes on a counterpart row and neither on the focused one", function()
    vim.api.nvim_set_current_win(V.panel_win)
    assert.same({ after = "counterpart", before = "counterpart", tree = "focused" }, lit_rows())
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
    assert.same({ after = "focused", before = "counterpart", tree = "focused" }, lit_rows())
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
    assert.same({ after = "focused", before = "counterpart", tree = "focused" }, lit_rows())
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
    assert.same({ after = "focused", before = "counterpart", tree = "focused" }, lit_rows())
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
    assert.same({ after = "counterpart", tree = "focused" }, lit_rows())
    vim.api.nvim_set_current_win(V.win)
    assert.same({ after = "bright", before = nil, tree = "bright" }, arrangement())
  end)

  view.toggle_layout()

  it("mutes the pane that comes back, without waiting for the next focus change", function()
    assert.is_truthy(V.before_win)
    assert.same({ after = "bright", before = "muted", tree = "bright" }, arrangement())
    assert.same({ after = "focused", before = "counterpart", tree = "focused" }, lit_rows())
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
    assert.same({ after = "focused", before = "counterpart", tree = "focused" }, lit_rows())
  end)
end)

--- A repaint the muting does not drive ---------------------------------------------

-- Every case above reaches the arrangement through a focus change, and a **paint never calls
-- `mute`**: the muting is reasserted from the `WinEnter`/`WinLeave` pair and from nowhere
-- else. `gA` repaints through `toggle_archived` -> `judge_archive` -> `paint`, which touches
-- no window option and attaches no namespace -- so the counterpart row surviving it is a
-- claim about what a repaint leaves alone, and nothing else in the suite makes it.
--
-- Driven through the key rather than through `view.toggle_archived`, for the reason focus is
-- moved with `<C-w>h` above: what is pinned down is the path a reviewer's keystroke really
-- takes, and the tree binds this key as well as the diff does.
describe("archived entries toggled off the diff and back", function()
  local V = assert(view.current(), "no review view open")
  vim.api.nvim_set_current_win(V.win)
  local was, was_lit = arrangement(), lit_rows()
  local twin = muted_hl("CursorLine").bg

  -- The guard every assertion below is worth nothing without: with nothing archived, `gA`
  -- repaints a render identical to the one before it, and "the arrangement did not change"
  -- then holds over a repaint that changed nothing at all. The batch the float block
  -- dispatched is what makes this a real one.
  it("has an archived entry on the diff to take away", function()
    assert.is_truthy(next(V.archived), "nothing is archived, so the toggle draws the same diff twice")
  end)

  it("starts from a counterpart row in the muted pane", function()
    assert.same({ after = "bright", before = "muted", tree = "bright" }, was)
    assert.same({ after = "focused", before = "counterpart", tree = "focused" }, was_lit)
  end)

  h.feed("gA")

  it("really did repaint a diff without them", function()
    assert.same({}, V.archived)
  end)

  it("leaves every review window drawing through what it drew through", function()
    assert.same(was, arrangement())
  end)

  it("leaves the counterpart row lit, in its own group, in the muted pane", function()
    assert.same(was_lit, lit_rows())
    assert.same({ after = "focused", before = "counterpart", tree = "focused" }, lit_rows())
  end)

  -- The one thing the two readings above cannot see. They name a group; a repaint that had
  -- written the twins again against nothing would leave the name reaching a different color.
  it("leaves the color that group holds alone", function()
    assert.same(twin, muted_hl("CursorLine").bg)
  end)

  h.feed("gA")

  it("puts the archived entries back", function()
    assert.is_truthy(next(V.archived), "the second press did not restore them")
  end)

  it("leaves all three the same through the repaint back", function()
    assert.same(was, arrangement())
    assert.same({ after = "focused", before = "counterpart", tree = "focused" }, lit_rows())
    assert.same(twin, muted_hl("CursorLine").bg)
  end)
end)

--- What the namespace holds -------------------------------------------------------

describe("a group the plugin cannot know about", function()
  it("is left out of the namespace deliberately, so it renders at full brightness", function()
    assert.same({}, vim.api.nvim_get_hl(MUTED, { name = "MutedSpecStranger" }))
  end)

  -- Nobody is to "fix" the case above by giving the namespace a palette of its own: a group
  -- with no variant falling back to its global definition is what keeps an unrecognized
  -- theme merely less muted instead of wrongly colored. `muted_child.lua` reads the cell.
  it("keeps a group the plugin does know about muted beside it", function()
    local add = muted_hl("CodeReviewAdd")
    assert.is_truthy(add.bg, "CodeReviewAdd has no muted variant")
  end)
end)

-- A family of its own, holding one member. The alternative is a second copy of the blend
-- arithmetic, which is how this one and the muting would drift apart in color.
describe("the group a muted pane lights its counterpart row in", function()
  local theme = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false }).bg
  local counterpart = muted_hl("CursorLine").bg

  it("is named for the group it blends, in a family of its own", function()
    assert.same("CodeReviewCounterpart.CursorLine", vim.api.nvim_get_hl(MUTED, { name = "CursorLine" }).link)
  end)

  it("is a blend of the lit row this theme draws, and not that row itself", function()
    assert.same(0x004488, theme)
    assert.is_truthy(counterpart, "a muted pane lights its row in no color of its own")
    assert.is_true(counterpart ~= theme, "the counterpart row is the focused pane's color")
  end)

  -- What the family is for: a row pulled as far as the muting is would be lost inside the
  -- pane it has to be found in. 0x004488 a quarter of the way to a black background is
  -- 0x003366, where the muting's half would leave it at 0x002244.
  it("is pulled less far toward the background than the muting pulls everything else", function()
    assert.is_true(
      config.get().counterpart.strength < config.get().muted.strength,
      "the counterpart row is blended at least as far as the muting"
    )
    assert.same(0x003366, counterpart)
  end)
end)

describe("changing colorscheme", function()
  local before = muted_hl("CodeReviewAdd").bg
  local was = vim.api.nvim_get_hl(0, { name = "CodeReviewAdd", link = false }).bg
  local lit_before = muted_hl("CursorLine").bg
  local lit_was = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false }).bg

  vim.cmd("colorscheme blue")

  local now = vim.api.nvim_get_hl(0, { name = "CodeReviewAdd", link = false }).bg
  local backdrop = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg or 0x000000
  local after = muted_hl("CodeReviewAdd").bg
  local lit_now = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false }).bg
  local lit_after = muted_hl("CursorLine").bg

  ---Assert that `blend` really is `theme` pulled some of the way to the background.
  ---@param what string
  ---@param blend integer
  ---@param theme integer
  local function pulled_toward_the_background(what, blend, theme)
    local t, b, m = channels(theme), channels(backdrop), channels(blend)
    for i = 1, 3 do
      local lo, hi = math.min(t[i], b[i]), math.max(t[i], b[i])
      assert.is_true(
        m[i] >= lo and m[i] <= hi,
        ("%s channel %d: %d is not between the theme's %d and the background's %d"):format(what, i, m[i], t[i], b[i])
      )
    end
  end

  -- Without these two the cases below pass on a theme that happens to paint a changed line,
  -- or a lit row, the same color the last one did -- which would prove nothing about
  -- recomputing anything.
  it("is a change the theme really made", function()
    assert.is_true(was ~= now, ("both themes give a changed line %s"):format(tostring(now)))
  end)

  it("is a change the theme really made to a lit row as well", function()
    assert.is_true(lit_was ~= lit_now, ("both themes light a row %s"):format(tostring(lit_now)))
  end)

  it("recomputes the muted color against the theme that is active now", function()
    assert.is_true(before ~= after, "the muted color is the one the old theme was blended into")
    assert.is_true(after ~= now, "the muted color is the new theme's, unmuted")
    pulled_toward_the_background("muted", after, now)
  end)

  it("recomputes the counterpart row against it too", function()
    assert.is_true(lit_before ~= lit_after, "the counterpart row is the color the old theme was blended into")
    assert.is_true(lit_after ~= lit_now, "the counterpart row is the new theme's lit row, unblended")
    pulled_toward_the_background("counterpart", lit_after, lit_now)
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
    assert.same({ after = "focused", before = "focused", tree = "focused" }, lit_rows())
  end)

  it("leaves them that way when focus moves", function()
    vim.api.nvim_set_current_win(V.panel_win)
    assert.same({ after = "untouched", before = "untouched", tree = "untouched" }, arrangement())
    assert.same({ after = "focused", before = "focused", tree = "focused" }, lit_rows())
  end)
end)

describe("a review opened with the counterpart row off", function()
  require("codereview").setup({ layout = "split", syntax = true, counterpart = { enabled = false } })
  view.close()
  view.open("branch")
  local V = assert(view.current(), "no review view open")
  vim.api.nvim_set_current_win(V.win)

  it("mutes the pane without focus exactly as it did", function()
    assert.same({ after = "bright", before = "muted", tree = "bright" }, arrangement())
  end)

  it("lights a row in the pane with focus only, as it did before this existed", function()
    assert.same({ after = "focused", before = "unlit", tree = "focused" }, lit_rows())
  end)

  -- The teeth of the case above, which holds over a namespace still pointing `CursorLine` at
  -- the counterpart family -- and that is the group the pane would light its row in the
  -- moment the switch went back on.
  it("mutes CursorLine with every other group instead", function()
    assert.same("CodeReviewMuted.CursorLine", vim.api.nvim_get_hl(MUTED, { name = "CursorLine" }).link)
  end)

  -- And back on, without closing the review. The namespace is built once per set of resolved
  -- capture groups, so a pass that did not run again would leave the counterpart row muted.
  require("codereview").setup({ layout = "split", syntax = true })
  vim.api.nvim_set_current_win(V.panel_win)
  vim.api.nvim_set_current_win(V.win)

  it("comes back to a counterpart row when the switch goes back on", function()
    assert.same({ after = "focused", before = "counterpart", tree = "focused" }, lit_rows())
  end)
end)

--- The cells a reviewer's screen holds ---------------------------------------------

-- One child per reading, because `nvim__inspect_cell` is only honest on the first call a
-- process makes. Each opens the same review over this spec's fixture, in the unified layout
-- at 80x24.
--
-- The muting is read on the first token the treesitter replay painted on an *added* line --
-- one cell carrying a changed line's background under a foreground from a higher priority
-- band, which is the only shape that can tell muting that reaches the diff from muting that
-- reaches nothing but the empty space.
--
-- The lit row is read on a token of a **context** line instead, because `line_hl_group` wins
-- over `CursorLine`: an added line prints its own background whether or not its row is lit,
-- so a reading taken there would say nothing about either. Both of those readings are taken
-- with the cursor inside the file the row belongs to, so the **fade** is the same in each and
-- the one thing that moves is whether the row is the row the cursor is on.
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
  -- default colors, and neither of these two comes from those.
  it("mutes both of them once its pane loses focus", function()
    assert.same("cell l fg=770000 bg=002200", (muted:gsub(" at %d+,%d+$", "")))
  end)

  it("leaves a group with no variant at its global brightness on a muted background", function()
    assert.same("cell l fg=00ee00 bg=002200", (stranger:gsub(" at %d+,%d+$", "")))
  end)

  it("paints exactly what it painted before muting existed when the switch is off", function()
    assert.same("cell l fg=ee0000 bg=004400", (off:gsub(" at %d+,%d+$", "")))
  end)

  --- The row each pane lights ------------------------------------------------------

  local lit_focused = child({ FOCUS = "diff", CELL = "row", CURSOR = "on" })
  local lit_muted = child({ FOCUS = "tree", CELL = "row", CURSOR = "on" })
  local unlit_muted = child({ FOCUS = "tree", CELL = "row", CURSOR = "off" })
  local lit_off = child({ FOCUS = "tree", CELL = "row", CURSOR = "on", COUNTERPART = "0" })

  it("lights the row the cursor is on, at the theme's own strength, in the pane with focus", function()
    assert.same("cell l fg=ee0000 bg=004488", (lit_focused:gsub(" at %d+,%d+$", "")))
  end)

  -- The claim: a quarter of the way to the background where everything around it is half of
  -- the way there, so the row is neither lost in its pane nor mistaken for the focused one.
  it("lights the counterpart row more quietly once its pane loses focus", function()
    assert.same("cell l fg=770000 bg=003366", (lit_muted:gsub(" at %d+,%d+$", "")))
  end)

  -- The control that proves the reading above came from the lit row and not from the pane:
  -- the same cell, in the same pane, with the cursor moved off its row.
  it("leaves every other row of that pane on the plain muted background", function()
    assert.same("cell l fg=770000 bg=000000", (unlit_muted:gsub(" at %d+,%d+$", "")))
  end)

  -- And the control that proves the switch works: the row the cursor is on, in a muted pane,
  -- reading exactly what the row beside it reads.
  it("lights no row at all in a muted pane when the switch is off", function()
    assert.same("cell l fg=770000 bg=000000", (lit_off:gsub(" at %d+,%d+$", "")))
  end)
end)

--- A configuration mistake --------------------------------------------------------

-- Last, because it deliberately leaves a bad value in the options: the switches beside these
-- are bare booleans, so `muted = false` is the mistake worth catching loudly. The counterpart
-- row's switch has the same shape and is asked the same question.
describe("the switch written the way the coarse ones are", function()
  local ok, err = pcall(require("codereview").setup, { muted = false })

  it("fails at setup rather than inside a window helper later", function()
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("muted = { enabled = false }", 1, true), tostring(err))
  end)

  local ok_c, err_c = pcall(require("codereview").setup, { counterpart = false })

  it("fails the same way for the counterpart row", function()
    assert.is_false(ok_c)
    assert.is_truthy(tostring(err_c):find("counterpart = { enabled = false }", 1, true), tostring(err_c))
  end)

  local ok_s, err_s = pcall(require("codereview").setup, { counterpart = { strength = 2 } })

  it("rejects a strength that is not a fraction of the way to the background", function()
    assert.is_false(ok_s)
    assert.is_truthy(tostring(err_s):find("counterpart.strength", 1, true), tostring(err_s))
  end)

  require("codereview").setup({ layout = "split", syntax = true })
end)
