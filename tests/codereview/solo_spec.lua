-- **Solo**: the review view draws one file -- the file being read -- and none of the others.
--
-- Two acts, after the split layout's example. This first one needs no window at all.
-- `render.build` is told which file to draw and returns data, so which files have rows,
-- where a header lands and what every anchor names are properties of that data -- asserted
-- here the way pane parity and anchor totality already are, and as cheaply.
--
-- What this act is really proving is the index-space decision (ADR-0009). The render is
-- told which file to draw and is never handed a shorter list, so the file index in every
-- anchor, in `file_rows` and in the header row it points at is still the *true* index into
-- the review's file list. Had the caller filtered its own list to one entry instead, every
-- one of these cases would still pass with the index reading 1 -- while the file tree, the
-- file picker and the reviewed marks went on speaking the real index. That is why the
-- assertions below are about *which* index and not merely about how many files were drawn.
--
-- Syntax is off. Nothing here reads a colour, and a treesitter pass on a fixture this file
-- never opens a window on would be work for no assertion.
local h = require("tests.helpers")

h.ui(120, 45)
local root = h.cd_fixture("mkfixture")

require("codereview").setup({ syntax = false })

local config = require("codereview.config")
local git = require("codereview.git")
local render = require("codereview.render")

--- Pure: no windows ------------------------------------------------------------

local scope = assert(git.resolve_scope("branch", root))
local files = assert(git.collect(scope, root, { context = 3, untracked = true }))

---@param opts table|nil Overrides on top of a plain 60-column unified render
---@return CRRender after, CRRender|nil before
local function build(opts)
  local cfg = config.get()
  return render.build(
    files,
    vim.tbl_extend("force", {
      width = 60,
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

---Which file indices a render actually drew rows for, ascending.
---
---Read off the anchors rather than off `file_rows`, because "which files have rows" is the
---claim and `file_rows` is one of the things under test: a map naming a file the walk never
---drew would satisfy an assertion made against itself.
---@param rendered CRRender
---@return integer[]
local function files_drawn(rendered)
  local seen, out = {}, {}
  for row = 1, #rendered.lines do
    local fi = rendered.anchors[row].file
    if not seen[fi] then
      seen[fi], out[#out + 1] = true, fi
    end
  end
  table.sort(out)
  return out
end

---The keys of a `file_rows` map, ascending. `#` is no answer over a sparse table.
---@param rendered CRRender
---@return integer[]
local function file_rows_keys(rendered)
  local out = vim.tbl_keys(rendered.file_rows)
  table.sort(out)
  return out
end

---The rows the full render spends on one file: its header down to the row before the next
---file's, which is where everything that asks where a file is drawn takes its span from.
---@param rendered CRRender
---@param fi integer
---@return string[]
local function rows_of(rendered, fi)
  local first = assert(rendered.file_rows[fi])
  local next_header = rendered.file_rows[fi + 1]
  return vim.list_slice(rendered.lines, first, next_header and next_header - 1 or #rendered.lines)
end

-- A file in the middle of the list, so that "the true index" is a number no accident
-- produces: not 1, which a collapsed index space would also give, and not the last, which
-- the end of the walk would.
local MAIN = "src/main.lua"

describe("the configuration option", function()
  -- Read off the defaults rather than off a `setup` this file made, which is what
  -- `spans_spec` and `faded_spec` do with theirs: the claim is about what a host that says
  -- nothing gets, and a `setup` here would be this file answering its own question.
  it("is off, so a reviewer who does nothing sees the review they already had", function()
    assert.is_false(config.defaults.solo)
  end)
end)

describe("a render told which file to draw", function()
  local fi = index_of(MAIN)
  local one = build({ solo = fi })

  it("draws that file and no other", function()
    assert.same({ fi }, files_drawn(one))
  end)

  it("puts its header row at its own true index, and no other index in the map", function()
    assert.same({ fi }, file_rows_keys(one))
    assert.same(1, one.file_rows[fi], "the soloed file's header is not the first row drawn")
  end)

  it("names that file in every anchor and no other", function()
    for row = 1, #one.lines do
      local a = one.anchors[row]
      assert.is_table(a, ("row %d has no anchor"):format(row))
      assert.same(fi, a.file, ("row %d names file %s"):format(row, tostring(a.file)))
    end
  end)

  -- Solo decides which files are drawn and nothing about how one of them is drawn. The
  -- gutter is still measured across every file in the review, so a soloed file does not
  -- shift sideways when its neighbours stop being drawn -- which an assertion about row
  -- counts alone would never notice.
  it("draws it exactly as the full render draws it", function()
    assert.same(rows_of(build(), fi), one.lines)
  end)

  it("draws every file when it is told nothing", function()
    local all = build()
    local every = {}
    for i = 1, #files do
      every[i] = i
    end
    assert.same(every, files_drawn(all))
    assert.same(every, file_rows_keys(all))
    -- Nil is the same answer as absent, so a caller that carries the option unset is the
    -- caller that never had one.
    assert.same(all, (build({ solo = nil })))
  end)
end)

describe("a soloed split", function()
  local fi = index_of(MAIN)
  local after, before = build({ solo = fi, layout = "split", before_width = 60 })

  -- Equal to each other *and* to what that one file spends in a full split render. Parity
  -- alone is structural -- the two panes cannot disagree, because one walk emits both -- so
  -- an assertion that stopped there would pass just as well with solo doing nothing.
  it("gives two panes of equal height, and it is one file's height", function()
    local full = build({ layout = "split", before_width = 60 })
    assert.same(#after.lines, #before.lines)
    assert.same(#rows_of(full, fi), #after.lines)
  end)

  it("puts the file's header on the same row in both panes, at its true index", function()
    assert.same(after.file_rows, before.file_rows)
    assert.same({ fi }, file_rows_keys(after))
    assert.same({ fi }, file_rows_keys(before))
  end)

  it("names that file in every anchor of both panes", function()
    for row = 1, #after.lines do
      assert.same(fi, after.anchors[row].file, ("after pane, row %d"):format(row))
      assert.same(fi, before.anchors[row].file, ("before pane, row %d"):format(row))
    end
  end)
end)

describe("a soloed file that is collapsed", function()
  local fi = index_of(MAIN)

  -- Collapsed is what a reviewed file is drawn as, so this is the state the view is in the
  -- moment `R` is pressed on the file on screen. Its body is not emitted; its header must
  -- be, or the view is blank with a file selected.
  it("still has its header row", function()
    local one = build({ solo = fi, expanded = { [MAIN] = false }, reviewed = { [MAIN] = "blob" } })
    assert.same({ fi }, file_rows_keys(one))
    assert.same(1, one.file_rows[fi])
    assert.is_true(one.lines[1]:find(MAIN, 1, true) ~= nil, ("row 1 is %q"):format(one.lines[1]))
  end)
end)

describe("an empty scope", function()
  -- A scope with nothing in it behaves as it always did. There is no file to solo, so being
  -- told to draw one is being told nothing, and the review is empty rather than broken.
  it("draws an empty review rather than failing", function()
    local cfg = config.get()
    local empty = render.build({}, {
      width = 60,
      icons = cfg.icons,
      expanded = {},
      reviewed = {},
      notes = {},
      types = cfg.types,
      solo = 1,
    })
    assert.same({}, empty.lines)
    assert.same({}, empty.file_rows)
    assert.same({}, empty.anchors)
  end)
end)
