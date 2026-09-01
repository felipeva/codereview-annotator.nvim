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

--- In a real view --------------------------------------------------------------

-- Solo on, from configuration. There is no key for it in this ticket -- that is a later one
-- -- so this is how a reviewer gets it, and it is what the option is for.
--
-- `setup` again rather than a second spec file. The default above is read off
-- `config.defaults`, which is the claim about a host that says nothing, so nothing done to
-- the options here can reach it.
require("codereview").setup({
  solo = true,
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "a note about a soloed file")
  end,
  send = function() end,
})

local annotate = require("codereview.annotate")
local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

view.open("branch")
local V = assert(view.current(), "no review view opened")
queue.clear()

---The file the diff cursor is in.
---@return integer
local function at()
  return V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]].file
end

---Put the view on a file without going through any of the keys under test.
---
---Reaching into the view the way `panel_spec` writes `V.reviewed` and `render_spec` writes
---the archived flag. This is where a case *starts*; driving it with `]f` would make every
---case below a test of `]f`.
---@param index integer
local function show(index)
  V.solo = index
  view.paint(index)
end

---Press keys in a window and collect what the plugin said while they ran.
---@param win integer
---@param keys string
---@return string[] messages
local function press(win, keys)
  local messages, restore = h.capture_notify()
  vim.api.nvim_set_current_win(win)
  h.feed(keys)
  restore()
  return messages
end

---@return string[]
local function panel_lines()
  return vim.api.nvim_buf_get_lines(V.panel_buf, 0, -1, false)
end

---Mark every file unreviewed again, so a case starts where the one before it did.
local function unreview()
  for path in pairs(V.reviewed) do
    V.reviewed[path] = nil
  end
  V.expanded = {}
  view.paint()
end

describe("a review opened with solo on", function()
  it("draws one file, and it is the first", function()
    assert.is_true(#V.files > 1, "the fixture has one file, so drawing one proves nothing")
    assert.same({ 1 }, files_drawn(V.render))
  end)

  it("still lists every file in the tree", function()
    assert.same(#V.files, #V.panel_render.file_rows)
  end)

  -- Solo is a rendering choice and never a **scope**, so the map of the review is whole
  -- while one square of it is read: the marks and the counts belong to the tree, and the
  -- tree is built from the review's files rather than from what the diff drew.
  it("keeps every file's reviewed mark and note count in the tree", function()
    local marked = assert(h.file_index(V, "src/routes.lua"))
    V.reviewed[V.files[marked].path] = V.files[marked].blob or ""
    vim.api.nvim_win_set_cursor(V.win, { assert(h.line_row(V, V.files[1].path)), 0 })
    annotate.annotate("bug")

    local lines = panel_lines()
    local icons = config.get().icons
    assert.is_truthy(
      lines[V.panel_render.file_row[marked]]:find(icons.reviewed, 1, true),
      lines[V.panel_render.file_row[marked]]
    )
    assert.same("1", lines[V.panel_render.file_row[1]]:match("(%d)%s*$"))

    queue.clear()
    unreview()
  end)

  -- `✓2/7` must not become `✓0/1` because of how someone is reading.
  it("counts every file in the scope in the review summary", function()
    local marked = assert(h.file_index(V, "src/routes.lua"))
    V.reviewed[V.files[marked].path] = V.files[marked].blob or ""
    view.paint()
    local icons = config.get().icons
    assert.is_truthy(h.winbar(V.win):find(("%s1/%d"):format(icons.reviewed, #V.files), 1, true), h.winbar(V.win))
    unreview()
  end)
end)

describe("the file keys", function()
  it("]f draws the next file", function()
    show(3)
    press(V.win, "]f")
    assert.same({ 4 }, files_drawn(V.render))
    assert.same(4, at())
  end)

  it("[f draws the previous file, from that file's header", function()
    show(4)
    press(V.win, "[f")
    assert.same({ 3 }, files_drawn(V.render))
    assert.same(3, at())
  end)

  -- The rule `]f` and `[f` have always followed is "the nearest file header row in that
  -- direction", and from inside a file the nearest header above it is that file's own. Said
  -- as an index now, because the file being looked for may have no row -- so this is the
  -- half of the old rule that a rewrite in index space could silently drop.
  it("[f from inside a file goes to the top of it rather than past it", function()
    show(4)
    vim.api.nvim_win_set_cursor(V.win, { #V.render.lines, 0 })
    press(V.win, "[f")
    assert.same({ 4 }, files_drawn(V.render))
    assert.same(V.render.file_rows[4], vim.api.nvim_win_get_cursor(V.win)[1])
  end)

  it("says there is no next file on the last one", function()
    show(#V.files)
    local said = press(V.win, "]f")
    assert.is_true(h.notified(said, "No next file here"), vim.inspect(said))
    assert.same({ #V.files }, files_drawn(V.render))
  end)
end)

-- The case this whole ticket exists to prevent. `file_rows` is sparse under solo -- one
-- entry, and not at index 1 -- so a candidate list built by walking that map as an array
-- comes back empty and `]F` reports the review finished with five files still unreviewed.
describe("]F and [F over a sparse map", function()
  it("draws the next unreviewed file, and does not claim the review is done", function()
    for i = 1, 3 do
      V.reviewed[V.files[i].path] = V.files[i].blob or ""
    end
    show(3)
    -- The guard the case needs: more than one file left, or an empty answer and the right
    -- answer are the same length.
    local left = 0
    for _, f in ipairs(V.files) do
      if not V.reviewed[f.path] then
        left = left + 1
      end
    end
    assert.is_true(left > 1, ("only %d unreviewed files"):format(left))

    local said = press(V.win, "]F")
    assert.is_false(h.notified(said, "Everything in this scope is reviewed"), vim.inspect(said))
    assert.same({ 4 }, files_drawn(V.render))
    assert.same(4, at())
  end)

  it("[F draws the previous unreviewed file", function()
    show(6)
    press(V.win, "[F")
    assert.same({ 5 }, files_drawn(V.render))
    assert.same(5, at())
  end)

  it("says the review is done only when every file is reviewed", function()
    for _, f in ipairs(V.files) do
      V.reviewed[f.path] = f.blob or ""
    end
    show(3)
    local said = press(V.win, "]F")
    assert.is_true(h.notified(said, "Everything in this scope is reviewed"), vim.inspect(said))
    unreview()
  end)
end)

describe("the file picker", function()
  it("<C-p> reaches a file that is not drawn", function()
    show(1)
    local wanted = assert(h.file_index(V, "src/routes.lua"))
    vim.ui.select = function(items, _, cb)
      for i, s in ipairs(items) do
        if s:find("src/routes.lua", 1, true) then
          return cb(s, i)
        end
      end
    end
    assert.is_nil(V.render.file_rows[wanted], "the file was already drawn, so the jump proves nothing")

    press(V.win, "<C-p>")
    assert.same({ wanted }, files_drawn(V.render))
    assert.same(wanted, at())
  end)
end)

describe("the tree's open action", function()
  it("<CR> on a tree row draws the file on it", function()
    show(1)
    local wanted = assert(h.file_index(V, "src/nonl.md"))
    assert.is_nil(V.render.file_rows[wanted], "the file was already drawn, so the jump proves nothing")

    vim.api.nvim_win_set_cursor(V.panel_win, { assert(V.panel_render.file_row[wanted]), 0 })
    press(V.panel_win, "<CR>")
    assert.same({ wanted }, files_drawn(V.render))
    assert.same(wanted, at())
  end)
end)

describe("the queue float", function()
  local first = 1
  local second = assert(h.file_index(V, "src/routes.lua"))

  -- One note in each of two files, which means drawing each of them to make it: solo is
  -- not a filter on what a reviewer has written, and this is what gives that something to
  -- be false about.
  show(first)
  vim.api.nvim_win_set_cursor(V.win, { assert(h.line_row(V, V.files[first].path)), 0 })
  annotate.annotate("bug")
  show(second)
  local target_row = assert(h.line_row(V, V.files[second].path))
  vim.api.nvim_win_set_cursor(V.win, { target_row, 0 })
  annotate.annotate("bug")

  it("lists every entry in the scope, not the drawn file's", function()
    assert.same(2, #queue.all())
    view.review_queue()
    local float = vim.api.nvim_get_current_win()
    local bar = vim.pesc(config.get().icons.change_bar)
    local numbered = 0
    for _, text in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false)) do
      if text:match("^%s*" .. bar .. "%s*%d+  ") then
        numbered = numbered + 1
      end
    end
    assert.same(2, numbered)
    vim.api.nvim_win_close(float, true)
  end)

  it("jumps to an entry in another file by drawing that file", function()
    show(second)
    assert.same({ second }, files_drawn(V.render))
    view.review_queue()
    local float = vim.api.nvim_get_current_win()
    local bar = vim.pesc(config.get().icons.change_bar)
    for row, text in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false)) do
      if text:match("^%s*" .. bar .. "%s*1  ") then
        vim.api.nvim_win_set_cursor(float, { row, 0 })
        break
      end
    end
    press(float, "<CR>")

    assert.same({ first }, files_drawn(V.render))
    assert.same(first, at())
  end)

  queue.clear()
  view.paint()
end)

describe("archived entries", function()
  it("are drawn on the file being read", function()
    local fi = assert(h.file_index(V, "src/routes.lua"))
    state.archive_batch({
      {
        id = 1,
        type = "bug",
        kind = "file",
        path = V.files[fi].path,
        key = render.file_key(V.files[fi].path),
        note = "already sent, about a soloed file",
      },
      -- `V.root` and not the path the fixture was built at: the archive is filed under the
      -- **checkout**, and git resolves the symlink macOS's temporary directory is
      -- (`/var/...` against `/private/var/...`). Filed under the other one it is an archive
      -- about somewhere else, and the diff draws nothing with nothing wrong on screen.
    }, "agent", V.root)
    show(fi)

    local found = false
    for _, m in ipairs(h.virt_marks(V)) do
      for _, line in ipairs(m[4].virt_lines) do
        for _, chunk in ipairs(line) do
          found = found or chunk[1]:find("already sent, about a soloed file", 1, true) ~= nil
        end
      end
    end
    assert.is_true(found, "the archived entry is not drawn on the file on screen")
    assert.is_true(h.virt_groups(V).CodeReviewArchived or false)
  end)
end)

describe("annotating a soloed file", function()
  ---An entry without the two fields no two captures can share.
  ---@param entry table
  ---@return table
  local function anonymous(entry)
    local out = vim.deepcopy(entry)
    out.id, out.at = nil, nil
    return out
  end

  -- Nothing about how the reviewer was reading reaches the **target**: the entry a soloed
  -- capture produces is the entry the same line produces with every file on screen.
  -- ADR-0009, asserted as an equality rather than as an absence, because "no field says
  -- solo" would pass with a field that said it under another name.
  it("produces the entry it produces unsoloed", function()
    queue.clear()
    local fi = assert(h.file_index(V, "src/main.lua"))
    show(fi)
    local row = assert(h.line_row(V, V.files[fi].path))
    vim.api.nvim_win_set_cursor(V.win, { row, 0 })
    annotate.annotate("bug")
    local soloed_entry = anonymous(queue.all()[1])

    queue.clear()
    config.get().solo = false
    view.paint(fi)
    local unsoloed_row = assert(h.row_of(V, V.files[fi].path, function(a)
      return a.kind == "line"
    end))
    vim.api.nvim_win_set_cursor(V.win, { unsoloed_row, 0 })
    annotate.annotate("bug")
    local plain_entry = anonymous(queue.all()[1])

    assert.same(plain_entry, soloed_entry)

    queue.clear()
    config.get().solo = true
    view.paint()
  end)
end)

-- **`]h` and `[h` stop at the drawn file's last and first hunk and report it.** A hunk key
-- that silently repainted the whole view would be a surprise, and `]F` is one keystroke away.
--
-- They do it by construction rather than through a branch of their own: `hunk_rows` is
-- appended inside the render's file walk, and solo gates that walk one file up, so a soloed
-- render can only ever hold the drawn file's hunks. Asserted here because a construction
-- nothing pins is one the next rewrite can lose without reddening anything -- and because the
-- fixture gives each file a single hunk, so a case reasoning from the count rather than
-- pressing the key would be right for the wrong reason.
describe("]h and [h", function()
  it("]h stops at the last hunk of the drawn file and says so", function()
    show(assert(h.file_index(V, "src/main.lua")))
    vim.api.nvim_win_set_cursor(V.win, { #V.render.lines, 0 })
    local said = press(V.win, "]h")
    assert.is_true(h.notified(said, "No next hunk here"), vim.inspect(said))
  end)

  it("[h stops at the first hunk of the drawn file and says so", function()
    unreview()
    local fi = assert(h.file_index(V, "src/main.lua"))
    show(fi)
    vim.api.nvim_win_set_cursor(V.win, { V.render.hunk_rows[1], 0 })
    local said = press(V.win, "[h")
    assert.is_true(h.notified(said, "No previous hunk here"), vim.inspect(said))
    assert.same({ fi }, files_drawn(V.render))
  end)

  -- The other half of what "stop" means: with solo off both keys walk out of the file they
  -- are in, which is what they have always done and what this ticket must not have changed.
  it("cross into the next and the previous file with solo off", function()
    unreview()
    config.get().solo = false
    view.paint(1)
    local fi = assert(h.file_index(V, "src/main.lua"))
    local rows = {}
    for _, r in ipairs(V.render.hunk_rows) do
      if V.render.anchors[r].file == fi then
        rows[#rows + 1] = r
      end
    end
    vim.api.nvim_win_set_cursor(V.win, { rows[#rows], 0 })
    press(V.win, "]h")
    local forward = at()
    vim.api.nvim_win_set_cursor(V.win, { rows[1], 0 })
    press(V.win, "[h")
    local backward = at()
    -- Read, put the option back, and only then assert, so a failure here does not leave solo
    -- off under every case below this one.
    config.get().solo = true
    view.paint(1)

    assert.same(fi + 1, forward)
    assert.same(fi - 1, backward)
  end)
end)

-- `]a` and `[a` are unchanged by this ticket, and they reach the drawn file's notes for the
-- same reason the hunk keys stop: they collect their rows out of the render's anchors, which
-- under solo name one file. The **queue** is not filtered -- the note in the file that is not
-- drawn is still in it, and still submits -- so this is about where a key can go, not about
-- what a reviewer has written.
describe("]a and [a", function()
  it("move between the drawn file's annotations and reach no other file's", function()
    unreview()
    local fi = assert(h.file_index(V, "src/main.lua"))
    local other = assert(h.file_index(V, "src/routes.lua"))
    -- One note in each, which means drawing each of them to make it.
    show(other)
    vim.api.nvim_win_set_cursor(V.win, { assert(h.line_row(V, V.files[other].path)), 0 })
    annotate.annotate("bug")
    show(fi)
    local annotated = assert(h.line_row(V, V.files[fi].path))
    vim.api.nvim_win_set_cursor(V.win, { annotated, 0 })
    annotate.annotate("bug")
    assert.same(2, #queue.all())

    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    press(V.win, "]a")
    assert.same(annotated, vim.api.nvim_win_get_cursor(V.win)[1])
    -- The drawn file holds one note, so both keys come back to it rather than reaching the
    -- one in the file that is not drawn, and neither of them draws another file.
    press(V.win, "]a")
    assert.same(annotated, vim.api.nvim_win_get_cursor(V.win)[1])
    press(V.win, "[a")
    assert.same(annotated, vim.api.nvim_win_get_cursor(V.win)[1])
    assert.same({ fi }, files_drawn(V.render))

    queue.clear()
    view.paint(fi)
  end)

  -- The sentence beside the keys. What the keys reach is unchanged; what they *say* when they
  -- reach nothing was a claim about the review made from a fact about one file, and a
  -- reviewer with annotations in other files read it as their work being gone (#215).
  it("says this file has none, and names the key that reviews the queue", function()
    unreview()
    queue.clear()
    -- One annotation, and it is in a file this case will not draw.
    local elsewhere = assert(h.file_index(V, "src/routes.lua"))
    show(elsewhere)
    vim.api.nvim_win_set_cursor(V.win, { assert(h.line_row(V, V.files[elsewhere].path)), 0 })
    annotate.annotate("bug")
    local bare = assert(h.file_index(V, "src/main.lua"))
    show(bare)
    assert.same(1, #queue.all())

    local header = assert(V.render.file_rows[bare])
    for _, key in ipairs({ "]a", "[a" }) do
      vim.api.nvim_win_set_cursor(V.win, { header, 0 })
      local said = press(V.win, key)
      assert.is_true(h.notified(said, "No annotations in this file"), key .. ": " .. vim.inspect(said))
      assert.is_true(h.notified(said, "`Q` reviews the queue"), key .. ": " .. vim.inspect(said))
      -- Neither key drew another file, and neither moved off the one that is drawn.
      assert.same({ bare }, files_drawn(V.render))
      assert.same(header, vim.api.nvim_win_get_cursor(V.win)[1])
    end
    -- The queue is a rendering choice's business in neither direction: the annotation made
    -- above is still in it, unread by any of this.
    assert.same(1, #queue.all())
    queue.clear()
    view.paint(bare)
  end)

  -- The honest case keeps its honest answer. Nothing found and nothing written is not a
  -- narrow fact, so *yet* is true and the sentence does not move.
  it("keeps the wide sentence when the queue holds nothing either", function()
    queue.clear()
    local bare = assert(h.file_index(V, "src/main.lua"))
    show(bare)
    assert.same(0, #queue.all())
    vim.api.nvim_win_set_cursor(V.win, { assert(V.render.file_rows[bare]), 0 })
    local said = press(V.win, "]a")
    assert.is_true(h.notified(said, "No annotations yet"), vim.inspect(said))
  end)

  -- And with solo off the keys searched every file, so nothing found really does mean nothing
  -- written. This is the sentence a reviewer has always had, and a fix for how solo reads must
  -- not change how everyone else reads.
  it("keeps the wide sentence with solo off and nothing written anywhere", function()
    queue.clear()
    config.get().solo = false
    view.paint(1)
    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    local said = press(V.win, "]a")
    local drawn = #files_drawn(V.render)
    -- Read, put the option back, and only then assert, so a failure here does not leave solo
    -- off under every case below this one.
    config.get().solo = true
    view.paint(1)

    assert.is_true(drawn > 1, "solo did not come off, so this case searched one file")
    assert.is_true(h.notified(said, "No annotations yet"), vim.inspect(said))
  end)
end)

-- **`R` is the one key whose meaning solo changes** rather than merely repainting for.
-- Outside solo it collapses the file it marks and the reviewer reads on down the diff; in
-- solo there is nothing else drawn to read on into, so the file gives way to the next
-- unreviewed one and marking and moving are one motion (`CONTEXT.md` under **Solo**, and
-- ADR-0009).
--
-- The sentences are the motion's own rather than a second set meaning the same thing: `R`
-- comes to `]F` to go on, so it wraps where `]F` wraps and says the review is done where
-- `]F` says it. Both are asserted here rather than assumed.
--
-- Every case below starts by clearing the marks rather than leaving them cleared, because
-- these run top to bottom and a case that fails never reaches its own cleanup. Cleaning up
-- afterwards makes one red case red the two below it as well.
describe("R with solo on", function()
  it("marks the drawn file reviewed and draws the next unreviewed file", function()
    unreview()
    local fi = assert(h.file_index(V, "src/main.lua"))
    local next_up = assert(h.file_index(V, "src/newname.lua"))
    show(fi)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    press(V.win, "R")
    assert.is_truthy(V.reviewed[V.files[fi].path])
    assert.same({ next_up }, files_drawn(V.render))
    assert.same(next_up, at())
  end)

  -- The collapse is kept, and it is what the reviewer meets on the way back rather than
  -- anything they see now: reviewed means collapsed is one rule, it is persisted, and a file
  -- marked while soloing has to come back collapsed when the drawing stops.
  it("collapses the file it marked, which is what ]f back onto it finds", function()
    unreview()
    local fi = assert(h.file_index(V, "src/main.lua"))
    show(fi)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    press(V.win, "R")
    assert.same(false, V.expanded[V.files[fi].path])
    press(V.win, "[f")
    assert.same({ fi }, files_drawn(V.render))
    assert.same(2, #V.render.lines)
    assert.is_truthy(V.render.lines[1]:find("src/main.lua", 1, true), V.render.lines[1])
    assert.same("", V.render.lines[2])
  end)

  it("wraps to the first unreviewed file in the motion's own words", function()
    unreview()
    local fi = assert(h.file_index(V, "src/main.lua"))
    for i = fi + 1, #V.files do
      V.reviewed[V.files[i].path] = V.files[i].blob or ""
    end
    show(fi)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    local said = press(V.win, "R")
    assert.is_true(h.notified(said, "Wrapped to the first unreviewed file"), vim.inspect(said))
    assert.same({ 1 }, files_drawn(V.render))
  end)

  -- Story 15: finishing has to be legible. The sentence is `]F`'s own, and the view is left
  -- on the file that was just marked -- collapsed, so its header is what is on screen, which
  -- is story 39's "never blank with a file selected" rather than an empty window.
  it("says the review is done on the last unreviewed file, and stays on it", function()
    unreview()
    local fi = assert(h.file_index(V, "src/main.lua"))
    for i, file in ipairs(V.files) do
      if i ~= fi then
        V.reviewed[file.path] = file.blob or ""
      end
    end
    show(fi)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    local said = press(V.win, "R")
    assert.is_true(h.notified(said, "Everything in this scope is reviewed"), vim.inspect(said))
    assert.is_truthy(V.reviewed[V.files[fi].path])
    assert.same({ fi }, files_drawn(V.render))
    assert.same(1, V.render.file_rows[fi])
    assert.same(fi, at())
    -- What is on screen, and not merely which file the render is about: the header row and
    -- the pad under it. Without this the mark could reach the state and never reach a paint.
    assert.same(2, #V.render.lines)
  end)

  -- Unmarking is a reviewer correcting themselves. Being carried off the file they have just
  -- reopened would undo the correction, and the motion would skip past it besides.
  it("does not advance when it unmarks a file", function()
    unreview()
    local fi = assert(h.file_index(V, "src/main.lua"))
    V.reviewed[V.files[fi].path] = V.files[fi].blob or ""
    V.expanded[V.files[fi].path] = false
    show(fi)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    press(V.win, "R")
    assert.is_nil(V.reviewed[V.files[fi].path])
    assert.same({ fi }, files_drawn(V.render))
    assert.is_true(V.expanded[V.files[fi].path])
  end)

  -- From the tree the file marked and the file the diff cursor is in are two different
  -- files, so this is where "the motion starts from the file that was marked" is a claim
  -- rather than a restatement: the diff is drawing `src/main.lua` and the row says
  -- `src/routes.lua`, and what is drawn afterwards is the file after *routes*.
  it("from the tree marks the file on the row and draws the next unreviewed one", function()
    unreview()
    show(assert(h.file_index(V, "src/main.lua")))
    local marked = assert(h.file_index(V, "src/routes.lua"))
    local next_up = assert(h.file_index(V, "src/untracked.bin"))
    local row = V.panel_render.file_row[marked]
    vim.api.nvim_win_set_cursor(V.panel_win, { row, 0 })
    press(V.panel_win, "R")
    assert.is_truthy(V.reviewed[V.files[marked].path])
    assert.same({ next_up }, files_drawn(V.render))
    assert.same(next_up, at())
    -- The tree's cursor is left on the row it was on, as it is with solo off.
    assert.same(row, vim.api.nvim_win_get_cursor(V.panel_win)[1])
  end)

  -- A directory row marks a whole subtree and reports that in a sentence of its own. It is a
  -- different motion from the file-by-file loop, so it does not carry the reviewer anywhere,
  -- and the drawn file inside it is left collapsed on its header rather than blank.
  --
  -- **What this case proves, and what it does not.** The fixture is flat: `src` is its only
  -- directory, so marking that row marks every file and there is nothing left to go on to.
  -- Advancing and staying put therefore draw the same thing, and the claim cannot be read off
  -- which file is drawn. It is read off what was *said* instead -- a motion that ran would
  -- have added a sentence of its own -- which catches the change anyone would make by
  -- accident, but not one that advances and suppresses the motion's sentence together. A
  -- nested tree is what would defend that half, by leaving unreviewed files outside the
  -- subtree; no spec here has one, and the decision is argued in the commit message.
  it("on a directory row marks the subtree and draws no other file", function()
    unreview()
    local fi = assert(h.file_index(V, "src/main.lua"))
    show(fi)
    vim.api.nvim_win_set_cursor(V.panel_win, { 1, 0 })
    local said = press(V.panel_win, "R")
    -- Exactly that sentence and no other. Marking the only directory of a flat fixture marks
    -- every file, so there is nothing left to go on to and "it did not go on" cannot be read
    -- off which file is drawn -- but a motion that ran would have said so, and this is where
    -- that shows.
    assert.same({ ("Marked %d files under src"):format(#V.files) }, said)
    assert.same({ fi }, files_drawn(V.render))
    assert.same(1, V.render.file_rows[fi])
  end)
end)

describe("R with solo off", function()
  it("collapses the file it marks and goes nowhere, exactly as it does today", function()
    unreview()
    config.get().solo = false
    view.paint(1)
    local fi = assert(h.file_index(V, "src/main.lua"))
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    press(V.win, "R")
    -- Read, put the option back, and only then assert: an assertion that fails here would
    -- otherwise leave solo off under every case below this one.
    local marked = V.reviewed[V.files[fi].path]
    local drawn, spent, landed = files_drawn(V.render), #rows_of(V.render, fi), at()
    unreview()
    config.get().solo = true
    view.paint(1)

    assert.is_truthy(marked)
    local every = {}
    for i = 1, #V.files do
      every[i] = i
    end
    assert.same(every, drawn)
    -- Down to its header and its pad, with the reviewer left on it.
    assert.same(2, spent)
    assert.same(fi, landed)
  end)
end)

describe("the option turned off in a live review", function()
  -- The other half of "off costs nothing": a view that stops soloing draws every file
  -- again, with no second path to get back to.
  it("draws every file again", function()
    show(3)
    assert.same({ 3 }, files_drawn(V.render))
    config.get().solo = false
    view.paint(3)
    local every = {}
    for i = 1, #V.files do
      every[i] = i
    end
    assert.same(every, files_drawn(V.render))
    config.get().solo = true
  end)
end)

-- Two things the view decides for itself, rather than being told by a key.
describe("the file the paint draws", function()
  it("is the last one when the index has outrun the file list", function()
    -- A **scope** change and a re-read both replace the file list under the soloed index,
    -- so it can name a file that is no longer there. Drawing the last file is a review a
    -- reviewer can read; drawing nothing is a blank window with no way out of it.
    V.solo = #V.files + 40
    view.paint()
    assert.same({ #V.files }, files_drawn(V.render))
  end)

  -- The `]F` sentence is decided by the review's files and not by where the cursor is,
  -- which is the order these two questions have to be asked in: a review with no files has
  -- no cursor in one, so asking the cursor first leaves an empty scope silent.
  it("is nothing at all in an empty review, which still says what ]F says", function()
    local kept = V.files
    V.files = {}
    view.paint()
    assert.same({}, V.render.lines)

    local said = press(V.win, "]F")
    assert.is_true(h.notified(said, "Everything in this scope is reviewed"), vim.inspect(said))

    V.files = kept
    V.solo = 1
    view.paint(1)
  end)
end)

-- **The intersection neither ticket owned.** `R` advancing is #196's and `go` is #195's, and
-- these two facts are true of the pair and of neither half alone: what turning solo off
-- restores is the file `R` *moved to*, and not the file `R` marked, and not the top of the
-- review.
--
-- Last in the file deliberately. `go` writes a module-local override in `config` that has no
-- reset, and once it is written `config.get().solo` no longer decides -- so every case that
-- reaches solo through the configuration option has to run before this key is first pressed.
describe("R and then go", function()
  it("draws every file with the cursor on the file R advanced to", function()
    unreview()
    local fi = assert(h.file_index(V, "src/main.lua"))
    local next_up = assert(h.file_index(V, "src/newname.lua"))
    show(fi)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    press(V.win, "R")
    local advanced_to = files_drawn(V.render)

    press(V.win, "go")
    local drawn, landed = files_drawn(V.render), at()
    -- Read, then put the switch back, and only then assert: the override outlives the case.
    press(V.win, "go")

    assert.same({ next_up }, advanced_to)
    local every = {}
    for i = 1, #V.files do
      every[i] = i
    end
    assert.same(every, drawn)
    -- The file it went on to. Not the file it marked -- which is drawn again now, collapsed,
    -- a few rows above -- and not row 1, which is where a paint that kept no file would land.
    assert.same(next_up, landed)
  end)

  it("stays on the last unreviewed file when the review is done and solo goes off", function()
    unreview()
    local fi = assert(h.file_index(V, "src/main.lua"))
    for i, file in ipairs(V.files) do
      if i ~= fi then
        V.reviewed[file.path] = file.blob or ""
      end
    end
    show(fi)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    local said = press(V.win, "R")

    press(V.win, "go")
    local drawn, landed = files_drawn(V.render), at()
    press(V.win, "go")
    unreview()

    assert.is_true(h.notified(said, "Everything in this scope is reviewed"), vim.inspect(said))
    local every = {}
    for i = 1, #V.files do
      every[i] = i
    end
    assert.same(every, drawn)
    -- `R` stayed put and said so, so this is the file it marked, which is also the file it
    -- was on. Every other file is reviewed and collapsed around it.
    assert.same(fi, landed)
  end)
end)
