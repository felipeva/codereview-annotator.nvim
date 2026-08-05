-- The rendered buffer and its anchor map: what each row means, and how navigation,
-- collapsing and scope switching move through it.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")
local root = assert(vim.uv.fs_realpath(fixture))

require("codereview").setup({})
local view = require("codereview.view")
local render = require("codereview.render")
local archive = require("codereview.archive")
local config = require("codereview.config")
local queue = require("codereview.queue")
local state = require("codereview.state")

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

-- Archived entries on the diff: what has already been reported, drawn beneath the code it
-- was about so a reviewer who keeps going while an agent works does not report it twice.
--
-- Everything here is asserted through extmark metadata and highlight *groups*. The colours
-- a colorscheme resolves those to are deliberately not tested, and never have been.
describe("archived entries", function()
  local V = view.current()
  local path = "src/main.lua"
  local fi = assert(h.file_index(V, path))
  local header = V.render.file_rows[fi]
  local line_row = assert(h.line_row(V, path))
  local anchor = V.render.anchors[line_row]
  local ln = V.files[anchor.file].hunks[anchor.hunk].lines[anchor.line]
  local line_key = render.line_key(path, ln)
  local file_key = render.file_key(path)

  ---The virtual lines the buffer's extmark on `row` carries, or nil.
  ---
  ---Read out of the buffer rather than out of the render, because what a reviewer sees is
  ---what was emitted -- and emission is bounded by the viewport. `src/main.lua` is the
  ---first file in this fixture, so its rows are inside the first band whatever the bound is.
  ---@param row integer 1-indexed
  ---@return table[]|nil
  local function virt_at(row)
    for _, m in ipairs(h.virt_marks(V)) do
      if m[2] == row - 1 then
        return m[4].virt_lines
      end
    end
  end

  ---The text of one virtual line, chunks joined.
  ---@param line table[]
  ---@return string
  local function text_of(line)
    local out = {}
    for _, chunk in ipairs(line) do
      out[#out + 1] = chunk[1]
    end
    return table.concat(out)
  end

  ---Every mark in a render that belongs to a row of some *other* file.
  ---@param marks table[]
  ---@return table[]
  local function marks_elsewhere(marks)
    return vim.tbl_filter(function(m)
      local a = V.render.anchors[m.row + 1]
      return a ~= nil and a.file ~= fi
    end, marks)
  end

  -- Taken before anything is archived, so "the flag off renders exactly as it does today"
  -- is a comparison against what today is rather than a claim about it.
  local pristine = vim.deepcopy(V.render.marks)

  it("costs a review with an empty archive nothing to open", function()
    assert.same({}, archive.by_key(root))
    assert.same(0, #h.virt_marks(V))
  end)

  state.archive_batch({
    { id = 1, type = "bug", kind = "file", path = path, key = file_key, note = "whole file, already sent" },
    {
      id = 2,
      type = "nitpick",
      kind = "line",
      path = path,
      key = line_key,
      first = ln.new or ln.old,
      note = "this line, already sent",
    },
  }, "agent", root)
  view.paint()

  it("hangs one about a whole file off that file's header, as a live one does", function()
    local virt = assert(virt_at(header), "nothing was drawn on the file header")
    assert.same(1, #virt)
    assert.is_truthy(text_of(virt[1]):find("whole file, already sent", 1, true))
  end)

  it("draws one about a line at that line's own anchor", function()
    local virt = assert(virt_at(line_row), "nothing was drawn on the line")
    assert.is_truthy(text_of(virt[1]):find("this line, already sent", 1, true))
  end)

  it("draws them in groups of their own, not in the annotation type's", function()
    local groups = h.virt_groups(V)
    assert.is_true(groups.CodeReviewArchived or false, vim.inspect(vim.tbl_keys(groups)))
    assert.is_true(groups.CodeReviewArchivedNote or false, vim.inspect(vim.tbl_keys(groups)))
    -- The entries archived above are a bug and a nitpick; drawn live, their markers would
    -- carry those types' groups, which is what these replace.
    assert.is_nil(groups.CodeReviewBug, vim.inspect(vim.tbl_keys(groups)))
    assert.is_nil(groups.CodeReviewNitpick, vim.inspect(vim.tbl_keys(groups)))
  end)

  -- Every group here is a `default = true` link into whatever colorscheme is active, which
  -- is the rule every other group in `hl.lua` follows and the only reason overriding one
  -- works. Asserted as a link to a defined group, never as a resolved colour.
  it("links those groups into the colorscheme rather than defining colours", function()
    for _, group in ipairs({ "CodeReviewArchived", "CodeReviewArchivedNote" }) do
      local def = vim.api.nvim_get_hl(0, { name = group })
      assert.is_truthy(def.link, ("%s is not a link: %s"):format(group, vim.inspect(def)))
      assert.is_truthy(vim.api.nvim_get_hl(0, { name = def.link }), ("%s links nowhere"):format(group))
    end
  end)

  -- The cost this slice was blocked on #78 for. A repaint has to grow with what is drawn,
  -- not with what is stored, and a file the archive says nothing about is where that shows.
  it("leaves a file carrying no archived entries exactly as it was", function()
    local elsewhere = marks_elsewhere(pristine)
    -- Or the comparison below holds over nothing, which is the way a set comparison goes
    -- quiet: an anchor lookup that stopped resolving would empty both sides at once.
    assert.is_true(#elsewhere > 0, "no marks belong to any other file")
    assert.same(elsewhere, marks_elsewhere(V.render.marks))
  end)

  -- What is still to send outranks what has already gone, so a reviewer reading down from
  -- the code meets the live remark first.
  queue.add({
    id = 99,
    type = "bug",
    kind = "file",
    path = path,
    abs_path = vim.fs.joinpath(root, path),
    key = file_key,
    note = "still to send",
  })
  view.paint()

  it("draws a queued and an archived entry on one anchor, queued first", function()
    local virt = assert(virt_at(header))
    assert.same(2, #virt)
    assert.is_truthy(text_of(virt[1]):find("still to send", 1, true))
    assert.is_truthy(text_of(virt[2]):find("whole file, already sent", 1, true))
  end)

  it("keeps the live entry in its own type's group beside the archived one", function()
    local groups = h.virt_groups(V)
    assert.is_true(groups.CodeReviewBug or false, vim.inspect(vim.tbl_keys(groups)))
    assert.is_true(groups.CodeReviewArchived or false, vim.inspect(vim.tbl_keys(groups)))
  end)

  -- Not merely "nothing archived is drawn": with the flag off the render has to be the one
  -- this repository produced before an archive existed, mark for mark.
  queue.clear()
  config.get().archived = false
  view.paint()

  it("renders exactly as it does today when the flag is off", function()
    assert.same(pristine, V.render.marks)
  end)

  it("draws nothing from the archive at all when the flag is off", function()
    assert.same({}, V.archived)
    assert.same(0, #h.virt_marks(V))
  end)

  config.get().archived = true
  view.paint()
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

-- How a winbar is assembled: typed segments in, the one string a bar is set to out.
--
-- No window, no fixture and no repository, which is why the seam is here rather than in the
-- view: the rule these cases hold is the one that protects a reviewer against the names
-- their own repository chose, and it is cheap to keep true only if it can be asserted like
-- this. The blocks below assert what the bar *says*; these assert what it is safe to put
-- on it.
describe("the winbar assembly", function()
  it("doubles every % in a literal", function()
    assert.same("src/%%f.lua", render.bar({ render.literal("src/%f.lua") }))
  end)

  it("draws what the plugin wrote as it stands", function()
    assert.same(" · ", render.bar({ render.chrome(" · ") }))
  end)

  it("joins the segments in the order they arrive", function()
    assert.same(
      " ○ ▾ src/50%% done.lua · api",
      render.bar({
        render.chrome(" "),
        render.literal("○ ▾ src/50% done.lua"),
        render.chrome(" · "),
        render.literal("api"),
      })
    )
  end)

  it("wraps a chrome segment that carries a highlight group", function()
    assert.same("%#CodeReviewAdd#+12%*", render.bar({ render.chrome("+12", "CodeReviewAdd") }))
  end)

  -- The two kinds are the whole point: the same text is markup on one and a name on the
  -- other, and nothing but the kind says which.
  it("keeps a marker in chrome and doubles the same text in a literal", function()
    assert.same("%#CodeReviewAdd#x", render.bar({ render.chrome("%#CodeReviewAdd#x") }))
    assert.same("%%#CodeReviewAdd#x", render.bar({ render.literal("%#CodeReviewAdd#x") }))
  end)

  -- A caller cannot put a path on the bar by accident, because a segment that says nothing
  -- about its kind is not a segment. The message is asserted, not merely the raise: every
  -- one of these raises while the assembly does not exist at all, and a case satisfied by
  -- that is measuring nothing.
  ---@param fn fun()
  local function refused(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("chrome", 1, true), tostring(err))
  end

  it("refuses a segment that does not say which kind it is", function()
    refused(function()
      render.bar({ { text = "src/%f.lua" } })
    end)
    refused(function()
      render.bar({ "src/%f.lua" })
    end)
    refused(function()
      render.bar_width({ { text = "src/%f.lua" } })
    end)
  end)

  -- Columns and never bytes, for the reason the padding already records: a bar measured by
  -- byte length drifts two columns for every glyph and does it on the first path with an
  -- accent in it. The second assertion is the guard -- with an all-ASCII string the two
  -- numbers agree and the case measures nothing.
  it("measures a literal in columns rather than bytes", function()
    local path = "○ ▾ src/café.lua"
    assert.same(vim.fn.strdisplaywidth(path), render.bar_width({ render.literal(path) }))
    assert.is_true(#path > vim.fn.strdisplaywidth(path), "nothing multibyte to measure")
  end)

  -- What is measured is what is drawn, not what is written: an escaped `%` is two
  -- characters in the string and one column on the screen.
  it("counts an escaped % as the one column it draws", function()
    local segments = { render.literal("50% done") }
    assert.same(8, render.bar_width(segments))
    assert.same(9, #render.bar(segments))
  end)

  -- The mirror of the byte trap, and the one this seam introduces: a highlight marker is
  -- characters in the string and no columns at all on the screen. Both spellings of one --
  -- carried by the segment, and written into it -- have to measure the same.
  it("gives a highlight marker no width at all", function()
    assert.same(4, render.bar_width({ render.chrome("+12", "CodeReviewAdd"), render.chrome(" ") }))
    assert.same(4, render.bar_width({ render.chrome("%#CodeReviewAdd#+12%*"), render.chrome(" ") }))
  end)

  -- The claim no comparison of two strings can make: that what comes out is markup Neovim
  -- reads rather than a plausible-looking string, and that the ruler above agrees with the
  -- one Neovim draws by. Every case here would have been written against a wrong encoding
  -- had one been chosen, and every one of them would have passed; this is the only one that
  -- reds when the marker and its expectation move together. Asked of the statusline parser
  -- a winbar goes through, so it needs no window of the review's own. `DiffAdd` because it
  -- exists on a bare Neovim -- which group the bar asks for is not this slice's business,
  -- and an undefined one comes back reported as no group at all.
  it("emits markup Neovim reads, and measures what Neovim would draw", function()
    local segments = {
      render.chrome(" "),
      render.chrome("+12", "DiffAdd"),
      render.chrome(" "),
      render.literal("src/50% done.lua"),
    }
    local drawn = vim.api.nvim_eval_statusline(render.bar(segments), { highlights = true })
    assert.same(" +12 src/50% done.lua", drawn.str)
    assert.same(render.bar_width(segments), drawn.width)
    local groups = {}
    for _, run in ipairs(drawn.highlights) do
      groups[run.group] = true
    end
    assert.is_true(groups.DiffAdd or false, vim.inspect(drawn.highlights))
  end)
end)

-- The sticky header: the file the cursor is in, named on the winbar so that reading past
-- that file's own header row no longer costs a reviewer the file.
--
-- Asserted through the window option, as the scope above already is -- what a reviewer's
-- editor holds after a real cursor movement, never the function that put it there. This is
-- the *unified* layout's bar, including the rename spelled `old → new`; the per-pane rules
-- are `split_spec`'s. Every case reads a file from well below its header row, because the
-- header is exactly what has gone by the time this matters.
--
-- These blocks run last in this file and move the pane's width and the scope about, which
-- nothing below them would survive.
describe("the sticky header", function()
  local V = view.current()

  local function bar()
    return vim.wo[V.win].winbar
  end

  ---Read a file the way a reviewer does -- autocmd and all, which is the only thing that
  ---moves the crossing latch -- landing on its *last* code row rather than on its header.
  ---@param path string
  ---@return integer row, integer header
  local function read_into(path)
    local index = assert(h.file_index(V, path))
    local last
    for row = 1, #V.render.lines do
      local a = V.render.anchors[row]
      if a and a.file == index and a.kind == "line" then
        last = row
      end
    end
    assert(last, "no code rows for " .. path)
    vim.api.nvim_set_current_win(V.win)
    vim.api.nvim_win_set_cursor(V.win, { last, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
    return last, V.render.file_rows[index]
  end

  local away = "src/nonl.md"
  local row, header = read_into(away)
  local first = V.files[1].path

  -- Guards the block itself: parked on the file's header row, or on the first file in the
  -- diff, every case below would pass with the winbar naming whatever is at the top.
  it("really is reading a file from below its own header", function()
    assert.is_true(row > header + 1, ("row %d is not below header %d"):format(row, header))
    assert.is_true(first ~= away, "the file being read is the first one in the diff")
  end)

  it("names the file the cursor is in, not the one the diff starts with", function()
    assert.is_truthy(bar():find(away, 1, true), bar())
    assert.is_nil(bar():find(first, 1, true), bar())
  end)

  it("carries that file's own stat beside its name", function()
    local file = V.files[assert(h.file_index(V, away))]
    assert.is_truthy(bar():find(("+%d -%d"):format(file.added, file.removed), 1, true), bar())
  end)

  -- Two crossings rather than one: a bar that named the file it was built with and never
  -- moved again would pass a single absolute assertion.
  it("changes when the cursor crosses into another file", function()
    read_into("src/main.lua")
    assert.is_truthy(bar():find("src/main.lua", 1, true), bar())
    assert.is_nil(bar():find(away, 1, true), bar())

    read_into(away)
    assert.is_truthy(bar():find(away, 1, true), bar())
    assert.is_nil(bar():find("src/main.lua", 1, true), bar())
  end)

  -- The half this slice must not have cost anyone: everything the winbar said before it
  -- existed is still on it, moved to the right rather than dropped.
  it("keeps the review summary beside the file", function()
    local added, removed = require("codereview.diff").totals(V.files)
    assert.is_truthy(bar():find(V.scope.label, 1, true), bar())
    assert.is_truthy(bar():find(("0/%d reviewed"):format(#V.files), 1, true), bar())
    assert.is_truthy(bar():find(("+%d -%d"):format(added, removed), 1, true), bar())
  end)
end)

-- The case the feature exists for. The tree is the one surface that answered "which file am
-- I in" before this, it is dismissible, and a sticky header hung off the tree's own repaint
-- would freeze exactly here -- `queue_jump_panel_spec` is the prior art for reaching this
-- state, and this is the same reason it exists.
describe("the sticky header with the tree dismissed", function()
  local V = view.current()
  view.toggle_panel()

  local function bar()
    return vim.wo[V.win].winbar
  end

  ---@param path string
  ---@return integer index
  local function read_into(path)
    local index = assert(h.file_index(V, path))
    vim.api.nvim_set_current_win(V.win)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index] + 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
    return index
  end

  it("really has no tree", function()
    assert.is_nil(V.panel_win)
    assert.is_nil(V.panel_render)
  end)

  it("still names the file the cursor crosses into", function()
    read_into("src/main.lua")
    assert.is_truthy(bar():find("src/main.lua", 1, true), bar())
    read_into("src/nonl.md")
    assert.is_truthy(bar():find("src/nonl.md", 1, true), bar())
    assert.is_nil(bar():find("src/main.lua", 1, true), bar())
  end)
end)

describe("the sticky header on a pane that has to choose", function()
  local V = view.current()
  view.toggle_panel() -- back, so the after pane has a neighbour to give columns to

  local function bar()
    return vim.wo[V.win].winbar
  end

  ---Resize the pane and repaint. `WinResized` is fired from the main loop and never lands
  ---in a headless spec, so the repaint is this test's to drive.
  ---@param width integer
  ---@return integer width
  local function resize(width)
    vim.api.nvim_win_set_width(V.win, width)
    view.paint()
    local index = assert(h.file_index(V, "src/newname.lua"))
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index] + 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
    return vim.api.nvim_win_get_width(V.win)
  end

  local wide = resize(100)

  it("really resized the pane", function()
    assert.same(100, wide)
  end)

  -- The in-buffer header's rule, not a second one: one header per file in this layout, so
  -- the arrow is spelled out.
  it("spells a rename out as the file header does", function()
    assert.is_truthy(bar():find("src/oldname.lua → src/newname.lua", 1, true), bar())
  end)

  -- The one case an ASCII assertion cannot make. This bar carries `○`, `▾`, `→` and `·`,
  -- every one of them wider in bytes than in columns, so a bar padded by `#` overshoots the
  -- pane by a dozen columns and this is what notices. The guard is the second assertion:
  -- with an all-ASCII bar the two lengths agree and the case measures nothing.
  it("fills the pane exactly, counting columns rather than bytes", function()
    assert.same(wide, vim.fn.strdisplaywidth(bar()), bar())
    assert.is_true(#bar() > wide, "nothing multibyte on the bar to measure")
  end)

  local narrow = resize(45)

  it("really narrowed the pane", function()
    assert.same(45, narrow)
  end)

  it("keeps the path's tail and shows the cut", function()
    assert.is_truthy(bar():find("src/newname.lua", 1, true), bar())
    assert.is_truthy(bar():find("…", 1, true), bar())
    assert.is_nil(bar():find("src/oldname.lua", 1, true), bar())
  end)

  -- The summary gives way, and gives up what the file beside it now says twice before what
  -- only it can say: the plugin's own name and the review's line totals go, the reviewed
  -- tally is still there.
  it("sheds the summary rather than the file", function()
    assert.is_nil(bar():find("Code review", 1, true), bar())
    assert.is_truthy(bar():find(("0/%d reviewed"):format(#V.files), 1, true), bar())
  end)
end)

-- The rule the assembly exists for, reached the way a reviewer reaches it. A **target**'s
-- short name is a name the plugin did not choose, so the bar has to draw it rather than
-- expand it -- and no fixture is needed to say so, because a picker stub can carry a `%`
-- where a file name cannot without moving every count in the suite.
--
-- The cases above prove the escape; this one proves the view still asks for it. Marking the
-- summary as text the plugin wrote is a one-word change that nothing else here would notice.
describe("the sticky header naming something with a % in it", function()
  local V = view.current()
  config.get().pick_target = function(cb)
    cb({ short = "ja%nus" })
  end
  -- Wide, so what is asserted is the escape and not what a narrow pane had room for.
  vim.api.nvim_win_set_width(V.win, 100)
  view.pick_target()

  local function bar()
    return vim.wo[V.win].winbar
  end

  it("doubles the % rather than letting it start a statusline item", function()
    assert.is_truthy(bar():find("ja%%nus", 1, true), bar())
    assert.is_nil(bar():find("ja%nus", 1, true), bar())
  end)
end)

describe("the sticky header on a review with no files", function()
  local V = view.current()
  -- A revspec whose two ends are the same commit: a review that opened on a real scope and
  -- has nothing in it, which is the only way to reach an empty one -- `open` refuses.
  view.set_scope("HEAD..HEAD")

  local function bar()
    return vim.wo[V.win].winbar
  end

  it("really has no files", function()
    assert.same(0, #V.files)
  end)

  -- Left-aligned and starting with the summary's first word: no file segment, and no empty
  -- one either. A bar that drew the icons with nothing after them would fail here.
  it("gives the summary the winbar to itself", function()
    assert.same(" Code review", bar():sub(1, #" Code review"), bar())
    assert.is_truthy(bar():find("0/0 reviewed", 1, true), bar())
  end)

  it("draws no chevron for a file that is not there", function()
    local icons = config.get().icons
    assert.is_nil(bar():find(icons.collapsed, 1, true), bar())
    assert.is_nil(bar():find(icons.expanded, 1, true), bar())
  end)
end)
