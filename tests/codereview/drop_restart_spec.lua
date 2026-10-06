-- A drop made in the queue float with no review view open, surviving a restart.
--
-- Two processes, for the reason `edit_restart_spec` gives: the queue is read back once per
-- session, so a process that drops and then restores reads its own memory, and would pass
-- whether or not the drop reached the disk.
--
-- The float used to persist a drop only when a review view was open, so this is the case
-- that came back: two bugs captured from a buffer, the first dropped in the float, and both
-- of them there again in the next session.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local queue = require("codereview.queue")
local state = require("codereview.state")

require("codereview").setup({ syntax = false })

local child

describe("the dropping process", function()
  -- The child shares this process's throwaway XDG_STATE_HOME and nothing else. It runs
  -- with `--clean` so no user config, and no minimal_init, can hand it a different one.
  child = vim
    .system({
      vim.v.progpath,
      "--clean",
      "-l",
      vim.fs.joinpath(h.root, "tests", "codereview", "drop_child.lua"),
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

  it("was told which entries the child queued", function()
    assert.same(2, #ids, out)
  end)

  -- Nothing in memory: everything asserted below came off the disk.
  it("starts with an empty queue", function()
    assert.same(0, queue.count())
  end)

  state.ensure_queue()
  local restored = queue.all()

  it("restores the entry that was kept, and not the one that was dropped", function()
    assert.same(
      { "kept one" },
      vim.tbl_map(function(item)
        return item.note
      end, restored)
    )
  end)

  it("restores the kept entry under the id it had before the drop", function()
    assert.same(ids[2], restored[1] and restored[1].id)
  end)
end)
