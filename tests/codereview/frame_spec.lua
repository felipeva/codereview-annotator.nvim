-- **Frame**: what marks a file out in a review -- a **band** filling its header row, and, on
-- the terminal that can compute no band, the rule this began as.
--
-- Two seams, and this file is the first of them. Which row carries which line-wide group is
-- pure data -- `render.build` takes a file list and hands back marks -- so it is asserted
-- here with no window on screen and no review open, the way the split layout's pane parity
-- and solo's index space already are. What no group name can say is whether the band is
-- *painted*, in what colour, and what it does to the marks under it, and that is four cells
-- read in `frame_child.lua`.
--
-- The claims that need a shape the flat fixture has not got are built by hand rather than by
-- a fixture of their own: a file with two hunks, so that "only the last pad row closes a
-- file" has something to fail on, and a review of one file. Everything else the fixture
-- already holds -- an expanded file, a binary file whose body is a note, a file with no
-- pre-image, and a last file.
--
-- Syntax is off. Nothing here reads a colour off a screen, and a treesitter pass on a fixture
-- this file never opens a window on would be work for no assertion.
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

-- The two halves of the family, which no longer say the same thing. A **band** fills a file's
-- header row; a **pad** group holds the blank row that closes the body, and on a true-colour
-- terminal it holds it with nothing at all.
local BANDS = { TOP, TOP_REVIEWED }
local PADS = { BOTTOM, BOTTOM_REVIEWED }

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
---width past the end of the text, which is what makes a band out of a group on a row the text
---does not fill. A mark with an `hl_group` and an `end_col` colours a run of characters and
---can be no band at all, so those are not counted here and a case cannot pass on one by
---accident.
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

---Every column mark's group on one row -- the marks the band is *under*.
---@param rendered CRRender
---@param row integer 1-indexed
---@return string[]
local function column_groups(rendered, row)
  local out = {}
  for _, m in ipairs(rendered.marks) do
    if m.row == row - 1 and m.opts.hl_group then
      out[#out + 1] = m.opts.hl_group
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

--- The colours the band is judged by ---------------------------------------------

---@param name string
---@return table
local function def(name)
  return vim.api.nvim_get_hl(0, { name = name })
end

---@param color integer 0xRRGGBB
---@return integer[]
local function channels(color)
  return { math.floor(color / 65536) % 256, math.floor(color / 256) % 256, color % 256 }
end

---How far two colours stand apart in their closest channel.
---
---The closest and not the average: a band that matched the cursor line in one channel and
---missed in two would average to a comfortable number and read as a shade of it on screen.
---@param a integer 0xRRGGBB
---@param b integer 0xRRGGBB
---@return integer
local function distance(a, b)
  local ca, cb = channels(a), channels(b)
  return math.min(math.abs(ca[1] - cb[1]), math.abs(ca[2] - cb[2]), math.abs(ca[3] - cb[3]))
end

---How far the band must stand off `CursorLine`, per channel, to have cleared it.
---
---**Calibrated by the band that was rejected, never by the one that shipped.** An inequality
---is what this started as, and an inequality cannot make the claim: the rejected prototype
---passes `~=` at four units, so the case would have passed over the exact rendering it was
---written to catch. The measurements, on Neovim's own default theme:
---
---    10%  dark  282a30 against 2c2e33 -> 4, 4, 3      the band that was rejected as invisible
---    10%  light ccced5 against c4c6cd -> 8, 8, 8      the same band, on the other side
---    20%  dark  3d3f44 against 2c2e33 -> 17, 17, 17   what ships
---    20%  light b7b9c1 against c4c6cd -> 13, 13, 12   what ships
---
---So the floor sits above the rejected band on **both** themes and below the shipped one on
---both -- ten is the round number in that gap. A floor of eight would let the rejected band
---through on a light theme, which is the failure this exists to name.
---
---It is a floor and not a target. What the strength is worth is judged by eye; this is the
---distance below which nobody needs to look, because the two colours are the same colour.
local CLEARANCE = 10

---Whether `band` sits between `bg` and `fg` on every channel, and on neither endpoint.
---
---**Strictly**, which is the half that catches a stale computation. A band pulled a fifth of
---the way cannot land *on* either colour it was pulled between, so a reading that does is a
---band computed against something other than the `Normal` in front of it -- which is exactly
---what a memo cleared at the end of the pass would give on a colorscheme change. A channel
---where the two endpoints agree is skipped: there is no interval there to be inside of.
---@param band integer
---@param bg integer
---@param fg integer
---@return boolean ok, string why
local function between(band, bg, fg)
  local cband, cbg, cfg = channels(band), channels(bg), channels(fg)
  for i = 1, 3 do
    if cbg[i] ~= cfg[i] then
      local lo, hi = math.min(cbg[i], cfg[i]), math.max(cbg[i], cfg[i])
      if cband[i] <= lo or cband[i] >= hi then
        return false, ("channel %d is %d, not inside %d..%d"):format(i, cband[i], lo, hi)
      end
    end
  end
  return true, ""
end

--- The groups the frame draws in -------------------------------------------------

describe("the frame's groups", function()
  -- The trap the whole family exists for. A `default = true` link copies its target's
  -- attributes wholesale, so a group linked to `Title` cannot be `Title` *and* a background
  -- no theme defines.
  it("are definitions and not links, or they could carry no attribute of their own", function()
    for _, group in ipairs(FRAME_GROUPS) do
      assert.is_nil(def(group).link, ("%s is a link: %s"):format(group, vim.inspect(def(group))))
    end
  end)

  it("fill a file's header row with a background of their own", function()
    for _, group in ipairs(BANDS) do
      assert.is_truthy(def(group).bg, ("%s has no band to fill with: %s"):format(group, vim.inspect(def(group))))
    end
  end)

  -- A band is a background and nothing else. A `line_hl_group` replaces every attribute it
  -- sets on every inline highlight the row carries, at any priority and in either direction,
  -- so a foreground here would draw the whole file header row in one colour -- the path's two
  -- halves, the `+N -M` stat, the note count and a host's glyph alike. A background is the one
  -- attribute the row does not already own. The cells at the foot of this file prove the
  -- consequence; this is the shape it rests on.
  it("carry no foreground, so they replace nothing on the row", function()
    for _, group in ipairs(FRAME_GROUPS) do
      assert.is_nil(def(group).fg, ("%s carries a foreground: %s"):format(group, vim.inspect(def(group))))
    end
  end)

  -- The measurement the strength was chosen by, asserted as the distance it is about rather
  -- than as a colour or as a bare inequality -- see `CLEARANCE`, which carries the readings.
  -- Every header row would otherwise read as permanently selected, and the cursor would
  -- disappear on the one row a reviewer lands on when they jump to a file. Theme-relative, so
  -- a theme that moves its cursor line is caught rather than trusted.
  it("stand clear of the theme's cursor line, by a distance and not by a hair", function()
    local cursor = assert(def("CursorLine").bg, "the theme under test lights no cursor line")
    for _, group in ipairs(BANDS) do
      -- Asserted off a band that is really there. A group carrying no background at all
      -- stands a long way from the cursor line, and a case that let that through would pass
      -- on the very rendering this one is here to replace.
      local band = assert(def(group).bg, ("%s has no band to compare"):format(group))
      assert.is_true(
        distance(band, cursor) >= CLEARANCE,
        ("%s is %d from CursorLine in its closest channel, under %d: %06x against %06x"):format(
          group,
          distance(band, cursor),
          CLEARANCE,
          band,
          cursor
        )
      )
    end
  end)

  it("fill in a background `Normal` does not have, or the band is one step off nothing", function()
    local normal = assert(def("Normal").bg, "the theme under test gives Normal no background")
    for _, group in ipairs(BANDS) do
      local band = assert(def(group).bg, ("%s has no band to compare"):format(group))
      assert.is_true(band ~= normal, ("%s is Normal's own background: %06x"):format(group, normal))
    end
  end)

  -- **Derived from `Normal`, never from `CursorLine`** -- deriving it from the cursor line
  -- makes the collision above the design. The arithmetic is not repeated here: a case that
  -- repeated it would agree with the code whatever the code said. What is asserted is the
  -- property that arithmetic has -- see `between` -- and the exact strength is read off a
  -- painted cell at the foot of this file, in a process whose `Normal` is a pair of numbers it
  -- set itself.
  it("land strictly between `Normal`'s background and `Normal`'s foreground", function()
    local normal = def("Normal")
    assert.is_truthy(normal.bg and normal.fg, "the theme under test gives Normal no pair to pull between")
    for _, group in ipairs(BANDS) do
      local ok, why = between(assert(def(group).bg), normal.bg, normal.fg)
      assert.is_true(ok, ("%s: %s"):format(group, why))
    end
  end)

  -- One computation at one strength. A reviewed file is not told from an unreviewed one by
  -- the band, so there is no second strength to keep in step with the first.
  it("fill a reviewed file's header row with the same band as any other", function()
    assert.same(def(TOP).bg, def(TOP_REVIEWED).bg)
  end)

  -- What keeps that one colour from costing the reviewed state its shade: what says a file is
  -- done is the column mark under the band, which is a different group in a different colour.
  -- Guards the case above -- without it, "both bands are one colour" could be a review that
  -- had stopped saying which files are done.
  it("leave a reviewed file's own colour to the column mark under them", function()
    local plain = vim.api.nvim_get_hl(0, { name = "CodeReviewFileHeader", link = false })
    local dim = vim.api.nvim_get_hl(0, { name = "CodeReviewFileReviewed", link = false })
    assert.is_true(plain.fg ~= dim.fg, "the two file header groups resolve to one foreground")
  end)

  -- The doubled rule going away, at the group. A header sat between two hairlines -- its own
  -- underline and the one on the pad row above it -- which is text in a box rather than a
  -- title. The band replaces the first, and the second has nothing left to close.
  it("draw no rule on a true-colour terminal, on the header row or on the pad row", function()
    for _, group in ipairs(FRAME_GROUPS) do
      assert.is_nil(def(group).underline, ("%s still underlines: %s"):format(group, vim.inspect(def(group))))
      assert.is_nil(def(group).sp, ("%s still carries a rule colour: %s"):format(group, vim.inspect(def(group))))
    end
  end)

  -- The pad group stays defined and carries nothing, rather than going away: the render's
  -- table hands out a pair per file state, and everything that reads it goes on finding one.
  it("leave the pad group with nothing at all to draw in gui", function()
    for _, group in ipairs(PADS) do
      for _, attr in ipairs({ "bg", "fg", "sp", "underline" }) do
        assert.is_nil(def(group)[attr], ("%s still carries %s: %s"):format(group, attr, vim.inspect(def(group))))
      end
    end
  end)

  -- The terminal that has no band. A palette index is not a colour with channels to pull, so
  -- there is no background to compute at a strength -- the rule stays there, and the pad row's
  -- rule stays with it. `nvim_set_hl` lets cterm follow the true-colour attributes only when
  -- its table is *absent*, so the underline is written by hand or it would leave with the gui
  -- rule it no longer has.
  it("underline in cterm, on the header row and on the pad row alike", function()
    for _, group in ipairs(FRAME_GROUPS) do
      assert.is_true((def(group).cterm or {}).underline == true, ("%s: %s"):format(group, vim.inspect(def(group))))
    end
  end)

  -- `overline` is accepted by this API and comes back in the `cterm` table, so a bottom edge
  -- drawn with it looks right here and is invisible on the terminals that ignore the
  -- sequence -- with nothing to report it.
  it("use no overline anywhere", function()
    for _, group in ipairs(FRAME_GROUPS) do
      assert.is_nil(def(group).overline, ("%s: %s"):format(group, vim.inspect(def(group))))
      assert.is_nil((def(group).cterm or {}).overline, ("%s: %s"):format(group, vim.inspect(def(group))))
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

  it("give the band a muted twin and a faded twin, each keeping the band", function()
    for _, group in ipairs(BANDS) do
      for _, family in ipairs({ "muted", "faded" }) do
        local twin = assert(hl.blended(family, group), ("%s has no %s twin"):format(group, family))
        assert.is_truthy(
          vim.api.nvim_get_hl(0, { name = twin }).bg,
          ("%s lost the band: %s"):format(twin, vim.inspect(vim.api.nvim_get_hl(0, { name = twin })))
        )
      end
    end
  end)

  -- The pad group has no colour left to blend, so it gets no twin -- and a caller that finds
  -- none draws the group as it stands, which is a group that draws nothing. That is the shape
  -- rather than an omission: a twin here would be a blend of nothing at all.
  it("give the pad group no twin, because it has no colour left to blend", function()
    for _, group in ipairs(PADS) do
      for _, family in ipairs({ "muted", "faded" }) do
        assert.is_nil(hl.blended(family, group), ("%s has a %s twin of nothing"):format(group, family))
      end
    end
  end)
end)

--- An expanded file --------------------------------------------------------------

describe("an expanded file", function()
  local fi = index_of("src/main.lua")
  local after = build(files)
  local header = assert(after.file_rows[fi])
  local closing = last_row(after, fi)

  it("really is expanded, and really has a body", function()
    assert.is_true(closing > header + 1, "the file spends no rows between its header and its pad")
  end)

  it("carries the band on its header row", function()
    assert.same({ TOP }, line_groups(after, header))
  end)

  -- The band says the row is a heading; the column mark under it says what the row is about.
  it("keeps its own header group as a column mark under the band", function()
    assert.is_true(
      vim.tbl_contains(column_groups(after, header), "CodeReviewFileHeader"),
      table.concat(column_groups(after, header), ", ")
    )
  end)

  -- The row is blank and it is a pad row. Both matter: the group is still emitted there, so
  -- the terminal that keeps the rule keeps it on a row the diff had anyway.
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

  -- No anchor is created or moved: both rows are rows the diff had anyway, and of the kinds
  -- those rows already were. A row of the frame's own would be a `nil` here, and a reviewer
  -- could put a cursor on a thing that is not part of the diff.
  it("draws on the file's own header anchor and its own pad anchor", function()
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

  it("is banded, because a file folded away is still a heading", function()
    assert.same({ TOP }, line_groups(after, header))
  end)

  -- It has no body to close, so the pad group is not emitted at all -- on the terminal that
  -- still draws rules, two rules with nothing between them read as a broken frame.
  it("puts no pad group on its pad row", function()
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

  it("carries the reviewed file's band and nothing on its pad row", function()
    assert.same({ TOP_REVIEWED }, line_groups(after, header))
    assert.same({}, line_groups(after, header + 1))
  end)

  -- The band is the same colour on a reviewed file as on any other, so what says the file is
  -- done is this mark under it.
  it("keeps the colour that says so on a column mark under the band", function()
    assert.is_true(
      vim.tbl_contains(column_groups(after, header), "CodeReviewFileReviewed"),
      table.concat(column_groups(after, header), ", ")
    )
  end)
end)

-- `za` expands a file without unmarking it, so this is what that key is for rather than an
-- oddity -- and it is the one arrangement in which a file could take its band from one source
-- and its pad group from another.
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

  it("is banded and closed like every other", function()
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

  it("is banded, so the band is not a thing that only appears in a crowd", function()
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

-- **Solo** draws one file where the review draws all of them, and it is the one arrangement
-- in which a band has no neighbour to mark a boundary against. It is banded all the same: the
-- band is what a file's beginning is, and not only what two files are told apart by.
describe("a soloed render", function()
  local fi = index_of("src/main.lua")
  local after = build(files, { solo = fi })

  it("really drew one file, and drew that one", function()
    assert.same({ fi }, vim.tbl_keys(after.file_rows))
  end)

  it("bands the file it draws", function()
    assert.same({ TOP }, line_groups(after, assert(after.file_rows[fi])))
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

  -- On the terminal that keeps the rule, one on every pad row would read as a file boundary
  -- per hunk, which says the file ended twice.
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

  it("is banded and closed", function()
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

  it("band and close the same rows", function()
    assert.same(framed_rows(after), framed_rows(before))
  end)

  it("draw every one of those rows in the same group, so the two images stay comparable", function()
    for _, row in ipairs(framed_rows(after)) do
      assert.same(line_groups(after, row), line_groups(before, row), ("row %d"):format(row))
    end
  end)

  it("band every file and close every file", function()
    local want = {}
    for fi = 1, #files do
      want[#want + 1] = assert(after.file_rows[fi])
      want[#want + 1] = last_row(after, fi)
    end
    table.sort(want)
    assert.same(want, framed_rows(after))
  end)

  -- A file that exists on the after side alone has no pre-image path, so that pane's header
  -- row holds nothing. It is banded all the same, and the band is the whole of what it says:
  -- the file begins here, and this side has nothing in it. Under the rule the before pane had
  -- an underline on an empty row, which reads as a stray line rather than as a beginning.
  it("band a before pane's empty header row, which is what states the truth about that side", function()
    local fi = index_of("src/fresh.lua")
    local row = assert(before.file_rows[fi])
    assert.same("", before.lines[row], "the pre-image side of an added file is not empty")
    assert.same({ TOP }, line_groups(before, row))
  end)
end)

--- What a screen really holds ---------------------------------------------------

-- Everything above is group names on marks. A mark set can be complete, correct and
-- invisible: a group name cannot say whether the band was painted, in what colour, or what it
-- did to the marks beneath it. These readings are taken from the screen.
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
  local name = child("name")
  local muted = child("muted")
  local pad = child("pad")

  --- The band, and what it must not do to the row ----------------------------------

  -- `333333` is a black `Normal` background pulled 20% toward a white `Normal` foreground,
  -- which is the child's own theme and no runner's. So the reading names the strength as well
  -- as the fact that something was painted: a band computed from `CursorLine`, or at the 10%
  -- the prototype started from, cannot pass it. `00ee00` is `Title`, which is where a file's
  -- own name takes its colour from -- the name keeps it, under a band that carries none.
  it("fills the header row with a band computed from that process's own Normal", function()
    assert.same('cell "g" fg=00ee00 bg=333333 sp=none underline=nil', name)
  end)

  -- The defect this shape exists for. A `line_hl_group` replaces every attribute it sets on
  -- every inline highlight the row carries, at any priority and in either direction -- so a
  -- band carrying a foreground draws the whole header row in one colour and the marks beneath
  -- it are emitted, correct and invisible. `covered` is the quiet half of a **path**, in a
  -- group of its own.
  it("leaves a column mark on the header row its own colour", function()
    assert.same('cell "r" fg=2266aa bg=333333 sp=none underline=nil', covered)
  end)

  -- **The claim the two absolute readings cannot make between them.** Each of them passes for
  -- one reason and fails for two: a band that flattens the row makes both cells one colour,
  -- and a column mark that is never emitted does the same. The absolute values name which
  -- failure it was; this says there was one. The backgrounds are read the other way round --
  -- one band, continuous across a row whose foregrounds are not.
  it("draws the two cells in two foregrounds over one band", function()
    local function field(reading, key)
      return assert(reading:match(key .. "=(%x+)"), reading)
    end
    assert.is_true(
      field(covered, "fg") ~= field(name, "fg"),
      ("the header row is one flat colour: %s against %s"):format(covered, name)
    )
    assert.same(field(covered, "bg"), field(name, "bg"))
  end)

  -- The band recedes with its pane, both halves of the cell at once: `007700` is the name's
  -- own colour halfway to the backdrop, `1a1a1a` is the band. A group named where
  -- `hl.groups()` does not read would come back here at full brightness, on a screen that
  -- looks wrong to a reviewer and right to every assertion made over names.
  it("mutes the band with its pane, and the name on it with the band", function()
    assert.same('cell "g" fg=007700 bg=1a1a1a sp=none underline=nil', muted)
  end)

  --- The pad row, and what is no longer on it --------------------------------------

  -- The doubled rule, gone from the screen rather than only from the group table. The child
  -- finds the pad row by the mark the render really emitted before it reads the cell, so this
  -- is an absence on a row that is marked -- which a review that emitted nothing at all could
  -- not pass. The pane's *last* column, because a rule one cell wide would hide from a
  -- reading taken at the first.
  it("draws no rule on the pad row it still marks", function()
    assert.same('cell " " fg=none bg=none sp=none underline=nil', pad)
  end)
end)

--- What the frame costs ----------------------------------------------------------

-- The whole of what the frame spends, stated as a number rather than reasoned about: the
-- header row's mark existed already and only changed which group it names, so the cost is one
-- mark per file with a body.
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
  -- file kept a pad group, which is the thing a collapsed file must not have.
  it("is one fewer with a file collapsed", function()
    assert.same(#files - 1, bottoms(build(files, { expanded = { ["src/main.lua"] = false } })))
  end)
end)

--- The theme underneath, changed ------------------------------------------------

-- Last in the file, and it puts the theme back. Everything above reads the colours the suite
-- opened with, and the child processes have already run -- each sets a `Normal` of its own
-- anyway. `spans_spec` changes colorscheme the same way for the other computed family.
--
-- **Two claims that only a second theme can make.** The band is computed rather than held, so
-- it has to follow a `:colorscheme` -- and the ordering that makes it follow is not obvious:
-- `hl.apply` writes the band before it rewrites the blended twins, and it is `recolor_twins`
-- that clears the memo of what a blend is pulled toward. A band read through that memo would
-- be computed against the theme that just left, which is why `apply_frame` reads `Normal`
-- itself. Nothing pinned that until this block: on this pair of themes a stale backdrop lands
-- the band exactly on the new `Normal`'s foreground, which is what `between` refuses.
--
-- The second claim is the light theme, which the suite otherwise never runs: a band is no use
-- to a reviewer on a light colorscheme if the strength was chosen on a dark one. It clears the
-- cursor line there by less than it does on dark -- 13, 13, 12 against 17, 17, 17 -- and that
-- is the margin `CLEARANCE` is set to catch the loss of.
describe("a colorscheme change, onto a light theme", function()
  local was = { background = vim.o.background, band = assert(def(TOP).bg), normal = assert(def("Normal").bg) }

  vim.o.background = "light"
  vim.cmd("colorscheme default")

  it("really changed the theme under the review", function()
    assert.is_true(def("Normal").bg ~= was.normal, "the colorscheme change moved nothing")
  end)

  it("recomputes the band against the theme that is active now", function()
    for _, group in ipairs(BANDS) do
      assert.is_true(def(group).bg ~= was.band, ("%s kept the band the last theme gave it"):format(group))
    end
  end)

  -- The ordering trap. A band taken from the memo `recolor_twins` clears at the end of the
  -- pass is computed against the theme that left, and on these two themes that lands it on the
  -- new foreground exactly.
  it("lands strictly inside the new `Normal`, which a stale backdrop cannot", function()
    local normal = def("Normal")
    for _, group in ipairs(BANDS) do
      local ok, why = between(assert(def(group).bg), normal.bg, normal.fg)
      assert.is_true(ok, ("%s: %s"):format(group, why))
    end
  end)

  it("stands clear of the light theme's cursor line too", function()
    local cursor = assert(def("CursorLine").bg, "the light theme lights no cursor line")
    for _, group in ipairs(BANDS) do
      local band = assert(def(group).bg)
      assert.is_true(
        distance(band, cursor) >= CLEARANCE,
        ("%s is %d from CursorLine in its closest channel, under %d: %06x against %06x"):format(
          group,
          distance(band, cursor),
          CLEARANCE,
          band,
          cursor
        )
      )
    end
  end)

  -- `:colorscheme` clears every definition this module writes, twins included, so the band's
  -- twin has to be written again against the new colours rather than left pointing at the old.
  it("gives the new band its twins again", function()
    for _, group in ipairs(BANDS) do
      for _, family in ipairs({ "muted", "faded" }) do
        local twin = assert(hl.blended(family, group), ("%s lost its %s twin to the new theme"):format(group, family))
        assert.is_truthy(vim.api.nvim_get_hl(0, { name = twin }).bg, ("%s lost the band"):format(twin))
      end
    end
  end)

  it("puts the theme back, so nothing after this file reads a light one", function()
    vim.o.background = was.background
    vim.cmd("colorscheme default")
    assert.same(was.normal, def("Normal").bg)
    assert.same(was.band, def(TOP).bg)
  end)
end)
