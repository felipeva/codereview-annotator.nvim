---Persisted review progress, and the blob-hash check that makes persisting safe.
---
---A review spans hours; losing reviewed marks and unsent annotations to a `:qa` is a real
---cost. The reason a queue is normally *not* worth persisting is that it describes a
---working-tree state a rebase can invalidate -- but that is an argument for detecting
---staleness, not for discarding the data. Every file records the blob it was reviewed or
---annotated against, and anything that no longer matches is corrected on load:
---
---  * a reviewed mark whose blob moved is silently un-marked -- the file changed, so you
---    have not reviewed what is there now;
---  * an annotation whose blob moved is kept but flagged stale, because the prose is
---    still worth sending and only its line anchor is untrustworthy.
---
---A third comparison lives here and is deliberately not a third case of that one:
---**touchedness** judges an *archived* entry against the working tree as it stood when its
---batch was **dispatched**, and answers where an agent has been rather than whether a note
---is still trustworthy. Same primitive, different blob, different entries, separate
---function -- see `reconcile_archive`.
local queue = require("codereview.queue")

local M = {}

---Bumping this discards every document written before the bump, so a key added to the
---shape is *not* a reason to touch it. `archive` was added by defaulting it on load
---exactly as `scopes` and `queue` already are: an older document simply lacks it, which
---costs an empty table, where a bump would cost every reviewed mark in the file.
local VERSION = 1

---A batch as it was dispatched, kept after the queue that held it was cleared.
---@class CRBatch
---@field at integer            When it went
---@field target string         Short name of where it went; "local" for the adapter's default
---@field snapshot string|nil   Commit object recording the working tree at that moment
---@field preamble string|nil   The prose it went under, absent when it went under none
---@field entries CRAnnotation[]

---How many dispatched batches a store keeps, oldest dropped on write.
---
---Public because it is a property of the store rather than a number this file happens to
---use. Bounded for the reason the global store sweeps on age: nothing else here will ever
---remove a batch, and a store nothing removes from grows for the life of the state
---directory.
M.ARCHIVE_LIMIT = 20

---How many times an archive has changed this session.
---
---What a projection of the archive onto a diff's anchors can be rebuilt from without a file
---read. That projection is handed to every repaint, and a repaint runs on every resize,
---expansion, reviewed toggle and scope change -- so decoding the document there would put
---the cost of the whole archive back onto the operation bounding extmark emission exists to
---keep cheap, and it would scale with what is stored rather than with what is drawn.
---
---Moved by everything that can change one: a dispatch, which is the only thing that writes
---an archive, and forgetting a store. Declared here rather than beside them because a Lua
---local is only in scope below itself, and one of those sits above the archive's own
---section. Not persisted and meaningless across processes -- what it answers is "has it
---changed since you last looked", which has no answer before you have looked, and a session
---reads the archive once anyway.
local archive_writes = 0

---@return integer
function M.archive_writes()
  return archive_writes
end

---@param root string
---@return string
function M.path(root)
  -- Basename for readability plus a hash of the full path, so two checkouts of the same
  -- repository do not share a progress file.
  local name = ("%s-%s"):format(vim.fn.fnamemodify(root, ":t"), vim.fn.sha256(root):sub(1, 10))
  return vim.fs.joinpath(vim.fn.stdpath("state"), "codereview", name .. ".json")
end

---@param root string
---@return table
function M.load(root)
  local file = M.path(root)
  if vim.fn.filereadable(file) == 0 then
    return { version = VERSION, scopes = {}, queue = {}, archive = {}, trims = {} }
  end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"), {
      luanil = { object = true, array = true },
    })
  end)
  if not ok or type(decoded) ~= "table" or decoded.version ~= VERSION then
    -- A corrupt or older file is discarded rather than migrated: the cost of losing
    -- review progress is far lower than the cost of restoring marks that mean something
    -- different than they did when written.
    return { version = VERSION, scopes = {}, queue = {}, archive = {}, trims = {} }
  end
  decoded.scopes = decoded.scopes or {}
  decoded.queue = decoded.queue or {}
  -- A document written before the archive existed lacks the key entirely, and defaulting
  -- it here is the whole of what it takes to read one: nothing about the marks stored
  -- beside it means anything different than it did. The **trims** arrived the same way,
  -- for the same reason -- a bump would throw away every reviewed mark in the file to add
  -- a key those files simply lack.
  decoded.archive = decoded.archive or {}
  decoded.trims = decoded.trims or {}
  -- The **checkout** and the save stamp are deliberately *not* defaulted here, though they
  -- arrived exactly as those two did. A document written before them has neither, and that
  -- absence is the whole of what keeps it out of a **sweep**: defaulted, it would reach the
  -- sweep either claiming to be about wherever it was loaded from or claiming an age of
  -- 1970, and either answer removes a document nothing knows anything about.
  return decoded
end

---@param root string
---@param data table
---@return boolean ok
function M.save(root, data)
  local file = M.path(root)
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  -- The two keys a **sweep** reads, written here rather than by each caller: every write of
  -- a document comes through this function, and a key set anywhere else is a key some other
  -- write silently drops.
  --
  -- The **checkout**, because the file name keeps a base name and a hash of the full path
  -- and the path cannot be recovered from either. The stamp, because a document may hold
  -- nothing but reviewed marks and trims, and the entries in it are not what a document's
  -- age is. Neither is a reason to bump `VERSION`: an older document simply lacks both,
  -- exactly as it lacks the archive and the trims.
  data.checkout = root
  data.saved = os.time()
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    return false
  end
  return pcall(vim.fn.writefile, { encoded }, file)
end

--- The store for annotations with no repository ---------------------------------

---How long an annotation with no repository behind it survives.
---
---Nothing else will ever remove one. The per-repository store is reconciled against a
---diff, which is the moment an entry can be judged obsolete; this store never is, so
---without a sweep it grows for the life of the editor's state directory. Matches the
---window the host config's draft store uses, for the same reason.
local GLOBAL_TTL_SECONDS = 7 * 24 * 60 * 60

---@return string
function M.global_path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "codereview", "no-repository.json")
end

---Directories already resolved, keyed by what was asked about.
---
---A directory per distinct string ever compared, rather than a `realpath` per entry per
---write: progress is written on every mutation, and a queue routinely holds several entries
---about one checkout. The same shape, and the same reason, as the **target**'s working
---directory being resolved once per submit rather than once per `@ref`.
local resolved = {}

---@param path string
---@return string
local function canonical(path)
  local hit = resolved[path]
  if not hit then
    -- Falls back to what it was given, which is what keeps a directory that has since been
    -- deleted comparable with itself rather than with nothing.
    hit = vim.uv.fs_realpath(path) or path
    resolved[path] = hit
  end
  return hit
end

---The **checkout** an entry is about: its absolute path with its repository-relative path
---removed.
---
---Derived from what the entry already carries rather than asked of git. Both halves have
---been on it since it was captured, and a `git rev-parse` per entry would be a process per
---annotation on every write, for an answer that cannot have changed.
---
---Resolved before it is handed back, and this is not belt and braces. `git rev-parse
-----show-toplevel` answers with symlinks resolved and buffer capture realpaths to match, so
---the two agree wherever the plugin built both -- but on macOS a directory reached through
---`/var` is a symlink into `/private/var`, and an entry whose absolute path arrived any
---other way would then be about a checkout that no root can ever equal. What that costs is
---an annotation quietly filed nowhere, which is the failure this whole slice exists to
---remove.
---@param item CRAnnotation
---@return string|nil checkout nil for an entry with no repository behind it
local function checkout_of(item)
  if not item.path or not item.abs_path then
    return nil
  end
  local suffix = "/" .. item.path
  if item.abs_path:sub(-#suffix) ~= suffix then
    return nil
  end
  return canonical(item.abs_path:sub(1, #item.abs_path - #suffix))
end

---Split the queue by the checkout each entry is about.
---
---Three lists, not two. Having a repository-relative path is no longer the whole test:
---a checkout keeps its own store, so an entry is filed under the checkout it is *about*
---and never under the one the reviewer happens to be in. Two worktrees of one repository
---hold the same repository-relative path, so the path alone cannot tell them apart -- the
---absolute path is what does.
---
---  * **owned** -- about this checkout, and filed in its document.
---  * **loose** -- no repository behind it at all: a capture outside every checkout and a
---    **bare note** both lack a repository-relative path, and both are exactly the entries
---    with nowhere repository-shaped to live. They go to the one store that needs no root.
---  * **elsewhere** -- about another checkout, which is reachable by annotating a file that
---    is not in the checkout you are in. Filed nowhere: writing it here would be the
---    misfiling this split exists to refuse, and writing it into a queue that is not being
---    shown would overwrite entries nothing has read back. The reviewer is told -- see
---    `say_unfiled`.
---@param items CRAnnotation[]
---@param root string|nil The checkout being written; nil outside every checkout, where
---       nothing with a repository behind it can be filed at all
---@return CRAnnotation[] owned, CRAnnotation[] loose, CRAnnotation[] elsewhere
local function partition(items, root)
  local owned, loose, elsewhere = {}, {}, {}
  -- Both sides through one resolver. A root arrives from `git rev-parse` or off a review,
  -- so it is already resolved; putting it through anyway is what stops the comparison
  -- depending on which of the two it came from.
  root = root and canonical(root) or nil
  for _, item in ipairs(items) do
    if not item.path then
      loose[#loose + 1] = item
    elseif root and checkout_of(item) == root then
      owned[#owned + 1] = item
    else
      elsewhere[#elsewhere + 1] = item
    end
  end
  return owned, loose, elsewhere
end

---Whatever is still inside the window, by each record's own stamp.
---
---One rule for the queued annotations and the archived batches alike: both are stamped
---when written, and neither has anything else that could ever decide it is finished with.
---@param records table[]|nil
---@param now integer
---@return table[]
local function unswept(records, now)
  local fresh = {}
  for _, record in ipairs(records or {}) do
    if type(record) == "table" and (now - (record.at or 0)) < GLOBAL_TTL_SECONDS then
      fresh[#fresh + 1] = record
    end
  end
  return fresh
end

---The whole store, swept.
---
---Read as one document rather than one key at a time, because a write has to put the
---other key back: `save_global` used to encode the queue and nothing else, which with an
---archive beside it would delete a dispatched batch every time an annotation was queued.
---@return { queue: CRAnnotation[], archive: CRBatch[] }
local function read_global()
  local file = M.global_path()
  if vim.fn.filereadable(file) == 0 then
    return { queue = {}, archive = {} }
  end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"), {
      luanil = { object = true, array = true },
    })
  end)
  if not ok or type(decoded) ~= "table" or decoded.version ~= VERSION then
    return { queue = {}, archive = {} }
  end

  -- The sweep, on load rather than on a timer: this is the only moment the store is
  -- read, so it is the only moment anything is in a position to drop from it.
  local now = os.time()
  return { queue = unswept(decoded.queue, now), archive = unswept(decoded.archive, now) }
end

---@param doc { queue: CRAnnotation[], archive: CRBatch[] }
---@return boolean ok
local function write_global(doc)
  local file = M.global_path()
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local ok, encoded = pcall(vim.json.encode, { version = VERSION, queue = doc.queue, archive = doc.archive })
  if not ok then
    return false
  end
  return pcall(vim.fn.writefile, { encoded }, file)
end

---@return CRAnnotation[]
function M.load_global()
  return read_global().queue
end

---The batches dispatched with nothing repository-shaped in them, newest first.
---@return CRBatch[]
function M.global_archive()
  return read_global().archive
end

---@param items CRAnnotation[]
---@return boolean ok
function M.save_global(items)
  local now = os.time()
  for _, item in ipairs(items) do
    -- Stamped once and then left alone. Refreshing it on every write would restart the
    -- clock each time anything else was queued, and nothing would ever age out.
    item.at = item.at or now
  end

  local doc = read_global()
  doc.queue = items
  return write_global(doc)
end

---Forget every annotation with no repository behind it, queued or already dispatched.
function M.clear_global()
  local file = M.global_path()
  if vim.fn.filereadable(file) == 1 then
    vim.fn.delete(file)
  end
  archive_writes = archive_writes + 1
end

--- The trim ---------------------------------------------------------------------

---The **trim** on a branch's review: the commits it takes out, by full sha.
---
---The commits **taken out** and never the commits kept, so a commit made after a trim is in
---the review the moment it is made. That is the same reason the `last N` count is derived
---rather than remembered: anything about the review recorded at pick time keeps describing
---the branch as it was then.
---
---A set and not the ref the review reads from, which is what this held before it was a set.
---What a trim leaves a review reading is worked out from the set when the **scope** is
---resolved, because the two answer different questions -- one is what the reviewer chose,
---the other is where that lands on this branch today -- and a second copy of the second one
---in the document is a second thing that has to stay true through every commit, rebase and
---checkout.
---
---Full shas, because an abbreviation is not an identity: git picks its length from the size
---of the repository, and a trim outlives the size it was stored at.
---
---**Kept in the state document, keyed by branch name**, beside the reviewed marks it is a
---review of. A review spans days, so a reviewer who trimmed on Monday opens the same branch
---on Tuesday where their reading stopped. Keyed by the branch rather than by the repository
---because two branches are two readings: trimming one says nothing about the other.
---
---The sentences below are said here, which is the one place in this module that says
---anything. Both are about the **store** and nothing above it can see either fact -- by the
---time a scope is resolved the trim is either usable or gone -- and saying them here is also
---what keeps one sentence one sentence: the surfaces that read a trim are the review and the
---commit list, and a rule copied into both is a rule that says it twice.
---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

---A trim set while `HEAD` is detached, which has no branch name to key on.
---
---It works for the session and reaches no document, because there is nothing to file it
---under: the next session may be anywhere. Keyed by root, which is all there is.
local session_trims = {}

---Roots already told that a detached `HEAD` keeps no trim.
---
---Said once, when a trim is set. Of the three cases where a trim is refused or limited this
---is the only one a reviewer could take for a defect -- the other two say what they refused
---at the moment they refuse it, and this one refuses nothing until the session ends.
local said_detached = {}

---@param root string
---@param branch string
---@param skipped string[]|nil nil removes it
local function store_trim(root, branch, skipped)
  local data = M.load(root)
  data.trims = data.trims or {}
  data.trims[branch] = skipped
  M.save(root, data)
end

---The branch's trim, checked before it is handed back.
---
---**The check is the point of storing it at all.** Every commit in the set has to still be
---one `HEAD` descends from; a rebase, an amend or a force-push leaves the set holding a
---commit that was rewritten, and a review that quietly resolves around one of those is worse
---than no trim.
---
---**Any commit failing it drops the whole set.** A rebase rewrote the reading, not one row
---of it: keeping the commits that survived would leave the review narrowed by a selection
---the reviewer never made, and which parts of a rewritten history are still the same reading
---is a claim nothing here can make. A trim that fails is dropped from the document as well
---as from this answer, which is what makes the sentence a reviewer reads a single sentence
---rather than one per resolve: there is nothing left to fail the next time.
---
---Checked on every read rather than once per session, because the history can be rewritten
---while a review is open -- a reviewer rebases in another window and comes back to the diff.
---@param root string
---@return string[]|nil skipped nil when the whole branch is in the review
function M.trim(root)
  local git = require("codereview.git")
  local branch = git.current_branch(root)
  if not branch then
    return session_trims[root]
  end

  local stored = (M.load(root).trims or {})[branch]
  if not stored or git.all_ancestors(stored, root) then
    return stored
  end
  store_trim(root, branch, nil)
  info("The trim was lost — a commit it took out is not in this branch any more, so the full branch is open")
  return nil
end

---@param root string
---@param skipped string[]|nil The commits to take out; nil removes the trim
function M.set_trim(root, skipped)
  local branch = require("codereview.git").current_branch(root)
  if not branch then
    session_trims[root] = skipped
    if skipped and not said_detached[root] then
      said_detached[root] = true
      info("HEAD is detached — this trim is not kept for the next session")
    end
    return
  end
  store_trim(root, branch, skipped)
end

--- The archive ------------------------------------------------------------------

---Add a batch to an archive, dropping the oldest once it is full.
---
---Newest first, because every reader of an archive wants the newest: the scope that diffs
---against a snapshot only ever reads that one, and the rest is there to be read back.
---@param archive CRBatch[]
---@param batch CRBatch
local function push(archive, batch)
  table.insert(archive, 1, batch)
  -- A loop rather than one removal, so a store written when the bound was larger comes
  -- back down instead of staying over it forever.
  while #archive > M.ARCHIVE_LIMIT do
    table.remove(archive)
  end
end

---Record a batch that has just been dispatched.
---
---Called on a dispatch and on nothing else (ADR-0005). An adapter that refused, one that
---raised, and the register the shipped default copies to all leave the archive exactly as
---they leave the queue -- a payload sitting in a register is not something an agent
---received. An **immediate send** is a batch of one (ADR-0004) and arrives here as one,
---with no special case.
---
---Split across the two stores on the rule that already routes the queue: an entry with a
---repository-relative path belongs to that repository, and a bare note or a file outside a
---checkout belongs to the store that needs no root. A batch holding both is recorded in
---both, because that is where its entries live.
---@param items CRAnnotation[] The batch as it went
---@param target string Short name of where it went, as every piece of chrome names it. The
---       label rather than the target itself: a host's target may carry anything at all,
---       functions included, and one that will not JSON-encode would take the whole
---       document's write down with it.
---@param root string|nil nil outside a repository, where only the global store applies
---@param preamble string|nil The prose the batch went out under, as the payload rendered it
---       -- nil where it rendered nothing, because the record is of what was sent. Written
---       to both halves rather than to either: a preamble is about the **dispatch**, exactly
---       as the stamp and the target are, and neither half is the thing it was written
---       about.
function M.archive_batch(items, target, root, preamble)
  local owned, loose, elsewhere = partition(items, root)
  -- An archive records what was *sent*, and everything in the batch went. So the split
  -- here stays the one it has always been -- a repository-relative path to the repository's
  -- own document -- and an entry about another checkout is recorded beside the rest rather
  -- than left out of the record of its own dispatch. What produces such an entry is a
  -- capture rooted in the working directory instead of in the review, which is what
  -- ADR-0008 removes; there is nothing for this file to do about it that does not cost the
  -- record more than it buys.
  vim.list_extend(owned, elsewhere)
  -- One stamp for the batch, taken once: the two stores are recording the same dispatch.
  local at = os.time()
  -- Once for the dispatch rather than once per store, and before the writes rather than
  -- after them: what this says is "an archive is not what you last read", and a partial
  -- write is already not what you last read.
  archive_writes = archive_writes + 1

  if #loose > 0 then
    local doc = read_global()
    -- No snapshot: these entries have no repository whose working tree could be recorded,
    -- and a snapshot of whichever checkout happened to be current would describe nothing
    -- they are about.
    push(doc.archive, { at = at, target = target, preamble = preamble, entries = loose })
    write_global(doc)
  end

  if not root or #owned == 0 then
    return
  end
  local data = M.load(root)
  push(data.archive, {
    at = at,
    target = target,
    -- Minted here rather than handed in. The snapshot is the working tree at the moment of
    -- dispatch, and it is only that if it is taken at that moment.
    snapshot = require("codereview.git").snapshot(root),
    preamble = preamble,
    entries = owned,
  })
  M.save(root, data)
end

---The batches already dispatched from a repository, newest first.
---
---Entries with nothing repository-shaped about them are in `global_archive` instead, for
---the same reason they queue there: there is no root to key a document against.
---@param root string|nil
---@return CRBatch[]
function M.archive(root)
  return root and M.load(root).archive or {}
end

---The batch a repository dispatched last, or nil when it has never dispatched one.
---
---One query rather than a `[1]` at each caller, and here rather than on either caller
---because both of them are already above this module. Two things ask it, and they ask it
---about the same dispatch: the `since-batch` scope, which diffs the working tree against
---that batch's **snapshot**, and the surface that lists that batch's **entries**. A
---reviewer reads one beside the other, so a disagreement about which batch is newest would
---put the response to one dispatch on screen with the annotations of another beside it,
---and nothing would say so. Two copies of `[1]` are what that drift looks like before it
---happens -- the same reason the payload renderer and the queue float group through one
---helper rather than two that agreed at the time.
---
---The repository's record only, which is what makes it the right answer for a caller that
---needs a snapshot: a snapshot can only ever belong to the half with a repository behind
---it. A batch that also held a **bare note** is recorded in the store that needs no root as
---well, and `archive.last` is what rejoins the two for a surface that has to list every
---entry.
---@param root string|nil
---@return CRBatch|nil
function M.last_batch(root)
  return M.archive(root)[1]
end

---The highest id any archived entry carries, across every archive given.
---
---Which is what the queue's counter has to resume past. See `queue.seed`.
---@param archives CRBatch[][]
---@return integer
local function highest_archived_id(archives)
  local highest = 0
  for _, archive in ipairs(archives) do
    for _, batch in ipairs(archive) do
      for _, entry in ipairs(batch.entries or {}) do
        highest = math.max(highest, entry.id or 0)
      end
    end
  end
  return highest
end

--- Writing and reading ----------------------------------------------------------

---Annotations the reviewer has already been told cannot be filed, by id.
---
---Said once for each, and never again. Progress is written on every mutation, so a
---sentence said per write would be said again on the next annotation, the next reviewed
---mark and the next drop -- about an entry the reviewer has already heard about and can do
---nothing more about until they are in its checkout.
local said_unfiled = {}

---Say that annotations are in the queue with nowhere to be saved.
---
---In the queue's own wording, because it is a fact about entries in the queue rather than
---about this file's stores, and here because nothing above this module can see it: by the
---time a write returns, an entry that was filed and one that was not look exactly alike.
---@param elsewhere CRAnnotation[]
local function say_unfiled(elsewhere)
  local fresh = 0
  for _, item in ipairs(elsewhere) do
    if item.id and not said_unfiled[item.id] then
      said_unfiled[item.id] = true
      fresh = fresh + 1
    end
  end
  if fresh > 0 then
    info(queue.unfiled_phrase(fresh))
  end
end

---Write the view's progress and the current queue.
---
---Merged over the stored document rather than rebuilt from the view. A view only knows the
---scopes it has itself opened -- `open` seeds `per_scope` with one key and `set_scope`
---adds one per scope cycled to -- so building the whole table from it wrote every other
---scope out of existence. Review a branch on Monday, open only `staged` on Tuesday, and
---Monday's reviewed marks were gone the first time anything touched the file.
---@param view CRView
function M.persist(view)
  local owned, loose, elsewhere = partition(queue.all(), view.root)
  M.save_global(loose)
  say_unfiled(elsewhere)

  local data = M.load(view.root)
  data.queue = owned
  data.scopes = data.scopes or {}
  for key, entry in pairs(view.per_scope) do
    -- `expanded` is deliberately not persisted: it is a transient way of peeking at a
    -- file, and restoring it would contradict the reviewed marks that drive collapse.
    --
    -- An emptied scope is written as absence rather than skipped. Skipping was harmless
    -- when the table was rebuilt every time; against a merge it would hand back the marks
    -- that were just un-marked. Only keys this view actually knows about are touched --
    -- one it has never opened is not evidence of anything.
    data.scopes[key] = not vim.tbl_isempty(entry.reviewed) and { reviewed = entry.reviewed } or nil
  end

  M.save(view.root, data)
end

---Write just the queue, leaving the rest of the document alone.
---
---For a capture made with no review view open. Such a capture has no `per_scope` to build
---a scopes table from, so writing a whole document the way `persist` does would blank the
---reviewed marks a review saved -- the queue would survive at the cost of the progress
---next to it.
---@param root string|nil nil when the working directory is not inside a repository, in
---       which case there is only the global store to write
function M.persist_queue(root)
  local owned, loose, elsewhere = partition(queue.all(), root)
  M.save_global(loose)
  say_unfiled(elsewhere)
  if not root then
    return
  end
  local data = M.load(root)
  data.queue = owned
  M.save(root, data)
end

---Load the queue from disk when nothing has been captured in this session yet.
---
---Separate from `restore`, which needs a view and a scope to put reviewed marks back.
---The queue needs neither: it is what you submit, not what you are looking at.
---@param root string|nil nil outside a repository, where only the global store applies
---@return integer staled
function M.restore_queue(root)
  -- The queue this restores is the queue the reviewer has from here on. A restore is how a
  -- checkout's entries are reached at all, so pointing at it here is what keeps the two in
  -- step -- the alternative is a caller that reads back one checkout's store and is then
  -- shown another's.
  queue.use(root)

  -- The guard, once per store rather than once for the pair. This checkout may already
  -- hold entries this session queued, and so may the store that needs no root -- and the
  -- two are independent, because every checkout shows the same loose entries. Asked of the
  -- whole queue instead, a reviewer holding one bare note would stop every checkout they
  -- visited from ever reading its own store, and reading the loose store per checkout would
  -- queue every loose entry again on the second one.
  local read_owned = queue.count_in(root) == 0
  local read_loose = queue.loose_count() == 0
  if not read_owned and not read_loose then
    return 0
  end

  -- Both stores, as one queue. Which store an entry came from is a persistence detail; the
  -- queue is the queue.
  local loose = read_global()
  local data = root and M.load(root) or nil
  if read_owned then
    queue.replace(root, data and data.queue or {})
  end
  if read_loose then
    queue.replace_loose(loose.queue)
  end
  -- Taken once both stores have been read, because an id is unique across the pair and the
  -- entries carrying one are split between them. Restoring the queue alone is not enough:
  -- a session that dispatched everything it queued restores nothing at all and still has
  -- ids on the diff to keep clear of. This checkout's archive, because the counter is one
  -- counter that only rises: each checkout lifts it past its own archive as it is read
  -- back, and none of them can ever lower it past another's.
  queue.seed(highest_archived_id({ data and data.archive or {}, loose.archive }))
  if not root then
    return 0
  end
  -- Judged as it comes back. This is the window staleness exists to cover: the file was
  -- free to change while nothing was watching it, and a restored note that still claims a
  -- line span is exactly the silent wrongness one queue was supposed to remove.
  return M.reconcile_queue(root)
end

---The **checkout** everything resolves against: the review's own when one is open, and the
---working directory's otherwise.
---
---Public because more than the restore has to ask it. Writing the queue with nothing open,
---emptying it after a submit and reading the last **batch** back all name a checkout, and a
---second copy of the question is a second chance to answer it differently.
---
---**The review wins, which is ADR-0008 in one line.** The two answers agreed until a
---**switch** existed, because a review could only ever be opened where the reviewer was
---standing. After a switch the working directory is still the checkout they are standing
---*in*, so reading it would file the review's annotations in that checkout's store and read
---that checkout's archive back under this review -- the corruption the per-checkout queue
---exists to remove, reached through a door the switch opened.
---
---The review tab's own directory is not consulted either, though it holds the same answer
---and looks equivalent: Neovim silently resets a tab's local directory to the global one
---once that directory is deleted, and fires no `DirChanged` when it does. `V.root` is the
---authority and the `:tcd` beside it is a courtesy to the **host**.
---
---**The fall-through is on the redraw path, so it is memoised.** The queued count asks
---this question first, and a statusline asks the count on every redraw. A review being
---open is answered from `V.root` and costs nothing at all; with none open the working
---directory goes through `git.root_cached`, which spawns one git process per checkout ever
---seen rather than one per redraw.
---
---The view is required function-locally, as `git` is above: the two require each other, and
---Lua resolves a require inside a function lazily.
---@return string|nil checkout nil outside every checkout, with no review open
function M.current_checkout()
  local view = require("codereview.view").current()
  if view then
    return view.root
  end
  -- A tab whose own local directory has been deleted reports no working directory at all,
  -- and fires no `DirChanged` when it happens -- the finding the paragraph above rests on,
  -- one step further along. Neovim adopts the global directory when that tab is next
  -- entered, and the event that arrives then is the one for leaving it, so this reads the
  -- same answer one moment earlier. Without it the empty string reads as "outside every
  -- checkout" everywhere: the count drops to the entries that belong to no checkout, and
  -- `persist_queue` files everything owned as an entry about somewhere else.
  --
  -- The tab-local read is no help either: `getcwd(0, 0)` still answers the directory that
  -- is gone, which is the paragraph above's lie wearing the other hat.
  local cwd = vim.fn.getcwd()
  if cwd == "" then
    cwd = vim.fn.getcwd(-1, -1)
  end
  return require("codereview.git").root_cached(cwd)
end

-- Restored lazily, and once per **checkout**. Eagerly at startup is worse, because the
-- working directory that decides which checkout's queue to load may not be the one the user
-- ends up in.
--
-- The queued count does not come through here at all, and that is the rule rather than an
-- oversight: a statusline asks it on every redraw, and a state file read per redraw is not
-- an option. It reports what the queue holds for a checkout rather than what that checkout's
-- store holds, so a checkout reached by a bare directory change counts 0 until the next
-- capture, submit, copy or queue float reads it back.
--
-- Per checkout rather than per session, or the second checkout a session visits never reads
-- its own store: the latch was set by the first, so unsent work in the second is invisible
-- for the rest of the session and is then written over.
---@type table<string, boolean>
local queue_restored = {}

---The key a latch is held under outside every checkout, where there is still a queue to
---read back -- the store that needs no root -- and nil is not a table key.
local NO_CHECKOUT = ""

---Load the persisted queue if this session has not seen it yet.
---
---Public because adding to the queue has to be able to demand it, not just reading it:
---`persist_queue` writes memory over the document, so anything that queues an annotation
---before the session has read the queue back would silently drop what the last session
---left. Capture makes that reachable as the very first thing a session does.
---
---Counted rather than announced, as reconciliation is: how many restored annotations are
---untrustworthy is a fact about the store, and the sentence a reviewer reads belongs to
---whichever surface asked.
---@return integer staled 0 once this checkout's queue has already been read back
function M.ensure_queue()
  return M.ensure_queue_for(M.current_checkout())
end

---The same read-back, for a checkout named rather than resolved.
---
---What a review opening uses. A **switch** is how a session reaches a checkout it has never
---read, and that checkout is owed everything a first visit owes: its stored queue, the
---entries that belong to no checkout, the latch that stops the next resolved read pointing
---the queue somewhere else, and the id counter lifted past what its own **archive** already
---draws on the diff. Reaching for the parts of that separately is how a second, quieter
---restore comes into existence beside this one.
---@param root string|nil nil outside every checkout, where the store needing no root still
---       has to be read
---@return integer staled 0 once this checkout's queue has already been read back
function M.ensure_queue_for(root)
  if queue_restored[root or NO_CHECKOUT] then
    -- Still pointed at, and this is the whole of what a return to a checkout costs: its
    -- entries never left memory, so what is owed is the queue being the one this checkout
    -- is about rather than the one the reviewer was last shown.
    queue.use(root)
    return 0
  end
  queue_restored[root or NO_CHECKOUT] = true
  -- No root is not a reason to skip: annotations with no repository behind them live in a
  -- store that does not need one, and they would otherwise never come back.
  return M.restore_queue(root)
end

---Restore saved progress into a freshly opened view.
---@param view CRView
---@param scope_key string
function M.restore(view, scope_key)
  -- The review's own checkout, which is the checkout its queue is about (ADR-0008). The
  -- working directory is not asked: what a review is reading is the review's to say.
  --
  -- The whole read-back rather than a queue swap of its own. A **switch** can open a review
  -- in a checkout this session has never touched, and half a restore there is worse than
  -- none: the latch would stay unset and the next resolved read would move the queue back
  -- to the checkout the reviewer is standing in, the loose entries would not ride along,
  -- and an annotation made here could take an id this checkout's archive already draws.
  --
  -- The count it returns is deliberately dropped. `view.open` calls `reconcile` immediately
  -- after this, and `reconcile` judges the same entries again and reports what it finds --
  -- so a sentence said here would be that same sentence said twice. A return to a checkout
  -- reports staleness in the existing wording and adds no sentence of its own.
  M.ensure_queue_for(view.root)

  local data = M.load(view.root)
  local saved = data.scopes and data.scopes[scope_key]
  if saved and saved.reviewed then
    for path, blob in pairs(saved.reviewed) do
      view.reviewed[path] = blob
      view.expanded[path] = false
    end
  end
end

---Judge working-tree annotations against the files on disk.
---
---These are the captures that have no scope behind them, so the diff-based rule never
---reaches them: it only judges what the current scope includes, which is correct for a
---review annotation and means a buffer annotation about an unrelated file would never be
---checked at all. Judged here at any scope, and with no view open.
---@param root string
---@return integer staled
function M.reconcile_queue(root)
  local git = require("codereview.git")

  local paths = {}
  for _, item in ipairs(queue.all()) do
    if item.worktree and item.path then
      paths[#paths + 1] = item.path
    end
  end
  if #paths == 0 then
    return 0
  end

  local hashes = git.hash_worktree(paths, root)
  local staled = 0
  for _, item in ipairs(queue.all()) do
    if item.worktree and item.path then
      -- A file that has been deleted hashes to nothing, which is at least as stale as one
      -- that merely changed: the lines the note names are gone either way.
      local moved = hashes[item.path] ~= (item.blob or "")
      item.stale = moved or nil
      if moved then
        staled = staled + 1
      end
    end
  end
  return staled
end

---Reconcile restored state against the diff that is actually on screen.
---
---Only files present in the current scope are judged: a file the scope does not include
---is not evidence that anything changed, and guessing from its absence would clear marks
---that are still correct.
---@param view CRView
---@return integer unmarked, integer staled
function M.reconcile(view)
  local by_path = {}
  for _, file in ipairs(view.files) do
    by_path[file.path] = file
  end

  local unmarked = 0
  for path, blob in pairs(vim.deepcopy(view.reviewed)) do
    local file = by_path[path]
    if file and (file.blob or "") ~= blob then
      view.reviewed[path] = nil
      view.expanded[path] = nil
      unmarked = unmarked + 1
    end
  end

  local staled = 0
  for _, item in ipairs(queue.all()) do
    -- A working-tree capture is judged below instead, against the file on disk. Judging it
    -- here as well would compare it against whichever blob this scope happens to show --
    -- the index, in a staged review -- and flag an annotation about a file nobody has
    -- touched since it was captured. Two rules that disagree, applied to one entry.
    local file = not item.worktree and by_path[item.path]
    if file then
      local moved = (file.blob or "") ~= (item.blob or "")
      item.stale = moved or nil
      if moved then
        staled = staled + 1
      end
    end
  end

  return unmarked, staled + M.reconcile_queue(view.root)
end

---Judge the newest archived batch's files against the code its batch went out with.
---
---**Touchedness is not staleness, and the two must never become one flag.** Sharing the
---blob comparison is the whole of what they share. Staleness judges a *queued* entry
---against the blob it was **captured** with and means *my note may be wrong*; this judges
---an *archived* entry against the working tree as it stood when its batch was
---**dispatched** and means *the agent has been here*. One flag would say both and neither:
---an entry captured on Monday, edited by the reviewer on Tuesday and dispatched on
---Wednesday is stale and untouched at once, and each read off the other is wrong in the
---direction that looks fine.
---
---**Judged against the snapshot, not against the entry's own blob.** That blob is the
---capture blob, so a file the reviewer themselves edited between annotating it and
---submitting would count as the agent's work -- and it would make this comparison
---arithmetically identical to the staleness one, which is how two rules become one by
---accident rather than by decision. The snapshot is what the archive already records the
---dispatch as, so there is no second copy of that fact to drift from it, and it is what
---`since-batch` diffs against: the tally and the diff a reviewer reads it beside therefore
---describe one dispatch by construction.
---
---**Per file, not per anchor.** Mapping an entry's line range through the diff since the
---snapshot is considerably more machinery and the case it improves stays fuzzy either way.
---The signal worth having is *the agent never opened this file*, and that one is exact
---under a per-file rule.
---
---Two batched calls, neither of which grows with the number of files -- `hash-object` for
---the working tree and `cat-file --batch-check` for the snapshot, exactly as the two sides
---of a diff are already hashed. One process per file was measurably more expensive than
---every treesitter operation combined.
---
---Three things are left unjudged rather than guessed at:
---  * a file the current scope does not cover, because absence from a scope is not evidence
---    that anything changed -- the rule `reconcile` already holds;
---  * a path the snapshot does not carry, which is a file untracked at dispatch: `git stash
---    create` records none of those, so the snapshot has nothing to say about it;
---  * a **bare note**, which is about no file at all. It lives in the store that needs no
---    root and never reaches this one.
---@param root string
---@param files CRFile[] The scope on screen, which is what decides who is judged
---@return table<integer, boolean> touched Keyed by entry id; an absent id was not judged
---@return integer|nil untouched How many judged entries' files have not moved, or nil when
---        nothing could be judged at all
function M.reconcile_archive(root, files)
  local batch = M.last_batch(root)
  if not batch or not batch.snapshot then
    return {}, nil
  end

  local in_scope = {}
  for _, file in ipairs(files) do
    in_scope[file.path] = true
  end

  -- Distinct paths: one batch routinely holds several entries about one file, and hashing
  -- a path once per entry is exactly the per-file cost the batching exists to avoid.
  local paths, seen = {}, {}
  for _, entry in ipairs(batch.entries or {}) do
    if entry.path and in_scope[entry.path] and not seen[entry.path] then
      seen[entry.path] = true
      paths[#paths + 1] = entry.path
    end
  end
  if #paths == 0 then
    return {}, nil
  end

  local git = require("codereview.git")
  local now = git.hash_worktree(paths, root)
  local specs = {}
  for i, path in ipairs(paths) do
    specs[i] = ("%s:%s"):format(batch.snapshot, path)
  end
  local sent = git.hash_refs(specs, root)

  local moved = {}
  for i, path in ipairs(paths) do
    local was = sent[specs[i]]
    if was then
      -- A file deleted since the dispatch hashes to nothing, and nothing is as moved as a
      -- rewrite: what the note was about is not there either way.
      moved[path] = now[path] ~= was
    end
  end

  local touched, untouched = {}, nil
  for _, entry in ipairs(batch.entries or {}) do
    if entry.id and entry.path and moved[entry.path] ~= nil then
      touched[entry.id] = moved[entry.path]
      untouched = (untouched or 0) + (moved[entry.path] and 0 or 1)
    end
  end
  return touched, untouched
end

---Forget everything saved for a repository.
---@param root string
function M.clear(root)
  local file = M.path(root)
  if vim.fn.filereadable(file) == 1 then
    vim.fn.delete(file)
  end
  -- The archive went with it, so anything holding a projection of it is holding entries
  -- that no longer exist -- and would go on drawing them until the next dispatch.
  archive_writes = archive_writes + 1
end

--- Sweeping orphaned state ------------------------------------------------------

---How long the state of a checkout that is gone is kept before a sweep may take it.
---
---Seven days, which is the number the store that needs no root and the draft store both
---carry -- and a different rule wearing it. Those two are lifetimes for stores nothing else
---ever prunes: they age out on their own or they grow forever. This one is a grace period,
---and it stands beside two other conditions rather than alone, so it gets a constant of its
---own rather than borrowing one of theirs.
---
---**It measures time without a write, not time missing.** The stamp it reads is rewritten
---on every save, and only a mutation saves -- opening a review does not, and closing one
---does not -- so a checkout last written to nine days ago and deleted a minute ago has no
---protection here at all. The design notes say what that costs and why the alternative was
---refused.
local ORPHAN_GRACE_SECONDS = 7 * 24 * 60 * 60

---A document whose checkout is **orphaned** and whose state may be discarded, or nil.
---
---Every condition in one place, so nothing can hold three of them and forget the fourth.
---@param file string The document being examined
---@param now integer
---@return table|nil doc The decoded document, when it may be swept
local function sweepable(file, now)
  local ok, doc = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"), {
      luanil = { object = true, array = true },
    })
  end)
  if not ok or type(doc) ~= "table" or doc.version ~= VERSION then
    return nil
  end

  -- Written before this file recorded either key. Such a document says neither which
  -- checkout it is about nor when it was last written, so there is nothing here to test and
  -- it is left alone -- for good, because the only way to gain the two keys is to be saved
  -- again, and a checkout that is gone is never saved again.
  --
  -- **This is also what leaves the sweep needing no list of files to leave alone.** The
  -- store that needs no root and the drafts beside it share this directory and are not
  -- checkout documents; both are turned away right here, before anything below has seen
  -- them. A list would be a third copy of where those two live.
  --
  -- **And it stops a raise, not only a wrong sweep.** Delete it and a document carrying a
  -- checkout with no stamp reaches the age test below, where `now - nil` raises: an error
  -- outside an `it` in a spec, and an error on every **switch** in an editor. `sweep_spec`
  -- keeps a document of exactly that shape, because that is the only way this half of the
  -- test is held on its own.
  if type(doc.checkout) ~= "string" or type(doc.saved) ~= "number" then
    return nil
  end

  -- The stored path is a second copy of what the file name already hashes, so it is checked
  -- against it rather than trusted: a state directory carried between machines names paths
  -- that mean nothing here, and a file written half way names anything at all.
  --
  -- What this refuses is a document filed under one checkout and naming another, and that
  -- is all it refuses. It is **not** what keeps the two stores above out of a sweep -- they
  -- are gone before this line runs. It would refuse them if they reached it, because
  -- `M.path(nil)` does not raise but answers `v:null-<hash>.json`, which no document is
  -- ever filed under -- and that is a true sentence about a path nothing ever takes.
  if M.path(doc.checkout) ~= file then
    return nil
  end

  -- Already read back, and memory is the truth. A checkout this session has read keeps its
  -- entries whether its directory is there or not, and the next write about it puts the
  -- document straight back -- so taking it here would report unsent work as destroyed while
  -- that work sits in the queue and in the number a statusline shows. It is also what keeps
  -- a sweep away from the checkout under an open review.
  if queue_restored[doc.checkout] then
    return nil
  end

  -- The directory is gone. A path that is there but is not a directory is gone too: what
  -- was a checkout is not one now.
  if (vim.uv.fs_stat(doc.checkout) or {}).type == "directory" then
    return nil
  end

  -- **Its parent is still there.** The condition that is easy to leave out, and the one
  -- that keeps an absent volume out of this: a volume that is not mounted takes the
  -- directory above the checkout with it, and a missing mount point is an absent volume
  -- rather than a checkout somebody removed. No grace period of any length can tell those
  -- two apart. The design notes say where this holds and where it does not.
  if (vim.uv.fs_stat(vim.fs.dirname(doc.checkout)) or {}).type ~= "directory" then
    return nil
  end

  -- Aged out, by the document's own stamp rather than by the entries in it: a document
  -- holding only reviewed marks and trims has no entry to take an age from.
  if (now - doc.saved) < ORPHAN_GRACE_SECONDS then
    return nil
  end

  return doc
end

---How a reviewer is told what a sweep took.
---
---Two figures and never one. How many checkouts went is a fact about the state directory;
---how many unsent annotations went with them is a fact about the reviewer's own work. A
---sum answers neither, and the checkout count alone says nothing at all about the work.
---@param checkouts integer
---@param entries integer
---@return string
local function swept_phrase(checkouts, entries)
  return ("Swept %d orphaned checkout%s — %d unsent annotation%s went with %s"):format(
    checkouts,
    checkouts == 1 and "" or "s",
    entries,
    entries == 1 and "" or "s",
    checkouts == 1 and "it" or "them"
  )
end

---Discard the stored state of checkouts that are gone.
---
---Run on a **switch** and on nothing else: that is the moment a checkout's existence is
---most likely to have just changed, it is rare, and it is nowhere near a hot path. No
---startup scan and no timer.
---
---The whole document goes rather than the queue inside it. An orphaned **archive** is
---already unreadable, because an archive is opened through the checkout being reviewed, and
---the reviewed marks and the **trim** beside it describe a diff that no longer exists.
---
---Says one line when it took something and nothing at all when it did not. It never asks:
---a confirmation on an operation this guarded teaches distrust of it, which is the reason a
---switch does not ask either.
---
---`archive_writes` is deliberately not moved. A projection of an archive is only ever the
---open review's, and the checkout under an open review has been read back -- which is one
---of the conditions above.
---@return { checkouts: integer, entries: integer } What went, as two figures
function M.sweep_orphans()
  local dir = vim.fs.dirname(M.global_path())
  local checkouts, entries = 0, 0
  if vim.fn.isdirectory(dir) == 0 then
    return { checkouts = checkouts, entries = entries }
  end

  local now = os.time()
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:sub(-5) == ".json" then
      local file = vim.fs.joinpath(dir, name)
      local doc = sweepable(file, now)
      if doc then
        checkouts = checkouts + 1
        -- What was unsent, which is the queue and not everything the document held: an
        -- archived entry has already reached an agent, and counting it would report work
        -- as lost that was delivered.
        entries = entries + #(doc.queue or {})
        vim.fn.delete(file)
      end
    end
  end

  if checkouts > 0 then
    info(swept_phrase(checkouts, entries))
  end
  return { checkouts = checkouts, entries = entries }
end

return M
