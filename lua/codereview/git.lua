---Git access for the review view.
---
---The only module in the plugin that shells out. Everything downstream consumes the
---plain-data structures built from this output, so the parser, the payload renderer and
---the state store can all be exercised without a repository.
local M = {}

-- Metadata queries are near-instant; a diff over a long branch is not. Two budgets rather
-- than one generous one, so a hung `rev-parse` still fails fast.
local QUICK_TIMEOUT_MS = 3000
local DIFF_TIMEOUT_MS = 15000

-- Enough to catch a NUL in any realistic header. Matches what git itself samples.
local BINARY_SNIFF_BYTES = 8000

--- Process boundary -----------------------------------------------------------

---@param args string[]
---@param opts? { cwd?: string, timeout?: integer, ok_codes?: integer[] }
---@return string|nil stdout Raw, untrimmed -- diff output is whitespace-significant
---@return string|nil err
local function run(args, opts)
  opts = opts or {}
  local cmd = { "git" }
  vim.list_extend(cmd, args)

  -- vim.system raises when the binary is missing, rather than returning a failure.
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true, cwd = opts.cwd }):wait(opts.timeout or QUICK_TIMEOUT_MS)
  end)
  if not ok then
    return nil, tostring(res)
  end

  if not vim.tbl_contains(opts.ok_codes or { 0 }, res.code) then
    local stderr = vim.trim(res.stderr or "")
    return nil, stderr ~= "" and stderr or ("git exited %d"):format(res.code)
  end
  return res.stdout or "", nil
end

---Single-line queries, trimmed. Returns nil for both failure and empty output, since
---every caller treats "no answer" and "empty answer" the same way.
---@param args string[]
---@param cwd? string
---@return string|nil
local function line(args, cwd)
  local out = run(args, { cwd = cwd })
  if not out then
    return nil
  end
  out = vim.trim(out)
  return out ~= "" and out or nil
end

--- Repository ------------------------------------------------------------------

---@param cwd? string
---@return string|nil root
function M.root(cwd)
  return line({ "rev-parse", "--show-toplevel" }, cwd)
end

---The repository's default branch, e.g. `origin/master`.
---
---Read from `origin/HEAD` rather than assumed: "main" is not universal -- repos on this
---machine use `master` -- and guessing wrong silently diffs against nothing.
---@param root string
---@return string|nil
function M.default_branch(root)
  local ref = line({ "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD" }, root)
  if ref then
    return (ref:gsub("^refs/remotes/", ""))
  end
  for _, candidate in ipairs({ "origin/main", "origin/master", "main", "master" }) do
    if line({ "rev-parse", "--verify", "--quiet", candidate }, root) then
      return candidate
    end
  end
  return nil
end

---@param root string
---@return string|nil name Current branch, or nil when detached
function M.current_branch(root)
  local name = line({ "symbolic-ref", "--quiet", "--short", "HEAD" }, root)
  return name
end

---@param a string
---@param b string
---@param root string
---@return string|nil
function M.merge_base(a, b, root)
  return line({ "merge-base", a, b }, root)
end

---A commit object recording the working tree as it stands, minted and nothing else.
---
---`git stash create` writes the commit and prints its sha; that is the whole of what it
---does. No ref moves, the index is left alone and the working tree is not reverted -- which
---is what makes it safe behind a submit, where a real stash would pull the reviewer's work
---out from under them mid-review.
---
---A clean tree mints nothing and prints nothing. That is an answer rather than a failure:
---there is nothing to record that `HEAD` does not already say, so `HEAD` is what it means.
---Untracked files are not in a `stash create` commit at all, which is the same gap the
---branch and worktree scopes already synthesise around.
---@param root string
---@return string|nil sha nil only when there is no HEAD to fall back to either
function M.snapshot(root)
  return line({ "stash", "create" }, root) or line({ "rev-parse", "--verify", "--quiet", "HEAD" }, root)
end

--- Scopes ----------------------------------------------------------------------

---@class CRScope
---@field name string       "branch"|"staged"|"unstaged"|"worktree"|"since-batch"|"revspec"
---@field label string      Shown in the view title
---@field args string[]     Appended to the `git diff` invocation
---@field before string     Ref for the pre-image; ":0" means the index
---@field after string|nil  Ref for the post-image; nil means the working tree
---@field untracked boolean Whether untracked files belong in this scope
---@field identity string   What makes this the same scope again; the view keys its
---                         per-scope progress on it

---Every scope with a name, in the order `gs` moves through them. A bare revspec is
---resolved separately, and completion offers exactly this list.
M.SCOPES = { "branch", "staged", "unstaged", "worktree", "since-batch" }

---The scopes `gs` actually moves through in this repository.
---
---`since-batch` is reachable by name and offered in completion unconditionally -- asking
---for it with an empty archive reports a sentence -- but the cycle drops it, because a
---cycle is walked blind and must never land on an error in a repository nothing has ever
---been dispatched from. Two rules, deliberately: one is a question a reviewer asked, the
---other is a key they held down.
---@param root string
---@return string[]
function M.cycle(root)
  local names = {}
  for _, name in ipairs(M.SCOPES) do
    if name ~= "since-batch" or require("codereview.state").last_batch(root) then
      names[#names + 1] = name
    end
  end
  return names
end

---Resolve a scope name, or any git revspec, into the refs the rest of the plugin needs.
---
---`before`/`after` exist because the diff text alone cannot tell the syntax highlighter
---where to find whole-file content: `--cached` compares HEAD to the index, and neither
---side is a file on disk.
---
---Every scope also carries an identity: the ref that tells the view which scope it reads
---progress for. Today it is `before` in each of them. That is what the progress key has
---always held, so a key written before this field existed still finds its reviewed marks.
---It is a field of its own because the two can move apart. If a scope moves its pre-image,
---the identity does not move with it, and the reviewer keeps the marks they made.
---@param spec string
---@param root string
---@return CRScope|nil, string|nil err
function M.resolve_scope(spec, root)
  if spec == "staged" then
    return {
      name = "staged",
      label = "staged",
      args = { "--cached" },
      before = "HEAD",
      after = ":0",
      untracked = false,
      identity = "HEAD",
    }
  elseif spec == "unstaged" then
    return {
      name = "unstaged",
      label = "unstaged",
      args = {},
      before = ":0",
      after = nil,
      untracked = false,
      identity = ":0",
    }
  elseif spec == "worktree" then
    return {
      name = "worktree",
      label = "worktree",
      args = { "HEAD" },
      before = "HEAD",
      after = nil,
      untracked = true,
      identity = "HEAD",
    }
  elseif spec == "since-batch" then
    -- Resolved here rather than anywhere of its own, and to a *real ref*: the diff parser,
    -- the blob hashing and the whole-file fetch the highlighter needs all read content out
    -- of `before`, and none of them can read a marker. Which is why the archive keeps a
    -- commit object -- read back here through the one query that answers which batch went
    -- last, shared with the surface that lists that batch's entries so the diff on screen
    -- and the annotations beside it can never describe two different dispatches.
    local batch = require("codereview.state").last_batch(root)
    if not batch then
      return nil, "nothing has been dispatched from this repository yet"
    end
    if not batch.snapshot then
      return nil, "the last batch went out with no snapshot to diff against"
    end
    return {
      name = "since-batch",
      label = "since the last batch",
      args = { batch.snapshot },
      before = batch.snapshot,
      after = nil,
      -- A file untracked at dispatch is not in the snapshot commit at all, so it arrives
      -- through the same synthesis the branch and worktree scopes already apply rather
      -- than through a mechanism of its own.
      untracked = true,
      identity = batch.snapshot,
    }
  elseif spec == "branch" or spec == "" or spec == nil then
    local branch = M.default_branch(root)
    if not branch then
      return nil, "could not determine the default branch"
    end
    local base = M.merge_base(branch, "HEAD", root)
    if not base then
      return nil, ("no merge base with %s"):format(branch)
    end
    return {
      name = "branch",
      label = ("branch vs %s"):format(branch),
      args = { base },
      before = base,
      after = nil,
      untracked = true,
      -- The merge base, which is what says *this branch*. A scope that starts at a later
      -- commit is the same branch review, and it reads the same progress back.
      identity = base,
    }
  end

  -- Anything else is a revspec. Resolve the endpoints ourselves so `before`/`after` are
  -- real refs the highlighter can `git show`; passing the raw spec through would leave us
  -- unable to fetch either side's file content.
  local left, kind, right = spec:match("^(.-)(%.%.%.?)(.*)$")
  if kind == "..." then
    local a = left ~= "" and left or "HEAD"
    local b = right ~= "" and right or "HEAD"
    local base = M.merge_base(a, b, root)
    if not base then
      return nil, ("no merge base between %s and %s"):format(a, b)
    end
    return {
      name = "revspec",
      label = spec,
      args = { spec },
      before = base,
      after = b,
      untracked = false,
      identity = base,
    }
  elseif kind == ".." then
    local a = left ~= "" and left or "HEAD"
    local b = right ~= "" and right or "HEAD"
    return {
      name = "revspec",
      label = spec,
      args = { spec },
      before = a,
      after = b,
      untracked = false,
      identity = a,
    }
  end

  if not line({ "rev-parse", "--verify", "--quiet", spec .. "^{commit}" }, root) then
    return nil, ("not a valid revision: %s"):format(spec)
  end
  return {
    name = "revspec",
    label = ("vs %s"):format(spec),
    args = { spec },
    before = spec,
    after = nil,
    untracked = true,
    identity = spec,
  }
end

--- Diff ------------------------------------------------------------------------

---Raw unified diff for a scope.
---
---`-M` detects renames, `--no-color` because we do our own highlighting, and
---`--no-ext-diff` so a user's configured external difftool cannot replace the machine-
---readable output we parse.
---@param scope CRScope
---@param root string
---@param context integer Lines of context (`-U`)
---@return string|nil text, string|nil err
function M.diff(scope, root, context)
  local args = { "diff", "--no-color", "--no-ext-diff", "-M", ("-U%d"):format(context or 3) }
  vim.list_extend(args, scope.args)
  return run(args, { cwd = root, timeout = DIFF_TIMEOUT_MS })
end

---Paths git is not tracking, honouring .gitignore.
---@param root string
---@return string[]
function M.untracked_files(root)
  local out = run({ "ls-files", "--others", "--exclude-standard" }, { cwd = root })
  if not out or vim.trim(out) == "" then
    return {}
  end
  return vim.split(vim.trim(out), "\n", { trimempty = true })
end

--- File content ----------------------------------------------------------------

---@param root string
---@param path string
---@return string|nil
local function read_worktree(root, path)
  local fd = io.open(vim.fs.joinpath(root, path), "rb")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

---Whole-file content on one side of the diff, for syntax highlighting.
---@param path string Relative to root
---@param ref string|nil nil = working tree, ":0" = index, otherwise a commit-ish
---@param root string
---@return string|nil
function M.file_content(path, ref, root)
  if ref == nil then
    return read_worktree(root, path)
  end
  local spec = ref == ":0" and (":0:" .. path) or (ref .. ":" .. path)
  -- Exit 128 is the normal answer for "this path does not exist at that ref" (an added or
  -- deleted file), not a failure worth reporting.
  local out = run({ "show", "--textconv", spec }, { cwd = root, timeout = DIFF_TIMEOUT_MS })
  return out
end

---Content hash of one side of a file -- the invalidation key for reviewed marks and
---queued annotations. A file whose blob still matches is a file you really did review.
---@param path string Relative to root
---@param ref string|nil nil = working tree, ":0" = index, otherwise a commit-ish
---@param root string
---@return string|nil
function M.blob(path, ref, root)
  if ref == nil then
    return line({ "hash-object", "--", path }, root)
  end
  local spec = ref == ":0" and (":0:" .. path) or (ref .. ":" .. path)
  return line({ "rev-parse", "--quiet", "--verify", spec }, root)
end

---Hash many working-tree files in one process.
---
---`git hash-object` accepts any number of paths, and a review of sixty files otherwise
---pays for sixty process spawns before it can draw anything -- which costs more than all
---the syntax parsing put together.
---@param paths string[]
---@param root string
---@return table<string, string>
function M.hash_worktree(paths, root)
  local out = {}
  -- A single missing path fails the whole invocation, so they are filtered out first
  -- rather than letting one deleted file lose every hash.
  local present = {}
  for _, p in ipairs(paths) do
    if vim.uv.fs_stat(vim.fs.joinpath(root, p)) then
      present[#present + 1] = p
    end
  end
  if #present == 0 then
    return out
  end

  local args = { "hash-object", "--" }
  vim.list_extend(args, present)
  local res = run(args, { cwd = root, timeout = DIFF_TIMEOUT_MS })
  if not res then
    return out
  end
  local lines = vim.split(vim.trim(res), "\n", { trimempty = true })
  for i, p in ipairs(present) do
    out[p] = lines[i]
  end
  return out
end

---Resolve many `<ref>:<path>` specs to blob hashes in one process.
---@param specs string[]
---@param root string
---@return table<string, string> Keyed by the spec that was asked for
function M.hash_refs(specs, root)
  local out = {}
  if #specs == 0 then
    return out
  end
  local ok, res = pcall(function()
    return vim
      .system({ "git", "cat-file", "--batch-check" }, {
        text = true,
        cwd = root,
        stdin = table.concat(specs, "\n") .. "\n",
      })
      :wait(DIFF_TIMEOUT_MS)
  end)
  if not ok or res.code ~= 0 then
    return out
  end
  -- One output line per input line: "<sha> blob <size>", or "<spec> missing" for a path
  -- that does not exist at that ref (an added or deleted file).
  local lines = vim.split(res.stdout or "", "\n", { trimempty = true })
  for i, spec in ipairs(specs) do
    local sha = (lines[i] or ""):match("^(%x+) blob ")
    if sha then
      out[spec] = sha
    end
  end
  return out
end

---@param text string|nil
---@return boolean
function M.looks_binary(text)
  if not text or text == "" then
    return false
  end
  return text:sub(1, BINARY_SNIFF_BYTES):find("\0", 1, true) ~= nil
end

--- Collection ------------------------------------------------------------------

---Every file in a scope, parsed, with untracked entries folded in and blobs filled.
---
---This is the seam between the process boundary and the pure parser: `diff.lua` stays
---git-free, and everything downstream receives one already-complete list.
---@param scope CRScope
---@param root string
---@param opts? { context?: integer, untracked?: boolean, spans?: boolean }
---@return CRFile[]|nil files, string|nil err
function M.collect(scope, root, opts)
  opts = opts or {}

  local text, err = M.diff(scope, root, opts.context or 3)
  if not text then
    return nil, err
  end

  local diff = require("codereview.diff")
  local files = diff.parse(text, { spans = opts.spans })

  -- Untracked files are invisible to `git diff` entirely, so a brand-new file would
  -- silently never appear in the review.
  if scope.untracked and opts.untracked ~= false then
    for _, path in ipairs(M.untracked_files(root)) do
      files[#files + 1] = diff.synthesize_added(path, read_worktree(root, path))
    end
  end

  -- Blobs are resolved in two batched calls rather than one process per file.
  local worktree_paths, ref_specs = {}, {}
  local want = {}
  for _, file in ipairs(files) do
    -- A deletion has no post-image, so its identity is the content that went away.
    local ref = file.status == "D" and scope.before or scope.after
    if file.status == "U" then
      ref = nil
    end
    want[file.path] = ref
    if ref == nil then
      worktree_paths[#worktree_paths + 1] = file.path
    else
      ref_specs[#ref_specs + 1] = (ref == ":0" and ":0:" or (ref .. ":")) .. file.path
    end
  end

  local from_worktree = M.hash_worktree(worktree_paths, root)
  local from_refs = M.hash_refs(ref_specs, root)

  for _, file in ipairs(files) do
    local ref = want[file.path]
    if ref == nil then
      file.blob = from_worktree[file.path]
    else
      file.blob = from_refs[(ref == ":0" and ":0:" or (ref .. ":")) .. file.path]
    end
  end

  table.sort(files, function(a, b)
    return a.path < b.path
  end)

  return files, nil
end

--- The branch's commits ---------------------------------------------------------

---@class CRCommit
---@field sha string      Short sha, abbreviated by git to whatever this repository needs
---@field when string     How long ago it was authored, in git's own words
---@field subject string  The commit's first line

---Every commit the branch carries, newest first.
---
---`--first-parent` from the merge base to `HEAD`. A merge is then one commit and reads as
---the one change it was, and the work that arrived through it is not listed beside the work
---the branch did itself.
---
---**There is no limit.** A limit would put the oldest commits on a long branch out of reach,
---which is the one thing a list a reviewer picks from must never do.
---
---The merge base is resolved here rather than taken from a scope. What a reviewer is being
---shown is the branch, and a scope's pre-image is free to be something narrower than the
---branch -- so reading it would quietly shorten the list the moment it was.
---@param root string
---@return CRCommit[]|nil commits, string|nil err
function M.branch_commits(root)
  local branch = M.default_branch(root)
  if not branch then
    return nil, "could not determine the default branch"
  end
  local base = M.merge_base(branch, "HEAD", root)
  if not base then
    return nil, ("no merge base with %s"):format(branch)
  end

  -- The fields are separated by a unit separator, and the subject comes last. A subject is
  -- one line and can hold anything else at all, including whatever a friendlier separator
  -- would be built out of -- so the one field that could contain the delimiter is the one
  -- field nothing is parsed after.
  local out, err = run({
    "log",
    "--first-parent",
    "--format=%h%x1f%ar%x1f%s",
    base .. "..HEAD",
    -- A long branch's log is closer to a diff than to a metadata query.
  }, { cwd = root, timeout = DIFF_TIMEOUT_MS })
  if not out then
    return nil, err
  end

  local commits = {}
  for _, entry in ipairs(vim.split(out, "\n", { trimempty = true })) do
    local sha, when, subject = entry:match("^(%S+)\31(.-)\31(.*)$")
    if sha then
      commits[#commits + 1] = { sha = sha, when = when, subject = subject }
    end
  end
  return commits, nil
end

return M
