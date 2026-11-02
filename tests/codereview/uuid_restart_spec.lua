-- An entry written before the uuid existed, across two genuine restarts.
--
-- This process writes both stores by hand, in the shape the release before the uuid wrote
-- them: the same `VERSION`, a reviewed mark, and entries with no `uuid` key. Then it spawns
-- `uuid_child.lua` two times. Each child only restores the queue. The first restore must
-- give each entry a uuid and write it back; the second must read the same uuid.
--
-- Two children, because one process cannot answer the question. The queue is read back
-- once per session, and a uuid issued in memory and never written is new at each restore.
-- This process never restores the queue itself, so the latch cannot hide anything.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local state = require("codereview.state")

require("codereview").setup({ syntax = false })

-- Through realpath, as the plugin resolves a checkout: under macOS a /var path names the
-- same directory as /private/var, but `state.path` hashes the string.
local root = assert(vim.uv.fs_realpath(fixture))
local owned_path = state.path(root)
local global_path = state.global_path()

local scopes = { ["branch:written-before"] = { reviewed = { ["src/main.lua"] = "0123456789abcdef" } } }

---@param file string
---@return table
local function read(file)
  return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"), { luanil = { object = true, array = true } })
end

---@return vim.SystemCompleted out, string text, string[] kinds, string[] uuids
local function session()
  local out = vim
    .system({
      vim.v.progpath,
      "--clean",
      "-l",
      vim.fs.joinpath(h.root, "tests", "codereview", "uuid_child.lua"),
    }, {
      cwd = fixture,
      text = true,
      env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = fixture },
    })
    :wait(60000)
  -- `-l` prints to stderr, so both streams are read.
  local text = (out.stdout or "") .. (out.stderr or "")
  local kinds, uuids = {}, {}
  for kind, uuid in text:gmatch("entry: (%S+) (%S+)") do
    kinds[#kinds + 1] = kind
    uuids[#uuids + 1] = uuid
  end
  return out, text, kinds, uuids
end

describe("a store written before the uuid", function()
  local now = os.time()
  vim.fn.mkdir(vim.fs.dirname(owned_path), "p")
  vim.fn.writefile({
    vim.json.encode({
      version = 1,
      checkout = root,
      saved = now,
      scopes = scopes,
      queue = {
        {
          id = 1,
          type = "bug",
          kind = "file",
          path = "src/main.lua",
          abs_path = vim.fs.joinpath(root, "src/main.lua"),
          key = "src/main.lua:f:0",
          inline = false,
          note = "owned, written before the uuid",
          at = now,
        },
      },
    }),
  }, owned_path)
  vim.fn.writefile({
    vim.json.encode({
      version = 1,
      queue = {
        { id = 2, type = "issue", kind = "note", key = "note:0", inline = false, note = "a bare note", at = now },
      },
      archive = {},
    }),
  }, global_path)

  -- The control. A store that already held a uuid would pass every case below.
  it("holds no uuid in either store before the first restore", function()
    assert.is_nil(read(owned_path).queue[1].uuid)
    assert.is_nil(read(global_path).queue[1].uuid)
  end)
end)

describe("the first restore", function()
  local out, text, kinds, uuids = session()

  it("exits cleanly", function()
    assert.same(0, out.code, text)
  end)

  it("gives the owned entry and the bare note each a uuid in RFC 4122 form", function()
    assert.same({ "file", "note" }, kinds, text)
    for _, uuid in ipairs(uuids) do
      assert.is_truthy(uuid:match(h.UUID), text)
    end
    assert.are_not.same(uuids[1], uuids[2])
  end)

  it("writes each uuid back to the store it came from", function()
    assert.same(uuids[1], read(owned_path).queue[1].uuid)
    assert.same(uuids[2], read(global_path).queue[1].uuid)
  end)

  it("keeps the version and the reviewed marks of the older document", function()
    local doc = read(owned_path)
    assert.same(1, doc.version)
    assert.same(scopes, doc.scopes)
    assert.same(scopes, state.load(root).scopes)
  end)

  local stat = vim.uv.fs_stat(owned_path)
  local global_stat = vim.uv.fs_stat(global_path)

  describe("and the restore after it", function()
    local again_out, again_text, _, again = session()

    it("exits cleanly", function()
      assert.same(0, again_out.code, again_text)
    end)

    it("reads the same uuids", function()
      assert.same(uuids, again, again_text)
    end)

    -- Every entry has a uuid now, so there is nothing to write back.
    it("does not write either store again", function()
      assert.same(stat.mtime, vim.uv.fs_stat(owned_path).mtime)
      assert.same(global_stat.mtime, vim.uv.fs_stat(global_path).mtime)
    end)
  end)
end)
