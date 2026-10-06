-- The **overlay**'s inline style: a **caption** above each annotated line, and the style
-- argument that picks it.
--
-- A real window throughout, as in overlay_spec. A caption is read back from the marks it
-- hangs on -- the anchors, and the paint's own mark for a whole-file entry -- with the group of
-- every chunk: groups, never colours, which are the colorscheme's. Where the claim is about
-- the screen (the text column, the row above line 1) it is read off a painted cell.
--
-- The resize that re-wraps a caption is an event, and the events never fire in a spec case
-- (see overlay_scroll_child); it is read in overlay_caption_child. Here the paint is called
-- by hand after a change, as overlay_spec does after a scroll.
--
-- The toggle and the style are module state and outlive every case, and plenary runs each
-- `it` as it reaches it, so every case that turns the overlay on turns it off again, and
-- every case names the style it turns on in.
local h = require("tests.helpers")

h.ui(80, 24)
local fixture = h.cd_fixture("mkfixture")

local LONG = "src/long.lua"
do
  local lines = {}
  for i = 1, 200 do
    lines[i] = ("local l%d = %d"):format(i, i)
  end
  vim.fn.writefile(lines, vim.fs.joinpath(fixture, LONG))
end

local NOTE = "queued from the buffer"
local OPTS = {
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, NOTE)
  end,
  send = function()
    return true
  end,
}
require("codereview").setup(OPTS)

local codereview = require("codereview")
local config = require("codereview.config")
local overlay = require("codereview.overlay")
local payload = require("codereview.payload")
local queue = require("codereview.queue")
local state = require("codereview.state")

local CONNECTOR = config.get().icons.caption
local root = assert(vim.uv.fs_realpath(fixture))

state.ensure_queue()

---@param over table
---@return CRAnnotation
local function queued(over)
  local first = over.first or 1
  return queue.add(vim.tbl_extend("force", {
    type = "bug",
    kind = "line",
    path = LONG,
    abs_path = vim.fs.joinpath(root, LONG),
    key = ("%s:n:%d"):format(LONG, first),
    first = first,
    last = first,
    note = "a note",
  }, over))
end

---@param over table|nil
---@return CRAnnotation
local function whole_file(over)
  return queue.add(vim.tbl_extend("force", {
    type = "suggestion",
    kind = "file",
    path = LONG,
    abs_path = vim.fs.joinpath(root, LONG),
    key = LONG .. ":f:0",
    tag = "whole file",
    note = "the whole thing",
  }, over or {}))
end

---One window, holding the long file, scrolled to the top, with no number column.
---@return integer win, integer buf
local function code_window()
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, LONG)))
  vim.wo.number = false
  vim.wo.signcolumn = "auto"
  vim.cmd("normal! gg")
  return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

---Turn the overlay on in a style, from off, and hand back what it said.
---@param style "margin"|"inline"
---@return string[] said
local function on(style)
  assert(not overlay.enabled(), "a case before this one left the overlay on")
  local said, restore = h.capture_notify()
  assert.is_true(codereview.overlay(style))
  restore()
  assert.equal(style, overlay.style())
  return said
end

local function off()
  if overlay.enabled() then
    assert.is_false(codereview.overlay())
  end
end

---Every caption block on a buffer, top to bottom: the 1-based line it is drawn above, and its
---rows as `virt_lines` chunks.
---@param buf integer
---@return { line: integer, above: boolean, rows: table[] }[]
local function captions(buf)
  local out = {}
  for _, ns in ipairs({ overlay.NS, overlay.NS_ANCHOR }) do
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local d = m[4]
      if d.virt_lines then
        out[#out + 1] = { line = m[2] + 1, above = d.virt_lines_above == true, rows = d.virt_lines }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.line < b.line
  end)
  return out
end

---@param row table One `virt_lines` row
---@return string
local function text(row)
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, row))
end

---The rows of every caption above a line, as text, top to bottom.
---@param buf integer
---@param line integer
---@return string[]
local function rows_at(buf, line)
  local out = {}
  for _, c in ipairs(captions(buf)) do
    if c.line == line then
      assert.is_true(c.above, "a caption hangs below its line")
      for _, row in ipairs(c.rows) do
        out[#out + 1] = text(row)
      end
    end
  end
  return out
end

---The group of the chunk of a row that is exactly `chunk`, or nil.
---@param row table
---@param chunk string
---@return string|nil
local function group_of(row, chunk)
  for _, c in ipairs(row) do
    if c[1] == chunk then
      return c[2]
    end
  end
end

---Every group a row carries, in order.
---@param row table
---@return string[]
local function groups(row)
  local out = {}
  for _, c in ipairs(row) do
    if c[2] then
      out[#out + 1] = c[2]
    end
  end
  return out
end

---The first caption row above a line.
---@param buf integer
---@param line integer
---@return table
local function first_row(buf, line)
  for _, c in ipairs(captions(buf)) do
    if c.line == line then
      return c.rows[1]
    end
  end
  error("no caption above line " .. line)
end

---@param buf integer
---@return table<integer, string[]>
local function signs(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.NS, 0, -1, { details = true })) do
    local d = m[4]
    if d.sign_text then
      out[m[2] + 1] = out[m[2] + 1] or {}
      table.insert(out[m[2] + 1], d.sign_hl_group)
    end
  end
  return out
end

---A screen row as text, from a column.
---@param row integer 1-based
---@param col integer 1-based
---@param width integer
---@return string
local function cells(row, col, width)
  local s = {}
  for c = col, col + width - 1 do
    s[#s + 1] = vim.fn.screenstring(row, c)
  end
  return table.concat(s)
end

describe("the style argument", function()
  after_each(off)

  it("turns the overlay on in the inline style, with no margin and no new window", function()
    queue.clear()
    local _, buf = code_window()
    queued({ first = 10 })
    local before = #vim.api.nvim_tabpage_list_wins(0)
    on("inline")
    assert.is_true(overlay.enabled())
    assert.is_nil(overlay.margin())
    assert.equal(before, #vim.api.nvim_tabpage_list_wins(0))
    assert.same({ CONNECTOR .. " ✗ a note" }, rows_at(buf, 10))
  end)

  it("is what :CodeReviewOverlay inline does, and the bare command still toggles it off", function()
    queue.clear()
    local _, buf = code_window()
    queued({ first = 10 })
    vim.cmd("CodeReviewOverlay inline")
    assert.is_true(overlay.enabled())
    assert.equal("inline", overlay.style())
    assert.is_nil(overlay.margin())
    assert.equal(1, #rows_at(buf, 10))
    vim.cmd("CodeReviewOverlay")
    assert.is_false(overlay.enabled())
    assert.same({}, captions(buf))
    assert.same({}, signs(buf))
  end)

  it("leaves the overlay on when it names the style already drawn", function()
    queue.clear()
    local _, buf = code_window()
    queued({ first = 10 })
    on("inline")
    assert.is_true(codereview.overlay("inline"))
    assert.is_true(overlay.enabled())
    assert.equal(1, #rows_at(buf, 10))
  end)

  it("is completed with the two style names", function()
    assert.same({ "margin", "inline" }, vim.fn.getcompletion("CodeReviewOverlay ", "cmdline"))
    assert.same({ "inline" }, vim.fn.getcompletion("CodeReviewOverlay in", "cmdline"))
  end)

  it("refuses a style it does not know, says so, and changes nothing", function()
    code_window()
    local said, restore = h.capture_notify()
    assert.is_false(codereview.overlay("beside"))
    restore()
    assert.is_false(overlay.enabled())
    assert.is_true(h.notified(said, 'Unknown overlay style "beside"'), vim.inspect(said))
  end)
end)

describe("a caption", function()
  after_each(off)

  it("is a virtual line above its anchor: connector and icon in the type's group, note in the note group", function()
    queue.clear()
    local _, buf = code_window()
    queued({ type = "fix", first = 12, note = "pull it out" })
    on("inline")
    local row = first_row(buf, 12)
    assert.equal(CONNECTOR .. " ✎ pull it out", text(row))
    assert.equal("CodeReviewFix", group_of(row, CONNECTOR .. " ✎ "))
    assert.equal("CodeReviewNote", group_of(row, "pull it out"))
    assert.same({ "CodeReviewFix", "CodeReviewNote" }, groups(row))
  end)

  it("says stale in the stale group, and only on a stale entry", function()
    queue.clear()
    local _, buf = code_window()
    queued({ first = 12, note = "moved", stale = true })
    queued({ first = 20, note = "still" })
    on("inline")
    local stale = first_row(buf, 12)
    assert.equal(CONNECTOR .. " ✗ ⚠ stale moved", text(stale))
    assert.equal("CodeReviewStale", group_of(stale, "⚠ stale "))
    assert.same({ "CodeReviewBug", "CodeReviewStale", "CodeReviewNote" }, groups(stale))
    assert.same({ "CodeReviewBug", "CodeReviewNote" }, groups(first_row(buf, 20)))
  end)

  it("draws an untyped entry with the untyped mark, in the note group", function()
    queue.clear()
    local _, buf = code_window()
    queue.add({
      kind = "line",
      path = LONG,
      abs_path = vim.fs.joinpath(root, LONG),
      key = LONG .. ":n:12",
      first = 12,
      last = 12,
      note = "worth a look",
    })
    on("inline")
    local row = first_row(buf, 12)
    assert.equal(CONNECTOR .. " • worth a look", text(row))
    assert.same({ "CodeReviewNote", "CodeReviewNote" }, groups(row))
  end)

  it("puts a sign in the type's group on every covered line", function()
    queue.clear()
    local _, buf = code_window()
    queued({ type = "fix", kind = "range", first = 9, last = 11, key = LONG .. ":n:9", note = "range" })
    on("inline")
    local s = signs(buf)
    assert.same({ "CodeReviewFix" }, s[9])
    assert.same({ "CodeReviewFix" }, s[10])
    assert.same({ "CodeReviewFix" }, s[11])
    assert.is_nil(s[8])
    assert.is_nil(s[12])
  end)

  -- Number and sign columns on, so the text width is the window's less six columns, and a
  -- note of three-letter words, so a budget that forgot those six columns would fill rows past
  -- the edge rather than stopping just short of it.
  it("wraps its note in full to the window's text width, continuation rows under the note", function()
    queue.clear()
    local win, buf = code_window()
    vim.wo[win].number = true
    vim.wo[win].signcolumn = "yes"
    local words = {}
    for i = 1, 60 do
      words[i] = ("w%02d"):format(i)
    end
    local note = table.concat(words, " ")
    queued({ first = 5, note = note })
    on("inline")
    local textoff = vim.fn.getwininfo(win)[1].textoff
    assert.equal(6, textoff)
    local width = vim.api.nvim_win_get_width(win) - textoff
    local c = captions(buf)[1]
    assert.is_true(#c.rows > 1, "the note did not wrap")
    local prefix = vim.fn.strdisplaywidth(c.rows[1][1][1])
    local joined = {}
    for n, row in ipairs(c.rows) do
      local w = vim.fn.strdisplaywidth(text(row))
      assert.is_true(w <= width, ("row %d is %d columns in a text width of %d"):format(n, w, width))
      -- Every row but the last breaks within a word's width of the edge.
      if n < #c.rows then
        assert.is_true(w > width - 4, ("row %d is %d columns, short of a text width of %d"):format(n, w, width))
      end
      if n > 1 then
        -- Under the note: the indent is exactly as wide as everything before it on row one.
        assert.equal(prefix, vim.fn.strdisplaywidth(row[1][1]))
        assert.equal("", vim.trim(row[1][1]))
      end
      joined[#joined + 1] = row[#row][1]
    end
    assert.equal(note, table.concat(joined, " "))
    vim.wo[win].number = false
    vim.wo[win].signcolumn = "auto"
  end)

  -- Read off the screen: the connector at the first text column, after the number and sign
  -- columns, on the row above line 5.
  it("starts at the text column, so the connector aligns with the code", function()
    queue.clear()
    local win = code_window()
    vim.wo[win].number = true
    queued({ first = 5, note = "aligned" })
    on("inline")
    vim.cmd("redraw")
    local textoff = vim.fn.getwininfo(win)[1].textoff
    assert.equal(CONNECTOR .. " ✗ aligned", vim.trim(cells(5, textoff + 1, 20)))
    assert.equal(CONNECTOR, cells(5, textoff + 1, 2):gsub("%s", ""))
    assert.equal("", vim.trim(cells(5, 1, textoff)))
    vim.wo[win].number = false
  end)

  it("re-wraps to the text width the window has at the next paint", function()
    queue.clear()
    local win, buf = code_window()
    local words = {}
    for i = 1, 40 do
      words[i] = ("w%02d"):format(i)
    end
    queued({ first = 5, note = table.concat(words, " ") })
    on("inline")
    local wide = #captions(buf)[1].rows
    vim.wo[win].number = true
    vim.wo[win].numberwidth = 20
    overlay.paint()
    local width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
    local narrow = captions(buf)[1].rows
    assert.is_true(#narrow > wide, ("%d rows at full width, %d with a wide number column"):format(wide, #narrow))
    for _, row in ipairs(narrow) do
      assert.is_true(vim.fn.strdisplaywidth(text(row)) <= width)
    end
    vim.wo[win].number = false
    vim.wo[win].numberwidth = 4
  end)
end)

describe("captions in one place", function()
  after_each(off)

  it("sit above line 1 for a whole-file entry, ahead of line 1's own, and on screen", function()
    queue.clear()
    local win, buf = code_window()
    queued({ type = "issue", first = 1, note = "line one" })
    whole_file()
    on("inline")
    assert.same({ CONNECTOR .. " ✦ the whole thing", CONNECTOR .. " ⚑ line one" }, rows_at(buf, 1))
    -- The window was at its top, so it is scrolled up into the rows above line 1.
    vim.cmd("redraw")
    assert.equal(1, vim.fn.line("w0", win))
    assert.equal(CONNECTOR .. " ✦ the whole thing", vim.trim(cells(1, 1, 40)))
    assert.equal(CONNECTOR .. " ⚑ line one", vim.trim(cells(2, 1, 40)))
    assert.equal("local l1 = 1", vim.trim(cells(3, 1, 40)):gsub("^%S*▌%s*", ""))
  end)

  it("sit above line 1 for a whole-file entry alone", function()
    queue.clear()
    local _, buf = code_window()
    whole_file()
    on("inline")
    assert.same({ CONNECTOR .. " ✦ the whole thing" }, rows_at(buf, 1))
  end)

  it("stack in id order on one line, whatever order their anchors were made in", function()
    queue.clear()
    local _, buf = code_window()
    -- Past the end, so it is skipped and gets no anchor on the first paint.
    local late = queued({ first = 500, note = "first in the queue" })
    queued({ type = "fix", first = 20, note = "second in the queue" })
    on("inline")
    assert.same({ CONNECTOR .. " ✎ second in the queue" }, rows_at(buf, 20))
    -- Now on line 20 too, and its anchor is made after the other's.
    late.first, late.last, late.key = 20, 20, LONG .. ":n:20"
    overlay.paint()
    assert.same({ CONNECTOR .. " ✗ first in the queue", CONNECTOR .. " ✎ second in the queue" }, rows_at(buf, 20))
  end)

  it("move with the code when an edit is made above them", function()
    queue.clear()
    local win, buf = code_window()
    queued({ first = 6, note = "follows" })
    on("inline")
    assert.equal(1, #rows_at(buf, 6))
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- one", "-- two" })
    -- No paint: the anchor carries the caption.
    assert.same({}, rows_at(buf, 6))
    assert.same({ CONNECTOR .. " ✗ follows" }, rows_at(buf, 8))
    off()
    vim.api.nvim_win_call(win, function()
      vim.cmd("silent! edit!")
    end)
  end)
end)

describe("entries a caption cannot draw", function()
  after_each(off)

  it("are skipped, the toggle says how many, and the drawn range keeps its signs", function()
    queue.clear()
    local _, buf = code_window()
    queued({ first = 7, key = LONG .. ":o:7", tag = "deleted", inline = true, note = "gone" })
    queued({ first = 500, note = "too far" })
    queued({ type = "fix", kind = "range", first = 9, last = 10, key = LONG .. ":o:9", tag = "change", note = "mixed" })
    local said = on("inline")
    assert.is_true(h.notified(said, "2 annotations not drawn"), vim.inspect(said))
    assert.same({ CONNECTOR .. " ✎ mixed" }, rows_at(buf, 9))
    assert.same({}, rows_at(buf, 7))
    assert.equal(1, #captions(buf))
    assert.same({ "CodeReviewFix" }, signs(buf)[9])
    assert.same({ "CodeReviewFix" }, signs(buf)[10])
    assert.is_nil(signs(buf)[7])
  end)

  it("include every one in a file with no entry, which gets nothing at all", function()
    queue.clear()
    queued({ first = 3, note = "about the long file" })
    vim.cmd("silent! only")
    vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
    local buf = vim.api.nvim_get_current_buf()
    local before = #vim.api.nvim_tabpage_list_wins(0)
    on("inline")
    assert.same({}, captions(buf))
    assert.same({}, signs(buf))
    assert.same({}, vim.api.nvim_buf_get_extmarks(buf, overlay.NS, 0, -1, {}))
    assert.equal(before, #vim.api.nvim_tabpage_list_wins(0))
    -- And the long file, entered next, gets its caption: the enter paints.
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, LONG)))
    assert.same({ CONNECTOR .. " ✗ about the long file" }, rows_at(vim.api.nvim_get_current_buf(), 3))
  end)

  it("include every one on a buffer the plugin owns", function()
    queue.clear()
    queued({ first = 1 })
    vim.cmd("silent! only")
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
    vim.api.nvim_buf_set_name(buf, "codereview://caption-spec")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b" })
    on("inline")
    assert.same({}, vim.api.nvim_buf_get_extmarks(buf, overlay.NS, 0, -1, {}))
    assert.same({}, vim.api.nvim_buf_get_extmarks(buf, overlay.NS_ANCHOR, 0, -1, {}))
    off()
    vim.cmd("bwipeout!")
  end)
end)

describe("switching the style while the overlay is on", function()
  after_each(off)

  -- The tick matters: a margin closed by anything but the plugin's own close is read as the
  -- reviewer closing it, and the toggle goes off on the next tick, not at once.
  it("from margin to inline closes the margin, draws the captions and leaves the toggle on", function()
    queue.clear()
    local win, buf = code_window()
    queued({ first = 10, note = "switched" })
    on("margin")
    local m = assert(overlay.margin())
    local mwin = m.win
    assert.same({}, captions(buf))
    assert.is_true(codereview.overlay("inline"))
    assert.is_false(vim.api.nvim_win_is_valid(mwin))
    assert.is_nil(overlay.margin())
    assert.same({ CONNECTOR .. " ✗ switched" }, rows_at(buf, 10))
    vim.wait(50)
    assert.is_true(overlay.enabled())
    assert.equal("inline", overlay.style())
    assert.equal(win, vim.api.nvim_get_current_win())
    assert.same({ "CodeReviewBug" }, signs(buf)[10])
  end)

  it("from inline to margin clears every caption it painted and opens the margin", function()
    queue.clear()
    local win, buf = code_window()
    queued({ first = 10, note = "here" })
    queued({ path = "src/main.lua", key = "src/main.lua:n:2", first = 2, note = "there" })
    on("inline")
    assert.equal(1, #rows_at(buf, 10))
    -- A second buffer painted by entering it, then back.
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
    local other = vim.api.nvim_get_current_buf()
    assert.equal(1, #rows_at(other, 2))
    vim.cmd("buffer " .. buf)
    assert.is_true(codereview.overlay("margin"))
    vim.wait(50)
    assert.same({}, captions(buf))
    assert.same({}, captions(other))
    local m = assert(overlay.margin(), "no margin opened")
    assert.equal(win, m.code)
    assert.is_true(overlay.enabled())
    assert.equal("margin", overlay.style())
    -- Its anchors kept, with nothing hung on them.
    assert.equal(1, #vim.api.nvim_buf_get_extmarks(buf, overlay.NS_ANCHOR, 0, -1, {}))
  end)

  it("changes no entry, no store, no payload and no archive", function()
    queue.clear()
    code_window()
    queued({ first = 10, note = "unchanged" })
    whole_file()
    local entries = vim.deepcopy(queue.all())
    local text_before = payload.render(queue.all(), root, { types = config.get().types })
    local path = state.path(root)
    local stored = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
    local archive = vim.deepcopy(state.archive(root))
    on("inline")
    codereview.overlay("margin")
    codereview.overlay("inline")
    off()
    assert.same(entries, queue.all())
    assert.equal(text_before, payload.render(queue.all(), root, { types = config.get().types }))
    assert.same(stored, vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {})
    assert.same(archive, state.archive(root))
  end)
end)

describe("a queue change with the inline style on", function()
  after_each(off)

  it("adds a caption for a capture from the buffer", function()
    queue.clear()
    local _, buf = code_window()
    on("inline")
    codereview.annotate("bug", { first = 12, last = 13 })
    assert.same({ CONNECTOR .. " ✗ " .. NOTE }, rows_at(buf, 12))
    assert.same({ "CodeReviewBug" }, signs(buf)[13])
  end)

  -- `x` in the float, with the float current: the repaint is of the window the overlay
  -- follows, which is the code window under it.
  it("takes the caption away for a drop through the queue float, and leaves the other", function()
    queue.clear()
    local _, buf = code_window()
    queued({ first = 4, note = "dropped from the float" })
    queued({ type = "fix", first = 10, note = "kept" })
    on("inline")
    assert.equal(1, #rows_at(buf, 4))
    require("codereview.view").review_queue()
    local float = vim.api.nvim_get_current_win()
    assert.is_true(vim.fn.search("dropped from the float") > 0, "the float does not list the entry")
    h.feed("x")
    if vim.api.nvim_win_is_valid(float) then
      vim.api.nvim_win_close(float, true)
    end
    assert.equal(1, #queue.all())
    assert.same({}, rows_at(buf, 4))
    assert.is_nil(signs(buf)[4])
    assert.same({ CONNECTOR .. " ✎ kept" }, rows_at(buf, 10))
  end)
end)

-- Last, because it replaces the options every case above read; restored before it ends.
describe("the configured style", function()
  it("fails at setup with a message when it is not a style", function()
    local ok, err = pcall(config.setup, { overlay = { style = "beside" } })
    config.setup(OPTS)
    assert.is_false(ok)
    assert.equal('codereview.setup: unknown `overlay.style` "beside" — expected one of "margin", "inline"', err)
  end)
end)

-- The resize, on a main loop that turns. See overlay_caption_child for why no case above can
-- reach the event. The narrow reading starts from rows that would not fit: the wide rows are
-- wider than the narrow window's text, so rows left as they were read as a failure.
describe("a resize with the inline style on", function()
  local run = vim
    .system({
      vim.v.progpath,
      "--clean",
      "--headless",
      "-c",
      "luafile " .. vim.fs.joinpath(h.root, "tests", "codereview", "overlay_caption_child.lua"),
    }, {
      cwd = fixture,
      text = true,
      env = {
        XDG_STATE_HOME = vim.fn.tempname() .. "-state",
        FIXTURE = fixture,
        GIT_CONFIG_GLOBAL = "/dev/null",
        GIT_CONFIG_SYSTEM = "/dev/null",
      },
    })
    :wait(60000)
  local ok, out = pcall(vim.json.decode, vim.trim(run.stdout or ""))
  if not ok then
    out = {}
  end
  local said = (run.stdout or "") .. (run.stderr or "")

  it("re-breaks the caption's rows to the window's new text width", function()
    assert.equal(0, run.code, said)
    assert.is_true(out.wide.widest > out.narrow.width, said)
    assert.is_true(out.narrow.rows > out.wide.rows, said)
    assert.is_true(out.narrow.widest <= out.narrow.width, said)
  end)
end)
