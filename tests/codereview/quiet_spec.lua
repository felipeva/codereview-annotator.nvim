-- Where the review's three quiet states meet.
--
-- **Faded** is a file the cursor is not in. **Dimmed** is an archived **entry** drawn on the
-- diff. **Muted** is a review window without focus. Two of them meet inside a faded file --
-- an entry drawn there, and a faded file drawn in a pane that has lost focus -- and each
-- meeting already behaves as it should. Each of them holds by construction rather than by
-- intent, and until this file none of them was asserted anywhere.
--
-- That is the shape #108 met in the winbar: a behavior nothing announces the end of. The
-- fade renames `hl_group` and `line_hl_group` and returns early for a mark that carries
-- neither, so it never reaches the chunks an entry's virtual lines are drawn from. The muted
-- namespace links the groups `hl.groups()` names, and the faded family is not among them, so
-- a faded row finds no entry there and falls back to its global definition. Neither fact is
-- written down in a line anyone would think to keep.
--
-- Asserted at the cell, in `quiet_child.lua`, one process per reading -- a group name cannot
-- tell a faded row from a bright one, and it cannot tell one blend from two. The blocks in
-- this process assert the mechanism each reading rests on, which is the only level that can
-- say *why* a color stayed where it is.
--
-- The one thing no cell can show: `CodeReviewFaded.CodeReviewAdd` is absent from the muted
-- namespace and is a definition with a color in it, not a link reaching nothing. An absent
-- entry falls back and draws; a dead link draws nothing at all. The claim rests on that
-- difference, so both halves are read here.
local h = require("tests.helpers")

local annotate = require("codereview.annotate")
local view = require("codereview.view")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

-- Colors with even channels, so a blend has no rounding in it and the numbers can be read
-- at a glance.
vim.o.termguicolors = true
vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x004400 })

---What the name of every blended group in the fade's family starts with.
local FADED = "CodeReviewFaded."

-- The plugin's own namespace, by name: `nvim_create_namespace` hands back the id a name
-- already has, so this is a lookup rather than a second namespace.
local MUTED = vim.api.nvim_create_namespace("codereview_muted")

-- The file every entry below is put in, and the file the cursor spends most of this spec
-- outside of. Not the first file of the review, so the cursor has somewhere else to be.
local PATH = "src/main.lua"

require("codereview").setup({
  layout = "unified",
  syntax = true,
  -- Two strengths that cannot be mistaken for each other, for the reason the child gives:
  -- one blend, the other blend and both blends are three different colors.
  muted = { enabled = true, strength = 0.25 },
  faded = { enabled = true, strength = 0.5 },
  types = { { name = "bug", key = "b", icon = "!", hl = "CodeReviewBug", label = "Bugs" } },
  compose = function(_, on_accept)
    on_accept(nil, "a note inside a faded file")
  end,
  send = function()
    return true
  end,
})

view.open("branch")
local V = assert(view.current(), "no review view open")

---Every highlight group the diff drew on rows `first`..`last`, as a set.
---@param first integer 1-indexed
---@param last integer 1-indexed, inclusive
---@return table<string, boolean>
local function drawn(first, last)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(V.buf, h.NS, { first - 1, 0 }, { last - 1, -1 }, { details = true })) do
    local group = m[4].hl_group or m[4].line_hl_group
    if group then
      out[group] = true
    end
  end
  return out
end

---The plugin's groups on one file's body, split by whether the fade renamed them.
---
---The span is written out from the render rather than asked of `fade.lua`: a case that asked
---the code under test where a file starts would agree with it whatever it answered.
---
---A group with **nothing to blend** counts as neither. The fade hands back nothing for it and
---emits it as it stands, which is the nil contract rather than a row left bright -- see the
---same rule, argued at more length, in `faded_spec`. The **pad** row's group is the one here:
---since a file's header row became a **band** it carries no gui colour, only the rule a
---terminal without true colour still draws.
---@param fi integer
---@return string[] faded, string[] bright
local function file_groups(fi)
  local next_header = V.render.file_rows[fi + 1]
  local first = V.render.file_rows[fi] + 1
  local last = (next_header and next_header - 1) or #V.render.lines
  local faded, bright = {}, {}
  for group in pairs(drawn(first, last)) do
    if group:sub(1, #FADED) == FADED then
      faded[#faded + 1] = group
    elseif group:sub(1, #"CodeReview") == "CodeReview" and require("codereview.hl").blended("faded", group) then
      bright[#bright + 1] = group
    end
  end
  table.sort(faded)
  table.sort(bright)
  return faded, bright
end

---The rows of `PATH` carrying a diff line of one side, lowest first.
---@param side string
---@return integer[]
local function rows_of(side)
  local rows = {}
  for row, a in pairs(V.render.anchors) do
    if a.kind == "line" and V.files[a.file].path == PATH then
      local ln = V.files[a.file].hunks[a.hunk].lines[a.line]
      if ln.side == side then
        rows[#rows + 1] = row
      end
    end
  end
  table.sort(rows)
  return rows
end

---Put the cursor on `row` and raise the event a reviewer's keystroke would.
---
---Neither `nvim_win_set_cursor` nor a `normal!` motion raises `CursorMoved` under a headless
---Neovim -- see tests/README.md -- so a case that only moved the cursor would be asserting
---against a crossing that never happened.
---@param row integer
local function move_to(row)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
end

local target = assert(h.file_index(V, PATH))

-- One entry already dispatched and one still queued, each on a row of its own inside the file
-- under test. The archived one goes first: a submit empties the queue, and what is queued
-- afterwards stays queued.
local archived_row = assert(rows_of("ctx")[1], "no context line to put an archived entry on")
move_to(archived_row)
annotate.annotate("bug")
view.submit()

local queued_row = assert(rows_of("add")[1], "no added line to put a queued entry on")
move_to(queued_row)
annotate.annotate("bug")

-- Out of that file, into the first, which is what fades it.
move_to(V.render.file_rows[1])

--- An entry inside a faded file ----------------------------------------------------

describe("a queued entry and an archived one inside a faded file", function()
  -- Without these the block below reads a bright file and calls the answer a fade rule.
  it("really is inside a file the cursor is not in, and that file really is faded", function()
    assert.is_true(target ~= 1, "the file under test is the file the cursor is in")
    assert.same(1, view.current_file())
    local faded, bright = file_groups(target)
    assert.same({}, bright)
    assert.is_true(#faded > 0, "the file under test carries no marks at all")
  end)

  it("draws both of them, on rows of their own", function()
    assert.is_true(archived_row ~= queued_row, ("both entries are on row %d"):format(queued_row))
    assert.same(2, #h.virt_marks(V), "the review is not drawing exactly two entries")
  end)

  -- The mechanism the whole claim rests on. An entry hangs *under* the row it is about, and
  -- its colors are in that mark's chunks. The fade renames `hl_group` and `line_hl_group`,
  -- which is what a mark puts on the row it sits on, and returns early for a mark that
  -- carries neither.
  it("puts no group of its own on the row it hangs under, so the fade has nothing to rename", function()
    for _, m in ipairs(h.virt_marks(V)) do
      assert.is_nil(m[4].hl_group)
      assert.is_nil(m[4].line_hl_group)
    end
  end)

  it("draws the queued one in its annotation type's group and the archived one in the archive's", function()
    local groups = h.virt_groups(V)
    assert.is_true(groups.CodeReviewBug, "the queued entry does not carry its type's group")
    assert.is_true(groups.CodeReviewArchived, "the archived entry does not carry the archive's group")
    assert.is_true(groups.CodeReviewArchivedNote, "the archived entry's prose does not carry the archive's group")
  end)

  -- *Already sent* and *not the file I am in* stay two statements, which is the rule this
  -- project keeps for **stale** and **touched** as well.
  it("blends neither of them", function()
    local blended = {}
    for group in pairs(h.virt_groups(V)) do
      if group:sub(1, #FADED) == FADED then
        blended[#blended + 1] = group
      end
    end
    assert.same({}, blended)
  end)

  it("draws exactly what it draws with the cursor inside that same file", function()
    local away = h.virt_groups(V)
    move_to(V.render.file_rows[target])
    assert.same(target, view.current_file())
    local inside = h.virt_groups(V)
    move_to(V.render.file_rows[1])
    assert.same(1, view.current_file())
    assert.same(away, inside)
    assert.same(away, h.virt_groups(V))
  end)
end)

--- A faded row and the muted namespace ---------------------------------------------

describe("the groups a faded row carries and the namespace a muted pane draws through", function()
  -- The guard every case below needs: with nothing in the namespace at all, "the faded family
  -- is not in it" holds over an empty table.
  it("links the group that faded row's color is blended from", function()
    assert.is_truthy(vim.api.nvim_get_hl(MUTED, { name = "CodeReviewAdd" }).link, "the namespace links nothing")
  end)

  it("draws a faded changed line in the fade's twin of that group, not in the group itself", function()
    local faded, bright = file_groups(target)
    assert.is_true(vim.tbl_contains(faded, FADED .. "CodeReviewAdd"), table.concat(faded, ", "))
    assert.same({}, bright)
  end)

  it("holds no entry for the twin, so a muted pane leaves it alone", function()
    assert.same({}, vim.api.nvim_get_hl(MUTED, { name = FADED .. "CodeReviewAdd" }))
  end)

  -- What the case above is worth nothing without, and what no cell reading can show. An
  -- absent entry falls back to the twin's global definition and draws it; a link reaching
  -- nothing draws nothing at all. Nobody is to "fix" the absence by adding a link.
  it("leaves a definition with a color in it to fall back to, not a dead link", function()
    local def = vim.api.nvim_get_hl(0, { name = FADED .. "CodeReviewAdd", link = false })
    assert.is_truthy(def.bg, "the fade's twin of a changed line holds no color")
    assert.is_nil(def.link)
  end)
end)

--- The cells a reviewer's screen holds ----------------------------------------------

-- One child per reading, because `nvim__inspect_cell` is only honest on the first call a
-- process makes. Each opens the same review over this spec's fixture, in the unified layout
-- at 80x24, puts one archived entry and one queued entry inside `src/main.lua`, and reads one
-- cell of it: the marker of either entry, or the first token the replay painted on an added
-- line of the code around them.
--
-- The fade pulls a color half of the way to the background and the window rule a quarter of
-- the way, so the four numbers a changed line's token can hold are all different: `ec0000` on
-- `004400` bright, `760000` on `002200` faded, `b10000` on `003300` muted, and `590000` on
-- `001a00` had it been both.
describe("the cell under a reviewer's eye", function()
  ---@param env table<string, string>
  ---@return string
  local function child(env)
    local run = vim
      .system({
        vim.v.progpath,
        "--clean",
        "-l",
        vim.fs.joinpath(h.root, "tests", "codereview", "quiet_child.lua"),
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

  local code_away = child({ CELL = "code", CURSOR = "out" })
  local code_inside = child({ CELL = "code", CURSOR = "in" })
  local code_muted = child({ CELL = "code", CURSOR = "out", FOCUS = "tree" })
  local current_muted = child({ CELL = "code", CURSOR = "in", FOCUS = "tree" })
  local note_away = child({ CELL = "note", CURSOR = "out" })
  local note_inside = child({ CELL = "note", CURSOR = "in" })
  local gone_away = child({ CELL = "archived", CURSOR = "out" })
  local gone_inside = child({ CELL = "archived", CURSOR = "in" })

  -- The two readings every claim below is measured against: the same token of the same file,
  -- at full strength and faded. Without them a bright entry is only known to be bright, not
  -- to be bright on a screen where anything receded at all.
  it("fades the code of a file the cursor is not in, and leaves the file it is in alone", function()
    assert.same("cell l fg=760000 bg=002200", code_away)
    assert.same("cell l fg=ec0000 bg=004400", code_inside)
  end)

  it("keeps a queued entry inside that faded file at full strength", function()
    assert.same("cell ! fg=00ec00 bg=440044", note_away)
  end)

  it("gives it exactly the color it has in a file that is not faded", function()
    assert.same(note_inside, note_away)
  end)

  -- The archive's own dimness, and no second blend over it: *already sent* and *not the file
  -- I am in* stay two statements.
  it("leaves an archived entry inside that faded file the dimness it already has", function()
    assert.same("cell ! fg=0000ec bg=444400", gone_away)
  end)

  it("gives that one exactly the color it has in a file that is not faded too", function()
    assert.same(gone_inside, gone_away)
  end)

  -- The window rule answers alone. Two blends over each other would read `590000` on
  -- `001a00` here.
  it("fades a file once when its pane has lost focus, not twice", function()
    assert.same(code_away, code_muted)
  end)

  -- And the window rule is untouched by any of it: the file the cursor *is* in still mutes
  -- with its pane. Without this the case above holds for a namespace that reaches nothing.
  it("mutes the file the cursor is in when that pane loses focus", function()
    assert.same("cell l fg=b10000 bg=003300", current_muted)
    assert.is_true(current_muted ~= code_inside, "the muted pane is no dimmer than the focused one")
  end)
end)
