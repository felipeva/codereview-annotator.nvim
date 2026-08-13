-- Emphasizing what changed inside a changed line.
--
-- Two seams, both pure, both asserted without a window. The parser decides *what* is
-- emphasized -- the pairing, unequal runs, the suppression threshold, character
-- boundaries -- and hangs spans on the lines it emphasizes. The render decides *how* they
-- are drawn: the priority band, background-only groups, byte offsets past the gutter, and
-- the same row in both panes.
--
-- The hand-written diffs below are inputs to a pure function rather than a fixture:
-- `diff.parse` is handed text and returns structures, so a case that needs a two-deletion
-- run followed by a three-addition run says so in five lines instead of in a repository.
-- What has to come from git -- which files pair at all, and the multibyte line -- comes
-- from `mkfixture`, and is derived from it rather than counted by hand.
local h = require("tests.helpers")

h.ui(110, 40)
local root = h.cd_fixture("mkfixture")

local last_ctx
local function configure(opts)
  require("codereview").setup(vim.tbl_extend("force", {
    syntax = false,
    compose = function(ctx, on_accept, _)
      last_ctx = ctx
      on_accept(nil, "note about " .. ctx.label)
    end,
  }, opts or {}))
end
configure()

local diff = require("codereview.diff")
local git = require("codereview.git")
local render = require("codereview.render")
local config = require("codereview.config")

--- The parser: what is emphasized ----------------------------------------------

---A one-hunk diff of `body`, each entry already carrying its `+`/`-`/space marker.
---@param body string[]
---@return CRLine[]
local function parse(body)
  local old, new = 0, 0
  for _, l in ipairs(body) do
    local marker = l:sub(1, 1)
    if marker == "-" then
      old = old + 1
    elseif marker == "+" then
      new = new + 1
    else
      old, new = old + 1, new + 1
    end
  end
  local text = table.concat({
    "diff --git a/x.lua b/x.lua",
    "--- a/x.lua",
    "+++ b/x.lua",
    ("@@ -1,%d +1,%d @@"):format(old, new),
  }, "\n") .. "\n" .. table.concat(body, "\n") .. "\n"
  return diff.parse(text, { spans = true })[1].hunks[1].lines
end

---The text each of a line's spans covers -- what a reviewer actually sees emphasized.
---@param ln CRLine
---@return string[]
local function emphasized(ln)
  local out = {}
  for _, s in ipairs(ln.spans or {}) do
    out[#out + 1] = ln.text:sub(s.col + 1, s.end_col)
  end
  return out
end

---A pair of lines built to a given proportion: `same` shared characters, then `changed`
---that differ, on both sides. Twenty characters throughout, so the proportion of the
---longer line inside spans is `changed / 20`.
---@param same integer
---@param changed integer
---@return CRLine del, CRLine add
local function pair_at(same, changed)
  local lines = parse({
    "-" .. ("a"):rep(same) .. ("b"):rep(changed),
    "+" .. ("a"):rep(same) .. ("c"):rep(changed),
  })
  return lines[1], lines[2]
end

describe("a deletion and its replacement", function()
  local lines = parse({
    ' local app = require("app")',
    "-local cfg = load()",
    "+local cfg = load_config()",
  })

  it("emphasizes the characters that differ", function()
    assert.same({ "_config" }, emphasized(lines[3]))
  end)

  it("emphasizes nothing that both lines share", function()
    assert.same({}, emphasized(lines[2]))
  end)

  -- Both sides, so a reviewer sees what an identifier was as well as what it became. The
  -- trailing `a` the two names happen to share is not emphasized on either: granularity is
  -- characters, not tokens, and widening a span to the enclosing identifier would be
  -- pointing at something that did not change.
  it("emphasizes what a rename was as well as what it became", function()
    local del, add = unpack(parse({ "-local cfg = alpha()", "+local cfg = omega()" }))
    assert.same({ "alph" }, emphasized(del))
    assert.same({ "omeg" }, emphasized(add))
  end)

  it("leaves a context line alone", function()
    assert.is_nil(lines[1].spans)
  end)
end)

describe("where an edit sits in the line", function()
  it("emphasizes several separate edits", function()
    local del, add = unpack(parse({ "-local a = 1; local b = 2", "+local a = 9; local b = 8" }))
    assert.same({ "1", "2" }, emphasized(del))
    assert.same({ "9", "8" }, emphasized(add))
  end)

  it("emphasizes an edit at the very start", function()
    local del, add = unpack(parse({ "-xfoo(bar)", "+yfoo(bar)" }))
    assert.same({ "x" }, emphasized(del))
    assert.same({ "y" }, emphasized(add))
    assert.same(0, add.spans[1].col)
  end)

  it("emphasizes an edit at the very end", function()
    local _, add = unpack(parse({ "-# no trailing newline", "+# no trailing newline CHANGED" }))
    assert.same({ " CHANGED" }, emphasized(add))
    assert.same(#add.text, add.spans[1].end_col)
  end)

  -- A re-indentation is otherwise the one change a reviewer cannot see at all.
  it("emphasizes a whitespace-only change", function()
    local _, add = unpack(parse({ "-  return x", "+    return x" }))
    assert.same({ "  " }, emphasized(add))
  end)
end)

describe("which lines pair", function()
  -- The i-th deletion of a run with the i-th addition of the run that follows it. Pairing
  -- them the other way round would emphasize the identifier as well as the number, so this
  -- fails rather than merely looking different if the rule changes.
  local lines = parse({
    "-local alpha = 1",
    "-local beta = 2",
    "+local alpha = 3",
    "+local beta = 4",
  })

  it("pairs the i-th deletion with the i-th addition", function()
    assert.same({ { "1" }, { "2" }, { "3" }, { "4" } }, {
      emphasized(lines[1]),
      emphasized(lines[2]),
      emphasized(lines[3]),
      emphasized(lines[4]),
    })
  end)

  it("starts a new pairing after a context line", function()
    local after_ctx = parse({
      "-local alpha = 1",
      " local ctx = 0",
      "-local beta = 2",
      "+local beta = 4",
    })
    -- The lone deletion above the context line has nothing to pair with; the pair below it
    -- is unaffected by it.
    assert.is_nil(after_ctx[1].spans)
    assert.same({ "2" }, emphasized(after_ctx[3]))
    assert.same({ "4" }, emphasized(after_ctx[4]))
  end)

  it("leaves the surplus of a longer addition run unpaired", function()
    local runs = parse({
      "-local alpha = 1",
      "-local beta = 2",
      "+local alpha = 3",
      "+local beta = 4",
      "+local gamma = 5",
    })
    assert.same({ "3" }, emphasized(runs[3]))
    assert.same({ "4" }, emphasized(runs[4]))
    assert.is_nil(runs[5].spans)
  end)

  it("leaves the surplus of a longer deletion run unpaired", function()
    local runs = parse({
      "-local alpha = 1",
      "-local beta = 2",
      "-local gamma = 5",
      "+local alpha = 3",
      "+local beta = 4",
    })
    assert.same({ "1" }, emphasized(runs[1]))
    assert.same({ "2" }, emphasized(runs[2]))
    assert.is_nil(runs[3].spans)
  end)
end)

describe("suppression", function()
  -- The threshold is a judgment, recorded in `diff.lua` with the diffs it was read off.
  -- These two cases sit either side of it by construction, so moving it in either
  -- direction reds one of them.
  it("emphasizes a pair that still shares most of its characters", function()
    local del, add = pair_at(9, 11)
    assert.same({ ("b"):rep(11) }, emphasized(del))
    assert.same({ ("c"):rep(11) }, emphasized(add))
  end)

  it("leaves a pair sharing almost nothing plainly colored", function()
    local del, add = pair_at(7, 13)
    assert.is_nil(del.spans)
    assert.is_nil(add.spans)
  end)

  it("leaves a line replaced wholesale plainly colored", function()
    local del, add = unpack(parse({
      "-  pcall(vim.api.nvim_win_set_cursor, V.win, { 1, 0 })",
      "+  place(1)",
    }))
    assert.is_nil(del.spans)
    assert.is_nil(add.spans)
  end)

  -- An empty line has nothing to point at, and everything on the other side is new.
  it("emphasizes nothing opposite an empty line", function()
    local del, add = unpack(parse({ "-", "+local x = 1" }))
    assert.is_nil(del.spans)
    assert.is_nil(add.spans)
  end)
end)

describe("characters, not bytes", function()
  -- é and è share their first byte, as do 🎉 and 🎈. A diff taken over bytes emphasizes
  -- the trailing byte alone -- a boundary inside a character, which is a rendering error
  -- rather than a cosmetic one -- and every assertion here is one such a diff fails.
  local del, add = unpack(parse({
    '-local name = "old"  -- café 日本語 🎉',
    '+local name = "new"  -- cafè 日本語 🎈',
  }))

  it("emphasizes whole characters on the deletion", function()
    assert.same({ "old", "é", "🎉" }, emphasized(del))
  end)

  it("emphasizes whole characters on the addition", function()
    assert.same({ "new", "è", "🎈" }, emphasized(add))
  end)

  it("never puts a boundary inside a multibyte character", function()
    for _, ln in ipairs({ del, add }) do
      for _, s in ipairs(ln.spans) do
        assert.same(0, vim.str_utf_start(ln.text, s.col + 1), ("start %d of %q"):format(s.col, ln.text))
        assert.is_true(
          s.end_col == #ln.text or vim.str_utf_start(ln.text, s.end_col + 1) == 0,
          ("end %d of %q"):format(s.end_col, ln.text)
        )
      end
    end
  end)

  it("emphasizes an edit adjacent to multibyte text", function()
    local _, add_ = unpack(parse({ "-日本語のテキスト", "+日本語のテキスト!" }))
    assert.same({ "!" }, emphasized(add_))
    -- Nine characters in, which is 24 bytes in: a byte-wise offset would land inside 卜.
    assert.same(24, add_.spans[1].col)
  end)
end)

--- The parser, against the fixture ---------------------------------------------

local scope = assert(git.resolve_scope("branch", root))
local files = assert(git.collect(scope, root, { context = 3, untracked = true, spans = true }))
local by = {}
for _, f in ipairs(files) do
  by[f.path] = f
end

---Every line of a file, flattened.
---@param path string
---@return CRLine[]
local function all_lines(path)
  local out = {}
  for _, hunk in ipairs(assert(by[path], path).hunks) do
    vim.list_extend(out, hunk.lines)
  end
  return out
end

describe("lines with no counterpart", function()
  -- Derived from the fixture rather than listed: whichever files git reports as wholly
  -- added or wholly deleted are the ones that must carry nothing.
  for _, path in ipairs({ "src/routes.lua", "src/gone.lua", "src/fresh.lua", "src/untracked.lua" }) do
    it(("carries no spans anywhere in %s"):format(path), function()
      local sides = {}
      for _, ln in ipairs(all_lines(path)) do
        sides[ln.side] = true
        assert.is_nil(ln.spans, ("%s line %s"):format(path, ln.new or ln.old))
      end
      -- Guard: a file with both a deletion and an addition in it would pair, and this case
      -- would then be asserting nothing.
      assert.is_falsy(sides.add and sides.del, ("%s has a pairable run"):format(path))
    end)
  end
end)

describe("the fixture's own multibyte line", function()
  -- The rest of the fixture is ASCII and cannot fail the byte-splitting bug; `src/nonl.md`
  -- is the line that can. It reaches here through git rather than through a literal, so
  -- the encoding survives `git diff` and the parser's own path decoding as well.
  local del, add
  for _, ln in ipairs(all_lines("src/nonl.md")) do
    del = ln.side == "del" and ln or del
    add = ln.side == "add" and ln or add
  end

  it("emphasizes whole characters as git delivered them", function()
    assert.same({ "é", "🎉" }, emphasized(assert(del)))
    assert.same({ "CHANGED ", "è", "🎈" }, emphasized(assert(add)))
  end)

  it("lands every boundary on a character", function()
    for _, ln in ipairs({ del, add }) do
      for _, s in ipairs(ln.spans) do
        assert.same(0, vim.str_utf_start(ln.text, s.col + 1), ("start %d of %q"):format(s.col, ln.text))
        assert.is_true(
          s.end_col == #ln.text or vim.str_utf_start(ln.text, s.end_col + 1) == 0,
          ("end %d of %q"):format(s.end_col, ln.text)
        )
      end
    end
  end)
end)

--- The render: how it is drawn -------------------------------------------------

---@param files_ CRFile[]
---@param layout string
---@return CRRender after, CRRender|nil before
local function build(files_, layout)
  local cfg = config.get()
  return render.build(files_, {
    width = 60,
    before_width = 60,
    layout = layout,
    icons = cfg.icons,
    expanded = {},
    reviewed = {},
    notes = {},
    types = cfg.types,
  })
end

---@param rendered CRRender
---@param row integer|nil 1-indexed; nil for every row
---@return table[]
local function span_marks(rendered, row)
  return vim.tbl_filter(function(m)
    return m.opts.priority == render.PRIORITY.span and (row == nil or m.row == row - 1)
  end, rendered.marks)
end

describe("drawing a span", function()
  local after = build(files, "unified")

  it("emits one mark per span the parser attached", function()
    local want = 0
    for _, f in ipairs(files) do
      for _, hunk in ipairs(f.hunks) do
        for _, ln in ipairs(hunk.lines) do
          want = want + #(ln.spans or {})
        end
      end
    end
    assert.is_true(want > 0, "the fixture produced no spans at all")
    assert.same(want, #span_marks(after))
  end)

  -- The load-bearing check: the parser's offsets are into the line's own text, and the
  -- render has to shift them past a gutter that is itself multibyte.
  it("covers exactly the characters the parser marked", function()
    for row, a in pairs(after.anchors) do
      if a.kind == "line" then
        local ln = files[a.file].hunks[a.hunk].lines[a.line]
        local marks = span_marks(after, row)
        assert.same(#(ln.spans or {}), #marks, ("row %d"):format(row))
        for i, s in ipairs(ln.spans or {}) do
          local m = marks[i]
          assert.same(
            ln.text:sub(s.col + 1, s.end_col),
            after.lines[row]:sub(m.col + 1, m.opts.end_col),
            ("row %d span %d"):format(row, i)
          )
        end
      end
    end
  end)

  it("sits above the gutter and below the syntax replay", function()
    assert.is_true(render.PRIORITY.gutter < render.PRIORITY.span)
    assert.is_true(render.PRIORITY.span < render.PRIORITY.syntax)
    for _, m in ipairs(span_marks(after)) do
      assert.is_true(m.opts.priority > render.PRIORITY.gutter)
      assert.is_true(m.opts.priority < render.PRIORITY.syntax)
    end
  end)

  it("names a side-specific group", function()
    local groups = {}
    for row, a in pairs(after.anchors) do
      if a.kind == "line" then
        local side = files[a.file].hunks[a.hunk].lines[a.line].side
        for _, m in ipairs(span_marks(after, row)) do
          groups[m.opts.hl_group] = side
        end
      end
    end
    assert.same({ CodeReviewAddSpan = "add", CodeReviewDelSpan = "del" }, groups)
  end)

  -- Emphasis means something by contrast, so the line's own background has to survive it.
  it("leaves the rest of the line its ordinary background", function()
    local rows = 0
    for row, a in pairs(after.anchors) do
      if a.kind == "line" and #span_marks(after, row) > 0 then
        rows = rows + 1
        local side = files[a.file].hunks[a.hunk].lines[a.line].side
        local want = side == "add" and "CodeReviewAdd" or "CodeReviewDel"
        local found = false
        for _, m in ipairs(after.marks) do
          found = found or (m.row == row - 1 and m.opts.line_hl_group == want)
        end
        assert.is_true(found, ("row %d lost its %s background"):format(row, want))
      end
    end
    assert.is_true(rows > 0)
  end)

  it("draws nothing when the parser attached nothing", function()
    local off = assert(git.collect(scope, root, { context = 3, untracked = true, spans = false }))
    assert.same(0, #span_marks(build(off, "unified")))
  end)
end)

describe("both panes", function()
  local after, before = build(files, "split")

  ---The row a file's deletion and its replacement collapse onto.
  ---@param path string
  ---@return integer
  local function paired_row(path)
    for row, a in pairs(after.anchors) do
      local b = before.anchors[row]
      if a.kind == "line" and b and b.kind == "line" then
        local aln = files[a.file].hunks[a.hunk].lines[a.line]
        local bln = files[b.file].hunks[b.hunk].lines[b.line]
        if files[a.file].path == path and aln.side == "add" and bln.side == "del" then
          return row
        end
      end
    end
    error("no paired row in " .. path)
  end

  -- `src/nonl.md`, not `src/main.lua`: main's edit is a pure insertion, so its deletion
  -- carries no spans at all and this case would be asserting the after pane twice. nonl's
  -- pair is the fixture's only one that emphasizes something on both sides.
  it("shows the emphasis in both panes on the same row", function()
    local row = paired_row("src/nonl.md")
    assert.is_true(#span_marks(after, row) > 0, "nothing emphasized in the after pane")
    assert.is_true(#span_marks(before, row) > 0, "nothing emphasized in the before pane")
  end)

  -- One pairing rule, so a layout toggle cannot change which characters are called out.
  it("emphasizes the same characters as the unified layout", function()
    ---@param rendered CRRender
    ---@param into table
    local function collect_by_key(rendered, into)
      for row, a in pairs(rendered.anchors) do
        if a.kind == "line" then
          local file = files[a.file]
          local ln = file.hunks[a.hunk].lines[a.line]
          if ln.spans then
            into[render.line_key(file.path, ln)] = emphasized(ln)
          end
        end
      end
      return into
    end
    local unified = collect_by_key(build(files, "unified"), {})
    local split = collect_by_key(after, collect_by_key(before, {}))
    assert.is_true(vim.tbl_count(unified) > 0)
    assert.same(unified, split)
  end)
end)

describe("the highlight groups", function()
  -- Background only. The syntax replay sits at a higher priority, so a foreground here
  -- would lose to it wherever treesitter painted and win wherever it did not.
  for _, group in ipairs({ "CodeReviewAddSpan", "CodeReviewDelSpan" }) do
    it(("gives %s a background and no foreground"):format(group), function()
      -- Read without resolving a link: a link would carry DiffText's foreground with it,
      -- and "no foreground" would then be a claim about DiffText rather than about us.
      local hl = vim.api.nvim_get_hl(0, { name = group })
      assert.is_nil(hl.link, group .. " is a link, so it inherits a foreground")
      assert.is_not_nil(hl.bg, group .. " has no background")
      assert.is_nil(hl.fg, group .. " set a foreground")
    end)
  end

  it("takes its background from the group colorschemes tune for changed text", function()
    local want = vim.api.nvim_get_hl(0, { name = "DiffText", link = false })
    assert.same(want.bg, vim.api.nvim_get_hl(0, { name = "CodeReviewAddSpan", link = false }).bg)
  end)

  it("follows a colorscheme change mid-session", function()
    local before_bg = vim.api.nvim_get_hl(0, { name = "CodeReviewAddSpan", link = false }).bg
    vim.cmd("colorscheme vim")
    local now = vim.api.nvim_get_hl(0, { name = "CodeReviewAddSpan", link = false })
    assert.same(vim.api.nvim_get_hl(0, { name = "DiffText", link = false }).bg, now.bg)
    assert.is_not.same(before_bg, now.bg)
    vim.cmd("colorscheme default")
  end)
end)

--- Configuration ---------------------------------------------------------------

describe("the configuration key", function()
  it("defaults to on", function()
    assert.is_true(require("codereview.config").defaults.spans)
  end)

  it("rejects a value that is not a boolean", function()
    local ok, err = pcall(configure, { spans = "yes" })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("spans", 1, true))
    configure()
  end)

  -- Not "produces no spans": the work must genuinely not be done.
  it("does no span work at all when it is off", function()
    local calls = 0
    local original = vim.diff
    vim.diff = function(...)
      calls = calls + 1
      return original(...)
    end
    git.collect(scope, root, { context = 3, untracked = true, spans = false })
    local off = calls
    git.collect(scope, root, { context = 3, untracked = true, spans = true })
    vim.diff = original
    assert.same(0, off)
    assert.is_true(calls > 0, "spans were requested and nothing was diffed")
  end)
end)

--- In a view -------------------------------------------------------------------

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")
local payload = require("codereview.payload")

view.open("branch")

describe("a repaint", function()
  local V = view.current()

  it("carries spans into the view", function()
    assert.is_true(#span_marks(V.render) > 0)
  end)

  it("recomputes nothing", function()
    local calls = 0
    local original = vim.diff
    vim.diff = function(...)
      calls = calls + 1
      return original(...)
    end
    view.paint()
    local fi = assert(h.file_index(V, "src/main.lua"))
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    view.toggle_reviewed()
    view.toggle_reviewed()
    view.toggle_expand()
    view.toggle_expand()
    vim.diff = original
    assert.same(0, calls)
  end)

  it("keeps the emphasis it started with", function()
    assert.is_true(#span_marks(view.current().render) > 0)
  end)
end)

describe("changing scope", function()
  it("produces spans correct for what is now on screen", function()
    view.set_scope("staged")
    local V = view.current()
    -- The staged scope is a pure addition, so there is nothing to pair and nothing to
    -- emphasize -- which is only meaningful because the branch scope did emphasize things.
    assert.same(
      { "src/routes.lua" },
      vim.tbl_map(function(f)
        return f.path
      end, V.files)
    )
    assert.same(0, #span_marks(V.render))

    view.set_scope("branch")
    assert.is_true(#span_marks(view.current().render) > 0)
  end)
end)

describe("what an annotation records", function()
  -- ADR-0002 read one step further: an entry does not record how it was captured, and it
  -- must not record how it was drawn either.

  ---The row holding a file's replacement line -- the emphasized one, not the context row
  ---above it, or this would be capturing on a line the feature never touches.
  ---@param V CRView
  ---@return integer
  local function replacement_row(V)
    return assert(h.row_of(V, "src/main.lua", function(a)
      return a.kind == "line" and V.files[a.file].hunks[a.hunk].lines[a.line].side == "add"
    end))
  end

  local function capture()
    queue.clear()
    local V = view.current()
    vim.api.nvim_win_set_cursor(V.win, { replacement_row(V), 0 })
    annotate.annotate("bug")
    local entry = vim.deepcopy(queue.all()[1])
    -- The queue's own counter, which counts captures in this process and nothing else.
    entry.id = nil
    return entry, payload.render(queue.all(), V.root, { types = config.get().types })
  end

  it("captured on a line that is emphasized", function()
    local V = view.current()
    assert.is_true(#span_marks(V.render, replacement_row(V)) > 0)
  end)

  local on_entry, on_payload = capture()

  configure({ spans = false })
  view.refresh()
  local off_entry, off_payload = capture()

  configure()
  view.refresh()

  it("produces the same entry with the feature on and off", function()
    assert.same(off_entry, on_entry)
  end)

  it("produces a byte-identical payload", function()
    assert.same(off_payload, on_payload)
  end)

  it("says nothing about spans in the composer's context", function()
    assert.is_nil(last_ctx.spans)
  end)
end)
