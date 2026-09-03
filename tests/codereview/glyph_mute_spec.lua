-- A host's file glyph **mutes** with the **pane** it is in.
--
-- A muted window draws through a highlight namespace built from the groups this plugin
-- knows (`hl.groups()`) plus the capture groups the syntax replay resolved
-- (`syntax.resolved_groups()`). A host's icon group belongs to neither set, so a wired glyph
-- stayed at full brightness in a pane that had lost focus -- the one bright thing in a window
-- that is meant to recede. The render records the groups the adapters answered with, and the
-- window rule asks for them alongside the other two.
--
-- **A spec of its own, and that is forced rather than tidy.** The recorded set is
-- module-level and only ever grows, exactly as the replay's resolved groups do -- so "with
-- nothing wired the set is empty" can only be asserted by a process that has not wired an
-- adapter yet, and `PlenaryBustedDirectory` gives one process per spec file. Put in
-- `file_icon_spec`, that claim would have to run in front of an act that hands adapters to
-- `render.file_label` directly, and any later re-ordering of that file would silently make it
-- vacuous. Put in `muted_spec`, wiring an adapter would move every header row and every tree
-- row that spec reads.
--
-- The order below is that constraint written out: nothing wired, then one adapter wired, then
-- the cells a reviewer's screen really holds.
--
-- **The claim needs a painted cell.** That a group name is in a namespace says nothing about
-- what a reviewer sees: the namespace holds a *link*, and a link reaching a group with no
-- colour draws nothing at all. The cells are in `glyph_mute_child.lua`, one process per
-- reading, because `nvim__inspect_cell` reports a cell's real attributes only on the first
-- call a process makes.
local h = require("tests.helpers")

h.ui(120, 45)
local fixture = h.cd_fixture("mkfixture")

local render = require("codereview.render")
local view = require("codereview.view")

-- The plugin's own namespace, by name: `nvim_create_namespace` hands back the id a name
-- already has, so this is a lookup rather than a second namespace.
local MUTED = vim.api.nvim_create_namespace("codereview_muted")

-- One column wide and more than one byte long, which is what a devicon is.
local LUA = "λ"

-- The group `mini.icons` answers with, spelled as it spells it. A host's group and never one
-- of this plugin's: the whole point is that the colour is the one the reviewer's icon plugin
-- already chose.
local AZURE = "MiniIconsAzure"

-- A group with a colour of its own that no adapter ever answers with. It must stay out of the
-- namespace: an implementation that swept up every group the editor defines would mute it
-- too, and every case below would still be green.
local STRANGER = "GlyphMuteStranger"

-- Colours with even channels, so a blend halfway to a black background has no rounding in it.
vim.o.termguicolors = true
vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, AZURE, { fg = 0x00ee00 })
vim.api.nvim_set_hl(0, STRANGER, { fg = 0x00ee00 })

---@return CRView
local function current()
  return assert(view.current(), "no review view open")
end

--- With nothing wired ------------------------------------------------------------

-- First in the file, and it has to be: the recorded set only grows, so once any block below
-- has opened a review with an adapter wired there is no process left here in which it is
-- empty. A review is opened and painted, because "nothing is recorded" is a claim about a
-- paint rather than about a module that has not been asked anything yet.
require("codereview").setup({ syntax = false, muted = { enabled = true, strength = 0.5 } })
view.open("branch")

describe("a review with no icon adapter wired", function()
  it("has painted a real diff to record nothing from", function()
    assert.is_true(#current().files > 0, "the scope is empty, so no file was ever named")
  end)

  it("records no group at all, which is the set as it was before this existed", function()
    assert.same({}, render.icon_groups())
  end)
end)

view.close()

--- With one wired ----------------------------------------------------------------

require("codereview").setup({
  syntax = false,
  muted = { enabled = true, strength = 0.5 },
  file_icon = function(_)
    return LUA, AZURE
  end,
})
view.open("branch")

describe("the group an icon adapter answered with", function()
  it("is readable from the render", function()
    assert.is_true(render.icon_groups()[AZURE] == true, vim.inspect(render.icon_groups()))
  end)

  it("is in the namespace a muted pane draws through", function()
    assert.same("CodeReviewMuted." .. AZURE, vim.api.nvim_get_hl(MUTED, { name = AZURE }).link)
  end)

  -- The hop the name cannot make on its own: the namespace holds a link, and a link reaching
  -- a group with no colour draws nothing at all.
  it("reaches a twin holding that group's colour pulled toward the background", function()
    local twin = vim.api.nvim_get_hl(0, { name = "CodeReviewMuted." .. AZURE, link = false })
    assert.same(0x007700, twin.fg)
  end)

  -- The control. Without it every case above passes on an implementation that put every group
  -- the editor knows into the namespace, which is the shape `hl.lua` refuses by design: a
  -- group with no variant falls back to its global definition, and that is what keeps an
  -- unfamiliar theme merely less muted rather than wrongly coloured.
  it("does not carry a group no adapter answered with in beside it", function()
    assert.same({}, vim.api.nvim_get_hl(MUTED, { name = STRANGER }))
  end)
end)

--- The cells a reviewer's screen holds --------------------------------------------

-- One child per reading, because `nvim__inspect_cell` is only honest on the first call a
-- process makes. Each opens the same review over this spec's fixture, in the unified layout at
-- 80x24, and reads the cell the glyph is drawn on -- found by the mark the review really
-- emitted rather than at an offset this spec expects it at.
--
-- The **frame**'s band is under that cell, so each reading names two things at once: the
-- glyph's own foreground, and the background of the row it is on. `333333` is a black
-- `Normal` background pulled 20% toward a white foreground, `00ee00` is the group the adapter
-- answered with -- and halfway to that backdrop the pair is `1a1a1a` and `007700`.
describe("the cell a reviewer's eye lands on", function()
  ---@param env table<string, string>
  ---@return string
  local function child(env)
    local run = vim
      .system({
        vim.v.progpath,
        "--clean",
        "-l",
        vim.fs.joinpath(h.root, "tests", "codereview", "glyph_mute_child.lua"),
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
    return (vim.trim(out):gsub(" at %d+,%d+$", ""))
  end

  local focused = child({ FOCUS = "diff" })
  local muted = child({ FOCUS = "tree" })

  it("draws the glyph in the colour the adapter's group holds while its pane has focus", function()
    assert.same(("cell %q fg=00ee00 bg=333333"):format(LUA), focused)
  end)

  -- **The whole of this ticket, and nothing said over group names can make it.** A glyph left
  -- out of the muted set reads `fg=00ee00` here, over a band that receded without it -- the one
  -- bright thing in a window that is meant to recede.
  it("mutes it with the pane, band and glyph together, once that pane loses focus", function()
    assert.same(("cell %q fg=007700 bg=1a1a1a"):format(LUA), muted)
  end)
end)

view.close()
