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

describe("replaying captures onto the diff", function()
  view.open("branch")
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

  it("uses @-prefixed treesitter groups a colorscheme can colour", function()
    for _, m in ipairs(marks) do
      assert.same("@", m[4].hl_group:sub(1, 1))
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
