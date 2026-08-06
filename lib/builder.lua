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

-- Minimal, deliberately small PATH for subprocesses. Build tools must be
-- declared as dependencies of the package; we never inherit a host PATH.
local BASE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

-- ---------------------------------------------------------------------------
-- p object construction
-- ---------------------------------------------------------------------------

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
    log.detail(("$ %s"):format(cmd))
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
    local ext = url:match("%.([%w]+)$") or "bin"
    return path.join(self.cache_dir, self.name .. "-" .. self.version .. "." .. ext)
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

-- ---------------------------------------------------------------------------
-- Install pipeline
-- ---------------------------------------------------------------------------

local function owned_rels(entries)
  local rels = {}
  for _, e in ipairs(entries) do rels[#rels + 1] = e.rel end
  return rels
end

-- Number of entries (files + dirs) below `dir`, 0 if empty or unreadable.
-- Used by -Test's structural check to prove the pipeline produced something.
local function count_tree(dir)
  local f = io.popen("find " .. path.quote(dir) .. " 2>/dev/null | wc -l")
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
  local got, err = fetch.get(resolved, dest)
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

-- install(manifest, opts) -- opts: { force, source, local_dir }
function builder.install(manifest, opts)
  opts = opts or {}
  local cfg = config.get()
  local name = manifest.name

  log.step(("installing %s-%s"):format(name, manifest.version))

  -- Optional architecture gate: a binary package may declare `arch` and will
  -- then refuse to install on a mismatched machine.
  if manifest.arch then
    local uname
    local f = io.popen("uname -m 2>/dev/null")
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
    local payload = obtain_payload(p, manifest, opts.local_dir)

    if manifest.archive then
      -- Declarative binary install: extract straight into the staging root.
      log.step(("unpacking archive (strip=%d)"):format(manifest.archive.strip))
      archive.extract(payload, stage, { strip = manifest.archive.strip })
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

    log.step(("committing files to %s"):format(cfg.root))
    local owned = commit.apply(stage, {
      whitelist = manifest.files,
      force = opts.force,
      pkg_name = name,
    })

    manifest.source = opts.source or "remote"
    db.record(name, manifest, owned_rels(owned))
  end)

  -- Always clean up staging + work dirs, even on failure.
  path.run("rm -rf " .. path.quote(work))
  path.run("rm -rf " .. path.quote(stage))

  if not ok then
    error(("install of %s failed: %s"):format(name, tostring(err)), 0)
  end

  log.ok(("installed %s-%s"):format(name, manifest.version))
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
      archive.extract(payload, stage, { strip = manifest.archive.strip })
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
