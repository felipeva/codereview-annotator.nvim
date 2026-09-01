-- `go` draws one file, or every file, for the rest of this Neovim.
--
-- A file of its own rather than more of `solo_spec`, which is what proves solo *renders*.
-- This one is about the switch in front of it and the key on the switch: the override that
-- outlives every review opened here, the two surfaces the key is bound on, the place the
-- reviewer keeps across the change, and the seven other view-wide keys that must not have an
-- opinion about it.
--
-- The override being module state and not view state is what decides the order below. "Unset
-- means the configured value" is only observable while this process has not yet pressed the
-- key, so the restart proof comes first and every case that presses `go` comes after it.
-- Plenary runs each `it` as it reaches it, so that order is the file's order.
--
-- Syntax is off: nothing here reads a colour, and a treesitter pass is work for no assertion.
local h = require("tests.helpers")

h.ui(120, 45)
local fixture = h.cd_fixture("mkfixture")

require("codereview").setup({
  -- Configured **off**, so that one file on screen is a state only the key can have reached.
  solo = false,
  syntax = false,
  -- Answering with the checkout the review is already in. What `gS` is asked below is
  -- whether arriving anywhere leaves the switch alone, and one checkout is enough to arrive
  -- at.
  pick_checkout = function(_, cb)
    cb(fixture)
  end,
})

local config = require("codereview.config")
local state = require("codereview.state")
local view = require("codereview.view")

view.open("branch")
local V = assert(view.current(), "no review view opened")

-- A file in the middle of the list, so that "the file the cursor was in" is a number no
-- accident produces: not 1, which is what an unset soloed index draws, and not the last,
-- which is where the end of the walk would leave one.
local MAIN = "src/main.lua"

---Which file indices a paint actually drew rows for, ascending.
---
---Read off the anchors rather than off `file_rows`, which is legitimately sparse under solo
---and is therefore one of the things under test elsewhere: the claim here is which files
---have rows.
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

---Every file index in the review, which is what an unsoloed paint draws.
---@return integer[]
local function every_file()
  local out = {}
  for i = 1, #V.files do
    out[i] = i
  end
  return out
end

---The file the diff cursor is in.
---
---Asked of the diff pane whichever window has focus, which is the question the key itself
---asks: `go` pressed in the tree narrows around the file being *read*, not around the row
---the tree happens to be on -- the tree's own `<CR>` is what that row drives.
---@return integer|nil
local function at()
  return V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]].file
end

---Normal-mode mappings bound to a buffer, as a set.
---
---Through `vim.keycode` on both sides: the API reports a key in its own notation rather than
---the one it was bound with, so comparing the strings as written can silently never match.
---@param buf integer
---@return table<string, boolean>
local function bound(buf)
  local lhs = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    lhs[vim.keycode(m.lhs)] = true
  end
  return lhs
end

---Feed keys with the cursor in a window, and take the view again afterwards.
---@param win integer
---@param keys string
local function feed_in(win, keys)
  vim.api.nvim_set_current_win(win)
  h.feed(keys)
  V = assert(view.current(), "the review view is gone")
end

--- The session the choice does not outlive -------------------------------------

-- Two children, from opposite configured values. Each presses the key, queues a note and
-- exits; this session is then asked what it starts from. A leftover `true` and a leftover
-- `false` are not the same bug, which is why one direction is not enough.
--
-- Both share this process's throwaway XDG_STATE_HOME and nothing else, and run with
-- `--clean` so no user config and no minimal_init can hand them a different one.

local root = assert(vim.uv.fs_realpath(fixture))

---@return string
local function stored()
  return table.concat(vim.fn.readfile(state.path(root)), "\n")
end

---@param solo boolean What the child is configured with; it presses the key to leave it
---@return vim.SystemCompleted
local function run_child(solo)
  return vim
    .system({
      vim.v.progpath,
      "--clean",
      "-l",
      vim.fs.joinpath(h.root, "tests", "codereview", "solo_toggle_child.lua"),
    }, {
      cwd = fixture,
      text = true,
      env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = fixture, SOLO = tostring(solo) },
    })
    :wait(60000)
end

describe("a session configured to draw every file, that pressed the key and exited", function()
  local child = run_child(false)

  it("exits cleanly", function()
    assert.same(0, child.code, (child.stderr or "") .. (child.stdout or ""))
  end)

  -- Without this the case below is vacuous: "the choice did not come back" would be
  -- satisfied by there being no channel between the two sessions at all.
  it("leaves what it queued in the store both sessions share", function()
    assert.is_truthy(stored():find("queued by the session that narrowed", 1, true), stored())
  end)

  it("writes nothing about the switch into it", function()
    assert.is_nil(stored():find("solo", 1, true), stored())
  end)
end)

describe("a session configured to draw one file, that pressed the key and exited", function()
  local child = run_child(true)

  it("exits cleanly", function()
    assert.same(0, child.code, (child.stderr or "") .. (child.stdout or ""))
  end)

  it("leaves what it queued in the store both sessions share", function()
    assert.is_truthy(stored():find("queued by the session that widened", 1, true), stored())
  end)

  -- The session before this one left its own note in the same document, so the store really
  -- is carried across a restart rather than replaced by whoever wrote last.
  it("leaves the session before it in there too", function()
    assert.is_truthy(stored():find("queued by the session that narrowed", 1, true), stored())
  end)

  it("writes nothing about the switch into it either", function()
    assert.is_nil(stored():find("solo", 1, true), stored())
  end)
end)

describe("what a session with the key unpressed starts from", function()
  -- Configuration is what decides at the start of every session, so how one afternoon was
  -- read cannot quietly become durable state restored into a different one.
  it("is the configured value", function()
    assert.same(config.get().solo, config.solo())
    assert.is_false(config.solo())
  end)

  -- And the other way round, which is the direction the second child ended the *opposite*
  -- side of: a session configured to draw one file draws one, however the session before it
  -- finished. Read through the same unset override, which is the state a fresh session is in.
  it("is the configured value the other way round too", function()
    config.get().solo = true
    assert.is_true(config.solo())
    config.get().solo = false
  end)
end)

--- The key ----------------------------------------------------------------------

describe("the key beside the switch", function()
  local main = assert(h.file_index(V, MAIN), "the fixture has no " .. MAIN)

  it("is bound in the diff and in the tree", function()
    assert.is_true(bound(V.buf)[vim.keycode("go")] == true, "go is not bound in the diff")
    assert.is_true(bound(assert(V.panel_buf))[vim.keycode("go")] == true, "go is not bound in the tree")
  end)

  it("draws one file when every file was drawn, and it is the file the cursor was in", function()
    assert.is_true(main > 1, "the file under test is the first one, which an unset index also draws")
    assert.same(every_file(), files_drawn(V.render))
    -- Inside the file rather than on its header, so that the arrival below is a move and
    -- not a coincidence.
    vim.api.nvim_win_set_cursor(V.win, { assert(V.render.file_rows[main]) + 2, 0 })

    feed_in(V.win, "go")

    -- The discriminating half: an index nothing set would draw file 1.
    assert.same({ main }, files_drawn(V.render))
    assert.same(main, at())
    -- And the cursor is where every file arrival lands, rather than left at whatever row of
    -- a much shorter buffer it was clamped to.
    assert.same(V.render.file_rows[main], vim.api.nvim_win_get_cursor(V.win)[1])
  end)

  it("leaves the configured value where the host set it", function()
    assert.is_false(config.get().solo)
  end)

  it("draws every file again from the file tree, without moving to the diff first", function()
    feed_in(V.panel_win, "go")

    assert.same(every_file(), files_drawn(V.render))
    -- The discriminating half this way round: a paint that did not keep the place would
    -- leave the cursor on the row it held in a one-file buffer, which is the top of the
    -- review.
    assert.same(main, at())
    assert.same(V.render.file_rows[main], vim.api.nvim_win_get_cursor(V.win)[1])
  end)

  it("keeps the choice across a repaint", function()
    feed_in(V.win, "go")
    assert.same({ main }, files_drawn(V.render))
    view.paint()
    assert.is_true(config.solo())
    assert.same({ main }, files_drawn(V.render))
  end)
end)

--- The keys that have no opinion about it ---------------------------------------

-- Each of these repaints for its own reasons, and none of them is a statement about how a
-- reviewer is reading. Solo is on for all of them, from the key above.

---Assert the switch is still on and the paint still drew exactly one file.
---@param where string
local function still_soloed(where)
  V = assert(view.current(), "no review view after " .. where)
  assert.is_true(config.solo(), "the switch moved on " .. where)
  assert.same(1, #files_drawn(V.render), "not one file drawn on " .. where)
end

describe("every other view-wide key", function()
  it("gl leaves it on, and a soloed split draws one file in both panes", function()
    feed_in(V.win, "gl")
    still_soloed("gl to the split layout")
    -- Row alignment is what split is for, and it is guaranteed by construction here: the
    -- two panes come out of one walk, so they draw the same one file at the same rows.
    local before = assert(V.before_render, "gl did not build a before pane")
    assert.same(files_drawn(V.render), files_drawn(before))
    assert.same(V.render.file_rows, before.file_rows)

    feed_in(V.win, "gl")
    still_soloed("gl back to unified")
  end)

  it("gr leaves it on", function()
    feed_in(V.win, "gr")
    still_soloed("gr")
  end)

  it("gA leaves it on, in both directions", function()
    feed_in(V.win, "gA")
    still_soloed("gA hiding archived entries")
    feed_in(V.win, "gA")
    still_soloed("gA showing them again")
  end)

  it("gp leaves it on, dismissed and summoned", function()
    feed_in(V.win, "gp")
    still_soloed("gp dismissing the tree")
    feed_in(V.win, "gp")
    still_soloed("gp summoning it again")
  end)

  it("za collapses the drawn file and leaves it on, with its header still on screen", function()
    local drawn = files_drawn(V.render)[1]
    local body = #V.render.lines
    vim.api.nvim_win_set_cursor(V.win, { assert(V.render.file_rows[drawn]), 0 })

    feed_in(V.win, "za")
    still_soloed("za collapsing the drawn file")
    assert.same({ drawn }, files_drawn(V.render))
    assert.is_true(#V.render.lines < body, ("za drew %d rows, not fewer than %d"):format(#V.render.lines, body))
    -- A collapsed file keeps its header row, so the view is never blank with a file
    -- selected. Asserted as the row naming the file rather than as a row count: what the
    -- render spends on a collapsed file besides its header is `render_spec`'s question.
    assert.same(1, V.render.file_rows[drawn])
    local header = V.render.lines[1]
    assert.is_true(header:find(V.files[drawn].path, 1, true) ~= nil, ("row 1 is %q"):format(header))

    feed_in(V.win, "za")
    still_soloed("za expanding it again")
    assert.same(body, #V.render.lines)
  end)

  it("gS leaves it on", function()
    feed_in(V.win, "gS")
    still_soloed("gS")
  end)

  it("gs leaves it on, all the way round the cycle", function()
    -- Round the whole cycle rather than one step: a **scope** change replaces the file list
    -- under the soloed index, and two of the scopes on the way hold one file -- where "one
    -- file drawn" is true whether or not the switch survived. Coming back to a scope of
    -- eight is what makes the last assertion mean something.
    local scopes = {}
    repeat
      feed_in(V.win, "gs")
      still_soloed("gs to " .. V.scope.name)
      scopes[#scopes + 1] = V.scope.name
    until V.scope.name == "branch" or #scopes > 8

    assert.same("branch", V.scope.name, "the cycle never came back: " .. vim.inspect(scopes))
    assert.is_true(#V.files > 1, "the scope it came back to has one file, which proves nothing")
    assert.same(1, #files_drawn(V.render))
  end)
end)

--- The place kept when the index has outrun the file list -----------------------

-- One state tells the soloed index and the file the cursor is in apart. Everywhere else
-- they are the same file: under solo only the drawn file has rows, so the cursor can be in
-- no other one. A **scope** change replaces the file list and leaves `V.solo` where the file
-- navigation put it. The paint clamps that index to the last file; the index itself stays
-- too large. `go` off keeps the reviewer's place, and the place is the file on screen.
--
-- Reached with keys only -- `]f` to the last file of a scope of eight, then `gs` to a scope
-- of three. Writing `V.solo` from here would prove the clamp, which `solo_spec` proves
-- already, and would pin an internal instead of a behaviour.
--
-- Last in the file, because it ends in a different scope from the one it started in.

describe("go with the soloed index outrun by the file list", function()
  local outrun

  it("is a state the keys reach", function()
    assert.is_true(config.solo(), "the switch is off, so the walk below draws every file")

    -- `]f` under solo draws the file it moves to, and drawing a file is what moves the
    -- index. Walk to the last file, so that every smaller scope outruns it.
    while at() < #V.files do
      feed_in(V.win, "]f")
    end
    outrun = assert(V.solo, "the walk set no soloed index")
    assert.same(#V.files, outrun)

    -- A scope with fewer files than the index, and with more than one file. One file is not
    -- enough: the paint would clamp to the first file, which is also the row a scope change
    -- parks the cursor on, and an arrival there proves nothing.
    local visited = {}
    repeat
      feed_in(V.win, "gs")
      visited[#visited + 1] = ("%s(%d)"):format(V.scope.name, #V.files)
    until (#V.files > 1 and #V.files < outrun) or #visited > 8

    assert.is_true(
      #V.files > 1 and #V.files < outrun,
      ("no scope holds between 2 and %d files: %s"):format(outrun - 1, vim.inspect(visited))
    )
    -- The state itself: the index names a file the review no longer has, the paint draws
    -- the last file the review does have, and the cursor is in that one.
    assert.same(outrun, V.solo)
    assert.same({ #V.files }, files_drawn(V.render))
    assert.same(#V.files, at())
  end)

  it("draws every file again and puts the cursor on the file the paint drew", function()
    local clamped = #V.files
    assert.is_true(clamped < outrun, "the index no longer outruns the file list")

    feed_in(V.win, "go")

    assert.same(every_file(), files_drawn(V.render))
    -- The discriminating half: the index has no row in a list this short, so a paint that
    -- kept the index instead of the file would leave the cursor at the top of the review.
    assert.same(clamped, at())
    assert.same(V.render.file_rows[clamped], vim.api.nvim_win_get_cursor(V.win)[1])
  end)
end)
