-- Annotations with no repository behind them.
--
-- Two shapes, entangled because neither has a root to key persistence against: a bare
-- thought with no file at all, and a file that lives outside any checkout. Both queue,
-- submit and persist like anything else -- to a single store that is not tied to a
-- repository, which prunes by age because nothing else will ever clear it.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local codereview = require("codereview")
local queue = require("codereview.queue")

local sent = {}
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "the note")
  end,
  send = function(text, target)
    sent[#sent + 1] = { text = text, target = target }
  end,
})

local root = assert(vim.uv.fs_realpath(fixture))

-- A directory that is genuinely not inside any checkout. Asserted rather than assumed:
-- if the temp directory ever sits inside a repository, every case below silently becomes
-- a test of the ordinary in-repository path.
local outside = vim.fn.tempname() .. "-outside"
vim.fn.mkdir(outside, "p")
local outside_file = vim.fs.joinpath(outside, "loose.lua")
vim.fn.writefile({ "local loose = true", "return loose" }, outside_file)

describe("the fixture the rest of this spec depends on", function()
  it("puts the loose file outside any repository", function()
    assert.is_nil(require("codereview.git").root(outside), outside .. " is inside a checkout")
  end)
end)

describe("a bare thought with no file at all", function()
  queue.clear()
  vim.cmd("enew")
  codereview.annotate("issue")
  local e = queue.all()[1]

  it("queues it rather than refusing", function()
    assert.same(1, queue.count())
  end)

  it("records it as a note", function()
    assert.same("note", e.kind)
  end)

  it("carries no path of any kind", function()
    assert.is_nil(e.path)
    assert.is_nil(e.abs_path)
  end)

  it("still carries its type and its text", function()
    assert.same("issue", e.type)
    assert.same("the note", e.note)
  end)
end)

describe("describing an annotation with no file", function()
  local view = require("codereview.view")
  local payload = require("codereview.payload")
  local config = require("codereview.config")

  queue.clear()
  vim.cmd("enew")
  local msgs, restore = h.capture_notify()
  codereview.annotate("issue")
  restore()

  -- Every one of these would read "nil" somewhere if the location string were built from
  -- a path that is not there, which is the whole hazard of a kind with no file.
  it("reports it without a stray nil", function()
    assert.is_true(h.notified(msgs, "Queued issue"), vim.inspect(msgs))
    assert.is_false(h.notified(msgs, "nil"), vim.inspect(msgs))
  end)

  it("renders in the payload without a path, and without breaking the renderer", function()
    local text = payload.render(queue.all(), root, { types = config.get().types })
    assert.is_truthy(text:find("### 1.", 1, true), text)
    assert.is_truthy(text:find("the note", 1, true), text)
    assert.is_nil(text:find("nil", 1, true), text)
  end)

  it("renders in the queue float without a path", function()
    view.review_queue()
    -- With no review view open the float is simply the current window.
    local float = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.api.nvim_win_close(0, true)

    assert.is_truthy(float:find("## Issues", 1, true), float)
    assert.is_truthy(float:find("the note", 1, true), float)
    assert.is_nil(float:find("nil", 1, true), float)
  end)
end)

describe("a file outside any checkout", function()
  local payload = require("codereview.payload")
  local config = require("codereview.config")
  local loose = assert(vim.uv.fs_realpath(outside_file))

  queue.clear()
  vim.cmd("edit " .. vim.fn.fnameescape(outside_file))
  local msgs, restore = h.capture_notify()
  codereview.annotate("bug")
  restore()
  local e = queue.all()[1]

  it("queues it rather than refusing", function()
    assert.same(1, queue.count())
  end)

  -- The confirmation names a file, and the only name this one has is the absolute path.
  it("reports it by name rather than as nil", function()
    assert.is_true(h.notified(msgs, "Queued bug"), vim.inspect(msgs))
    assert.is_false(h.notified(msgs, "nil"), vim.inspect(msgs))
    assert.is_true(h.notified(msgs, "loose.lua"), vim.inspect(msgs))
  end)

  it("is an ordinary file annotation", function()
    assert.same("file", e.kind)
    assert.same("bug", e.type)
    assert.same("the note", e.note)
  end)

  it("carries its absolute path", function()
    assert.same(loose, e.abs_path)
  end)

  -- No root to be relative to. Its absence is also what routes the entry away from a
  -- repository's store later.
  it("has no repository-relative path", function()
    assert.is_nil(e.path)
  end)

  it("renders by absolute path, since no target tree contains it", function()
    local text = payload.render(queue.all(), root, { types = config.get().types })
    assert.is_truthy(text:find(loose, 1, true), text)
    assert.is_nil(text:find("nil", 1, true), text)
  end)
end)

describe("persisting across a restart", function()
  local state = require("codereview.state")

  ---@param mode "write"|"read"
  local function session(mode)
    return vim
      .system({
        vim.v.progpath,
        "--clean",
        "-l",
        vim.fs.joinpath(h.root, "tests", "codereview", "norepo_child.lua"),
      }, {
        cwd = fixture,
        text = true,
        env = {
          XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
          FIXTURE = fixture,
          LOOSE_FILE = outside_file,
          MODE = mode,
        },
      })
      :wait(60000)
  end

  queue.clear()
  state.clear(root)
  state.clear_global()

  local wrote = session("write")
  local output = (wrote.stdout or "") .. (wrote.stderr or "")

  it("the writing session exits cleanly having queued all three", function()
    assert.same(0, wrote.code, output)
    assert.is_true(output:find("queued: 3", 1, true) ~= nil, output)
  end)

  it("keeps only the repository's own annotation in the repository store", function()
    local saved = state.load(root).queue
    assert.same(1, #saved)
    assert.same("src/main.lua", saved[1].path)
  end)

  it("routes the other two to the store that is not keyed to a repository", function()
    local global = state.load_global()
    assert.same(2, #global)
    assert.same({ "fix", "issue" }, {
      global[1] and global[1].type,
      global[2] and global[2].type,
    })
  end)

  it("keeps the loose file's absolute path, and gives the note no path at all", function()
    local global = state.load_global()
    assert.same(assert(vim.uv.fs_realpath(outside_file)), global[1].abs_path)
    assert.is_nil(global[2].abs_path)
    assert.same("note", global[2].kind)
  end)

  local read = session("read")
  local restored = (read.stdout or "") .. (read.stderr or "")

  it("restores all three in a genuinely new process", function()
    assert.same(0, read.code, restored)
    assert.is_true(restored:find("restored: 3", 1, true) ~= nil, restored)
  end)

  it("restores each with its kind intact", function()
    assert.is_true(restored:find("bug/file", 1, true) ~= nil, restored)
    assert.is_true(restored:find("fix/file", 1, true) ~= nil, restored)
    assert.is_true(restored:find("issue/note", 1, true) ~= nil, restored)
  end)
end)

-- Nothing ever reconciles this store against a diff, so no other moment could decide an
-- entry is finished with. Without the sweep it grows for as long as the state directory
-- lives.
describe("the age sweep", function()
  local state = require("codereview.state")
  local week = 7 * 24 * 60 * 60
  local now = os.time()

  queue.clear()
  state.clear_global()
  state.save_global({
    { type = "bug", kind = "note", key = "note:0", note = "long abandoned", at = now - week - 3600 },
    { type = "fix", kind = "note", key = "note:0", note = "written today", at = now - 3600 },
  })

  local kept = vim.tbl_map(function(i)
    return i.note
  end, state.load_global())

  it("drops what is past the window", function()
    assert.is_false(vim.tbl_contains(kept, "long abandoned"), vim.inspect(kept))
  end)

  it("keeps what is inside it", function()
    assert.same({ "written today" }, kept)
  end)

  it("does not hand a swept entry back to the queue", function()
    queue.clear()
    state.restore_queue(root)
    local notes = vim.tbl_map(function(i)
      return i.note
    end, queue.all())
    assert.is_true(vim.tbl_contains(notes, "written today"), vim.inspect(notes))
    assert.is_false(vim.tbl_contains(notes, "long abandoned"), vim.inspect(notes))
  end)
end)

describe("submitting a batch that mixes both", function()
  local view = require("codereview.view")
  local state = require("codereview.state")

  queue.clear()
  state.clear(root)
  state.clear_global()

  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
  codereview.annotate("bug")
  vim.cmd("edit " .. vim.fn.fnameescape(outside_file))
  codereview.annotate("fix")
  vim.cmd("enew")
  codereview.annotate("issue")

  it("queued all three into one queue", function()
    assert.same(3, queue.count())
  end)

  local before = #sent
  view.submit()

  it("sends them as a single message", function()
    assert.same(before + 1, #sent)
    assert.same(0, queue.count())
  end)

  it("carries all three in that message, each addressed as best it can be", function()
    local text = sent[#sent].text
    assert.is_truthy(text:find("3 annotations", 1, true), text)
    assert.is_truthy(text:find("@src/main.lua", 1, true), text)
    assert.is_truthy(text:find("loose.lua", 1, true), text)
    assert.is_truthy(text:find("(no file)", 1, true), text)
  end)

  it("clears the repository store", function()
    assert.same(0, #state.load(root).queue)
  end)

  it("clears the store with no repository too", function()
    assert.same(0, #state.load_global())
  end)
end)
