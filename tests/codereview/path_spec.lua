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
