-- Treesitter harvest and replay.
--
-- The fixture is Lua and Markdown because Neovim core ships both parsers *and* their
-- `highlights` queries. Nothing here needs nvim-treesitter or a compiler, so CI exercises
-- the real parse -> capture -> anchor -> byte-column path on a bare Neovim.
local h = require("tests.helpers")

local syntax = require("codereview.syntax")
local config = require("codereview.config")

h.ui(110, 40)
h.cd_fixture("mkfixture")

describe("language detection", function()
  it("maps an extension to a parser language", function()
    assert.same("lua", syntax.lang_for("x/y.lua"))
    assert.same("markdown", syntax.lang_for("docs/guide.md"))
  end)

  it("returns nil for an extension with no filetype", function()
    assert.is_nil(syntax.lang_for("a/b.zzzz"))
  end)

  -- Rust and Go have filetypes but no bundled parser. `lang_for` must not claim them, or
  -- every .rs file in a diff pays for a file read and a doomed parse.
  --
  -- This is the check that caught the real bug: `vim.treesitter.language.add()` is lazy in
  -- 0.12 and returns true for a language with no parser installed, so availability has to
  -- be proven by instantiating a parser.
  it("returns nil for a filetype whose parser is not installed", function()
    assert.is_nil(syntax.lang_for("a/b.rs"))
    assert.is_nil(syntax.lang_for("a/b.go"))
  end)

  -- The multi-language path is exercised by the fixture itself (Lua and Markdown in one
  -- buffer). This case only proves an out-of-core language resolves when it is present,
  -- so it stands down rather than failing on a bare CI runner.
  local ts = syntax.lang_for("src/app.ts")
  if ts then
    it("resolves typescript when its parser is installed", function()
      assert.same("typescript", ts)
    end)
  else
    pending("typescript parser is not installed")
  end
end)

require("codereview").setup({})
local view = require("codereview.view")

-- What the open below costs in git invocations, counted through the two functions that make
-- them. Snapshotted the moment the review is open, because later cases in this file clear
-- the memo and repaint, and the claim is about one pass.
local git = require("codereview.git")
local fetch = { batches = 0, sides = 0, single = 0 }
do
  local one, many = git.file_content, git.file_contents
  git.file_contents = function(items, ...)
    fetch.batches, fetch.sides = fetch.batches + 1, fetch.sides + #items
    return many(items, ...)
  end
  git.file_content = function(path, ref, ...)
    -- A nil ref is read off the disk and spawns nothing, so it is not what this counts.
    if ref then
      fetch.single = fetch.single + 1
    end
    return one(path, ref, ...)
  end
end

---@type { batches: integer, sides: integer, single: integer }
local opened

describe("replaying captures onto the diff", function()
  view.open("branch")
  opened = vim.deepcopy(fetch)
  local V = view.current()
  local marks = h.syntax_marks(V)

  it("produces syntax extmarks", function()
    assert.is_true(#marks > 0)
  end)

  -- The load-bearing check: does every syntax extmark cover exactly the token it came
  -- from? This validates parse -> capture -> anchor -> byte-column in one shot.
  it("covers exactly the token text each capture came from", function()
    local buf_lines = vim.api.nvim_buf_get_lines(V.buf, 0, -1, false)
    for _, m in ipairs(marks) do
      local row, col, ec = m[2], m[3], m[4].end_col
      local anchor = V.render.anchors[row + 1]
      if anchor and anchor.kind == "line" then
        local ln = V.files[anchor.file].hunks[anchor.hunk].lines[anchor.line]
        local text = buf_lines[row + 1]:sub(col + 1, ec)
        -- The covered bytes must lie inside the code text, never over the gutter.
        assert.is_true(col >= anchor.col, ("row %d: col %d is left of the gutter"):format(row + 1, col))
        assert.is_true(text ~= "", ("row %d: empty span"):format(row + 1))
        assert.is_truthy(ln.text:find(text, 1, true), ("row %d: %q not in %q"):format(row + 1, text, ln.text))
      end
    end
  end)

  -- A **faded** file's tokens are replayed in the blended twin of the same group, which is
  -- that group's own name behind the family's prefix -- so the check is made on the name
  -- underneath it. What must never appear either way is a name no colorscheme can reach.
  local FADED = "CodeReviewFaded."

  it("uses @-prefixed treesitter groups a colorscheme can color", function()
    for _, m in ipairs(marks) do
      local group = m[4].hl_group
      local bare = group:sub(1, #FADED) == FADED and group:sub(#FADED + 1) or group
      assert.same("@", bare:sub(1, 1), group)
    end
  end)

  -- Deleted lines come from the pre-image parse, added lines from the post-image. If only
  -- one side were wired up this would still produce plenty of marks.
  it("highlights both sides of the diff", function()
    local sides = {}
    for _, m in ipairs(marks) do
      local a = V.render.anchors[m[2] + 1]
      if a and a.kind == "line" then
        sides[V.files[a.file].hunks[a.hunk].lines[a.line].side] = true
      end
    end
    assert.is_true(sides.add, "no added line was highlighted")
    assert.is_true(sides.del, "no deleted line was highlighted")
  end)

  -- One buffer, two languages. A single `vim.treesitter.start` cannot do this, which is
  -- the whole reason captures are harvested from strings and replayed as extmarks.
  it("highlights files of different languages in the same buffer", function()
    local langs = {}
    for _, m in ipairs(marks) do
      local a = V.render.anchors[m[2] + 1]
      if a and a.kind == "line" then
        langs[syntax.lang_for(V.files[a.file].path)] = true
      end
    end
    assert.is_true(langs.lua, "no Lua file was highlighted")
    assert.is_true(langs.markdown, "no Markdown file was highlighted")
  end)
end)

describe("caching and laziness", function()
  local V = view.current()

  -- The reason `apply` decides what is due before it paints any of it. Fetched one file at
  -- a time, a review costs a git process per file that comes near the window -- which on a
  -- wide change is a process per file in it. The count is what says the work has not moved
  -- back: it stays at one however many files the pass brings into view.
  it("fetches every side one pass needs in a single git call", function()
    assert.is_true(opened.sides > 1, "the open had nothing to batch, so this proves nothing")
    assert.same(1, opened.batches)
    assert.same(0, opened.single)
  end)

  it("memoises captures per file and side", function()
    assert.is_true(vim.tbl_count(V.syntax_cache) > 0)
  end)

  it("never parses a binary file", function()
    assert.is_nil(V.syntax_cache["src/untracked.bin|after"])
  end)

  -- Reviewing a file collapses it; a repaint must then do no syntax work for it, and the
  -- memo must not be re-derived for anything else either.
  it("does no work for a collapsed file", function()
    local fi = assert(h.file_index(V, "src/main.lua"))
    V.syntax_cache = {}
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    view.toggle_reviewed()
    assert.is_nil(V.syntax_cache["src/main.lua|after"])
    assert.is_not_nil(V.syntax_cache["src/routes.lua|after"])
  end)

  it("parses it again when it is expanded", function()
    view.toggle_reviewed()
    assert.is_not_nil(V.syntax_cache["src/main.lua|after"])
  end)
end)

-- The map `apply` looks rows up in, rather than rebuilding per call. Its risk is not the
-- caching but the invalidation: a map that outlives the render it was inverted from still
-- produces well-formed extmarks, in the right groups, on rows that now hold other code.
describe("the row map behind the replay", function()
  local V = view.current()

  ---Assert the map describes the render that is on screen: every row it records is anchored
  ---to that same file at that same byte column, keyed by the source line drawn there, and
  ---each file's bounds are exactly the rows it occupies -- those are what decide whether a
  ---file is near enough to the window to be parsed.
  ---
  ---Both images are read out of `V.render.anchors`, which holds for the unified layout only;
  ---this spec never opens the split one.
  local function agrees_with_render()
    local rows = assert(V.syntax_rows, "no row map on the view")
    assert.is_true(vim.tbl_count(rows) > 0, "the map covers no file")
    for fi, per_file in pairs(rows) do
      local first, last = math.huge, 0
      local function check(side, key_of)
        for line, slot in pairs(side) do
          local a = V.render.anchors[slot.row]
          assert.is_truthy(a, ("row %d is anchored to nothing"):format(slot.row))
          assert.same("line", a.kind)
          assert.same(fi, a.file)
          assert.same(a.col, slot.col)
          assert.same(line, key_of(V.files[a.file].hunks[a.hunk].lines[a.line]))
          first, last = math.min(first, slot.row), math.max(last, slot.row)
        end
      end
      check(per_file.after, function(ln)
        return ln.new
      end)
      check(per_file.before, function(ln)
        return ln.old
      end)
      assert.same({ first = first, last = last }, { first = per_file.first, last = per_file.last })
    end
  end

  ---Every syntax extmark covers exactly the token its capture came from, judged against the
  ---buffer as it stands now. This is the symptom a stale map produces, and the reason the
  ---invalidation is the careful half.
  local function marks_cover_their_tokens()
    local marks = h.syntax_marks(V)
    assert.is_true(#marks > 0, "nothing is highlighted")
    local buf_lines = vim.api.nvim_buf_get_lines(V.buf, 0, -1, false)
    for _, m in ipairs(marks) do
      local a = V.render.anchors[m[2] + 1]
      if a and a.kind == "line" then
        local ln = V.files[a.file].hunks[a.hunk].lines[a.line]
        local text = buf_lines[m[2] + 1]:sub(m[3] + 1, m[4].end_col)
        assert.is_truthy(ln.text:find(text, 1, true), ("row %d: %q not in %q"):format(m[2] + 1, text, ln.text))
      end
    end
  end

  it("holds a map of the render on the view", function()
    agrees_with_render()
  end)

  it("records the row and byte column each source line is drawn at", function()
    local row = assert(h.line_row(V, "src/main.lua"))
    local a = V.render.anchors[row]
    local ln = V.files[a.file].hunks[a.hunk].lines[a.line]
    local side = ln.new and "after" or "before"
    assert.same({ row = row, col = a.col }, V.syntax_rows[a.file][side][ln.new or ln.old])
  end)

  -- The keystroke case: `apply` is wired to CursorMoved, so a pass with nothing new near the
  -- window must be a lookup against the map rather than another inversion of the whole
  -- review.
  it("reuses the map across passes with no repaint between them", function()
    local map = V.syntax_rows
    syntax.apply(V, h.NS)
    syntax.apply(V, h.NS)
    assert.are.equal(map, V.syntax_rows)
  end)

  it("rebuilds it when a repaint produces new renders", function()
    local map = V.syntax_rows
    view.paint()
    assert.are_not.equal(map, V.syntax_rows)
    agrees_with_render()
  end)

  -- Collapsing a file moves every row below it, which is exactly what a map kept past its
  -- render would go on pointing at. The guard is that the rows really did move: without it
  -- the case passes on a repaint that changed nothing.
  it("replays onto the rows a repaint moved, not the ones they replaced", function()
    local main = assert(h.file_index(V, "src/main.lua"))
    local routes = assert(h.file_index(V, "src/routes.lua"))
    local was = V.render.file_rows[routes]

    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[main], 0 })
    view.toggle_reviewed()
    assert.is_true(V.render.file_rows[routes] ~= was, "collapsing src/main.lua moved nothing")

    agrees_with_render()
    marks_cover_their_tokens()

    view.toggle_reviewed()
    marks_cover_their_tokens()
  end)

  -- Both `refresh` and `set_scope` discard through here, and both then repaint, so the
  -- discard itself is the only moment either of them could skip it.
  it("goes with the captures when the diff behind them is dropped", function()
    assert.is_not_nil(V.syntax_rows)
    syntax.invalidate(V)
    assert.is_nil(V.syntax_rows)
  end)

  it("comes back from the diff a re-read produced", function()
    view.refresh()
    agrees_with_render()
  end)

  it("comes back from the scope a change switched to", function()
    view.set_scope("staged")
    assert.same(
      { "src/routes.lua" },
      vim.tbl_map(function(f)
        return f.path
      end, V.files)
    )
    agrees_with_render()

    -- Back to where the rest of this file expects to be: the branch scope, with the cursor
    -- inside src/main.lua, which is what puts src/routes.lua near enough to the window for
    -- the cases below to have anything to say about it.
    view.set_scope("branch")
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[assert(h.file_index(V, "src/main.lua"))], 0 })
  end)
end)

describe("guardrails", function()
  local V = view.current()

  it("memoises a hard skip past the byte cap", function()
    config.setup({ max_syntax_bytes = 1 })
    V.syntax_cache = {}
    view.paint()
    -- `false`, not nil: the point of the memo is that the file is never reconsidered.
    assert.is_false(V.syntax_cache["src/routes.lua|after"])
    assert.same(0, #h.syntax_marks(V))
  end)

  it("does no work at all when syntax is disabled", function()
    config.setup({ syntax = false })
    V.syntax_cache = {}
    view.paint()
    assert.same(0, vim.tbl_count(V.syntax_cache))
  end)
end)
