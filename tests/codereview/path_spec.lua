-- How a file's path is styled: its directories quiet, its own name bright.
--
-- The label function is what both surfaces that name a file ask, so it answers in **typed
-- segments** -- the vocabulary the winbar is already assembled from, where a segment says
-- whether it is chrome the plugin wrote or a literal the repository chose and must therefore
-- be escaped. The header row paints those segments at byte offsets; the winbar turns the
-- same ones into markup.
--
-- This first act asserts that answer directly, with no review, no fixture and no repository
-- behind it -- exactly as `render_spec` asserts winbar assembly from segments, and for the
-- same reason: a rule about what a file is called needs no diff to be true, and a case that
-- opened one would be slower and would say less about which part of it moved.
local render = require("codereview.render")

-- The shipped glyphs, spelled here rather than read off the configuration: nothing in this
-- file calls `setup`, and what a label does with an icon is to carry it, not to choose it.
local ICONS = { reviewed = "✓", annotated = "●", unreviewed = "○", collapsed = "▸", expanded = "▾" }

local DIR, NAME = "CodeReviewFileDir", "CodeReviewFileName"

---One label of an ordinary modified file, with `file` and `opts` overriding what it needs to.
---@param file table|nil
---@param opts table|nil
---@return CRFileLabel
local function label(file, opts)
  return render.file_label(
    vim.tbl_extend(
      "force",
      { path = "src/main.lua", status = "M", added = 1, removed = 1, binary = false, hunks = {} },
      file or {}
    ),
    vim.tbl_extend("force", { icons = ICONS, expanded = {}, reviewed = {}, notes = {} }, opts or {})
  )
end

describe("the segments a path is drawn as", function()
  it("splits a plain path into a quiet half and a bright one", function()
    assert.same({
      { kind = "literal", text = "src/", hl = DIR },
      { kind = "literal", text = "main.lua", hl = NAME },
    }, label().name)
  end)

  -- The split is at the *last* separator and not at the first, which is invisible on a path
  -- with one directory in it -- every path in the flat fixture has exactly one.
  it("cuts at the last separator, so every directory above the file is quiet", function()
    assert.same({
      { kind = "literal", text = "apps/api/src/routes/", hl = DIR },
      { kind = "literal", text = "users.ts", hl = NAME },
    }, label({ path = "apps/api/src/routes/users.ts" }).name)
  end)

  -- A file at the repository root has no quiet half, and is not a special case anyone
  -- notices: one segment comes back, in the bright group, with no empty one in front of it.
  it("gives a root-level file its name alone, with no quiet segment before it", function()
    assert.same({ { kind = "literal", text = "README.md", hl = NAME } }, label({ path = "README.md" }).name)
  end)

  -- A path a reviewer's repository chose can hold anything, and the separator is what the
  -- split is made at -- so the two halves land on character boundaries whatever is either
  -- side of it. The guard is what makes this case able to fail at all: over an ASCII path
  -- byte counting and character counting agree, and both halves pass.
  it("splits a path that is not ASCII without cutting a character in half", function()
    local segments = label({ path = "src/café/naïve.lua" }).name
    assert.same({
      { kind = "literal", text = "src/café/", hl = DIR },
      { kind = "literal", text = "naïve.lua", hl = NAME },
    }, segments)
    local text = render.segment_text(segments)
    assert.is_true(#text > vim.fn.strchars(text), "nothing multibyte in this path to split")
  end)

  -- Both halves are the repository's own name, so both are literals: the kind is what
  -- decides the escaping, and a path is exactly the thing the escaping exists for.
  it("makes both halves literals, because a repository chose the whole path", function()
    for _, seg in ipairs(label({ path = "a/b.lua" }).name) do
      assert.same("literal", seg.kind)
    end
  end)
end)

describe("a renamed file in the unified layout", function()
  local RENAME = { path = "src/newname.lua", old_path = "src/oldname.lua", status = "R" }

  -- Both paths take the rule. Dimming one of them says the wrong thing about which is which,
  -- and the arrow between them is the plugin's own chrome, so it reads as punctuation rather
  -- than as part of either name.
  it("styles both of its paths and draws the arrow as chrome", function()
    assert.same({
      { kind = "literal", text = "src/", hl = DIR },
      { kind = "literal", text = "oldname.lua", hl = NAME },
      { kind = "chrome", text = " → ", hl = DIR },
      { kind = "literal", text = "src/", hl = DIR },
      { kind = "literal", text = "newname.lua", hl = NAME },
    }, label(RENAME).name)
  end)

  -- The layout decides how a rename is spelled, and it always did: a split layout has a pane
  -- per side, so each side names its own path and no arrow is spelled anywhere.
  it("names only the after path in a split layout, with no arrow", function()
    assert.same({
      { kind = "literal", text = "src/", hl = DIR },
      { kind = "literal", text = "newname.lua", hl = NAME },
    }, label(RENAME, { layout = "split" }).name)
  end)

  it("gives the before pane the pre-image path, styled by the same rule", function()
    assert.same({
      { kind = "literal", text = "src/", hl = DIR },
      { kind = "literal", text = "oldname.lua", hl = NAME },
    }, label(RENAME, { layout = "split" }).before)
  end)
end)

describe("the pre-image half", function()
  it("is the file's own path when it was not renamed", function()
    assert.same({
      { kind = "literal", text = "src/", hl = DIR },
      { kind = "literal", text = "main.lua", hl = NAME },
    }, label().before)
  end)

  -- A file that exists only on the after side has no pre-image path at all, and neither its
  -- header row nor its winbar names one. Nil rather than an empty list, because "there is
  -- nothing to draw" is what every caller already branches on.
  it("is absent for a file added on the branch", function()
    assert.is_nil(label({ path = "src/fresh.lua", status = "A" }).before)
    assert.is_nil(label({ path = "src/untracked.lua", status = "U" }).before)
  end)
end)

-- The escaping is the reason the kinds exist. A `%` in a path a reviewer's repository chose
-- would otherwise be read as a statusline item on the winbar and expanded into something
-- else -- `%f` into the window's own file name, which is not even the file being named.
describe("a name carrying a %", function()
  local PERCENT = { path = "src/50%f done.lua" }

  it("keeps it in a literal rather than in chrome", function()
    local segments = label(PERCENT).name
    assert.same({ kind = "literal", text = "50%f done.lua", hl = NAME }, segments[#segments])
  end)

  -- The claim the kind is worth nothing without: what reaches a winbar is the name as it
  -- stands, in the group asked for, and no wider than the ruler said.
  it("draws as the name it is when the same segments are assembled into a bar", function()
    local segments = label(PERCENT).name
    local drawn = vim.api.nvim_eval_statusline(render.bar(segments), { highlights = true })
    assert.same("src/50%f done.lua", drawn.str)
    assert.same(render.bar_width(segments), drawn.width)
  end)
end)

describe("the text those segments spell", function()
  -- The header row is built from this, so it has to be the path and nothing else: no
  -- markers, no doubled `%`, and the arrow where the arrow goes.
  it("is the path itself, with no markup and nothing escaped", function()
    assert.same("src/50%f done.lua", render.segment_text(label({ path = "src/50%f done.lua" }).name))
    assert.same(
      "src/oldname.lua → src/newname.lua",
      render.segment_text(label({ path = "src/newname.lua", old_path = "src/oldname.lua", status = "R" }).name)
    )
  end)
end)

-- What #198 and #200 read off this label, and what every surface that names a file has always
-- read off it. Asserted here because the segments are a change to this return value, and a
-- field quietly dropped from it is a thing no case about segments would notice.
describe("what else the label goes on answering", function()
  it("still says whether the file is reviewed, expanded and annotated, and which glyphs it carries", function()
    local plain = label()
    assert.is_false(plain.reviewed)
    assert.is_true(plain.expanded)
    assert.same(0, plain.notes)
    assert.same(ICONS.unreviewed, plain.icon)
    assert.same(ICONS.expanded, plain.chevron)
    assert.same("+1 -1", plain.stat)
    assert.same("+1 -1", plain.right)
  end)

  it("still collapses a reviewed file and names it with the reviewed glyph", function()
    local done = label(nil, { reviewed = { ["src/main.lua"] = "blob" } })
    assert.is_true(done.reviewed)
    assert.is_false(done.expanded)
    assert.same(ICONS.reviewed, done.icon)
    assert.same(ICONS.collapsed, done.chevron)
  end)

  it("still counts the notes anywhere in the file and puts them on the right", function()
    local noted = label(nil, { notes = { ["src/main.lua:n:1"] = { {}, {} } } })
    assert.same(2, noted.notes)
    assert.same(ICONS.annotated, noted.icon)
    assert.same("+1 -1  [2 notes]", noted.right)
  end)
end)

--- The header row -------------------------------------------------------------

-- The second surface, and the one the byte offsets live on. `render.build` is pure -- data
-- in, data out -- so which mark falls at which column is asserted here with no window, no
-- fixture and no repository, exactly as the anchor map and the split layout's pane parity
-- already are.
--
-- **The offsets are bytes, and that is the whole hazard.** `"○ ▾ "` is eight bytes and four
-- display columns, so a mark placed at the display column lands four bytes early and colors
-- the chevron instead of the first directory. Every case below reads the header row's own
-- text back and computes what it expects from `#`, which is what makes it able to say so.
local ICON, CHEVRON = ICONS.unreviewed, ICONS.expanded
local PREFIX = ("%s %s "):format(ICON, CHEVRON)

---@param files table[]
---@param opts table|nil
---@return CRRender after, CRRender|nil before
local function build(files, opts)
  return render.build(
    files,
    vim.tbl_extend(
      "force",
      { width = 60, icons = ICONS, expanded = {}, reviewed = {}, notes = {}, types = {} },
      opts or {}
    )
  )
end

---@param file table|nil
---@return table
local function one(file)
  return vim.tbl_extend(
    "force",
    { path = "src/main.lua", status = "M", added = 1, removed = 1, binary = false, hunks = {} },
    file or {}
  )
end

---Every mark on `row` that colors a range of it, as `{ col, end_col, group }`, in the order
---the render emitted them. `line_hl_group` marks are not ranges and are left out: what a row
---carries line-wide is #198's claim and not this one.
---@param rendered CRRender
---@param row integer 1-indexed
---@return table[]
local function ranges(rendered, row)
  local out = {}
  for _, m in ipairs(rendered.marks) do
    if m.row == row - 1 and m.opts.hl_group then
      out[#out + 1] = { m.col, m.opts.end_col, m.opts.hl_group }
    end
  end
  return out
end

---The marks that color a file's path on its header row, in column order.
---@param rendered CRRender
---@param fi integer
---@return table[]
local function path_marks(rendered, fi)
  local out = {}
  for _, r in ipairs(ranges(rendered, assert(rendered.file_rows[fi]))) do
    if r[3] == DIR or r[3] == NAME then
      out[#out + 1] = r
    end
  end
  table.sort(out, function(a, b)
    return a[1] < b[1]
  end)
  return out
end

describe("the byte offsets a path is colored at", function()
  -- The guard the whole block rests on: the prefix in front of every path is multibyte, so
  -- byte offsets and display columns are different numbers here. Without this, every case
  -- below would pass with the render measuring columns.
  it("really has a prefix whose bytes and columns disagree", function()
    assert.same(8, #PREFIX)
    assert.same(4, vim.fn.strdisplaywidth(PREFIX))
  end)

  it("colors the directories and the file's own name at the bytes they occupy", function()
    local after = build({ one() })
    assert.same({
      { #PREFIX, #PREFIX + #"src/", DIR },
      { #PREFIX + #"src/", #PREFIX + #"src/main.lua", NAME },
    }, path_marks(after, 1))
  end)

  -- The case the ticket asked for on a path that is not ASCII, and the reason it is built
  -- here rather than read out of a fixture: **no fixture in this suite has a non-ASCII
  -- path.** `mkfixture.sh`'s `src/nonl.md` is non-ASCII *content* on a plain ASCII path, and
  -- adding an accented path to it would move counts and row assertions in nine specs to
  -- cover a hazard the split itself cannot have -- `/` is ASCII and UTF-8 is
  -- self-synchronising, so a cut at the last separator always lands on a character boundary.
  -- What a non-ASCII path *can* still catch is a mark measured in anything but bytes, which
  -- is why this case exists and why nobody should delete it for having no fixture behind it.
  it("colors a path that is not ASCII at its bytes and not at its columns", function()
    local path = "src/café/naïve.lua"
    local after = build({ one({ path = path }) })
    local marks = path_marks(after, 1)
    assert.same({
      { #PREFIX, #PREFIX + #"src/café/", DIR },
      { #PREFIX + #"src/café/", #PREFIX + #path, NAME },
    }, marks)
    assert.is_true(#path > vim.fn.strdisplaywidth(path), "nothing multibyte in this path to measure")
    -- Read back off the row itself, which is the claim a computed expectation cannot make:
    -- the two ranges are exactly the two halves of the path and nothing either side of them.
    local line = after.lines[after.file_rows[1]]
    assert.same("src/café/", line:sub(marks[1][1] + 1, marks[1][2]))
    assert.same("naïve.lua", line:sub(marks[2][1] + 1, marks[2][2]))
  end)

  it("gives a root-level file one mark and no quiet range in front of it", function()
    local after = build({ one({ path = "README.md" }) })
    assert.same({ { #PREFIX, #PREFIX + #"README.md", NAME } }, path_marks(after, 1))
  end)

  -- A rename is two paths and an arrow in this layout, and each path gets the rule. The arrow
  -- is chrome -- the plugin wrote it, so it is never escaped -- and it takes the directories'
  -- quiet, which is what leaves the two names the only bright things in the field. What makes
  -- it punctuation is the color it does *not* have, and that is what this reads.
  it("colors both of a rename's paths and draws the arrow between them quietly", function()
    local after = build({ one({ path = "src/newname.lua", old_path = "src/oldname.lua", status = "R" }) })
    local line = after.lines[after.file_rows[1]]
    local drawn = {}
    for _, m in ipairs(path_marks(after, 1)) do
      drawn[#drawn + 1] = { line:sub(m[1] + 1, m[2]), m[3] }
    end
    assert.same({
      { "src/", DIR },
      { "oldname.lua", NAME },
      { " → ", DIR },
      { "src/", DIR },
      { "newname.lua", NAME },
    }, drawn)
  end)

  -- Every mark on a header row has to be inside the row: an `end_col` past the end of a line
  -- is a hard error, and a header cut to fit a narrow pane is where one would come from.
  it("keeps every mark inside a header row that had to be cut to fit", function()
    local after = build({ one({ path = "apps/api/src/routes/users/handlers/create.ts" }) }, { width = 40 })
    local row = assert(after.file_rows[1])
    local line = after.lines[row]
    assert.is_true(#line < #PREFIX + #"apps/api/src/routes/users/handlers/create.ts", "nothing was cut")
    for _, m in ipairs(ranges(after, row)) do
      assert.is_true(m[2] <= #line, ("%s ends at %d past a row of %d"):format(m[3], m[2], #line))
      assert.is_true(m[1] < m[2], ("%s is an empty range"):format(m[3]))
    end
  end)

  -- The right-hand side of the header row is nobody's to move. Asserted beside the path
  -- because the path is what changed the way that row is built, and `stat_col` is computed
  -- from `#header - #right`.
  it("leaves the stat and the note count where they were, in the groups they had", function()
    local after = build({ one() }, { notes = { ["src/main.lua:n:1"] = { {} } } })
    local row = assert(after.file_rows[1])
    local line = after.lines[row]
    local right = {}
    for _, m in ipairs(ranges(after, row)) do
      if m[3] ~= DIR and m[3] ~= NAME then
        right[#right + 1] = { line:sub(m[1] + 1, m[2]), m[3] }
      end
    end
    assert.same({
      { "+1", "CodeReviewStatAdd" },
      { "-1", "CodeReviewStatDel" },
      { "  [1 note]", "CodeReviewNoteCount" },
    }, right)
    assert.same("+1 -1  [1 note]", line:sub(#line - #"+1 -1  [1 note]" + 1))
  end)

  -- Solo draws one file and no other, and a drawn file is drawn exactly as it is drawn among
  -- the others. Neither feature depends on the other, and this is where that is checked.
  it("colors the drawn file's path the same way under solo", function()
    local files = { one({ path = "src/a.lua" }), one({ path = "src/b.lua" }), one({ path = "src/c.lua" }) }
    local all = build(files)
    local only = build(files, { solo = 2 })
    assert.same({ 2 }, vim.tbl_keys(only.file_rows))
    assert.same(path_marks(all, 2), path_marks(only, 2))
    -- A file solo did not draw has no header row to color, and the map says so at its own
    -- true index rather than by collapsing the index space.
    assert.is_nil(only.file_rows[1])
  end)
end)

describe("the before pane's header row", function()
  local RENAME = one({ path = "src/newname.lua", old_path = "src/oldname.lua", status = "R" })

  it("colors the pre-image path it names, by the same rule and at its own bytes", function()
    local _, before = build({ RENAME }, { layout = "split", before_width = 60 })
    local row = assert(before.file_rows[1])
    local line = before.lines[row]
    local drawn = {}
    for _, m in ipairs(path_marks(before, 1)) do
      drawn[#drawn + 1] = { line:sub(m[1] + 1, m[2]), m[3] }
    end
    assert.same({ { "src/", DIR }, { "oldname.lua", NAME } }, drawn)
  end)

  -- The two panes name the two sides of a rename, which is the layout's whole rule: neither
  -- pane spells the arrow, and neither pane names the other's path.
  it("names its own side while the after pane names the other", function()
    local after, before = build({ RENAME }, { layout = "split", before_width = 60 })
    assert.is_truthy(after.lines[after.file_rows[1]]:find("newname.lua", 1, true))
    assert.is_nil(after.lines[after.file_rows[1]]:find("oldname.lua", 1, true))
    assert.is_nil(before.lines[before.file_rows[1]]:find("newname.lua", 1, true))
  end)

  it("colors nothing on the row of a file that has no pre-image at all", function()
    local _, before = build({ one({ path = "src/fresh.lua", status = "A" }) }, { layout = "split", before_width = 60 })
    assert.same({}, path_marks(before, 1))
    assert.same("", before.lines[before.file_rows[1]])
  end)
end)

--- The groups themselves -------------------------------------------------------

-- Named where the muting derives its namespace from, which is the one thing about a new
-- group that fails silently: a group named anywhere else draws at full brightness in a pane
-- without focus and nothing reports it.
describe("the two groups a path is drawn in", function()
  local hl = require("codereview.hl")
  hl.apply()

  it("are in the set the muted namespace is built from", function()
    local groups = hl.groups()
    assert.is_true(vim.tbl_contains(groups, DIR), DIR .. " is not in hl.groups()")
    assert.is_true(vim.tbl_contains(groups, NAME), NAME .. " is not in hl.groups()")
  end)

  it("link into the colorscheme rather than defining colors of their own", function()
    for _, group in ipairs({ DIR, NAME }) do
      local def = vim.api.nvim_get_hl(0, { name = group })
      assert.is_truthy(def.link, ("%s is not a link: %s"):format(group, vim.inspect(def)))
      assert.is_truthy(vim.api.nvim_get_hl(0, { name = def.link }), ("%s links nowhere"):format(group))
    end
  end)

  -- A **faded** file's rows are emitted in the blended twin of every group they carry, so a
  -- group with no twin is a group a faded file draws bright. Asserted as a definition holding
  -- a color, never as a link: a link reaching nothing draws nothing at all.
  it("have fade twins, each holding a color rather than a link back", function()
    for _, group in ipairs({ DIR, NAME }) do
      local twin = assert(hl.blended("faded", group), group .. " has no fade twin")
      local def = vim.api.nvim_get_hl(0, { name = twin, link = false })
      assert.is_truthy(def.fg, ("%s holds no color"):format(twin))
      assert.is_nil(def.link)
    end
  end)

  -- The two are different colors, or the rule draws nothing a reviewer can see. Read after
  -- `hl.apply` has linked both into the active colorscheme.
  it("resolve to two different colors, so the rule is visible at all", function()
    local dir = vim.api.nvim_get_hl(0, { name = DIR, link = false })
    local name = vim.api.nvim_get_hl(0, { name = NAME, link = false })
    assert.are_not.same(dir.fg, name.fg)
  end)
end)

--- The cut a narrow pane makes --------------------------------------------------

-- The **sticky header** cuts a path from the left and keeps the file's own name, because the
-- part worth keeping is the part at the end. Now that a path is styled, the cut has to come
-- back styled: what survives is segments and not a string, or the bar would have to re-split
-- what it was handed and the two surfaces would be two rules again.
describe("keeping the tail of a path that does not fit", function()
  ---@param path string
  ---@return CRBarSegment[]
  local function segments(path)
    return label({ path = path }).name
  end

  ---@param segs CRBarSegment[]
  ---@return table[]
  local function drawn(segs)
    local out = {}
    for i, seg in ipairs(segs) do
      out[i] = { seg.kind, seg.text, seg.hl }
    end
    return out
  end

  it("hands back what it was given when the whole path fits", function()
    local segs = segments("src/main.lua")
    assert.same(segs, render.keep_tail_segments(segs, 40))
  end)

  -- The quiet half gives up its head and the bright name survives whole, in its own group:
  -- what a reviewer keeps on a narrow pane is the part that says which file this is.
  it("cuts into the directories and leaves the file's own name whole and bright", function()
    local segs = render.keep_tail_segments(segments("apps/api/src/routes/users.ts"), 16)
    assert.same({
      { "chrome", "…", DIR },
      { "literal", "routes/", DIR },
      { "literal", "users.ts", NAME },
    }, drawn(segs))
    assert.same(16, render.bar_width(segs))
  end)

  -- A cut that reaches past the whole quiet half drops it rather than leaving an empty
  -- segment behind, and the ellipsis then lands on the name it cut into.
  it("drops a segment the cut swallowed whole", function()
    local segs = render.keep_tail_segments(segments("apps/api/handlers.ts"), 8)
    assert.same({ { "chrome", "…", NAME }, { "literal", "lers.ts", NAME } }, drawn(segs))
  end)

  -- The ellipsis is the plugin's own mark that something was cut, so it is chrome. A literal
  -- would be a name the plugin claimed a repository had chosen.
  it("marks the cut with chrome and never with a literal", function()
    for _, seg in ipairs(render.keep_tail_segments(segments("a/b/c/d.lua"), 6)) do
      if seg.text == "…" then
        assert.same("chrome", seg.kind)
      end
    end
  end)

  -- A pane with nothing left to give says only that something was cut, which is still worth
  -- saying.
  it("comes back as the ellipsis alone on a pane with no room at all", function()
    assert.same({ { "chrome", "…", nil } }, drawn(render.keep_tail_segments(segments("src/main.lua"), 1)))
  end)

  -- By display width, like every other fit in this plugin: a path a repository chose can
  -- hold anything, and a cut counted in bytes overshoots on the first accent. The guard is
  -- the second assertion -- over an ASCII path the two counts agree and the case says
  -- nothing.
  it("cuts by columns rather than by bytes, on a path that is not ASCII", function()
    local path = "src/café/naïve.lua"
    local segs = render.keep_tail_segments(segments(path), 12)
    assert.same(12, render.bar_width(segs))
    assert.is_true(#render.segment_text(segs) > 12, "nothing multibyte survived the cut")
    -- What no width can say: the cut fell between characters rather than inside one.
    local text = render.segment_text(segs)
    assert.same(text, vim.fn.strcharpart(text, 0, vim.fn.strchars(text)))
  end)

  -- A rename is cut by the same rule, and what it keeps is the file's name *now*.
  it("keeps the after name of a rename and gives up the head of the whole field", function()
    local segs = render.keep_tail_segments(
      label({
        path = "src/newname.lua",
        old_path = "src/oldname.lua",
        status = "R",
      }).name,
      16
    )
    local text = render.segment_text(segs)
    assert.is_truthy(text:find("newname.lua", 1, true), text)
    assert.is_nil(text:find("oldname.lua", 1, true), text)
    assert.same(NAME, segs[#segs].hl)
  end)
end)

--- Both surfaces, one answer ----------------------------------------------------

-- The last act needs a review, because what it asserts is that **both** consumers ask the one
-- function -- and no assertion made against either surface alone can say so. Two surfaces
-- spelling the same path is what a second copy of the rules would also produce, right up to
-- the first file only one of the two authors had in mind.
--
-- So the answer is replaced and both surfaces are read. A header row or a winbar that spelled
-- a path itself would go on drawing the file's real name; one that asks goes on saying
-- whatever the answer says. The real function is put back in the same case, because specs run
-- top to bottom and everything below this would otherwise be reading a planted review.
local h = require("tests.helpers")

h.ui(120, 45)
h.cd_fixture("mkfixture")
require("codereview").setup({ syntax = false })
local view = require("codereview.view")

describe("the header row and the sticky header asking one function", function()
  view.open("branch")
  local V = assert(view.current(), "no review view opened")
  local index = assert(h.file_index(V, "src/main.lua"))

  ---Read a file the way a reviewer does, so the bar names the file under the cursor.
  local function read_into()
    vim.api.nvim_set_current_win(V.win)
    vim.api.nvim_win_set_cursor(V.win, { assert(view.current().render.file_rows[index]) + 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
  end

  ---@return string
  local function header()
    local row = assert(view.current().render.file_rows[index])
    return vim.api.nvim_buf_get_lines(V.buf, row - 1, row, false)[1]
  end

  read_into()

  -- The guard: with the two surfaces naming nothing, the case below would be asserting that
  -- a planted name is absent from two empty strings.
  it("really names that file on both surfaces to begin with", function()
    assert.is_truthy(header():find("src/main.lua", 1, true), header())
    assert.is_truthy(h.winbar(V.win):find("src/main.lua", 1, true), h.winbar(V.win))
  end)

  it("draws both of them from that function's answer and from no second spelling of it", function()
    local real = render.file_label
    render.file_label = function(file, opts)
      local answer = real(file, opts)
      answer.name = { render.literal("planted/", DIR), render.literal("witness.lua", NAME) }
      return answer
    end
    local ok, err = pcall(function()
      view.paint()
      read_into()
      assert.is_truthy(header():find("planted/witness.lua", 1, true), header())
      assert.is_truthy(h.winbar(V.win):find("planted/witness.lua", 1, true), h.winbar(V.win))
    end)
    render.file_label = real
    view.paint()
    read_into()
    assert(ok, tostring(err))
  end)

  it("has the review back on its real names afterwards", function()
    assert.is_truthy(header():find("src/main.lua", 1, true), header())
    assert.is_truthy(h.winbar(V.win):find("src/main.lua", 1, true), h.winbar(V.win))
  end)

  -- And the styling reaches both, in the same two groups. The header row's is a byte range on
  -- an extmark and the bar's is statusline markup, which is the same claim asked of the two
  -- mechanisms that can carry it.
  it("styles the path on the header row and on the bar in one pair of groups", function()
    local row = assert(view.current().render.file_rows[index])
    local groups = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(V.buf, h.NS, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
      if m[4].hl_group == DIR or m[4].hl_group == NAME then
        groups[m[4].hl_group] = true
      end
    end
    assert.same({ [DIR] = true, [NAME] = true }, groups)
    assert.same(DIR, h.winbar_group(V.win, "src/"))
    assert.same(NAME, h.winbar_group(V.win, "main.lua"))
  end)
end)
