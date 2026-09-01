-- The `file_icon` adapter: a host's own glyph for a file, beside the mark that says what the
-- reviewer has done with it.
--
-- The adapter is a stub here, as every adapter in this suite is. There is no icon plugin to
-- drive, and which glyph a file deserves is exactly what this plugin declines to have an
-- opinion about (ADR-0001) -- so what is asserted is what the adapter is *handed*, what the
-- two surfaces do with what it answers, and what they do when it answers nothing usable.
--
-- Three acts, and they have to run in this order, for the reason `open_diff_spec`'s two do:
-- what a review draws with **no** adapter wired can only be asserted by a process that has
-- not injected one yet. The first act needs neither, because `file_label` and `render.build`
-- are pure -- data in, data out -- and a rule about what a file is called needs no review
-- open to be true.
--
-- The glyph goes **after** the chevron and before the path. It says what kind of file this
-- is, which is an attribute of the file's name; the state mark is the leftmost column and a
-- reviewer reads it down the page for what they have already done. A variable-width glyph in
-- front of that column would break the one thing that column is for.
local h = require("tests.helpers")
local render = require("codereview.render")

-- The shipped glyphs, spelled here rather than read off the configuration, as `path_spec`
-- spells them: nothing in the first act calls `setup`, and what a label does with an icon is
-- to carry it rather than to choose it.
local ICONS = { reviewed = "✓", annotated = "●", unreviewed = "○", collapsed = "▸", expanded = "▾" }
local DIR, NAME = "CodeReviewFileDir", "CodeReviewFileName"

-- One column wide and more than one byte long, which is what a devicon is. **That is what
-- makes the offsets below able to fail**: over an ASCII glyph a mark measured in columns and
-- a mark measured in bytes land on the same character, and every case in the second act
-- passes with the render measuring the wrong one.
local LUA, MD, OTHER = "λ", "¶", "◆"

---A host's adapter, keyed on the extension as a real one is.
---@param path string
---@return string
local function by_extension(path)
  return path:match("%.lua$") and LUA or path:match("%.md$") and MD or OTHER
end

--- What the adapter is handed, and what its answer becomes ----------------------

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

---Every call an adapter took, as the argument lists it was handed.
---@param answer any What the adapter answers with, whatever that is
---@return { calls: table[], fn: fun(...): any }
local function recording(answer)
  local calls = {}
  return {
    calls = calls,
    fn = function(...)
      calls[#calls + 1] = { ... }
      return answer
    end,
  }
end

describe("the adapter a host wires", function()
  it("is handed the file's own path and nothing else", function()
    local rec = recording(LUA)
    label({ path = "apps/api/src/routes/users.ts" }, { file_icon = rec.fn })
    assert.same({ { "apps/api/src/routes/users.ts" } }, rec.calls)
  end)

  -- A rename is two names in the unified layout and the icon is one glyph, so the question
  -- has to be about one of them. The post-image name is the file as it is now, which is the
  -- name the file tree, the picker and every key that reaches a file already speak.
  it("is asked about the post-image path of a renamed file", function()
    local rec = recording(LUA)
    label({ path = "src/newname.lua", old_path = "src/oldname.lua", status = "R" }, { file_icon = rec.fn })
    assert.same({ { "src/newname.lua" } }, rec.calls)
  end)

  -- One label is one file named once. A second call per label is invisible on screen and is
  -- three hundred extra calls into a host's icon plugin on a large review.
  it("is asked exactly once for one label", function()
    local rec = recording(LUA)
    label(nil, { file_icon = rec.fn })
    assert.same(1, #rec.calls)
  end)
end)

describe("the glyph it answers with", function()
  it("arrives beside the state mark and never in place of it", function()
    local answer = label(nil, { file_icon = by_extension })
    assert.same(LUA, answer.file_icon)
    assert.same(ICONS.unreviewed, answer.icon)
  end)

  -- The rule the whole ticket rests on: a reviewer must not lose *this file is reviewed* in
  -- exchange for *this file is Lua*. Both states that have a mark of their own are asked,
  -- because a replacement would be invisible on the third one.
  it("leaves a reviewed file its reviewed mark", function()
    local answer = label(nil, { file_icon = by_extension, reviewed = { ["src/main.lua"] = "blob" } })
    assert.same(ICONS.reviewed, answer.icon)
    assert.same(LUA, answer.file_icon)
  end)

  it("leaves an annotated file its annotated mark", function()
    local answer = label(nil, { file_icon = by_extension, notes = { ["src/main.lua:n:1"] = { {} } } })
    assert.same(ICONS.annotated, answer.icon)
    assert.same(LUA, answer.file_icon)
  end)

  -- The prefix is what both surfaces draw in front of the path, so this is where the order
  -- of the three glyphs is decided -- once, rather than once per surface.
  it("goes after the chevron and before the path", function()
    assert.same(
      ("%s %s %s "):format(ICONS.unreviewed, ICONS.expanded, LUA),
      label(nil, { file_icon = by_extension }).prefix
    )
  end)

  it("follows the file rather than the reviewer, so two files can carry two glyphs", function()
    assert.same(MD, label({ path = "docs/readme.md" }, { file_icon = by_extension }).file_icon)
    assert.same(OTHER, label({ path = "src/blob.bin" }, { file_icon = by_extension }).file_icon)
  end)
end)

describe("a review with no adapter wired", function()
  it("gives a file no glyph at all", function()
    assert.is_nil(label().file_icon)
  end)

  -- **Byte for byte the row it has always drawn.** The separator rides with the glyph rather
  -- than standing beside it, so an absent glyph contributes nothing rather than a space --
  -- which would shift every path offset on every header row in every review by one, and look
  -- right on the screen while doing it.
  it("draws the prefix it has always drawn, byte for byte", function()
    assert.same(("%s %s "):format(ICONS.unreviewed, ICONS.expanded), label().prefix)
    assert.same(8, #label().prefix)
  end)
end)

-- A host's configuration is a host's, and this one is called once per file per paint. Every
-- way of being broken answers the same way, and it is the way no adapter answers: no glyph,
-- and a row that reads exactly as it reads with nothing wired.
describe("an adapter that cannot answer", function()
  local BARE = ("%s %s "):format(ICONS.unreviewed, ICONS.expanded)

  ---@param adapter any
  ---@return CRFileLabel
  local function survived(adapter)
    local answer = label(nil, { file_icon = adapter })
    assert.same(BARE, answer.prefix)
    return answer
  end

  it("is survived when it raises", function()
    assert.is_nil(survived(function()
      error("this host's icon plugin is not loaded")
    end).file_icon)
  end)

  it("is survived when it answers with nothing", function()
    assert.is_nil(survived(function() end).file_icon)
  end)

  -- An empty glyph is not a glyph. Drawn, it is the space behind it: a column of nothing in
  -- front of every path, and every offset behind it moved.
  it("is survived when it answers with an empty string", function()
    assert.is_nil(survived(function()
      return ""
    end).file_icon)
  end)

  -- What comes back is checked as well as caught. A number would reach the header row as
  -- `42` and a table as `table: 0x...`, both of them drawn, and both of them moving every
  -- byte offset on the row behind them.
  it("is survived when it answers with something that is not a glyph", function()
    assert.is_nil(survived(function()
      return 42
    end).file_icon)
    assert.is_nil(survived(function()
      return { "󰢱" }
    end).file_icon)
  end)

  it("is survived when what was wired is not a function at all", function()
    assert.is_nil(survived({ lua = LUA }).file_icon)
  end)
end)

-- The performance rule, asserted where it is kept rather than where it is felt: **there is
-- no glyph shipped behind this adapter and therefore no default implementation of it.** That
-- is the whole guarantee that a review with nothing wired calls nothing per file, and it is
-- what makes this adapter's shape different from the composer's and the checkout picker's,
-- which the plugin does ship a default implementation of (ADR-0003, ADR-0007). Those are
-- reached by a keystroke; this one would be reached three hundred times a paint.
describe("what the plugin ships behind the key", function()
  local config = require("codereview.config")

  it("ships nothing, so the default is an absence rather than a function to call", function()
    assert.is_nil(config.defaults.file_icon)
    assert.is_nil(config.get().file_icon)
  end)
end)

--- The header row ---------------------------------------------------------------

-- The first of the two surfaces, and the one the byte offsets live on. `render.build` is pure,
-- so which mark falls at which column is asserted here with no window, no fixture and no
-- repository, exactly as `path_spec` asserts the path's own two ranges.
local BARE = ("%s %s "):format(ICONS.unreviewed, ICONS.expanded)
local PREFIX = ("%s %s %s "):format(ICONS.unreviewed, ICONS.expanded, LUA)

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

---The marks that color a file's path on its header row, in column order.
---@param rendered CRRender
---@param fi integer
---@return table[]
local function path_marks(rendered, fi)
  local out = {}
  local row = assert(rendered.file_rows[fi])
  for _, m in ipairs(rendered.marks) do
    if m.row == row - 1 and (m.opts.hl_group == DIR or m.opts.hl_group == NAME) then
      out[#out + 1] = { m.col, m.opts.end_col, m.opts.hl_group }
    end
  end
  table.sort(out, function(a, b)
    return a[1] < b[1]
  end)
  return out
end

---@param rendered CRRender
---@param fi integer
---@return string
local function header_of(rendered, fi)
  return rendered.lines[assert(rendered.file_rows[fi])]
end

describe("the glyph on the header row", function()
  -- The guard the whole block rests on. Without it a mark placed at a display column and a
  -- mark placed at a byte offset land in the same place, and every case below passes either
  -- way.
  it("really is a glyph whose bytes and columns disagree", function()
    assert.is_true(#LUA > vim.fn.strdisplaywidth(LUA), "nothing multibyte in this glyph to measure")
    assert.same(11, #PREFIX)
    assert.same(6, vim.fn.strdisplaywidth(PREFIX))
  end)

  it("is drawn between the chevron and the path", function()
    local after = build({ one() }, { file_icon = by_extension })
    assert.same(PREFIX .. "src/main.lua", header_of(after, 1):sub(1, #PREFIX + #"src/main.lua"))
  end)

  -- **The byte offsets, which is what this ticket waited for #199 to land.** The path is
  -- colored in two ranges that start where the prefix ends, and the prefix is now three
  -- multibyte glyphs deep. A mark placed at the display column lands five bytes early and
  -- colors the glyph instead of the first directory.
  it("moves the path's own two ranges by its bytes and not by its columns", function()
    local after = build({ one() }, { file_icon = by_extension })
    local marks = path_marks(after, 1)
    assert.same({
      { #PREFIX, #PREFIX + #"src/", DIR },
      { #PREFIX + #"src/", #PREFIX + #"src/main.lua", NAME },
    }, marks)
    -- Read back off the row, which is the claim a computed expectation cannot make: the two
    -- ranges are the two halves of the path and nothing either side of them.
    local line = header_of(after, 1)
    assert.same("src/", line:sub(marks[1][1] + 1, marks[1][2]))
    assert.same("main.lua", line:sub(marks[2][1] + 1, marks[2][2]))
  end)

  -- The rule, on the surface a reviewer reads it on: the mark is still the first thing on the
  -- row, in its own column, whatever glyph the file carries beside it.
  it("leaves the state mark first on the row, in its own column", function()
    local cases = {
      { ICONS.unreviewed, {} },
      { ICONS.reviewed, { reviewed = { ["src/main.lua"] = "blob" } } },
      { ICONS.annotated, { notes = { ["src/main.lua:n:1"] = { {} } } } },
    }
    for _, case in ipairs(cases) do
      local opts = vim.tbl_extend("force", { file_icon = by_extension }, case[2])
      local line = header_of(build({ one() }, opts), 1)
      assert.same(case[1], line:sub(1, #case[1]))
      assert.is_truthy(line:find(LUA, 1, true), line)
    end
  end)

  it("asks the adapter once for each file the render draws", function()
    local rec = recording(LUA)
    build(
      { one({ path = "src/a.lua" }), one({ path = "src/b.lua" }), one({ path = "src/c.lua" }) },
      { file_icon = rec.fn }
    )
    assert.same({ { "src/a.lua" }, { "src/b.lua" }, { "src/c.lua" } }, rec.calls)
  end)

  -- **Solo** draws one file and no other, so it asks about one file and no other. The saving
  -- is free -- the walk gives way before the label is asked -- and this is where that stays
  -- true.
  it("asks about the one file a soloed render draws, and about no other", function()
    local rec = recording(LUA)
    build(
      { one({ path = "src/a.lua" }), one({ path = "src/b.lua" }), one({ path = "src/c.lua" }) },
      { file_icon = rec.fn, solo = 2 }
    )
    assert.same({ { "src/b.lua" } }, rec.calls)
  end)
end)

describe("a header row with no glyph on it", function()
  local FILES = {
    one(),
    one({ path = "README.md" }),
    one({ path = "src/newname.lua", old_path = "src/oldname.lua", status = "R" }),
  }

  it("is what it always was, byte for byte, with no adapter wired", function()
    local after = build(FILES)
    assert.same(BARE .. "src/main.lua", header_of(after, 1):sub(1, #BARE + #"src/main.lua"))
    assert.same({ #BARE, #BARE + #"src/", DIR }, path_marks(after, 1)[1])
  end)

  -- The strongest form of it, and the one that cannot be satisfied by a row that merely looks
  -- right: an adapter that raises leaves *every* row and *every* mark exactly as the review
  -- with nothing wired draws them.
  it("is what it always was when an adapter raises on every file", function()
    local none = build(FILES)
    local broken = build(FILES, {
      file_icon = function()
        error("no icon plugin here")
      end,
    })
    assert.same(none.lines, broken.lines)
    for fi = 1, #FILES do
      assert.same(path_marks(none, fi), path_marks(broken, fi))
    end
  end)
end)

describe("the right-hand side of a header row carrying a glyph", function()
  -- The padding is arithmetic in display columns, and a glyph is the first thing to reach it
  -- that a host chose. A glyph two columns wide is what proves the arithmetic is not counting
  -- bytes: `#` would give this one four.
  local WIDE = "🦀"

  it("keeps the stat against the right margin", function()
    local line = header_of(
      build({ one() }, {
        file_icon = function()
          return WIDE
        end,
      }),
      1
    )
    assert.is_true(#WIDE > vim.fn.strdisplaywidth(WIDE), "nothing multibyte in this glyph")
    assert.same("+1 -1", line:sub(#line - #"+1 -1" + 1))
    assert.same(60, vim.fn.strdisplaywidth(line))
  end)

  -- An `end_col` past the end of a row is a hard error, and a glyph is one more thing pushing
  -- a long path over the edge of a narrow pane.
  it("keeps every mark inside a row the glyph helped fill", function()
    local after = build({ one({ path = "apps/api/src/routes/users/handlers/create.ts" }) }, {
      width = 40,
      file_icon = by_extension,
    })
    local row = assert(after.file_rows[1])
    local line = after.lines[row]
    for _, m in ipairs(after.marks) do
      if m.row == row - 1 and m.opts.end_col then
        assert.is_true(
          m.opts.end_col <= #line,
          ("%s ends at %d past a row of %d"):format(m.opts.hl_group, m.opts.end_col, #line)
        )
      end
    end
  end)
end)

describe("the before pane's header row", function()
  local RENAME = one({ path = "src/newname.lua", old_path = "src/oldname.lua", status = "R" })

  -- The before pane indents its pre-image path to sit under the after pane's, and the indent
  -- is measured off the prefix rather than counted from its parts -- so it grows with the
  -- glyph. Counted, it would learn about the state mark and the chevron and about nothing
  -- else, and a renamed file's two paths would sit two columns apart.
  it("indents its path under the after pane's, past the glyph", function()
    local after, before = build({ RENAME }, { layout = "split", before_width = 60, file_icon = by_extension })
    local aline = header_of(after, 1)
    local bline = header_of(before, 1)
    local astart = assert(aline:find("src/newname.lua", 1, true))
    local bstart = assert(bline:find("src/oldname.lua", 1, true))
    assert.same(vim.fn.strdisplaywidth(aline:sub(1, astart - 1)), vim.fn.strdisplaywidth(bline:sub(1, bstart - 1)))
    -- The guard: over a prefix of bytes-equal-columns the case above passes on a byte count
    -- as well.
    assert.is_true(astart - 1 > vim.fn.strdisplaywidth(aline:sub(1, astart - 1)), "the prefix is not multibyte")
  end)
end)

--- The file tree -----------------------------------------------------------------

-- The third surface that names a file, and the one a reviewer looks at first. `panel.build`
-- is pure in the way `render.build` is -- files and options in, lines and marks out, with no
-- window and no repository behind it -- so every claim about what a tree row draws is
-- answerable here. The one that is not is that the glyph a tree row draws is the glyph that
-- file's header row draws; two surfaces agreeing is a property of neither, and it waits for
-- a review at the end of this file.
--
-- Hand-built file lists rather than the nested fixture `panel_spec` reads. That spec's row
-- assertions are structural, and an adapter wired into its process would move every one of
-- them -- its top-level listing is spelled out glyph by glyph. This is the first act's own
-- idiom, one surface over.
local panel = require("codereview.panel")

local TREE = {
  one({ path = "apps/api/src/routes/users.ts" }),
  one({ path = "apps/api/src/main.lua" }),
  one({ path = "docs/guide.md" }),
  one({ path = "README.md" }),
}
local WIDTH = 34

---@param opts table|nil
---@param files table[]|nil
---@return CRPanelRender
local function tree(opts, files)
  return panel.build(
    files or TREE,
    vim.tbl_extend("force", { width = WIDTH, icons = ICONS, reviewed = {}, notes = {}, collapsed = {} }, opts or {})
  )
end

---@param files table[]
---@param path string
---@return integer
local function index_of(files, path)
  for i, file in ipairs(files) do
    if file.path == path then
      return i
    end
  end
  error(path .. " is not in this file list")
end

---A file's row in a built tree: which row it is, and the line drawn on it.
---@param rendered CRPanelRender
---@param path string
---@param files table[]|nil
---@return integer row, string line
local function file_row(rendered, path, files)
  local row = assert(rendered.file_row[index_of(files or TREE, path)], path .. " has no row")
  return row, rendered.lines[row]
end

---@param rendered CRPanelRender
---@param dir string
---@return string
local function dir_row(rendered, dir)
  for row, path in pairs(rendered.row_dir) do
    if path == dir then
      return rendered.lines[row]
    end
  end
  error(dir .. " has no row")
end

---The leftmost highlighted range on a row, read back off the row itself.
---
---**Read rather than computed, because the rule is about a column.** The state mark is the
---first thing after the indent, so what the leftmost range covers *is* the state mark or the
---rule is broken -- and an expectation computed from the same offsets the row was built from
---would agree with a glyph that had taken the mark's place.
---@param rendered CRPanelRender
---@param row integer
---@return string text, string group
local function leading(rendered, row)
  local first
  for _, m in ipairs(rendered.marks) do
    if m.row == row - 1 and m.opts.end_col and (not first or m.col < first.col) then
      first = m
    end
  end
  assert(first, "no highlighted range on that row")
  return rendered.lines[row]:sub(first.col + 1, first.opts.end_col), first.opts.hl_group
end

---@param line string
---@param head string
local function begins(line, head)
  assert.same(head, line:sub(1, #head))
end

describe("the glyph on a tree row", function()
  it("is drawn between the state mark and the name", function()
    local _, line = file_row(tree({ file_icon = by_extension }), "apps/api/src/main.lua")
    begins(line, ("  %s %s main.lua"):format(ICONS.unreviewed, LUA))
  end)

  -- The rule the whole ticket rests on, on the surface a reviewer scans down: the mark is
  -- still the first thing after the indent and the range that colors it still covers it,
  -- whatever glyph the file carries beside it. All three states are asked, because a glyph
  -- that had taken the mark's place would be invisible on any two of them.
  it("leaves the state mark first on the row, in its own column", function()
    local cases = {
      { ICONS.unreviewed, {} },
      { ICONS.reviewed, { reviewed = { ["apps/api/src/main.lua"] = "blob" } } },
      { ICONS.annotated, { notes = { ["apps/api/src/main.lua:n:1"] = { {} } } } },
    }
    for _, case in ipairs(cases) do
      local rendered = tree(vim.tbl_extend("force", { file_icon = by_extension }, case[2]))
      local row, line = file_row(rendered, "apps/api/src/main.lua")
      begins(line, ("  %s %s "):format(case[1], LUA))
      assert.same(case[1], (leading(rendered, row)))
    end
  end)

  it("follows the file rather than the reviewer, so two files can carry two glyphs", function()
    local rendered = tree({ file_icon = by_extension })
    begins(select(2, file_row(rendered, "docs/guide.md")), ("  %s %s guide.md"):format(ICONS.unreviewed, MD))
    begins(
      select(2, file_row(rendered, "apps/api/src/routes/users.ts")),
      ("    %s %s users.ts"):format(ICONS.unreviewed, OTHER)
    )
  end)

  -- The tree shows a basename and the adapter is handed the whole path -- which is what lets
  -- the tree and the diff reach the same answer for the same file at all.
  it("is handed the file's repository-relative path and nothing else", function()
    local rec = recording(LUA)
    tree({ file_icon = rec.fn }, { one({ path = "apps/api/src/main.lua" }) })
    assert.same({ { "apps/api/src/main.lua" } }, rec.calls)
  end)

  -- **The directory decision, asserted as the absence it is.** A directory names no file, so
  -- there is nothing to ask about it, and the adapter is reached from the file branch and
  -- from nowhere else. `apps/api/src`, `apps/api/src/routes` and `docs` are all drawn here
  -- and none of them is in this list.
  it("asks about every file it draws, once each, and about no directory", function()
    local rec = recording(LUA)
    tree({ file_icon = rec.fn })
    local asked = {}
    for _, call in ipairs(rec.calls) do
      asked[#asked + 1] = call[1]
    end
    table.sort(asked)
    assert.same({
      "README.md",
      "apps/api/src/main.lua",
      "apps/api/src/routes/users.ts",
      "docs/guide.md",
    }, asked)
  end)
end)

describe("a directory row", function()
  it("draws no glyph, whatever the adapter would answer for its path", function()
    local none, wired = tree(), tree({ file_icon = by_extension })
    for _, dir in ipairs({ "apps/api/src", "apps/api/src/routes", "docs" }) do
      assert.same(dir_row(none, dir), dir_row(wired, dir))
    end
  end)

  it("keeps its chevron, its compacted chain and its N/M count", function()
    local line = dir_row(tree({ file_icon = by_extension }), "apps/api/src")
    begins(line, ("%s apps/api/src"):format(ICONS.expanded))
    assert.same("0/2", line:match("(%d+/%d+)%s*$"))
  end)
end)

describe("a tree row with no glyph on it", function()
  -- **Byte for byte the row it has always drawn.** The separator rides with the glyph rather
  -- than standing beside it, so a file with no glyph contributes nothing rather than a space
  -- -- which would move every name in every tree by one column and look right while doing it.
  it("is what it always was, with no adapter wired", function()
    begins(select(2, file_row(tree(), "apps/api/src/main.lua")), ("  %s main.lua"):format(ICONS.unreviewed))
  end)

  -- The strongest form, and the one a row that merely looks right cannot satisfy: an adapter
  -- that raises on every file leaves every line and every mark exactly as no adapter does.
  it("is what it always was when an adapter raises on every file", function()
    local broken = tree({
      file_icon = function()
        error("no icon plugin here")
      end,
    })
    assert.same(tree().lines, broken.lines)
    assert.same(tree().marks, broken.marks)
  end)
end)

-- A host's configuration is a host's, and this one is asked once per file on every paint and
-- on every file crossing. Every way of being broken answers the same way, and it is the way
-- no adapter answers: no glyph, and a row that reads exactly as it reads with nothing wired.
describe("an adapter the tree cannot use", function()
  local BARE_ROW = ("  %s main.lua"):format(ICONS.unreviewed)

  ---@param adapter any
  local function survives(adapter)
    begins(select(2, file_row(tree({ file_icon = adapter }), "apps/api/src/main.lua")), BARE_ROW)
  end

  it("is survived when it raises", function()
    survives(function()
      error("this host's icon plugin is not loaded")
    end)
  end)

  it("is survived when it answers with nothing", function()
    survives(function() end)
  end)

  -- An empty glyph is not a glyph. Drawn, it is the separator behind it: a column of nothing
  -- in front of every name, and every name in the tree moved along by one.
  it("is survived when it answers with an empty string", function()
    survives(function()
      return ""
    end)
  end)

  -- A number would draw as `42` and a table as `table: 0x...`, both of them pushing the name
  -- along behind them.
  it("is survived when it answers with something that is not a glyph", function()
    survives(function()
      return 42
    end)
    survives(function()
      return { "󰢱" }
    end)
  end)

  it("is survived when what was wired is not a function at all", function()
    survives({ lua = LUA })
  end)
end)

describe("a panel too narrow for the name", function()
  local NARROW = 20
  local LONG = { one({ path = "src/very-long-handler-name.ts" }) }

  ---@param opts table|nil
  ---@return CRPanelRender
  local function narrow(opts)
    return panel.build(
      LONG,
      vim.tbl_extend(
        "force",
        { width = NARROW, icons = ICONS, reviewed = {}, notes = {}, collapsed = {}, file_icon = by_extension },
        opts or {}
      )
    )
  end

  -- What survives the cut is the end of the name, which is where the extension is -- and the
  -- extension is what the glyph is about. The mark and the glyph are not what is spent.
  it("cuts the path, and never the glyph or the mark", function()
    local rendered = narrow()
    local row, line = file_row(rendered, "src/very-long-handler-name.ts", LONG)
    begins(line, ("  %s %s …"):format(ICONS.unreviewed, OTHER))
    assert.same(ICONS.unreviewed, (leading(rendered, row)))
    assert.is_true(vim.fn.strdisplaywidth(line) <= NARROW, line)
  end)

  it("keeps the note count against the right margin", function()
    local rendered = narrow({ notes = { ["src/very-long-handler-name.ts:n:1"] = { {}, {} } } })
    local _, line = file_row(rendered, "src/very-long-handler-name.ts", LONG)
    assert.same("2", line:sub(-1))
    assert.is_true(vim.fn.strdisplaywidth(line) <= NARROW, line)
  end)

  -- An `end_col` past the end of a row is a hard error, and a glyph is one more thing pushing
  -- a long name over the edge of a panel this narrow.
  it("keeps every mark inside the row the glyph helped fill", function()
    local rendered = narrow({ notes = { ["src/very-long-handler-name.ts:n:1"] = { {}, {} } } })
    for _, m in ipairs(rendered.marks) do
      local line = rendered.lines[m.row + 1]
      if m.opts.end_col then
        assert.is_true(
          m.opts.end_col <= #line,
          ("%s ends at %d past a row of %d"):format(m.opts.hl_group, m.opts.end_col, #line)
        )
      end
    end
  end)
end)

describe("a file name that is not ASCII", function()
  local ACCENTED = { one({ path = "src/ünïcödé-nàme.lua" }) }

  it("is drawn whole with a glyph in front of it", function()
    local _, line = file_row(tree({ file_icon = by_extension }, ACCENTED), "src/ünïcödé-nàme.lua", ACCENTED)
    begins(line, ("  %s %s ünïcödé-nàme.lua"):format(ICONS.unreviewed, LUA))
    assert.is_true(vim.fn.strdisplaywidth(line) <= WIDTH, line)
  end)

  -- Cut from the left in characters and not in bytes: a cut inside a multibyte character is
  -- a rendering error, and every character in this name is two bytes long.
  it("is cut on a character boundary when the panel is too narrow for it", function()
    local rendered = panel.build(ACCENTED, {
      width = 18,
      icons = ICONS,
      reviewed = {},
      notes = {},
      collapsed = {},
      file_icon = by_extension,
    })
    local _, line = file_row(rendered, "src/ünïcödé-nàme.lua", ACCENTED)
    begins(line, ("  %s %s …"):format(ICONS.unreviewed, LUA))
    assert.is_truthy(line:find("nàme.lua", 1, true), line)
    assert.same(vim.fn.strcharlen(line), vim.fn.strcharlen(vim.fn.strcharpart(line, 0)))
  end)
end)

describe("an empty scope", function()
  it("draws an empty tree and raises nothing", function()
    local rendered = tree({ file_icon = by_extension }, {})
    assert.same({ "", "0/0 reviewed" }, rendered.lines)
    assert.same({}, rendered.file_rows)
  end)
end)

-- **The performance rule, and the one claim here a row cannot make.** With nothing wired the
-- tree draws the same row whether it guards the call or not: a `pcall` over a nil adapter
-- answers with no glyph, exactly as no adapter does. So the row is silent about the only
-- thing that matters -- whether the tree reached for the rule at all, once for every file, on
-- every paint *and* on every file crossing.
--
-- The rule itself is therefore watched. The guarantee underneath it is the one #200 made
-- structural and the block above keeps: there is no glyph shipped behind this adapter, so
-- with nothing wired there is nothing to call.
describe("the rule the tree reaches for", function()
  ---Run a build with `render.file_icon` counted, and put it back afterwards.
  ---@param opts table|nil
  ---@return integer
  local function calls_during(opts)
    local real = render.file_icon
    local calls = 0
    render.file_icon = function(...)
      calls = calls + 1
      return real(...)
    end
    local ok, err = pcall(tree, opts)
    render.file_icon = real
    assert.is_true(ok, tostring(err))
    return calls
  end

  -- First, so that the zero below is *not called* rather than *not watching*. A case about an
  -- absence needs a case that proves the instrument can see a presence.
  it("is reached once for each file when an adapter is wired", function()
    assert.same(#TREE, calls_during({ file_icon = by_extension }))
  end)

  it("is not reached at all, for any file, with nothing wired", function()
    assert.same(0, calls_during())
  end)
end)

--- Both surfaces, one glyph -----------------------------------------------------

-- The last two acts need a review, because what they assert is that the **sticky header** and
-- the header row say one thing about one file -- which no assertion made against either
-- surface alone can say.
--
-- The order is the one `open_diff_spec` runs in and for the same reason: `setup` is a
-- process, so the review with nothing wired has to be read before anything is injected.
h.ui(120, 45)
h.cd_fixture("mkfixture")

local view = require("codereview.view")

---@return CRView
local function current()
  return assert(view.current(), "no review view open")
end

---Read a file the way a reviewer does, so the bar names the file under the cursor.
---@param path string
local function read_into(path)
  local V = current()
  local index = assert(h.file_index(V, path), path .. " is not in this scope")
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { assert(V.render.file_rows[index]) + 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
end

---That file's header row, as the buffer holds it.
---@param path string
---@return string
local function header(path)
  local V = current()
  local row = assert(V.render.file_rows[assert(h.file_index(V, path))])
  return vim.api.nvim_buf_get_lines(V.buf, row - 1, row, false)[1]
end

---That file's row in the **file tree**, as the panel buffer holds it.
---@param path string
---@return string
local function tree_line(path)
  local V = current()
  local row = assert(V.panel_render.file_row[assert(h.file_index(V, path))], path .. " has no tree row")
  return vim.api.nvim_buf_get_lines(V.panel_buf, row - 1, row, false)[1]
end

require("codereview").setup({ syntax = false })

describe("a review opened with no adapter wired", function()
  view.open("branch")
  read_into("src/main.lua")

  it("draws the header row it has always drawn", function()
    assert.same(BARE .. "src/main.lua", header("src/main.lua"):sub(1, #BARE + #"src/main.lua"))
  end)

  it("draws the sticky header it has always drawn", function()
    local bar = h.winbar(current().win)
    assert.is_truthy(bar:find(BARE .. "src/main.lua", 1, true), bar)
  end)

  it("draws the tree row it has always drawn", function()
    assert.same(("%s main.lua"):format(ICONS.unreviewed), vim.trim(tree_line("src/main.lua")))
  end)

  view.close()
end)

--- With one injected -------------------------------------------------------------

-- `src/nonl.md` is given a glyph no host would choose, and that is deliberate: a bar is a
-- statusline, and a glyph is a name the plugin did not choose. `%f` on a bar that did not
-- escape it expands into the window's own file name -- which is not even the file being
-- named. The rule is `path_spec`'s `src/50%f done.lua`, arriving at the bar through the other
-- door.
local PERCENT = "%f"

require("codereview").setup({
  syntax = false,
  file_icon = function(path)
    return path == "src/nonl.md" and PERCENT or by_extension(path)
  end,
})

view.open("branch")

describe("a file's glyph on both surfaces", function()
  it("is drawn on the header row, after the chevron and before the path", function()
    read_into("src/main.lua")
    assert.same(PREFIX .. "src/main.lua", header("src/main.lua"):sub(1, #PREFIX + #"src/main.lua"))
  end)

  it("is drawn on the sticky header, and it is the same glyph", function()
    read_into("src/main.lua")
    local bar = h.winbar(current().win)
    assert.is_truthy(bar:find(PREFIX .. "src/main.lua", 1, true), bar)
  end)

  -- One file, one icon: a second file with a glyph of its own is what says the bar is naming
  -- *this* file rather than carrying a glyph the plugin liked.
  it("follows the cursor from one file to the next", function()
    read_into("src/nonl.md")
    local bar = h.winbar(current().win)
    assert.is_truthy(bar:find("src/nonl.md", 1, true), bar)
    assert.is_nil(bar:find(LUA, 1, true), bar)
  end)

  -- The escape, on the surface that needs one. `%f` reaches the bar as `%f` and not as a
  -- statusline item, because the head it rides in is a literal and a literal doubles every
  -- `%` in it.
  it("is drawn literally on the winbar, whatever a host put in it", function()
    read_into("src/nonl.md")
    local head = ("%s %s %s src/nonl.md"):format(ICONS.unreviewed, ICONS.expanded, PERCENT)
    local bar = h.winbar(current().win)
    assert.is_truthy(bar:find(head, 1, true), bar)
    -- And the header row draws the same two characters, so neither surface is reading a name
    -- as markup.
    assert.same(head, header("src/nonl.md"):sub(1, #head))
  end)

  -- Quiet, like the mark and the chevron it sits with: it is chrome in front of the name, and
  -- the name is what should be the brightest thing on the left.
  it("is drawn in the group the mark and the chevron are drawn in", function()
    read_into("src/main.lua")
    assert.same("CodeReviewBarIcon", h.winbar_group(current().win, LUA))
  end)
end)

-- **The claim the pure seam cannot make.** That the glyph a **file tree** row draws is the
-- glyph that file's header row draws is a property of neither surface on its own, so it is
-- asserted with a review open and both of them built. Both glyphs are read back off the rows
-- rather than spelled again here: an expectation written twice agrees with itself whatever
-- the two surfaces do.
describe("the same glyph on the tree and on the diff", function()
  ---The glyph a header row draws: the third field, after the state mark and the chevron.
  ---@param path string
  ---@return string|nil
  local function on_the_diff(path)
    return header(path):match("^%S+ %S+ (%S+) ")
  end

  ---The glyph a tree row draws: the second field, after the indent and the state mark.
  ---@param path string
  ---@return string|nil
  local function on_the_tree(path)
    return tree_line(path):match("^%s*%S+ (%S+) ")
  end

  it("is one glyph for one file", function()
    read_into("src/main.lua")
    -- Named first, so that the two surfaces agreeing is not two nils agreeing.
    assert.same(LUA, on_the_diff("src/main.lua"))
    assert.same(on_the_diff("src/main.lua"), on_the_tree("src/main.lua"))
  end)

  -- A second file with a glyph of its own, and one the plugin would never choose: what says
  -- the tree is answering about *this* file rather than carrying a glyph it liked.
  it("is a different glyph for a different file, on both surfaces at once", function()
    read_into("src/nonl.md")
    assert.same(PERCENT, on_the_diff("src/nonl.md"))
    assert.same(on_the_diff("src/nonl.md"), on_the_tree("src/nonl.md"))
  end)

  -- And the tree row still says what it said before the glyph arrived: the state mark first
  -- after the indent, then the glyph, then the name.
  it("leaves the tree's state mark first on its row", function()
    read_into("src/main.lua")
    assert.same(("%s %s main.lua"):format(ICONS.unreviewed, LUA), vim.trim(tree_line("src/main.lua")))
  end)
end)

describe("the state a file's mark carries, with a glyph beside it", function()
  it("is still on both surfaces before the file is reviewed", function()
    read_into("src/main.lua")
    assert.same(ICONS.unreviewed, header("src/main.lua"):sub(1, #ICONS.unreviewed))
    assert.is_truthy(h.winbar(current().win):find(ICONS.unreviewed, 1, true))
  end)

  -- The claim in the ticket's own words: a reviewer must not lose *this file is reviewed* in
  -- exchange for *this file is Lua*. Marked through the exported action, so what is read is
  -- the review a reviewer would be looking at.
  it("becomes the reviewed mark on both surfaces when the file is marked", function()
    read_into("src/main.lua")
    view.toggle_reviewed()
    read_into("src/main.lua")
    local line = header("src/main.lua")
    assert.same(ICONS.reviewed, line:sub(1, #ICONS.reviewed))
    -- Reviewed means collapsed, so the chevron turns with it -- and the glyph is still there
    -- between that chevron and the path.
    assert.same(
      ("%s %s %s src/main.lua"):format(ICONS.reviewed, ICONS.collapsed, LUA),
      line:sub(1, #("%s %s %s src/main.lua"):format(ICONS.reviewed, ICONS.collapsed, LUA))
    )
    local bar = h.winbar(current().win)
    assert.is_truthy(bar:find(("%s %s %s src/main.lua"):format(ICONS.reviewed, ICONS.collapsed, LUA), 1, true), bar)
  end)
end)
