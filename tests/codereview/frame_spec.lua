-- **Frame**: the rule above and below a file's body, so a file has a visible end and not
-- only a visible beginning.
--
-- Two seams, and this file is the first of them. Which row carries which line-wide group is
-- pure data -- `render.build` takes a file list and hands back marks -- so it is asserted
-- here with no window on screen and no review open, the way the split layout's pane parity
-- and solo's index space already are. What no group name can say is whether the rule is
-- *painted*, and that is one cell inside a muted pane, read in `frame_child.lua`.
--
-- The claims that need a shape the flat fixture has not got are built by hand rather than by
-- a fixture of their own: a file with two hunks, so that "only the last pad row closes a
-- file" has something to fail on, and a review of one file. Everything else the fixture
-- already holds -- an expanded file, a binary file whose body is a note, and a last file.
--
-- Syntax is off. Nothing here reads a colour, and a treesitter pass on a fixture this file
-- never opens a window on would be work for no assertion.
local h = require("tests.helpers")

h.ui(120, 45)
local root = h.cd_fixture("mkfixture")

require("codereview").setup({ syntax = false })

local config = require("codereview.config")
local git = require("codereview.git")
local hl = require("codereview.hl")
local render = require("codereview.render")

local scope = assert(git.resolve_scope("branch", root))
local files = assert(git.collect(scope, root, { context = 3, untracked = true }))

--- What the frame draws in ------------------------------------------------------

local TOP = "CodeReviewFrameHeader"
local BOTTOM = "CodeReviewFramePad"
local TOP_REVIEWED = "CodeReviewFrameReviewed"
local BOTTOM_REVIEWED = "CodeReviewFramePadReviewed"
local FRAME_GROUPS = { TOP, BOTTOM, TOP_REVIEWED, BOTTOM_REVIEWED }

---@param files_ CRFile[]
---@param opts table|nil Overrides on top of a plain 80-column unified render
---@return CRRender after, CRRender|nil before
local function build(files_, opts)
  local cfg = config.get()
  return render.build(
    files_,
    vim.tbl_extend("force", {
      width = 80,
      icons = cfg.icons,
      expanded = {},
      reviewed = {},
      notes = {},
      types = cfg.types,
    }, opts or {})
  )
end

---@param path string
---@return integer
local function index_of(path)
  for i, f in ipairs(files) do
    if f.path == path then
      return i
    end
  end
  error("no such file in the fixture: " .. path)
end

---Every line-wide group a render put on one row, in the order the marks were emitted.
---
---A line-wide group is the whole of what the frame is: it is painted across the full window
---width past the end of the text, which is what makes a rule out of a group on a blank row.
---A mark with an `hl_group` and an `end_col` colours a run of characters and can be no rule
---at all, so those are not counted here and a case cannot pass on one by accident.
---@param rendered CRRender
---@param row integer 1-indexed
---@return string[]
local function line_groups(rendered, row)
  local out = {}
  for _, m in ipairs(rendered.marks) do
    if m.row == row - 1 and m.opts.line_hl_group then
      out[#out + 1] = m.opts.line_hl_group
    end
  end
  return out
end

---The last row a file spends: the row before the next file's header, or the last row drawn.
---
---Written out here rather than asked of `fade.body`, which answers the same question in the
---code under test -- a case that asked it would agree with it whatever it said.
---@param rendered CRRender
---@param fi integer
---@return integer
local function last_row(rendered, fi)
  local next_header = rendered.file_rows[fi + 1]
  return (next_header and next_header - 1) or #rendered.lines
end

---Every row of a render carrying any of the frame's four groups, ascending.
---@param rendered CRRender
---@return integer[]
local function framed_rows(rendered)
  local seen, out = {}, {}
  for _, m in ipairs(rendered.marks) do
    local group = m.opts.line_hl_group
    if group and vim.tbl_contains(FRAME_GROUPS, group) and not seen[m.row] then
      seen[m.row], out[#out + 1] = true, m.row + 1
    end
  end
  table.sort(out)
  return out
end

--- The groups the frame draws in -------------------------------------------------

describe("the frame's groups", function()
  -- The trap the whole family exists for. A `default = true` link copies its target's
  -- attributes wholesale, so a group linked to `Title` cannot be `Title` *and* an underline.
  it("are definitions and not links, or they could carry no attribute of their own", function()
    for _, group in ipairs(FRAME_GROUPS) do
      local def = vim.api.nvim_get_hl(0, { name = group })
      assert.is_nil(def.link, ("%s is a link: %s"):format(group, vim.inspect(def)))
      assert.is_truthy(def.sp, ("%s has no colour of its own: %s"):format(group, vim.inspect(def)))
    end
  end)

  -- A rule is an underline and the colour of that underline. A `line_hl_group` replaces every
  -- attribute it sets on every inline highlight the row carries, at any priority and in
  -- either direction, so a foreground here would draw the whole file header row in one
  -- colour -- the stat, the note count and a styled path with it. The cells at the foot of
  -- this file are what prove the consequence; this is the shape it rests on.
  it("carry no foreground and no background, so they replace nothing on the row", function()
    for _, group in ipairs(FRAME_GROUPS) do
      local def = vim.api.nvim_get_hl(0, { name = group })
      assert.is_nil(def.fg, ("%s carries a foreground: %s"):format(group, vim.inspect(def)))
      assert.is_nil(def.bg, ("%s carries a background: %s"):format(group, vim.inspect(def)))
    end
  end)

  -- On both terminals. `nvim_set_hl` lets cterm follow the true-color attributes only when
  -- the `cterm` table is absent, and `nvim_get_hl` hands one over for any source carrying a
  -- cterm attribute of its own -- `Title` is bold in Neovim's own default theme. Copied
  -- along, it would give a frame underlined on a true-color terminal and on no other.
  it("underline, in gui and in cterm alike", function()
    for _, group in ipairs(FRAME_GROUPS) do
      local def = vim.api.nvim_get_hl(0, { name = group })
      assert.is_true(def.underline == true, ("%s: %s"):format(group, vim.inspect(def)))
      assert.is_true((def.cterm or {}).underline == true, ("%s: %s"):format(group, vim.inspect(def)))
    end
  end)

  -- `overline` is accepted by this API and comes back in the `cterm` table, so a bottom edge
  -- drawn with it looks right here and is invisible on the terminals that ignore the
  -- sequence -- with nothing to report it.
  it("use no overline anywhere", function()
    for _, group in ipairs(FRAME_GROUPS) do
      local def = vim.api.nvim_get_hl(0, { name = group })
      assert.is_nil(def.overline, ("%s: %s"):format(group, vim.inspect(def)))
      assert.is_nil((def.cterm or {}).overline, ("%s: %s"):format(group, vim.inspect(def)))
    end
  end)

  -- The failure this cannot be caught by looking: a group named anywhere else draws at full
  -- brightness in a pane without focus, and nothing says so.
  it("are named where the muting derives its namespace from", function()
    local named = hl.groups()
    for _, group in ipairs(FRAME_GROUPS) do
      assert.is_true(vim.tbl_contains(named, group), ("%s is in no table hl.groups() reads"):format(group))
    end
  end)

  it("each have a fade twin, and the twin keeps the underline", function()
    for _, group in ipairs(FRAME_GROUPS) do
      local twin = assert(hl.blended("faded", group), ("%s has no fade twin"):format(group))
      local def = vim.api.nvim_get_hl(0, { name = twin })
      assert.is_true(def.underline == true, ("%s: %s"):format(twin, vim.inspect(def)))
    end
  end)

  -- Each pair comes from one source, so a file's top edge and its bottom edge cannot
  -- disagree about its state. Read as colours rather than as names: the names are this
  -- file's own constants and would agree with themselves.
  it("draw each pair's two edges in one colour", function()
    assert.same(
      vim.api.nvim_get_hl(0, { name = TOP }).sp,
      vim.api.nvim_get_hl(0, { name = BOTTOM }).sp,
      "the two edges of an unreviewed file's frame are two colours"
    )
    assert.same(
      vim.api.nvim_get_hl(0, { name = TOP_REVIEWED }).sp,
      vim.api.nvim_get_hl(0, { name = BOTTOM_REVIEWED }).sp,
      "the two edges of a reviewed file's frame are two colours"
    )
  end)

  -- Guards the pair above: with one source for all four, every assertion about which pair a
  -- file takes would pass over one colour.
  it("draw a reviewed file's frame in a different colour from an unreviewed one's", function()
    assert.is_true(
      vim.api.nvim_get_hl(0, { name = TOP }).sp ~= vim.api.nvim_get_hl(0, { name = TOP_REVIEWED }).sp,
      "both pairs resolve to one colour, so no case below can tell them apart"
    )
  end)
end)

--- An expanded file --------------------------------------------------------------

describe("an expanded file", function()
  local fi = index_of("src/main.lua")
  local after = build(files)
  local header = assert(after.file_rows[fi])
  local closing = last_row(after, fi)

  it("really is expanded, and really has a body", function()
    assert.is_true(closing > header + 1, "the file spends no rows between its two edges")
  end)

  it("carries the top edge on its header row", function()
    assert.same({ TOP }, line_groups(after, header))
  end)

  -- The row is blank and it is a pad row. Both matter: a rule needs a line-wide group on a
  -- row with nothing on it to be a rule from the first column to the last, and a pad row is
  -- a row the diff had anyway.
  it("closes on the blank pad row after its last hunk", function()
    assert.same("", after.lines[closing])
    assert.same("pad", after.anchors[closing].kind)
    assert.same({ BOTTOM }, line_groups(after, closing))
  end)

  it("puts no frame group on any row between its two edges", function()
    for row = header + 1, closing - 1 do
      for _, group in ipairs(line_groups(after, row)) do
        assert.is_false(vim.tbl_contains(FRAME_GROUPS, group), ("row %d carries %s"):format(row, group))
      end
    end
  end)

  -- No anchor is created or moved: both edges land on rows the diff had anyway, and on the
  -- kinds those rows already were. A row of the frame's own would be a `nil` here, and a
  -- reviewer could put a cursor on a thing that is not part of the diff.
  it("draws its two edges on the file's own header anchor and its own pad anchor", function()
    assert.same({ kind = "file", file = fi }, after.anchors[header])
    assert.same("pad", after.anchors[closing].kind)
    assert.same(fi, after.anchors[closing].file)
  end)
end)

--- A collapsed file, and a reviewed one ------------------------------------------

describe("a collapsed file", function()
  local fi = index_of("src/main.lua")
  local after = build(files, { expanded = { ["src/main.lua"] = false } })
  local header = assert(after.file_rows[fi])

  it("really is collapsed, and spends its header row and a pad row", function()
    assert.same(header + 1, last_row(after, fi))
    assert.same("", after.lines[header + 1])
  end)

  it("carries the top edge", function()
    assert.same({ TOP }, line_groups(after, header))
  end)

  -- Two rules with nothing between them read as a broken frame rather than as a closed
  -- file, so a collapsed file gets one rule and not two.
  it("puts no rule on its pad row", function()
    assert.same({}, line_groups(after, header + 1))
  end)
end)

describe("a reviewed file, which collapses", function()
  local fi = index_of("src/main.lua")
  local after = build(files, { reviewed = { ["src/main.lua"] = "abc123" } })
  local header = assert(after.file_rows[fi])

  it("really collapsed without anything being said about expansion", function()
    assert.same(header + 1, last_row(after, fi))
  end)

  it("carries the reviewed file's top edge and no second rule", function()
    assert.same({ TOP_REVIEWED }, line_groups(after, header))
    assert.same({}, line_groups(after, header + 1))
  end)
end)

-- `za` expands a file without unmarking it, so this is what that key is for rather than an
-- oddity -- and it is the one arrangement in which a frame could take its top edge from one
-- source and its bottom edge from another.
describe("a reviewed file a reviewer has expanded again", function()
  local fi = index_of("src/main.lua")
  local after = build(files, {
    reviewed = { ["src/main.lua"] = "abc123" },
    expanded = { ["src/main.lua"] = true },
  })
  local header = assert(after.file_rows[fi])
  local closing = last_row(after, fi)

  it("really is reviewed and really has a body", function()
    assert.is_true(closing > header + 1, "the file was not expanded")
  end)

  it("draws both edges in the reviewed pair, so they agree about the file", function()
    assert.same({ TOP_REVIEWED }, line_groups(after, header))
    assert.same({ BOTTOM_REVIEWED }, line_groups(after, closing))
  end)
end)

--- The shapes a review can be ----------------------------------------------------

describe("the last file in a review", function()
  local after = build(files)
  local fi = #files

  it("really is last, and the render ends on its closing row", function()
    assert.same(#after.lines, last_row(after, fi))
  end)

  it("is framed like every other", function()
    assert.same({ TOP }, line_groups(after, assert(after.file_rows[fi])))
    assert.same({ BOTTOM }, line_groups(after, #after.lines))
  end)
end)

describe("a review with one file", function()
  local one = { files[index_of("src/main.lua")] }
  local after = build(one)

  it("really holds one file", function()
    assert.same(1, #vim.tbl_keys(after.file_rows))
  end)

  it("is framed, so the rule is not a thing that only appears in a crowd", function()
    assert.same({ 1, #after.lines }, framed_rows(after))
    assert.same({ TOP }, line_groups(after, 1))
    assert.same({ BOTTOM }, line_groups(after, #after.lines))
  end)
end)

describe("a review with no files", function()
  local after, before = build({}, { layout = "split", before_width = 80 })

  it("draws nothing at all, and raises nothing", function()
    assert.same({}, after.lines)
    assert.same({}, framed_rows(after))
    assert.same({}, framed_rows(assert(before)))
  end)
end)

--- A file with more than one hunk ------------------------------------------------

-- Built by hand: every file the flat fixture carries has exactly one hunk, so over that
-- fixture "the last hunk's pad row" and "every hunk's pad row" draw the same thing and a
-- case cannot tell them apart.
describe("a file with two hunks", function()
  ---@type CRFile[]
  local two = {
    {
      path = "src/two.lua",
      status = "M",
      added = 2,
      removed = 0,
      binary = false,
      hunks = {
        {
          header = "@@ -1 +1 @@",
          heading = "",
          old_start = 1,
          new_start = 1,
          lines = { { side = "add", new = 1, text = "first" } },
        },
        {
          header = "@@ -9 +9 @@",
          heading = "",
          old_start = 9,
          new_start = 9,
          lines = { { side = "add", new = 9, text = "second" } },
        },
      },
    },
  }
  local after = build(two)
  local closing = #after.lines

  it("really drew two hunks, each with a pad row after it", function()
    assert.same(2, #after.hunk_rows)
    local pads = {}
    for row, a in pairs(after.anchors) do
      if a.kind == "pad" then
        pads[#pads + 1] = row
      end
    end
    assert.same(2, #pads)
  end)

  -- A rule on every pad row would read as a file boundary per hunk, which says the file
  -- ended twice.
  it("closes on the last hunk's pad row alone", function()
    assert.same({ 1, closing }, framed_rows(after))
    assert.same({ BOTTOM }, line_groups(after, closing))
  end)
end)

-- Binary, a rename with no content change, a mode-only change: a file with no hunks and a
-- line saying why. That line is the body, so the pad row after it closes one -- and it is
-- emitted by a branch of its own, which is where a frame written for the hunk walk alone
-- would stop.
describe("a file whose whole body is a note", function()
  local fi = index_of("src/untracked.bin")
  local after = build(files)
  local header = assert(after.file_rows[fi])
  local closing = last_row(after, fi)

  it("really has no hunks and really draws a note", function()
    assert.same(0, #files[fi].hunks)
    assert.is_truthy(after.lines[header + 1]:find("binary", 1, true), after.lines[header + 1])
  end)

  it("is framed on both edges", function()
    assert.same({ TOP }, line_groups(after, header))
    assert.same({ BOTTOM }, line_groups(after, closing))
  end)
end)

--- Both panes of a split ---------------------------------------------------------

describe("both panes of a split layout", function()
  local after, before = build(files, { layout = "split", before_width = 80 })
  before = assert(before)

  it("really drew two panes of the same height", function()
    assert.same(#after.lines, #before.lines)
  end)

  it("frame the same rows", function()
    assert.same(framed_rows(after), framed_rows(before))
  end)

  it("frame every row in the same group, so the two images stay comparable row for row", function()
    for _, row in ipairs(framed_rows(after)) do
      assert.same(line_groups(after, row), line_groups(before, row), ("row %d"):format(row))
    end
  end)

  it("frame every file, top and bottom", function()
    local want = {}
    for fi = 1, #files do
      want[#want + 1] = assert(after.file_rows[fi])
      want[#want + 1] = last_row(after, fi)
    end
    table.sort(want)
    assert.same(want, framed_rows(after))
  end)
end)

--- What a screen really holds ---------------------------------------------------

-- Everything above is group names on marks. A mark set can be complete, correct and
-- invisible: a group name cannot say whether the rule was painted, in what colour, or what
-- it did to the marks beneath it. These readings are taken from the screen.
--
-- One child per cell, because `nvim__inspect_cell` is honest only on the first call a process
-- makes.
describe("the cells a reviewer's screen really holds", function()
  ---@param cell string
  ---@return string
  local function child(cell)
    local run = vim
      .system({
        vim.v.progpath,
        "--clean",
        "-l",
        vim.fs.joinpath(h.root, "tests", "codereview", "frame_child.lua"),
      }, {
        cwd = root,
        text = true,
        env = {
          FIXTURE = root,
          CELL = cell,
          XDG_STATE_HOME = vim.fn.tempname() .. "-state",
          GIT_CONFIG_GLOBAL = "/dev/null",
          GIT_CONFIG_SYSTEM = "/dev/null",
        },
      })
      :wait(60000)
    -- `nvim -l` sends print to stderr, so read both streams rather than guessing.
    local out = (run.stdout or "") .. (run.stderr or "")
    assert(run.code == 0, out)
    return (vim.trim(out):gsub(" at %d+,%d+$", ""))
  end

  local covered = child("covered")
  local bare = child("bare")
  local pad = child("pad")

  --- The bottom rule, in a pane without focus --------------------------------------

  -- 0x00ee00 is what `Title` is set to in the child, and 0x007700 is that halfway to a black
  -- `Normal` background -- the muting's own arithmetic and nothing else's. A frame group the
  -- namespace did not name would read `sp=00ee00` here, on a screen that looks wrong to a
  -- reviewer and right to every assertion made over names.
  it("mutes the bottom rule with its pane, and keeps its underline out there", function()
    assert.same('cell " " fg=808080 sp=007700 underline=true', pad)
  end)

  --- The top rule, and what it must not do to the row ------------------------------

  -- The defect this shape exists for. A `line_hl_group` replaces every attribute it sets on
  -- every inline highlight the row carries, at any priority and in either direction -- so a
  -- frame group with a foreground draws the whole header row in the frame's colour and the
  -- marks beneath it are emitted, correct and invisible.
  --
  -- `covered` is a cell under a column mark on the header row; `bare` is a cell on the same
  -- row that no column mark covers.
  it("leaves a column mark on the header row its own colour", function()
    assert.same('cell "r" fg=2266aa sp=00ee00 underline=true', covered)
  end)

  it("colours the rest of that row in the header's own group", function()
    assert.same('cell "g" fg=00ee00 sp=00ee00 underline=true', bare)
  end)

  -- **The claim the two absolute readings cannot make between them.** Each of them passes
  -- for one reason and fails for two: a frame that flattens the row makes both cells the
  -- frame's colour, and a column mark that is never emitted makes both cells the header's.
  -- The absolute values name which failure it was; this says there was one.
  it("draws the two cells in different colours, which is the whole of the claim", function()
    local function fg_of(reading)
      return assert(reading:match("fg=(%x+)"), reading)
    end
    assert.is_true(
      fg_of(covered) ~= fg_of(bare),
      ("the header row is one flat colour: %s against %s"):format(covered, bare)
    )
  end)

  -- Both cells carry the rule, so it is continuous across a row whose colours are not.
  it("runs the rule across the whole row whatever each cell is coloured in", function()
    for _, reading in ipairs({ covered, bare }) do
      assert.is_truthy(reading:find("underline=true", 1, true), reading)
      assert.is_truthy(reading:find("sp=00ee00", 1, true), reading)
    end
  end)
end)

--- What the frame costs ----------------------------------------------------------

-- The whole of what a paint gains, stated as a number rather than reasoned about: the header
-- row's mark existed already and only changed which group it names, so the frame's cost is
-- one mark per file with a body.
describe("the marks the frame adds", function()
  ---@param rendered CRRender
  ---@return integer
  local function bottoms(rendered)
    local n = 0
    for _, m in ipairs(rendered.marks) do
      local group = m.opts.line_hl_group
      if group == BOTTOM or group == BOTTOM_REVIEWED then
        n = n + 1
      end
    end
    return n
  end

  it("is one per file, where every file has a body", function()
    assert.same(#files, bottoms(build(files)))
  end)

  -- The same review with one file closed. A count that did not move would say the collapsed
  -- file kept a bottom edge, which is the thing a collapsed file must not have.
  it("is one fewer with a file collapsed", function()
    assert.same(#files - 1, bottoms(build(files, { expanded = { ["src/main.lua"] = false } })))
  end)
end)
