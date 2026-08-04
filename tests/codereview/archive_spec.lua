-- The archive: the batches already dispatched, kept after the queue that held them was
-- cleared.
--
-- Two processes, like state_spec and for the same reason -- persistence is only
-- meaningfully tested across a genuine restart, and a `state.load()` called twice in one
-- process proves nothing about what reached the disk. `archive_child.lua` dispatches a
-- batch and exits; everything below reads it back in a Neovim that has never seen it.
--
-- The id case needs that second process for a reason of its own: the queue's counter is
-- module-level, so a session that dispatched 1..n and restarted begins at 1 again, and a
-- one-process test passes whether or not the counter is seeded from the archive.
--
-- Assertions go through the public accessor and against git, never against the JSON.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local codereview = require("codereview")
local git = require("codereview.git")
local queue = require("codereview.queue")
local state = require("codereview.state")

local root = assert(vim.uv.fs_realpath(fixture))
local main = assert(vim.uv.fs_realpath(vim.fs.joinpath(fixture, "src/main.lua")))

-- A file that is genuinely not inside any checkout. Asserted rather than assumed: if the
-- temp directory ever sits inside a repository, the entries this spec expects in the store
-- that needs no root would quietly archive to a repository's instead.
local outside = vim.fn.tempname() .. "-outside"
vim.fn.mkdir(outside, "p")
local outside_file = vim.fs.joinpath(outside, "loose.lua")
vim.fn.writefile({ "local loose = true", "return loose" }, outside_file)

local sent = {}
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "from this session")
  end,
  send = function(text, target)
    sent[#sent + 1] = { text = text, target = target }
  end,
})

---One queued annotation with a repository behind it, so a batch is of a known size.
---@param note string
local function queue_one(note)
  queue.clear()
  queue.add({
    type = "bug",
    kind = "file",
    path = "src/main.lua",
    abs_path = main,
    key = "src/main.lua:f:0",
    note = note,
  })
end

describe("the fixture the rest of this spec depends on", function()
  it("puts the loose file outside any repository", function()
    assert.is_nil(git.root(outside), outside .. " is inside a checkout")
  end)
end)

-- Read before anything of ours has run, so that "the snapshot disturbed nothing" is a
-- comparison rather than a claim about what git happens to say afterwards.
local head_before = h.git_lines(root, { "rev-parse", "HEAD" })
local status_before = h.git_lines(root, { "status", "--porcelain" })

describe("the dispatching process", function()
  local cmd = {
    vim.v.progpath,
    "--clean",
    "-l",
    vim.fs.joinpath(h.root, "tests", "codereview", "archive_child.lua"),
  }
  local proc = vim.system(cmd, {
    cwd = fixture,
    text = true,
    env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = fixture, LOOSE_FILE = outside_file },
  })
  local child = proc:wait(60000)
  local output = (child.stdout or "") .. (child.stderr or "")

  it("exits cleanly", function()
    assert.same(0, child.code, output)
  end)

  it("emptied its queue on the way out, so nothing below is reading memory", function()
    assert.is_true(output:find("queued: 0 left", 1, true) ~= nil, output)
  end)
end)

describe("what a restart finds", function()
  local archive = state.archive(root)
  local loose = state.global_archive()

  it("holds the batch the previous session dispatched", function()
    assert.same(1, #archive, vim.inspect(archive))
  end)

  it("holds the entries that had a repository behind them, and only those", function()
    assert.same(1, #archive[1].entries)
    assert.same("src/main.lua", archive[1].entries[1].path)
    assert.same("bug", archive[1].entries[1].type)
  end)

  it("keeps each entry's note as it went", function()
    assert.is_truthy(archive[1].entries[1].note:find("dispatched by an earlier session", 1, true))
  end)

  it("records which target it went to", function()
    assert.same("agent", archive[1].target)
  end)

  it("records when it went", function()
    -- Loose, because the assertion is that a real time was stamped rather than that a
    -- clock reads a particular value.
    assert.is_true(math.abs(os.time() - archive[1].at) < 600, tostring(archive[1].at))
  end)

  -- The rule that already routes the queue, applied unchanged: a repository-relative path
  -- means that repository, and everything else means the store that needs no root.
  it("routes a bare note and a file outside a checkout to the other store", function()
    assert.same(1, #loose, vim.inspect(loose))
    assert.same(2, #loose[1].entries)
    assert.same({ "fix", "issue" }, {
      loose[1].entries[1].type,
      loose[1].entries[2].type,
    })
  end)

  it("keeps the loose file's absolute path, and gives the bare note no path at all", function()
    assert.same(assert(vim.uv.fs_realpath(outside_file)), loose[1].entries[1].abs_path)
    assert.is_nil(loose[1].entries[2].path)
    assert.is_nil(loose[1].entries[2].abs_path)
  end)

  -- There is no repository whose working tree could be recorded, and a snapshot of
  -- whichever checkout happened to be current would describe nothing these are about.
  it("gives that batch no snapshot", function()
    assert.is_nil(loose[1].snapshot)
  end)
end)

-- Runs before anything else in this process touches the queue: the counter has issued no
-- id yet, and `ensure_queue` latches on the first read.
describe("an annotation queued after the restart", function()
  it("starts from an empty queue, so every id below came off the disk", function()
    assert.same(0, queue.count())
  end)

  local archived = {}
  for _, store in ipairs({ state.archive(root), state.global_archive() }) do
    for _, batch in ipairs(store) do
      for _, entry in ipairs(batch.entries) do
        archived[#archived + 1] = entry.id
      end
    end
  end
  table.sort(archived)

  -- Without this the case is vacuous: a counter that was never seeded issues 1, and only
  -- an archive that actually holds 1 can catch it.
  it("has archived ids low enough to collide with", function()
    assert.same(1, archived[1], vim.inspect(archived))
  end)

  vim.cmd("edit " .. vim.fn.fnameescape(main))
  codereview.annotate("bug")

  it("takes an id above every archived one", function()
    local queued = assert(queue.all()[1], "nothing was queued")
    assert.is_true(queued.id > archived[#archived], ("%d is not above %s"):format(queued.id, vim.inspect(archived)))
  end)
end)

-- Where the id collision becomes visible, and the only place it can be asserted: both
-- entries are on one anchor, drawn one above the other, and the counter that has to keep
-- them apart did not survive the process that dispatched the first.
--
-- The block above pinned the seeding against the record. This pins it against what a
-- reviewer sees and acts on -- which is what the seeding is for, and what nothing before
-- archived entries were drawn could have exercised.
describe("an anchor carrying both a queued and an archived entry", function()
  local view = require("codereview.view")
  local annotate = require("codereview.annotate")

  local archived_entry = state.archive(root)[1].entries[1]
  local queued_entry = assert(queue.all()[1], "the block above queued nothing")

  it("is one anchor, reached by two sessions", function()
    assert.same(archived_entry.key, queued_entry.key)
  end)

  -- Without the seed both are id 1, and every claim below about which of them `x` acted on
  -- is a claim about two things the plugin cannot tell apart.
  it("gives the two of them different ids", function()
    assert.is_true(
      archived_entry.id ~= queued_entry.id,
      ("both entries carry id %s"):format(vim.inspect(queued_entry.id))
    )
  end)

  codereview.open("branch")
  local V = assert(view.current())
  local header = V.render.file_rows[assert(h.file_index(V, "src/main.lua"))]

  ---The virtual lines the diff draws on the file header.
  ---@return table[]
  local function drawn()
    for _, m in ipairs(h.virt_marks(V)) do
      if m[2] == header - 1 then
        return m[4].virt_lines
      end
    end
    return {}
  end

  ---@param line table[]
  ---@return string
  local function text_of(line)
    local out = {}
    for _, chunk in ipairs(line) do
      out[#out + 1] = chunk[1]
    end
    return table.concat(out)
  end

  it("draws both, what is still to send above what has already gone", function()
    local virt = drawn()
    assert.same(2, #virt, vim.inspect(virt))
    assert.is_truthy(text_of(virt[1]):find("from this session", 1, true), text_of(virt[1]))
    assert.is_truthy(text_of(virt[2]):find("dispatched by an earlier session", 1, true), text_of(virt[2]))
  end)

  vim.api.nvim_win_set_cursor(V.win, { header, 0 })
  local msgs, restore = h.capture_notify()
  annotate.drop()
  restore()

  it("drops the queued entry", function()
    assert.same(0, queue.count())
    assert.is_true(h.notified(msgs, "Dropped bug note"), vim.inspect(msgs))
  end)

  -- The archive is not the queue's other half, and nothing that acts on the queue may reach
  -- into it: an archived entry says something already happened, and no key revises that.
  it("leaves the archived entry in the archive", function()
    assert.same(1, #state.archive(root)[1].entries)
    assert.same(archived_entry.id, state.archive(root)[1].entries[1].id)
  end)

  it("leaves the archived entry on the diff", function()
    local virt = drawn()
    assert.same(1, #virt, vim.inspect(virt))
    assert.is_truthy(text_of(virt[1]):find("dispatched by an earlier session", 1, true), text_of(virt[1]))
  end)

  -- Every block below submits, and a view open over them would repaint against an archive
  -- they are deliberately overflowing.
  codereview.close()
end)

describe("the snapshot a dispatch minted", function()
  local snapshot = assert(state.archive(root)[1].snapshot, "the batch was archived without one")

  it("is a commit object", function()
    assert.same({ "commit" }, h.git_lines(root, { "cat-file", "-t", snapshot }))
  end)

  -- Derived from git rather than hardcoded: which files the fixture leaves dirty is a fact
  -- about the fixture, and hardcoded lists have gone stale in this repository before.
  it("records the working tree rather than what HEAD says", function()
    local dirty = h.git_lines(root, { "diff", "--name-only", "HEAD" })
    assert.is_true(#dirty > 0, "the fixture's working tree is clean, so this proves nothing")
    assert.same(dirty, h.git_lines(root, { "diff", "--name-only", "HEAD", snapshot }))
  end)

  it("moved no ref, and stashed nothing for real", function()
    assert.same({}, h.git_lines(root, { "stash", "list" }))
    assert.same(head_before, h.git_lines(root, { "rev-parse", "HEAD" }))
  end)

  it("left the index and the working tree exactly as they were", function()
    assert.same(status_before, h.git_lines(root, { "status", "--porcelain" }))
  end)
end)

-- `git stash create` mints nothing when there is nothing to record, which is a case rather
-- than an edge to assume away. The fallback has to be a real ref, because everything that
-- will read a snapshot back reads file content out of it.
describe("a batch dispatched from a clean working tree", function()
  local clean = h.fixture("mkfixture")
  h.git_lines(clean, { "reset", "--hard" })
  h.git_lines(clean, { "clean", "-fdx" })
  local clean_root = assert(vim.uv.fs_realpath(clean))

  it("is dispatched from a tree with nothing in it to record", function()
    assert.same({}, h.git_lines(clean, { "status", "--porcelain" }))
  end)

  queue_one("from a clean tree")
  vim.cmd("cd " .. vim.fn.fnameescape(clean))
  local msgs, restore = h.capture_notify()
  codereview.submit()
  restore()
  vim.cmd("cd " .. vim.fn.fnameescape(fixture))

  it("was dispatched at all", function()
    assert.is_true(h.notified(msgs, "Submitted 1 annotation"), vim.inspect(msgs))
  end)

  it("archives to the repository it went out of", function()
    assert.same(1, #state.archive(clean_root))
  end)

  it("falls back to HEAD, since there is nothing else to record", function()
    assert.same(h.git_lines(clean, { "rev-parse", "HEAD" })[1], state.archive(clean_root)[1].snapshot)
  end)
end)

-- Nothing here ever reconciles a batch against a diff, so no later moment could decide one
-- is finished with. Without a bound the archive grows for the life of the state directory,
-- which is the failure the other store's age sweep already exists to prevent.
describe("the bound on how many batches are kept", function()
  state.clear(root)
  local overflow = state.ARCHIVE_LIMIT + 2

  local _, restore = h.capture_notify()
  for i = 1, overflow do
    queue_one(("batch %d"):format(i))
    codereview.submit()
  end
  restore()

  local archive = state.archive(root)
  local notes = vim.tbl_map(function(batch)
    return batch.entries[1].note
  end, archive)

  it("keeps no more than the bound", function()
    assert.same(state.ARCHIVE_LIMIT, #archive)
  end)

  it("keeps the newest, and holds it first", function()
    assert.same(("batch %d"):format(overflow), notes[1])
  end)

  it("dropped the oldest, one per write past the bound", function()
    assert.is_false(vim.tbl_contains(notes, "batch 1"), vim.inspect(notes))
    assert.is_false(vim.tbl_contains(notes, "batch 2"), vim.inspect(notes))
    assert.is_true(vim.tbl_contains(notes, "batch 3"), vim.inspect(notes))
  end)
end)

-- The version was deliberately not bumped to make room for the archive. A mismatched
-- version is discarded on load, so a bump would throw away every reviewed mark in the file
-- to add a key that older documents simply lack -- which is why the document written by
-- hand below carries version 1 and expects to be read, not discarded.
describe("a document written before the archive existed", function()
  local path = state.path(root)
  local scope_key = "branch:0123456789abcdef"
  vim.fn.writefile({
    vim.json.encode({
      version = 1,
      scopes = { [scope_key] = { reviewed = { ["src/main.lua"] = "deadbeef" } } },
      queue = { { id = 4, type = "bug", kind = "file", path = "src/main.lua", key = "k", note = "written before" } },
    }),
  }, path)
  local loaded = state.load(root)

  it("keeps the reviewed marks it was written with", function()
    assert.same("deadbeef", loaded.scopes[scope_key].reviewed["src/main.lua"])
  end)

  it("keeps the queue it was written with", function()
    assert.same(1, #loaded.queue)
    assert.same("written before", loaded.queue[1].note)
  end)

  it("gains an empty archive rather than nothing at all", function()
    assert.same({}, loaded.archive)
  end)
end)
