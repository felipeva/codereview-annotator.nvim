-- The rendered buffer and its anchor map: what each row means, and how navigation,
-- collapsing and scope switching move through it.
local h = require("tests.helpers")

h.ui(110, 40)
h.cd_fixture("mkfixture")

require("codereview").setup({})
local view = require("codereview.view")
local render = require("codereview.render")

describe("the anchor map", function()
  view.open("branch")
  local V = view.current()

  it("opens a view", function()
    assert.is_table(V)
  end)

  it("emits one file row per file", function()
    assert.same(#V.files, #V.render.file_rows)
  end)

  it("anchors every file row to its own file", function()
    for fi, row in ipairs(V.render.file_rows) do
      local a = V.render.anchors[row]
      assert.is_table(a)
      assert.same({ fi, "file" }, { a.file, a.kind })
    end
  end)

  it("anchors every hunk row to a hunk", function()
    for _, row in ipairs(V.render.hunk_rows) do
      assert.same("hunk", V.render.anchors[row].kind)
    end
  end)

  -- Every "line" anchor must point at a real CRLine, and its recorded byte column must be
  -- exactly where the code text starts in the rendered row. This is the one check that
  -- validates gutter width, byte offsets and the anchor map together.
  it("records the byte column where each line's code actually starts", function()
    local lines = vim.api.nvim_buf_get_lines(V.buf, 0, -1, false)
    for row, a in pairs(V.render.anchors) do
      if a.kind == "line" then
        local ln = V.files[a.file].hunks[a.hunk].lines[a.line]
        assert.is_table(ln, ("row %d has no CRLine"):format(row))
        assert.same(ln.text, lines[row]:sub(a.col + 1), ("row %d, col %d"):format(row, a.col))
      end
    end
  end)
end)

describe("navigation", function()
  local V = view.current()

  it("]f moves to the next file header", function()
    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    view.jump("file", true)
    assert.same(V.render.file_rows[2], vim.api.nvim_win_get_cursor(V.win)[1])
  end)

  it("[f moves back", function()
    view.jump("file", false)
    assert.same(V.render.file_rows[1], vim.api.nvim_win_get_cursor(V.win)[1])
  end)

  it("]h lands on a hunk header", function()
    view.jump("hunk", true)
    assert.same("hunk", V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]].kind)
  end)
end)

describe("marking a file reviewed", function()
  local V = view.current()
  local rows_before = #V.render.lines

  -- Park on the largest file so collapsing it is unmistakable.
  local biggest, bi = 0, 1
  for i, f in ipairs(V.files) do
    if #f.hunks > 0 and (f.added + f.removed) > biggest then
      biggest, bi = f.added + f.removed, i
    end
  end
  local target = V.files[bi].path

  vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[bi], 0 })
  view.toggle_reviewed()

  it("records the blob it was reviewed against", function()
    assert.same(V.files[bi].blob, V.reviewed[target])
  end)

  it("collapses the file", function()
    assert.is_true(#V.render.lines < rows_before)
  end)

  it("keeps the cursor on that file's header", function()
    assert.same(V.render.file_rows[bi], vim.api.nvim_win_get_cursor(V.win)[1])
  end)

  it("emits no line anchors for a collapsed file", function()
    for _, a in pairs(V.render.anchors) do
      assert.is_false(a.file == bi and a.kind == "line")
    end
  end)

  it("restores the rows when unmarked", function()
    view.toggle_reviewed()
    assert.same(rows_before, #V.render.lines)
  end)

  it("clears the blob when unmarked", function()
    assert.is_nil(V.reviewed[target])
  end)
end)

describe("the panel", function()
  local V = view.current()

  it("opens alongside the diff", function()
    assert.is_true(V.panel_win ~= nil and vim.api.nvim_win_is_valid(V.panel_win))
  end)

  it("footers the reviewed tally", function()
    local lines = vim.api.nvim_buf_get_lines(V.panel_buf, 0, -1, false)
    assert.same(("0/%d reviewed"):format(#V.files), lines[#lines])
  end)

  it("maps a row to every file", function()
    assert.same(#V.files, vim.tbl_count(V.panel_render.row_file))
  end)
end)

describe("scope cycling", function()
  it("returns to branch after a full cycle", function()
    for _ = 1, 4 do
      view.set_scope(nil)
    end
    assert.same("branch", view.current().scope.name)
  end)

  it("selects a scope by name", function()
    view.set_scope("staged")
    assert.same("staged", view.current().scope.name)
  end)

  it("shows only the staged file in the staged scope", function()
    assert.same(
      { "src/routes.lua" },
      vim.tbl_map(function(f)
        return f.path
      end, view.current().files)
    )
  end)

  it("names the scope in the winbar", function()
    view.set_scope("branch")
    local V = view.current()
    assert.is_truthy(vim.wo[V.win].winbar:find("branch vs master", 1, true))
  end)
end)

describe("line keys", function()
  -- The same line number means different things on the two sides of a diff, so the key
  -- has to carry the side or an annotation on a deletion collides with one on an
  -- addition.
  it("distinguishes the pre- and post-image sides", function()
    assert.same({ "a.lua:o:20", "a.lua:n:20" }, {
      render.line_key("a.lua", { side = "del", old = 20 }),
      render.line_key("a.lua", { side = "add", new = 20 }),
    })
  end)
end)
