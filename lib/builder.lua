-- builder.lua -- the `p` build-context API and the per-package install pipeline.
--
-- The `p` object is the ONLY interface a package's install/build function has
-- to the system (the manifest sandbox removes io/os/require). Every method is
-- audited Zeta code that logs verbosely and fails fast. Design notes:
--
--   * p:run streams the child's output directly (no pipes) so builds are fast
--     and the user sees everything.
--   * p:run runs in p.cwd (defaults to the unpacked source dir) and tracks
--     `cd x` used by recipes, so `p:run("mkdir build && cd build")` followed
--     by p:meson(...) executes inside build/.
--   * The environment handed to every subprocess is minimal and sanitized --
--     no distro-specific variables leak in.
--   * install_root is a DESTDIR-style staging dir. After the package runs,
--     commit.apply() walks it; the relative path under install_root IS the
--     recorded owned path, so nothing needs manual registration.

local builder = {}

local path = require("path")
local log = require("log")
local config = require("config")
local fetch = require("fetch")
local checksum = require("checksum")
local archive = require("archive")
local commit = require("commit")
local db = require("db")
local spinner = require("spinner")
local profile = require("profile")

-- Minimal, deliberately small PATH for subprocesses. Build tools must be
-- declared as dependencies of the package; we never inherit a host PATH.
local BASE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

-- Cache filename suffix for a payload url. Multi-part suffixes must be kept
-- whole: archive.extract dispatches on the payload's own filename, so
-- collapsing .pkg.tar.zst/.pkg.tar.xz to .zst/.xz would bypass the Arch
-- package path (the .deb dispatch has always relied on this staying intact).
local function cache_suffix(url)
  if url:match("%.pkg%.tar%.zst$") then return "pkg.tar.zst" end
  if url:match("%.pkg%.tar%.xz$") then return "pkg.tar.xz" end
  return url:match("%.([%w]+)$") or "bin"
end

-- p object construction

local function find_tool(p, name)
  local path_env = p.env.PATH or BASE_PATH
  for dir in path_env:gmatch("[^:]+") do
    local candidate = path.join(dir, name)
    local f = io.open(candidate, "r")
    if f then
      f:close()
      return candidate
    end
  end
  return nil
end

local function make_p(manifest, dirs)
  local p = {
    name = manifest.name,
    version = manifest.version,
    summary = manifest.summary,
    prefix = manifest.prefix,
    work_dir = dirs.work,
    install_root = dirs.stage,
    cache_dir = config.get().cache_dir,
    local_dir = dirs.local_dir,
    env = {},
    cwd = dirs.work,
    _manifest = manifest,
  }

  -- Run a shell command in p.cwd with a sanitized environment.
  function p:run(cmd)
    local env = { PATH = BASE_PATH, TMPDIR = self.work_dir }
    for k, v in pairs(self.env) do env[k] = v end
    local prefix
    local parts = {}
    for k, v in pairs(env) do
      if v == nil then
        parts[#parts + 1] = "unset " .. k
      else
        parts[#parts + 1] = k .. "=" .. path.quote(v)
      end
    end
    prefix = "cd " .. path.quote(self.cwd) .. " && "
    local full = prefix .. table.concat(parts, " ") .. " " .. cmd
    if config.get().verbose then
      log.detail(("  run: %s"):format(full))
    else
      log.detail(("$ %s"):format(cmd))
    end
    if not path.run(full) then
      error(("command failed for %s in %s: %s"):format(self.name, self.cwd, cmd), 0)
    end
    -- Heuristic: if the command cds into a subdirectory, persist that so the
    -- example-style recipe `p:run("mkdir build && cd build")` keeps its cwd.
    local m = cmd:match("cd%s+([^%s;&|]+)")
    if m then
      local dir = m:gsub('^"', ""):gsub('"$', ""):gsub("^'", ""):gsub("'$", "")
      self:cd(dir)
    end
    return true
  end

  -- Explicitly change the working directory for subsequent p:run/tool calls.
  function p:cd(dir)
    if not dir:match("^/") then dir = path.join(self.cwd, dir) end
    self.cwd = dir
    log.detail(("cwd -> %s"):format(self.cwd))
  end

  -- Generic tool runner (meson/ninja/make/cmake).
  local function tool(p, name, args)
    if not find_tool(p, name) then
      error(("tool %q not found in PATH for %s — add %q to deps or install it"):format(
        name, p.name, name), 0)
    end
    local parts = { name }
    for _, a in ipairs(args) do parts[#parts + 1] = path.quote(tostring(a)) end
    log.detail(("[%s] %s"):format(name, table.concat(args, " ")))
    p:run(table.concat(parts, " "))
  end

  function p:meson(...) tool(self, "meson", { ... }) end
  function p:ninja(...) tool(self, "ninja", { ... }) end
  function p:make(...) tool(self, "make", { ... }) end
  function p:cmake(...) tool(self, "cmake", { ... }) end

  -- Cache filename for a url, keyed by name-version-extension so reinstalls
  -- reuse the already-downloaded artifact.
  function p:cache_path(url)
    return path.join(self.cache_dir, self.name .. "-" .. self.version .. "." .. cache_suffix(url))
  end

  -- Download `url` (default: the manifest url) and verify its sha256.
  function p:fetch(url)
    local u = url or self._manifest.url
    if not u then error("p:fetch needs a url", 0) end
    if not u:match("^%w+://") and not u:match("^/") then
      -- bare filename: resolve relative to the local package directory
      if not self.local_dir then
        error(("url %q has no scheme and no local package directory"):format(u), 0)
      end
      u = path.join(self.local_dir, u)
    end
    local dest = self:cache_path(u)
    local got, err = fetch.get(u, dest)
    if not got then error(("fetch failed: %s"):format(tostring(err)), 0) end
    if self._manifest.sha256 then
      local vok, verr = checksum.verify(dest, self._manifest.sha256)
      if not vok then error(tostring(verr), 0) end
    end
    return dest
  end

  -- Extract an archive into p.work_dir (or opts.dest). Returns the single
  -- top-level directory name when the archive has exactly one, else nil.
  function p:unpack(archive_file, opts)
    opts = opts or {}
    local dest = opts.dest or self.work_dir
    path.mkdir_p(dest)
    local entries, err = archive.extract(archive_file, dest, { strip = opts.strip or 0 })
    if not entries then error(tostring(err), 0) end
    local tops = {}
    for _, e in ipairs(entries) do
      local top = e.path:match("^([^/]+)")
      if top then tops[top] = true end
    end
    local names = {}
    for k in pairs(tops) do names[#names + 1] = k end
    if #names == 1 then return names[1] end
    return nil
  end

  -- Copy a file/dir into the install_root staging tree at `dest_rel`
  -- (relative, e.g. "usr/bin/foo" or "/usr/bin/foo").
  function p:install(src, dest_rel)
    local full_src = src
    if not src:match("^/") then full_src = path.join(self.cwd, src) end
    local rel = dest_rel:gsub("^/+", "")
    if not path.relative_inside(rel) then
      error(("p:install destination %q escapes the root"):format(dest_rel), 0)
    end
    local target = path.join(self.install_root, rel)
    path.mkdir_p(path.dirname(target))
    if not path.run("cp -a " .. path.quote(full_src) .. " " .. path.quote(target)) then
      error(("p:install failed to copy %q"):format(src), 0)
    end
    log.detail(("p:install %s -> %s"):format(src, rel))
    return true
  end

  function p:env_set(k, v) self.env[k] = v end
  function p:env_unset(k) self.env[k] = nil end
  function p:log(msg) log.info(("[" .. self.name .. "] " .. msg)) end

  return p
end

-- Install pipeline

-- Number of entries (files + dirs) below `dir`, 0 if empty or unreadable.
-- Used by -Test's structural check to prove the pipeline produced something.
local function count_tree(dir)
  local f = path.popen("find " .. path.quote(dir) .. " 2>/dev/null | wc -l")
  if not f then return 0 end
  local line = f:read("*l")
  f:close()
  local n = tonumber(line)
  return n and n > 1 and (n - 1) or 0
end

-- Resolve a manifest url into a local file in the cache, verifying sha256.
-- Returns the payload path or throws. `local_dir` is used for bare filenames.
local function obtain_payload(p, manifest, local_dir)
  if not manifest.url then return nil end
  local url = manifest.url
  local resolved = url
  if not url:match("^%w+://") and not url:match("^/") then
    -- bare filename: relative to the local package directory
    if not local_dir then
      error(("manifest %q url %q has no scheme and no local package directory"):format(
        manifest.name, url), 0)
    end
    resolved = path.join(local_dir, url)
  end
  local dest = p:cache_path(url)
  log.step(("fetching %s"):format(url))
  local got, err = fetch.get(resolved, dest, path.basename(url))
  if not got then error(("download failed: %s"):format(tostring(err)), 0) end
  if manifest.sha256 then
    log.step(("verifying sha256 of %s"):format(path.basename(got)))
    local vok, verr = checksum.verify(got, manifest.sha256)
    if not vok then error(tostring(verr), 0) end
    log.ok("sha256 verified")
  elseif manifest.url:match("^https?://") then
    log.warn(("no sha256 in manifest for %s; checksum not verified"):format(manifest.name))
  end
  return got
end

-- Resolve a manifest's payload URL and check the cache. Returns:
--   { url = resolved_url, dest = cache_path } if download is needed
--   { cached = path } if already in cache
--   nil if manifest has no url
-- Used by the parallel fetch phase to prepare downloads before building.
function builder.fetch_payload(manifest, opts)
  opts = opts or {}
  if not manifest.url then return nil end
  local url = manifest.url
  local resolved = url
  if not url:match("^%w+://") and not url:match("^/") then
    if not opts.local_dir then
      return nil, ("manifest %q url %q has no scheme and no local package directory"):format(
        manifest.name, url)
    end
    resolved = path.join(opts.local_dir, url)
  end
  -- Build a cache path using the same logic as make_p:cache_path
  local dest = path.join(config.get().cache_dir,
    manifest.name .. "-" .. manifest.version .. "." .. cache_suffix(url))
  if path.exists(dest) then
    -- A cached payload is only reusable while it matches the manifest sha256.
    -- Constructs are occasionally rebuilt in place (same name, same version,
    -- new contents), so a stale entry must be discarded and fetched again
    -- instead of surfacing a checksum failure at install time.
    if manifest.sha256 then
      local vok = checksum.verify(dest, manifest.sha256)
      if not vok then
        os.remove(dest)
        return { url = resolved, dest = dest }
      end
    end
    return { cached = dest }
  end
  return { url = resolved, dest = dest }
end

-- Verify sha256 for a downloaded payload. Throws on mismatch.
function builder.verify_payload(manifest, payload)
  if manifest.sha256 and payload then
    log.step(("verifying sha256 of %s"):format(path.basename(payload)))
    local vok, verr = checksum.verify(payload, manifest.sha256)
    if not vok then error(tostring(verr), 0) end
    log.ok("sha256 verified")
  elseif manifest.url and manifest.url:match("^https?://") then
    log.warn(("no sha256 in manifest for %s; checksum not verified"):format(manifest.name))
  end
end

-- verify_all(items) -- items: { { manifest = ..., payload = ... }, ... }
--
-- Batch sha256 verification of every downloaded payload. Runs before anything
-- is unpacked or committed: a corrupt download aborts the run with the system
-- untouched. Throws on the first mismatch.
function builder.verify_all(items)
  local pending = 0
  for _, it in ipairs(items) do
    if it.payload and it.manifest.sha256 then pending = pending + 1 end
  end
  if pending == 0 then return end
  log.step("verifying sha256 of downloaded archives.")
  for _, it in ipairs(items) do
    local manifest, payload = it.manifest, it.payload
    if payload then
      if manifest.sha256 then
        local ok, verr = checksum.verify(payload, manifest.sha256)
        if not ok then error(tostring(verr), 0) end
      elseif manifest.url and manifest.url:match("^https?://") then
        log.warn(("no sha256 in manifest for %s; checksum not verified"):format(manifest.name))
      end
    end
  end
  log.ok("sha256 instances verified")
end

-- stage_one(manifest, opts) -> staged
--
-- Extract (or build) one package into a fresh staging tree and return the
-- handle commit_all consumes: { stage = <dir>, work = <dir> }. Nothing
-- outside the staging dirs is touched, so a failure here leaves the system
-- exactly as it was. opts:
--   payload    an already-downloaded payload path (from the fetch phase)
--   verified   true when verify_all already checked the payload's sha256
--   local_dir  local package directory for bare filenames
-- Without a payload the payload is obtained (and verified) here.
function builder.stage_one(manifest, opts)
  opts = opts or {}
  local cfg = config.get()
  local name = manifest.name

  -- Optional architecture gate: a binary package may declare `arch` and will
  -- then refuse to install on a mismatched machine.
  if manifest.arch then
    local uname
    local f = path.popen("uname -m 2>/dev/null")
    if f then
      uname = f:read("*l")
      f:close()
    end
    if uname and uname ~= manifest.arch then
      error(("package %s targets architecture %q but this machine is %q"):format(
        name, manifest.arch, uname), 0)
    end
  end

  local stamp = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
  local work = path.join(cfg.tmp_dir, "work", name .. "-" .. stamp)
  local stage = path.join(cfg.tmp_dir, "staging", name .. "-" .. stamp)
  path.mkdir_p(work)
  path.mkdir_p(stage)

  local p = make_p(manifest, { work = work, stage = stage, local_dir = opts.local_dir })

  local ok, err = pcall(function()
    local payload
    if opts.payload then
      payload = opts.payload
      if not opts.verified then builder.verify_payload(manifest, payload) end
    else
      payload = obtain_payload(p, manifest, opts.local_dir)
    end

    if manifest.archive then
      -- Declarative binary install: extract straight into the staging root.
      log.step(("unpacking archive (strip=%d)"):format(manifest.archive.strip))
      local _, extract_err = archive.extract(payload, stage, {
        strip = manifest.archive.strip,
        allow_root_files = manifest.archive.allow_root_files,
      })
      if not _ then error(tostring(extract_err), 0) end
    elseif manifest.build then
      if payload then
        log.step(("unpacking source %s"):format(path.basename(payload)))
        local top = p:unpack(payload, {})
        if top then p:cd(top) end
      end
      log.step(("running build function for %s"):format(name))
      manifest.build(p)
    elseif manifest.install then
      if payload then
        log.step(("unpacking payload %s"):format(path.basename(payload)))
        local top = p:unpack(payload, {})
        if top then p:cd(top) end
      end
      log.step(("running install function for %s"):format(name))
      manifest.install(p)
    end
  end)

  if not ok then
    builder.discard_staged({ stage = stage, work = work })
    error(("install of %s failed: %s"):format(name, tostring(err)), 0)
  end
  return { stage = stage, work = work }
end

-- discard_staged(staged) -- delete the staging tree produced by stage_one.
function builder.discard_staged(staged)
  if not staged then return end
  if staged.work then path.run("rm -rf " .. path.quote(staged.work)) end
  if staged.stage then path.run("rm -rf " .. path.quote(staged.stage)) end
end

-- commit_placement(name, version, staging, opts) -> owned entries
--
-- The file-placement half of a commit -- what a worker process runs. All
-- output belongs to the caller (see commit.apply's on_progress): the batch
-- commit draws one aggregate header and counter. System-wide side effects
-- are deferred to commit.run_system_ops so concurrent commits can never
-- collide on them. opts: { root, whitelist, force, on_progress }.
function builder.commit_placement(name, version, staging, opts)
  opts = opts or {}
  return commit.apply(staging, {
    whitelist = opts.whitelist,
    force = opts.force,
    pkg_name = name,
    root = opts.root,
    defer_system = true,
    on_progress = opts.on_progress,
  })
end

-- commit_record(manifest, rels, opts) -- the parent-side half: the database
-- write. opts (normally the item table): { source, kind, isolate_root,
-- record }.
function builder.commit_record(manifest, rels, opts)
  opts = opts or {}
  if opts.record == false then
    -- Dependency pulled into an isolated store: the files landed, but only
    -- the owning package is registered (the store is deleted as a unit).
    return
  end
  manifest.source = opts.source or "remote"
  db.record(manifest.name, manifest, rels, {
    kind = opts.kind,
    isolated = opts.isolate_root ~= nil,
    reserve_root = opts.isolate_root,
  })
end

-- commit_wire(items) -- mirror each entry's deps into the dependents lists so
-- -Delete knows what still requires it (covers deps installed earlier in this
-- run AND deps that were already present). Isolated stores skip this: they are
-- self-contained and deleted wholesale. Runs once, in plan order, after every
-- package is recorded: the pool completes packages out of order, and a
-- dependent must never be wired before its dependency is registered.
function builder.commit_wire(items)
  for _, it in ipairs(items) do
    if it.record ~= false and it.isolate_root == nil then
      for _, d in ipairs(it.manifest.deps or {}) do
        if db.is_installed(d.name) then db.add_dependent(d.name, it.manifest.name) end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Commit pool
-- ---------------------------------------------------------------------------

-- The Lua interpreter running us (arg[-1], the pattern the test harness uses).
local LUA_BIN = (arg and arg[-1]) or "lua"

-- This module's directory, so the worker script sits next to us no matter
-- where Zeta is installed.
local function worker_script()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  local dir = src:match("^(.*)[/\\][^/\\]*$") or "."
  return path.join(dir, "commitworker.lua")
end

-- A worker ticket is a Lua file the worker dofile()s.
local function write_ticket(file, t)
  local f = io.open(file, "w")
  if not f then return nil, ("could not write worker ticket %s"):format(file) end
  f:write("return {\n")
  f:write(("  name = %q,\n"):format(t.name))
  f:write(("  version = %q,\n"):format(t.version))
  f:write(("  staging = %q,\n"):format(t.staging))
  f:write(("  report = %q,\n"):format(t.report))
  f:write(("  status = %q,\n"):format(t.status))
  f:write(("  progress = %q,\n"):format(t.progress))
  if t.root then f:write(("  root = %q,\n"):format(t.root)) end
  if t.force then f:write("  force = true,\n") end
  if t.whitelist then
    f:write("  whitelist = {\n")
    for _, w in ipairs(t.whitelist) do f:write(("    %q,\n"):format(w)) end
    f:write("  },\n")
  end
  f:write("}\n")
  f:close()
  return true
end

-- Worker results are line files: the report lists owned entries as
-- "<type>|<rel>", the status file carries the exit code on its first line
-- and an error message below.
local function read_lines(file)
  local f = io.open(file, "rb")
  if not f then return nil end
  local out = {}
  for line in f:lines() do out[#out + 1] = line end
  f:close()
  return out
end

-- Split a worker report into the owned paths (for the database) and the
-- per-type counts (for the aggregate summary).
local function parse_report(lines)
  local rels, c = {}, { files = 0, symlinks = 0, dirs = 0 }
  for _, l in ipairs(lines or {}) do
    local tag, rel = l:match("^([fld])%|(.*)$")
    if tag then
      rels[#rels + 1] = rel
      if tag == "f" then c.files = c.files + 1
      elseif tag == "l" then c.symlinks = c.symlinks + 1
      else c.dirs = c.dirs + 1 end
    end
  end
  return rels, c
end

-- Launch one commit worker in the background. The shell leaves a status file
-- behind even when the worker process dies before writing one.
local function spawn_worker(item, opts, slot, dir)
  local m = item.manifest
  local base = path.join(dir, "commit-" .. slot .. "-" .. m.name)
  local w = {
    item = item,
    out = base .. ".out",
    ticket = base .. ".lua",
    report = base .. ".report",
    status = base .. ".status",
    progress = base .. ".progress",
    pid_file = base .. ".pid",
    done = 0,
  }
  local ok, terr = write_ticket(w.ticket, {
    name = m.name,
    version = m.version,
    staging = item.staged.stage,
    root = item.isolate_root,
    force = opts.force,
    whitelist = m.files,
    report = w.report,
    status = w.status,
    progress = w.progress,
  })
  if not ok then return nil, terr end
  local cmd = ("{ %s %s %s > %s 2>&1; [ -f %s ] || echo 1 > %s; } & echo $! > %s"):format(
    path.quote(LUA_BIN), path.quote(worker_script()), path.quote(w.ticket),
    path.quote(w.out), path.quote(w.status), path.quote(w.status),
    path.quote(w.pid_file))
  os.execute(cmd)
  return w
end

-- commit_all(items, opts) -> true | nil, errmsg
--
-- Commit every staged package as ONE transaction: a single "committing files
-- to <root>" header and one live counter summed across every package's
-- entries. Up to opts.jobs provides run at a time and the next starts as soon
-- as a slot frees. The database writes and the dependents wiring stay in this
-- process (single-threaded, so no two workers can race on the registries),
-- and the system-wide side effects (ldconfig, GSettings schema compilation)
-- run once at the very end.
--
-- When the counter settles: one aggregate file/symlink/dir summary, then the
-- list of what was provided (plan order; a package with announce = false is
-- left out because the closing block announces it).
--
-- items: { { manifest, staged, kind, source, isolate_root, record, announce } }
--        `staged` is the handle from stage_one; it is discarded here.
-- opts:  { jobs, force }
function builder.commit_all(items, opts)
  opts = opts or {}
  local cfg = config.get()
  local jobs = tonumber(opts.jobs) or cfg.jobs or 2
  if jobs < 1 then jobs = 1 end

  local dir = path.join(cfg.tmp_dir, "commit-"
    .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)))
  path.mkdir_p(dir)

  -- The counter's denominator is known before the first file moves.
  -- Timed as its own sub-phase: this serial tree-walk is what the pool later
  -- repeats per worker, so the receipt should show it separately.
  profile.submark("count")
  local dest_root = cfg.root
  for _, it in ipairs(items) do
    if it.isolate_root then dest_root = it.isolate_root end
  end
  local total_entries = 0
  local pok, perr = pcall(function()
    for _, it in ipairs(items) do
      total_entries = total_entries + commit.count_owned(it.staged.stage, it.manifest.files)
    end
  end)
  if not pok then
    path.run("rm -rf " .. path.quote(dir))
    return nil, tostring(perr)
  end

  log.step(("committing files to %s"):format(dest_root))
  profile.submark("pool")

  local show_counter = spinner.enabled() and not cfg.verbose
  local settled, live, live_rel = 0, 0, nil
  local counts = { files = 0, symlinks = 0, dirs = 0 }
  local completed, schemas, failed = {}, false, nil

  local function draw(final)
    if show_counter then
      -- Absolute, so the row reads the same way -Delete's paths do.
      local rel = live_rel and path.join(dest_root, live_rel)
      commit.counter(settled + live, total_entries, final, rel)
    end
  end

  -- Run a print without breaking the live counter line.
  local function around(fn)
    if show_counter then io.write("\r\27[K") end
    fn()
    if show_counter then draw(false) end
  end

  local function message(text)
    around(function() io.write(text) end)
  end

  -- One package is fully placed: record it (parent-side, serialized), fold
  -- its numbers into the aggregate summary, and announce it right away --
  -- the stream itself shows the completion order.
  local function finish_item(it, rels, c)
    settled = settled + #rels
    counts.files = counts.files + (c and c.files or 0)
    counts.symlinks = counts.symlinks + (c and c.symlinks or 0)
    counts.dirs = counts.dirs + (c and c.dirs or 0)
    for _, r in ipairs(rels) do
      if r:match("^usr/share/glib%-2%.0/schemas/.+%.gschema%.xml$") then
        schemas = true
      end
    end
    local rok, rerr = pcall(builder.commit_record, it.manifest, rels, it)
    if not rok then
      failed = failed or ("install of %s failed: %s"):format(it.manifest.name, tostring(rerr))
      return
    end
    completed[#completed + 1] = it
    -- The target (announce = false) is named by the closing block instead.
    if it.announce ~= false then
      around(function()
        log.ok(("provided %s-%s"):format(it.manifest.name, it.manifest.version))
      end)
    end
  end

  if jobs == 1 then
    -- No pool: place and record in this process, one package at a time.
    for _, it in ipairs(items) do
      if failed then break end
      local m = it.manifest
      live, live_rel = 0, nil
      local iok, owned = pcall(builder.commit_placement, m.name, m.version,
        it.staged.stage, {
          root = it.isolate_root,
          whitelist = m.files,
          force = opts.force,
          on_progress = function(done, total, rel)
            live = done
            live_rel = rel
            draw(false)
          end,
        })
      if not iok then
        failed = failed or ("install of %s failed: %s"):format(m.name, tostring(owned))
      else
        local rels, c = {}, { files = 0, symlinks = 0, dirs = 0 }
        for _, e in ipairs(owned) do
          rels[#rels + 1] = e.rel
          if e.type == "symlink" then c.symlinks = c.symlinks + 1
          elseif e.type == "dir" then c.dirs = c.dirs + 1
          else c.files = c.files + 1 end
        end
        finish_item(it, rels, c)
        live, live_rel = 0, nil
      end
    end
  else
    -- Rolling pool: dispatch up to `jobs` workers, start the next one the
    -- moment a slot frees. All drawing happens here, from the progress
    -- stamps the workers leave behind.
    local running = {}
    local next_i, slot = 1, 0
    local hook
    hook = function()
      for _, w in ipairs(running) do
        local pid = read_lines(w.pid_file)
        if pid and pid[1] then os.execute("kill " .. pid[1] .. " 2>/dev/null") end
      end
      path.remove_cleanup(hook)
    end
    path.on_cleanup(hook)

    while next_i <= #items or #running > 0 do
      while not failed and #running < jobs and next_i <= #items do
        local it = items[next_i]
        next_i = next_i + 1
        slot = slot + 1
        local w, werr = spawn_worker(it, opts, slot, dir)
        if not w then
          failed = failed or ("install of %s failed: %s"):format(it.manifest.name, tostring(werr))
        else
          running[#running + 1] = w
        end
      end

      for k = #running, 1, -1 do
        local w = running[k]
        local status = read_lines(w.status)
        if status then
          table.remove(running, k)
          -- Verbose per-file output is the only thing a worker prints;
          -- replay it under the counter as one piece.
          local block = read_lines(w.out)
          if block and #block > 0 then
            message(table.concat(block, "\n") .. "\n")
          end
          if tonumber(status[1] or "") == 0 then
            local rels, c = parse_report(read_lines(w.report))
            finish_item(w.item, rels, c)
          else
            local msg = table.concat(status, "\n", 2)
            failed = failed or ("install of %s failed: %s"):format(
              w.item.manifest.name, (msg ~= "" and msg) or "commit worker failed")
          end
        end
      end

      -- Redraw the aggregate counter from the workers' progress stamps. Each
      -- stamp carries its current entry on line 2, so the row can show what is
      -- actually landing while the totals tick up. Reset first: once every
      -- worker has finished there is no live path to show.
      live, live_rel = 0, nil
      for _, w in ipairs(running) do
        local p = read_lines(w.progress)
        live = live + (p and tonumber(p[1] or "") or 0)
        if p and p[2] and p[2] ~= "" then live_rel = p[2] end
      end
      draw(false)

      if #running > 0 then os.execute("sleep 0.1") end
    end
    path.remove_cleanup(hook)
  end

  -- Pool done: wire/system-ops below belong to the phase, not to pool.
  profile.close_sub()

  -- The transaction is over: settle the counter and summarize what landed.
  if failed then
    if show_counter then io.write("\r\27[K") end
  else
    draw(true)
  end
  if counts.files > 0 then
    log.info(("- committed %d files to %s"):format(counts.files, dest_root))
  end
  if counts.symlinks > 0 then
    log.info(("- committed %d symlinks to %s"):format(counts.symlinks, dest_root))
  end
  if counts.dirs > 0 then
    log.info(("- committed %d dirs to %s"):format(counts.dirs, dest_root))
  end

  -- Everything that will ever be on disk is on disk now: wire dependents in
  -- plan order (every completed package is recorded) and run the deferred
  -- system-wide operations exactly once.
  if #completed > 0 then
    builder.commit_wire(completed)
    local root, isolated = cfg.root, false
    for _, it in ipairs(completed) do
      if it.isolate_root then
        root, isolated = it.isolate_root, true
      end
    end
    commit.run_system_ops({ root = root, isolated = isolated, schemas = schemas })
  end

  -- Drop every staging tree, committed or not, along with the worker files.
  for _, it in ipairs(items) do
    builder.discard_staged(it.staged)
  end
  path.run("rm -rf " .. path.quote(dir))

  if failed then return nil, failed end
  return true
end

-- install(manifest, opts) -- the one-package pipeline: stage_one + commit_all
-- with the pool disabled. Batch flows (actions._install / actions.transcend)
-- drive the phases themselves so every payload is verified and staged before
-- the first file is committed; this wrapper is for single-package callers.
-- opts: { force, source, local_dir, kind, pre_fetched, verified,
--         isolate_root, record, announce }
-- opts.kind is "package" for an explicit install or "dependency" for an
-- auto-installed dependency (see actions.lua); it decides which database
-- registry the entry lands in.
-- opts.pre_fetched is an optional path to an already-downloaded payload;
-- when set, obtain_payload is skipped and the given path is used directly.
-- opts.verified marks a pre_fetched payload as already sha256-verified (the
-- batch flows check everything up front in verify_all).
-- opts.isolate_root is an explicit install root (the /zeta/reserve store for
-- an isolated package). When set, files commit into that root instead of
-- config.root, and the host linker cache is left alone.
-- opts.record (default true) controls the database write: dependency installs
-- into an isolated store are not registered (the whole store is deleted as a
-- unit when the owning package is uninstalled).
function builder.install(manifest, opts)
  opts = opts or {}
  local staged = builder.stage_one(manifest, {
    local_dir = opts.local_dir,
    payload = opts.pre_fetched,
    verified = opts.verified,
  })
  local ok, err = builder.commit_all({ {
    manifest = manifest,
    staged = staged,
    kind = opts.kind,
    source = opts.source,
    isolate_root = opts.isolate_root,
    record = opts.record,
    announce = opts.announce,
  } }, { force = opts.force, jobs = 1 })
  if not ok then error(tostring(err), 0) end
  return true
end

-- test(manifest, opts) -- opts: { local_dir }
--
-- Runs the same pipeline as install (local payload fetch, sha256 verify,
-- unpack/build/install into a scratch stage) but NEVER commits to the root
-- and NEVER records in the database. If the manifest declares a `test` hook
-- it is run against the staged tree; otherwise the check is structural
-- (payload integrity plus a non-empty staging tree). Strictly offline:
-- payloads must resolve from the local package directory.
function builder.test(manifest, opts)
  opts = opts or {}
  local cfg = config.get()
  local name = manifest.name

  log.step(("testing %s-%s"):format(name, manifest.version))

  local stamp = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
  local work = path.join(cfg.tmp_dir, "work", name .. "-" .. stamp)
  local stage = path.join(cfg.tmp_dir, "staging", name .. "-" .. stamp)
  path.mkdir_p(work)
  path.mkdir_p(stage)

  local p = make_p(manifest, { work = work, stage = stage, local_dir = opts.local_dir })

  local ok, err = pcall(function()
    if manifest.url and manifest.url:match("^https?://") then
      error(("offline test refused: %s-%s has a remote url %s"):format(
        name, manifest.version, manifest.url), 0)
    end
    local payload = obtain_payload(p, manifest, opts.local_dir)

    if manifest.archive then
      -- Declarative binary package: extract straight into the staging root.
      log.step(("unpacking archive (strip=%d)"):format(manifest.archive.strip))
      local _, extract_err = archive.extract(payload, stage, {
        strip = manifest.archive.strip,
        allow_root_files = manifest.archive.allow_root_files,
      })
      if not _ then error(tostring(extract_err), 0) end
    elseif manifest.build then
      if payload then
        log.step(("unpacking source %s"):format(path.basename(payload)))
        local top = p:unpack(payload, {})
        if top then p:cd(top) end
      end
      log.step(("running build function for %s"):format(name))
      manifest.build(p)
    elseif manifest.install then
      if payload then
        log.step(("unpacking payload %s"):format(path.basename(payload)))
        local top = p:unpack(payload, {})
        if top then p:cd(top) end
      end
      log.step(("running install function for %s"):format(name))
      manifest.install(p)
    end

    if manifest.test then
      log.step(("running test function for %s"):format(name))
      manifest.test(p)
    else
      -- Structural check: the pipeline must actually produce something.
      local n = count_tree(stage)
      if n == 0 then
        error(("test failed: %s-%s produced no files in the staging tree"):format(
          name, manifest.version), 0)
      end
      log.detail(("staging tree holds %d entries"):format(n))
    end
  end)

  -- Always clean up staging + work dirs, even on failure.
  path.run("rm -rf " .. path.quote(work))
  path.run("rm -rf " .. path.quote(stage))

  if not ok then
    error(("test of %s failed: %s"):format(name, tostring(err)), 0)
  end

  log.ok(("test passed for %s-%s"):format(name, manifest.version))
  return true
end

return builder
