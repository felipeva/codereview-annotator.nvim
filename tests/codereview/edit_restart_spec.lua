-- An edited note, and a changed type, surviving a restart.
--
-- Two processes, because one cannot answer the question. The queue is read back once per
-- session, so a process that edits and then restores reads its own memory, and would pass
-- whether or not the edit reached the disk. Prior art is `state_spec` and
-- `checkout_restart_spec`, which write in a child and read after a restart.
--
-- What the child left is three bugs captured from a buffer, the middle one's note edited,
-- the first one's type taken off and the last one made a nitpick, and nothing written after
-- that.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local queue = require("codereview.queue")
local state = require("codereview.state")

require("codereview").setup({ syntax = false })

local child

describe("the editing process", function()
  -- The child shares this process's throwaway XDG_STATE_HOME and nothing else. It runs
  -- with `--clean` so no user config, and no minimal_init, can hand it a different one.
  child = vim
    .system({
      vim.v.progpath,
      "--clean",
      "-l",
      vim.fs.joinpath(h.root, "tests", "codereview", "edit_child.lua"),
    }, {
      cwd = fixture,
      text = true,
      env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = fixture },
    })
    :wait(60000)

  it("exits cleanly", function()
    assert.same(0, child.code, (child.stderr or "") .. (child.stdout or ""))
  end)
end)

describe("the session after it", function()
  -- `-l` prints to stderr, so both streams are read.
  local out = (child.stdout or "") .. (child.stderr or "")
  local ids = vim.tbl_map(tonumber, vim.split(out:match("ids: ([%d,]+)") or "", ",", { trimempty = true }))
  local edited = tonumber(out:match("edited: (%d+)"))

  it("was told which entries the child queued, and which one it edited", function()
    assert.same(3, #ids, out)
    assert.is_truthy(edited, out)
  end)

  -- Nothing in memory: everything asserted below came off the disk.
  it("starts with an empty queue", function()
    assert.same(0, queue.count())
  end)

  state.ensure_queue()
  local restored = queue.all()

  it("restores the edited note, and not the one it replaced", function()
    assert.same(
      { "first", "second, as edited", "third" },
      vim.tbl_map(function(item)
        return item.note
      end, restored)
    )
  end)

  it("restores the changed types: one taken off, one changed, one left alone", function()
    assert.same(
      { "untyped", "bug", "nitpick" },
      vim.tbl_map(function(item)
        return item.type or "untyped"
      end, restored)
    )
  end)

  it("restores every entry under the id it had before the edit", function()
    assert.same(
      ids,
      vim.tbl_map(function(item)
        return item.id
      end, restored)
    )
  end)

  it("restores the edited entry in the place it held", function()
    assert.same(edited, restored[2] and restored[2].id)
  end)
end)
