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
---@return integer|nil code The exit status, for a caller that accepts more than one
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
    return nil, stderr ~= "" and stderr or ("git exited %d"):format(res.code), res.code
  end
  return res.stdout or "", nil, res.code
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

---Whether `HEAD` still descends from every one of them.
---
---What a stored **trim** is checked with before a review reads from it. A rebase, an amend
---and a force-push all end in the same place: a commit the trim took out is not in this
---branch any more, and a review resolved from one of those is a review nobody asked for.
---
---**One process for the whole set**, because a trim holds as many commits as the reviewer
---took out and this runs on every read. `rev-list` walks the commits it is given and
---excludes everything `HEAD` reaches, so a count of nothing left over is the one answer that
---means *all of them* -- and asking per commit would spend a process per row of a listing
---the reviewer is free to take the whole of.
---
---One answer out of two failures, deliberately. A commit that is real and off this line of
---work is counted, and a commit this repository has nothing under at all -- which is what a
---`git gc` after a rebase leaves a stored trim naming -- makes `rev-list` exit non-zero
---instead. Both mean *not commits this review can read from*, and the reviewer has one thing
---to be told either way.
---
---An empty set asks nothing: a trim that takes no commit out has no commit that can fail.
---@param commits string[]
---@param root string
---@return boolean
function M.all_ancestors(commits, root)
  if #commits == 0 then
    return true
  end
  local args = { "rev-list", "--count" }
  vim.list_extend(args, commits)
  vim.list_extend(args, { "--not", "HEAD" })
  return line(args, root) == "0"
end

---How many commits `from` is behind `HEAD` on the branch's own line of work.
---
---What the scope label reports as `last N`, counted from what a **trim** leaves the review
---reading from. Derived rather than remembered: a reviewer who commits again after trimming
---has one more commit in their review than they picked, and a number stored at pick time
---would keep saying the old one.
---
---`--first-parent` for the reason the listing is: a merge is one commit, and counting what
---arrived through it would report a number no row of the commit list adds up to.
---@param from string
---@param root string
---@return integer|nil nil when `from` names no commit this repository has
function M.count_commits(from, root)
  local out = line({ "rev-list", "--count", "--first-parent", from .. "..HEAD" }, root)
  return out and tonumber(out) or nil
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

--- The pre-image a trim reads from -----------------------------------------------

---The subject on a commit object that exists because a review asked for a tree nothing on
---the branch has. Never reachable from a ref, so this is all there is to read it by.
local SYNTHESIZED = "codereview: synthesized pre-image"

---The trees already built for a trim with a hole in it, by the whole of what built them.
---
---**The recorded trap about memoising a trim does not reach this, and the key is why.** That
---trap is a stored *sha* going stale against a rewritten `HEAD`: a memo answers from memory
---without ever asking `HEAD` again, which is the exact failure the ancestry check exists to
---refuse. This key holds `HEAD` itself, beside the repository, the base and the set -- every
---input the accumulation reads -- so any of them moving is a new key rather than a stale
---answer. Nothing else is cached: not the trim, not its ancestry answer, not the resolved
---scope.
---
---Without it, every scope cycle and every reopen pays the whole accumulation again, and a
---pick pays it twice over: once to find out whether it can be assembled, once to resolve.
local built = {}

---@param root string
---@param base string
---@param skipped string[]
---@return string|nil key nil when this repository has no `HEAD` to key on
local function cache_key(root, base, skipped)
  local head = line({ "rev-parse", "--verify", "--quiet", "HEAD" }, root)
  if not head then
    return nil
  end
  -- Sorted, because the same set stored in another order is the same set, and a key that
  -- said otherwise would rebuild what it already holds.
  local order = vim.deepcopy(skipped)
  table.sort(order)
  return table.concat({ root, base, head, table.concat(order, ",") }, "\31")
end

---Three-way merge one skipped commit onto the accumulation, and print the tree.
---
---`merge-tree` is the primitive for exactly this: a real three-way merge that writes a tree
---and reports conflicts, touching no index, no working tree and no ref -- the stance
---`snapshot` already takes with `stash create`. It is what sets the git 2.38 floor the
---README states, and **only a trim with a hole in it ever reaches it**, so the floor gates
---the new selections rather than the trim that already ships.
---
---**The exit status is the whole answer.** `--name-only` prints the tree object on the first
---line and, when the merge conflicted, the conflicting paths on the lines below it, above
---the blank line the informational messages sit under. Deciding instead by searching that
---trailer for the word `CONFLICT` would be a search that reports a conflicting merge as
---**clean** wherever the wording differs -- and the wording is a message written for a human,
---not an interface, so it is free to differ across the versions above the floor. A false
---negative there ships a review built from a tree that could not be assembled. The exit code
---is what `all_ancestors` already leans on, for the same reason.
---@param root string
---@param ours string The accumulation so far, as a commit
---@param commit string The skipped commit being applied
---@return string|nil tree nil when the merge conflicted or git refused it
---@return string[] conflicts The paths it conflicts in; empty when git refused outright
---@return string|nil err What git said, when it refused outright
local function merge_tree(root, ours, commit)
  local out, err, code = run({
    "merge-tree",
    "--write-tree",
    "--name-only",
    -- The commit's own parent, so what is applied is what that commit did and nothing else.
    "--merge-base=" .. commit .. "^",
    ours,
    commit,
  }, { cwd = root, timeout = DIFF_TIMEOUT_MS, ok_codes = { 0, 1 } })
  -- Anything but a clean merge or a conflicting one -- an unknown option on a git below the
  -- floor, a bad object -- is what git said it was, reported through the same path.
  if not out then
    return nil, {}, err
  end

  local lines = vim.split(out, "\n", { plain = true })
  if code == 0 then
    local tree = vim.trim(lines[1] or "")
    return tree ~= "" and tree or nil, {}, nil
  end

  local conflicts = {}
  for i = 2, #lines do
    if lines[i] == "" then
      break
    end
    conflicts[#conflicts + 1] = lines[i]
  end
  return nil, conflicts, nil
end

---@class CRTrim
---@field before string  The pre-image the review reads from
---@field kept integer   How many of the branch's commits the trim leaves in the review
---@field total integer  How many the branch has
---@field hole boolean   Whether a commit was taken out with an older one left in

---@param commit CRCommit
---@param conflicts string[]
---@param err string|nil
---@return string
local function refusal(commit, conflicts, err)
  -- The skipped commit and the files, and no dependency commit: `merge-tree` reports the
  -- files, and naming the kept commit that introduced the conflicting region would take a
  -- heuristic pass of its own that can name the wrong commit confidently.
  if #conflicts > 0 then
    return ("Taking out %s %s conflicts in %s — the review is unchanged"):format(
      commit.sha,
      commit.subject,
      table.concat(conflicts, ", ")
    )
  end
  return ("Taking out %s %s could not be assembled — %s"):format(commit.sha, commit.subject, err or "git refused it")
end

---What a reviewer is told when they take a merge out of the middle of a trim.
---
---**It names no file**, and that is the whole difference between this sentence and the one
---above it. The files a merge collides in are every file the side branch brought: the
---reviewer did not write them, did not ask about them, and can do nothing with a list of
---them. What they can act on is the reason, and the reason is that the merge is not the
---thing they think they are taking out: merging the default branch moves the merge base
---forward, so everything that merge brought is already outside this review.
---@param commit CRCommit
---@return string
local function merge_refusal(commit)
  local named = ("Taking out the merge %s %s is not needed"):format(commit.sha, commit.subject)
  return named .. ": a merge brings nothing the review does not already read — the review is unchanged"
end

---What a **trim** leaves a branch review reading from.
---
---A trim is the commits taken out, so the review has to read from a tree that already holds
---every one of them and none of the commits kept. It is built in two parts.
---
---It **anchors on the leading run**: the commits the trim takes off the *start* of the
---branch, from the oldest up, for as far as the set matches the branch. The newest commit of
---that run is a real commit whose own tree is exactly that, so nothing is assembled for it.
---With nothing in the run the anchor is the merge base: a trim that takes no commit out
---reads the branch whole. That is the *oldest row* of the commit list, and the anchor is why
---it needs no case of its own -- on a branch with a merge in it the oldest commit's parent
---is not the merge base, and a review reading from that parent draws a file the merge base
---already had as one the branch added.
---
---**The anchor is the whole design and not an optimization.** Accumulating every skipped
---commit from the merge base instead refuses two ordinary cases, both confirmed against a
---real repository: a plain prefix trim reaching past a merge -- which is the shipped `gc`
---flow on any branch with a merge in it -- and taking every commit out. Both collide, because
---a merge's first-parent diff *adds* what the side branch brought while the merge base
---already holds it.
---
---Above the run each skipped commit is **three-way merged onto the accumulation, oldest
---first**, and a commit object is minted between steps because `merge-tree` merges commits
---rather than trees. Only a set with a hole in it gets that far, and a **merge** above the
---run never gets that far at all: the rule below refuses it first. **No ref is written**:
---the synthesized commit is unreachable, which is the exposure `snapshot` already accepts,
---and git's default prune window is two weeks -- an automatic collection cannot take a
---commit minted minutes ago, and the cache re-mints on the next resolve if an explicit
---prune does.
---
---**A merge cannot start a hole**, and the refusal comes before any merge is attempted. A
---merge above the run collides wholesale, for the same reason the anchor exists: its
---first-parent diff *adds* everything the side branch brought, and the anchor already holds
---it. Attempting it would answer the reviewer with a list of files they did not touch and
---cannot act on, so what they are told instead is the reason -- and the reason is that the
---merge brings this review nothing. Merging the default branch moves the merge base
---forward, so what the merge brought is already outside the review: taking it out of the
---middle is unnecessary as well as impossible.
---
---The rule is **dynamic**, which is the point of it. The same merge taken off the *start* of
---the branch, with every commit older than it taken off too, is inside the run: it assembles
---nothing and reads what a trim past a merge has always read. Only a merge with a kept
---commit older than it is refused -- which is exactly a skipped merge above the run -- so the
---same row is free or refused depending on what else the trim takes, and no surface can grey
---it out ahead of time.
---
---The branch's commits are read back through `branch_commits`, which is the listing the
---reviewer picked off. One rule for which commits are on the branch, for the reason there is
---one rule for where it starts: a trim built from one listing and resolved against another
---is a trim that can stop resolving without either side changing. A set holding a commit
---that listing does not name is one this cannot read from, and it gives the whole branch
---back rather than a narrower reading than the reviewer asked for.
---@param root string
---@param base string The merge base: where the branch starts
---@param skipped string[] The commits the trim takes out
---@return CRTrim|nil trim nil when the set cannot be read from or cannot be built
---@return string|nil refused The sentence a reviewer is told, when the set is refused
local function pre_image(root, base, skipped)
  local commits = M.branch_commits(root, base)
  if not commits then
    return nil, nil
  end

  local taken = {}
  for _, sha in ipairs(skipped) do
    taken[sha] = true
  end

  -- Up from the oldest commit, which is the end of a listing drawn newest first.
  local anchor, run = base, 0
  for i = #commits, 1, -1 do
    if not taken[commits[i].id] then
      break
    end
    anchor, run = commits[i].id, run + 1
  end

  -- Derived from the listing rather than remembered, exactly as the `last N` count is: the
  -- commit a reviewer makes after trimming is in the review, and in both of these numbers,
  -- the moment it is made.
  local trim = { kept = #commits - #skipped, total = #commits, hole = run < #skipped }
  if not trim.hole then
    trim.before = anchor
    return trim, nil
  end

  -- A merge cannot start a hole, refused here rather than attempted -- see the header. The
  -- walk is the accumulation's own: from the row above the run up to the newest, so the merge
  -- named is the one the build would have met first. A merge *inside* the run is never
  -- reached, which is what leaves a trim past a merge free while this one is refused.
  for i = #commits - run, 1, -1 do
    local commit = commits[i]
    if taken[commit.id] and commit.merge then
      return nil, merge_refusal(commit)
    end
  end

  local key = cache_key(root, base, skipped)
  if key and built[key] then
    trim.before = built[key]
    return trim, nil
  end

  local acc, applied = anchor, run
  -- Oldest first, from the row above the run down to the newest.
  for i = #commits - run, 1, -1 do
    local commit = commits[i]
    if taken[commit.id] then
      local tree, conflicts, err = merge_tree(root, acc, commit.id)
      if not tree then
        return nil, refusal(commit, conflicts, err)
      end
      acc = line({ "commit-tree", tree, "-p", acc, "-m", SYNTHESIZED }, root)
      if not acc then
        return nil, nil
      end
      applied = applied + 1
    end
  end
  if applied ~= #skipped then
    return nil, nil
  end

  if key then
    built[key] = acc
  end
  trim.before = acc
  return trim, nil
end

---Why a set of commits cannot leave this branch's review, or nil when it can.
---
---What a pick asks **before anything is stored**, so a refusal reaches the reviewer with the
---float still open and the store holding what it held. It is not a seam of its own: it
---answers out of the same builder scope resolution reads, and the tree it builds on the way
---is the tree that resolve then finds in the cache.
---
---A set this cannot read from at all -- one holding a commit the branch does not list -- is
---not a refusal. That is the shipped answer for a trim nothing can resolve: the whole branch
---opens, and the reviewer is not told a sentence about a build that was never begun.
---@param root string
---@param base string The merge base: the review's own scope identity
---@param skipped string[]|nil
---@return string|nil refused
function M.trim_refusal(root, base, skipped)
  if not skipped then
    return nil
  end
  local _, refused = pre_image(root, base, skipped)
  return refused
end

---Resolve a scope name, or any git revspec, into the refs the rest of the plugin needs.
---
---`before`/`after` exist because the diff text alone cannot tell the syntax highlighter
---where to find whole-file content: `--cached` compares HEAD to the index, and neither
---side is a file on disk.
---
---Every scope also carries an identity: the ref that tells the view which scope it reads
---progress for. It is `before` in every scope but a trimmed `branch`, which is what the
---progress key has always held, so a key written before this field existed still finds its
---reviewed marks. It is a field of its own because the two do move apart, and `branch` is
---where: a **trim** moves the pre-image up the branch and the identity stays at the merge
---base, so the reviewer keeps every mark they made on the review they are narrowing.
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

    -- The **trim**, read here rather than taken as an argument -- the shape `since-batch`
    -- already has, and for the reason recorded for it: handing the value in would put the
    -- one scope that needs it into every caller of scope resolution, and scope resolution
    -- is exactly what has to stay one function. What comes back is already checked: the
    -- store drops a set holding a commit `HEAD` no longer descends from, and says so, so a
    -- commit this repository cannot read from never reaches the anchor below.
    local skipped = require("codereview.state").trim(root)
    -- Only the first answer, deliberately. A refusal belongs to the **pick**, which asks
    -- before it stores anything and still has the reviewer in front of it; here a set that
    -- cannot be built gives the whole branch back, which is what an unresolvable trim has
    -- always done rather than a narrower reading than the reviewer asked for.
    local trim
    if skipped then
      trim = pre_image(root, base, skipped)
    end

    -- Two spellings of one number, for two different questions. While the trim is a prefix
    -- the review is the last N commits, and how far `HEAD` is from the pre-image is a
    -- question git answers -- and a count the repository cannot take leaves the whole branch
    -- open rather than a review narrowed by an answer nothing could work out. Under a hole
    -- the review is not a run of commits at all, so there is no ref to count from and what
    -- is left in is the size of the kept set.
    local kept
    if trim then
      kept = trim.hole and trim.kept or M.count_commits(trim.before, root)
    end
    local before = kept and trim.before or base

    -- Short, because the winbar is width-constrained and the summary is what a narrow pane
    -- gives up first. The label is also the only thing that stops a trim from being a trap,
    -- so it carries two forms: `last N` while the trim is a prefix, and `N of M` once it has
    -- a hole in it or has taken the whole branch out. Neither of those is the last anything,
    -- and a label must never claim a shape the reading does not have.
    local label = ("branch vs %s"):format(branch)
    if kept and (trim.hole or kept == 0) then
      label = ("%s · %d of %d"):format(label, kept, trim.total)
    elseif kept then
      label = ("%s · last %d"):format(label, kept)
    end

    return {
      name = "branch",
      label = label,
      args = { before },
      -- What the commits the trim took out are already in, so the ones it kept are the diff.
      before = before,
      -- Both of these follow from how far a trim reaches: it takes commits out, and the
      -- post-image is the working tree, so the work in the tree is on the other side of the
      -- review and no trim of any shape reaches it.
      after = nil,
      untracked = true,
      -- The merge base, which is what says *this branch*, and it does not move when the
      -- pre-image does. A trimmed review is the same branch review and reads the same
      -- progress back, which is what leaves a reviewer's marks where they left them.
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

---Paths git is not tracking, honoring .gitignore.
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
---@field id string       Full sha: what a **trim** that takes this commit out is stored as
---@field when string     How long ago it was authored, in git's own words
---@field subject string  The commit's first line
---@field merge boolean   Whether it has a second parent: a **trim** cannot start a hole here

---Every commit the branch carries, newest first.
---
---`--first-parent` from the merge base to `HEAD`. A merge is then one commit and reads as
---the one change it was, and the work that arrived through it is not listed beside the work
---the branch did itself.
---
---**There is no limit.** A limit would put the oldest commits on a long branch out of reach,
---which is the one thing a list a reviewer picks from must never do.
---
---The base is handed in and never derived here. The one answer to *where does this branch
---start* is the scope's own identity, and a second derivation can disagree with it: a
---`git fetch` in another window moves the default branch, and the list would then be drawn
---against a base the review on screen is not using. What must **not** be handed in is the
---scope's pre-image, which is exactly what a trim narrows -- reading that would shorten the
---list every time a reviewer trimmed, and take the rows they need to widen it again away.
---
---Each commit carries both spellings of its name. The abbreviation is what a row is read
---by; the full sha is what a **trim** taking that commit out is stored as, because git
---abbreviates to whatever the repository needs at the moment it is asked, a repository
---grows, and a trim outlives the length it was picked at.
---
---Each one also says whether it is a **merge**, read off the parents this same listing
---already knows: a merge cannot start a hole in a trim, and the rule that refuses one is a
---rule about a row of *this* listing. Asked for separately it would be a second walk of the
---branch and a second answer to which commits are on it.
---@param root string
---@param base string Where the branch starts: the scope's identity
---@return CRCommit[]|nil commits, string|nil err
function M.branch_commits(root, base)
  -- The fields are separated by a unit separator, and the subject comes last. A subject is
  -- one line and can hold anything else at all, including whatever a friendlier separator
  -- would be built out of -- so the one field that could contain the delimiter is the one
  -- field nothing is parsed after.
  local out, err = run({
    "log",
    "--first-parent",
    -- `%P` is every parent, space-separated, so a second one is what says *merge*. It goes
    -- after the two sha fields, which are matched as one word each and a parent list is not
    -- one word, and before the subject, which is still the one field nothing is parsed after.
    "--format=%h%x1f%H%x1f%P%x1f%ar%x1f%s",
    base .. "..HEAD",
    -- A long branch's log is closer to a diff than to a metadata query.
  }, { cwd = root, timeout = DIFF_TIMEOUT_MS })
  if not out then
    return nil, err
  end

  local commits = {}
  for _, entry in ipairs(vim.split(out, "\n", { trimempty = true })) do
    local sha, id, parents, when, subject = entry:match("^(%S+)\31(%S+)\31(.-)\31(.-)\31(.*)$")
    if sha then
      commits[#commits + 1] = {
        sha = sha,
        id = id,
        when = when,
        subject = subject,
        merge = parents:find(" ", 1, true) ~= nil,
      }
    end
  end
  return commits, nil
end

---@class CRCommitSize
---@field added integer    Lines the commit added
---@field deleted integer  Lines it deleted
---@field files integer    Files it touched

---How much each commit on the branch changed, answered on a later tick.
---
---**Asked apart from the listing, and that is the whole point of it.** `branch_commits` is a
---metadata query and near-instant; this is a diff of every commit on the branch, and on a
---long one it is the slowest thing either surface asks for. Made a field of that format it
---would put the whole cost in front of the float opening -- which is exactly what was
---refused when these counts were first left off a row. Asked here it costs the float
---nothing: the rows are drawn from the listing and the columns fill when the answer lands.
---
---**One process for the whole branch**, for the reason the listing carries the merge flag
---rather than asking per row: a commit at a time is a process per row of a list a reviewer
---is free to take the whole of, and a second walk is a second answer to which commits are on
---the branch. One question, one answer, and it is `--first-parent` from the same base so the
---answer is keyed by the rows the listing drew.
---
---**`--numstat` and never `--shortstat`.** The short form is a sentence git writes for a
---human and translates for their locale; the long form is two numbers and a path per file,
---which is what `git diff --numstat` is for. A binary file prints `-` for both counts: it is
---a file the commit touched and no lines anybody wrote, and it is counted that way.
---
---**`--diff-merges=first-parent` states what the row has to claim.** A merge is one row here
---and the review reads its first-parent diff, so that is the size the row reports. Every git
---above this plugin's floor already diffs a merge that way under `--first-parent`; the flag
---says it rather than inheriting it, because a row claiming a size the review does not have
---is worse than a row claiming none.
---
---The callback is handed nil when git cannot answer, and a row then carries no figures at
---all. No sentence: a size sits beside the subject to be glanced at, and a reviewer who can
---still read every subject and press every key has lost nothing worth a notification.
---
---It always lands on a later tick and where the editor can be touched, failure and answer
---alike, so a caller has one rule to write against rather than two.
---@param root string
---@param base string Where the branch starts: the scope's identity
---@param on_done fun(sizes: table<string, CRCommitSize>|nil) Keyed by full sha
function M.branch_sizes(root, base, on_done)
  local function answer(sizes)
    vim.schedule(function()
      on_done(sizes)
    end)
  end

  local cmd = {
    "git",
    "log",
    "--first-parent",
    "--diff-merges=first-parent",
    "--numstat",
    -- The unit separator is what tells a commit's own line from the numstat lines under it:
    -- those start with a count or a `-` and hold tabs, and nothing else here starts with a
    -- character a path cannot begin with either.
    "--format=%x1f%H",
    base .. "..HEAD",
  }
  -- vim.system raises when the binary is missing, rather than reporting it to the callback.
  local ok = pcall(vim.system, cmd, { text = true, cwd = root, timeout = DIFF_TIMEOUT_MS }, function(res)
    if res.code ~= 0 then
      return answer(nil)
    end

    local sizes, at = {}, nil
    for _, entry in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
      local id = entry:match("^\31(%S+)$")
      if id then
        at = { added = 0, deleted = 0, files = 0 }
        sizes[id] = at
      elseif at then
        local added, deleted = entry:match("^(%S+)\t(%S+)\t")
        if added then
          at.files = at.files + 1
          at.added = at.added + (tonumber(added) or 0)
          at.deleted = at.deleted + (tonumber(deleted) or 0)
        end
      end
    end
    answer(sizes)
  end)
  if not ok then
    answer(nil)
  end
end

return M
