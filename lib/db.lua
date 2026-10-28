-- db.lua -- the installed-package database.
--
-- State lives at <ZETA_ROOT>/var/db/zeta/ split into three registries:
--   packages/<name>/      explicitly installed packages (kind = "package")
--   dependencies/<name>/   packages pulled in automatically as dependencies
--                          (kind = "dependency")
--   isolated/<name>/       packages installed into a /zeta/reserve store with
--                          --isolate; meta carries `reserve_root`. Shares no
--                          queries with the other two (a name may exist in
--                          both a system and an isolated registry).
-- Each entry contains:
--   meta.lua  -- a serialized manifest (return {...}), loaded under the sandbox
--   files     -- one owned relative path per line
--
-- A dependency's meta.lua also carries `dependents`, the list of installed
-- entries that depend on it. That back-reference is what lets -Delete decide
-- whether an entry is still required and lets --with-deps cascade safely.
--
-- Legacy databases (entries directly under <state_dir>/<name>) are migrated
-- lazily, once per state dir, into the packages/ registry.
--
-- The "files" list is the authoritative set of what -Delete may touch: deletion
-- unlinks exactly those paths and then prunes now-empty parent directories.
-- Files are plain text / Lua for transparency and easy manual inspection.

local db = {}

local config = require("config")
local path = require("path")
local sandbox = require("sandbox")

-- ---------------------------------------------------------------------------
-- Minimal Lua table serializer (for meta.lua)
-- ---------------------------------------------------------------------------

local function ser(v)
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return string.format("%q", v) end
  if t == "table" then
    local parts = {}
    for k, val in pairs(v) do
      local key
      if type(k) == "number" then
        key = "[" .. tostring(k) .. "]"
      elseif type(k) == "string" and k:match("^[%a_][%w_]*$") then
        key = k
      else
        key = "[" .. string.format("%q", tostring(k)) .. "]"
      end
      parts[#parts + 1] = key .. " = " .. ser(val)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  return "nil"
end

-- ---------------------------------------------------------------------------
-- Layout + lazy migration
-- ---------------------------------------------------------------------------

function db.dir()
  return config.get().state_dir
end

function db.packages_dir()
  return path.join(db.dir(), "packages")
end

function db.dependencies_dir()
  return path.join(db.dir(), "dependencies")
end

-- Isolated installs (/zeta/reserve stores) live in a third registry so a
-- package name can exist as both a system package and an isolated store
-- without either view seeing the other.
function db.isolated_dir()
  return path.join(db.dir(), "isolated")
end

local migrated = {}
local migrating = {}

-- Marker left in <state_dir>/ after a successful walk so later invocations
-- skip it entirely. Carries a schema number so a future layout change can
-- force a re-run by bumping MIGRATION_SCHEMA.
local MIGRATION_MARKER = ".migrated"
local MIGRATION_SCHEMA = 1

-- Read an entry's meta straight from a registry we already know holds it.
-- Deliberately not db.get()/db.kind(): each of those stats twice and forks a
-- shell on every miss, which is what made a full walk cost ~30s on a
-- 600-package database.
local function read_meta_at(dir, name)
  local chunk = sandbox.loadfile(path.join(dir, name, "meta.lua"))
  if not chunk then return nil end
  local ok, m = pcall(chunk)
  if not ok or type(m) ~= "table" then return nil end
  return m
end

-- Persist a meta into a registry we already know holds the entry, for the
-- same reason as read_meta_at (db.meta_path() would re-run the kind lookup).
local function write_meta_at(dir, name, m)
  local final = path.join(dir, name, "meta.lua")
  local tmp = final .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return end
  f:write("return " .. ser(m) .. "\n")
  f:close()
  os.rename(tmp, final)
end

local function finish_migration(sd)
  migrating[sd] = nil
  migrated[sd] = true
end

-- Move legacy entries directly under <state_dir>/ into packages/, then mirror
-- every installed entry's `deps` into the `dependents` list of its
-- dependencies. Re-entrant calls during a walk are a no-op; once the marker
-- exists the whole walk is skipped, because builder.commit_wire() keeps
-- `dependents` current from then on and the marker is only written after a
-- complete pass.
local function ensure_migrated()
  local sd = db.dir()
  if migrated[sd] or migrating[sd] then return end
  migrating[sd] = true

  -- io.open, not path.exists: a miss there forks a shell, and this check runs
  -- on every command that touches the database.
  local mf = io.open(path.join(sd, MIGRATION_MARKER), "rb")
  if mf then
    mf:close()
    finish_migration(sd)
    return
  end

  -- 1) Relocate any legacy entries that sit directly under <state_dir>/.
  local f = path.popen("ls -1 " .. path.quote(sd) .. " 2>/dev/null")
  if f then
    for line in f:lines() do
      if line ~= "" and line ~= "packages" and line ~= "dependencies" and line ~= "isolated" then
        local entry = path.join(sd, line)
        if path.exists(path.join(entry, "meta.lua")) then
          path.mkdir_p(db.packages_dir())
          path.run("mv " .. path.quote(entry) .. " " .. path.quote(path.join(db.packages_dir(), line)))
        end
      end
    end
    f:close()
  end

  -- 2) One in-memory pass over both system registries: read each meta once,
  --    derive the dependents each entry should list, and persist only the
  --    entries that actually change. list_packages()/list_dependencies() are
  --    safe here -- they re-enter ensure_migrated(), which returns instantly
  --    on the migrating[sd] guard, then list the directory with io.open
  --    probes only (no forks for entries that are present).
  local packages_dir, dependencies_dir = db.packages_dir(), db.dependencies_dir()
  local reg_of, names, meta = {}, {}, {}
  local function take(reg, list)
    for _, n in ipairs(list) do
      if not reg_of[n] then
        local m = read_meta_at(reg, n)
        if m then
          reg_of[n] = reg
          meta[n] = m
          names[#names + 1] = n
        end
      end
    end
  end
  take(packages_dir, db.list_packages())
  take(dependencies_dir, db.list_dependencies())
  table.sort(names)

  -- Which dependents each entry should list, derived from every entry's deps.
  local wanted = {}
  for _, n in ipairs(names) do
    local deps = meta[n].deps
    if deps then
      for _, d in ipairs(deps) do
        -- Stored metas carry deps as plain names; builder feeds manifests
        -- whose deps are { name=... } tables. Accept both.
        local dn = type(d) == "table" and d.name or d
        -- Only installed entries can carry a back-reference.
        if dn and meta[dn] then
          local list = wanted[dn]
          if not list then list = {}; wanted[dn] = list end
          local seen = false
          for _, e in ipairs(list) do
            if e == n then seen = true break end
          end
          if not seen then list[#list + 1] = n end
        end
      end
    end
  end

  -- Merge rather than replace: an existing list can hold names this walk
  -- cannot derive, and dropping them would break -Delete's checks.
  for _, dep in ipairs(names) do
    local add = wanted[dep]
    if add then
      local m = meta[dep]
      local merged, present = {}, {}
      for _, e in ipairs(m.dependents or {}) do
        merged[#merged + 1] = e
        present[e] = true
      end
      local dirty = false
      for _, n in ipairs(add) do
        if not present[n] then
          merged[#merged + 1] = n
          present[n] = true
          dirty = true
        end
      end
      if dirty then
        m.dependents = merged
        write_meta_at(reg_of[dep], dep, m)
      end
    end
  end

  -- 3) Persist the marker. Best effort: a read-only state dir must not leave
  --    this process stuck re-running the walk on every call.
  local tmp = path.join(sd, MIGRATION_MARKER .. ".tmp")
  local h = io.open(tmp, "wb")
  if h then
    h:write("schema = " .. tostring(MIGRATION_SCHEMA) .. "\n")
    h:close()
    os.rename(tmp, path.join(sd, MIGRATION_MARKER))
  end

  finish_migration(sd)
end

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

-- The on-disk directory for `name`, resolved by its current kind. Entries
-- that are not installed yet default to the packages registry (used when
-- recording a fresh package).
function db.pkg_dir(name)
  if db.kind(name) == "dependency" then
    return path.join(db.dependencies_dir(), name)
  end
  return path.join(db.packages_dir(), name)
end

function db.meta_path(name)
  return path.join(db.pkg_dir(name), "meta.lua")
end

function db.files_path(name)
  return path.join(db.pkg_dir(name), "files")
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- "package" for explicit installs, "dependency" for auto-installed ones,
-- nil when not installed.
function db.kind(name)
  ensure_migrated()
  if path.exists(path.join(db.packages_dir(), name, "meta.lua")) then return "package" end
  if path.exists(path.join(db.dependencies_dir(), name, "meta.lua")) then return "dependency" end
  return nil
end

function db.is_installed(name)
  return db.kind(name) ~= nil
end

function db.get(name)
  if not db.is_installed(name) then return nil end
  local chunk, err = sandbox.loadfile(db.meta_path(name))
  if not chunk then return nil end
  local ok, m = pcall(chunk)
  if not ok or type(m) ~= "table" then return nil end
  return m
end

local function list_dir(dir)
  local names = {}
  local f = path.popen("ls -1 " .. path.quote(dir) .. " 2>/dev/null")
  if f then
    for line in f:lines() do
      if line ~= "" and path.exists(path.join(dir, line, "meta.lua")) then
        names[#names + 1] = line
      end
    end
    f:close()
  end
  table.sort(names)
  return names
end

function db.list_packages()
  ensure_migrated()
  return list_dir(db.packages_dir())
end

function db.list_dependencies()
  ensure_migrated()
  return list_dir(db.dependencies_dir())
end

-- Isolated registry queries. These intentionally do NOT participate in
-- db.kind / db.list / db.files: the same name may be installed both ways and
-- the two views must never mix.

function db.isolated(name)
  return path.exists(path.join(db.isolated_dir(), name, "meta.lua"))
end

function db.list_isolated()
  return list_dir(db.isolated_dir())
end

function db.isolated_meta(name)
  local chunk = sandbox.loadfile(path.join(db.isolated_dir(), name, "meta.lua"))
  if not chunk then return nil end
  local ok, m = pcall(chunk)
  if not ok or type(m) ~= "table" then return nil end
  return m
end

function db.isolated_files(name)
  local f = io.open(path.join(db.isolated_dir(), name, "files"), "rb")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local files = {}
  for line in content:gmatch("[^\n]+") do
    if line ~= "" then files[#files + 1] = line end
  end
  return files
end

-- Every installed entry (packages + dependencies), sorted.
function db.list()
  local names = db.list_packages()
  for _, n in ipairs(db.list_dependencies()) do names[#names + 1] = n end
  table.sort(names)
  return names
end

function db.files(name)
  local f = io.open(db.files_path(name), "rb")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local files = {}
  for line in content:gmatch("[^\n]+") do
    if line ~= "" then files[#files + 1] = line end
  end
  return files
end

-- Installed entries that depend on `name`, from the stored `dependents` list.
-- Each install maintains that list (see db.record); migration wires it for
-- pre-existing entries. Stale references to deleted entries are dropped.
function db.reverse_dependents(name)
  ensure_migrated()
  local m = db.get(name)
  local out = {}
  for _, d in ipairs(m and m.dependents or {}) do
    if type(d) == "string" and db.is_installed(d) then out[#out + 1] = d end
  end
  table.sort(out)
  return out
end

-- Return a list of installed packages (excluding `name`) that also list
-- `file` in their files list. Used by -Delete to decide whether a shared
-- file can safely be deleted.
-- `index` is an optional prebuilt db.file_owner_index(): passing it turns
-- the call into an O(1) lookup instead of a full database rescan.
function db.other_owners(name, file, index)
  local others = {}
  if index then
    for n in pairs(index[file] or {}) do
      if n ~= name then others[#others + 1] = n end
    end
    table.sort(others)
    return others
  end
  for _, n in ipairs(db.list()) do
    if n ~= name then
      local files = db.files(n)
      for _, f in ipairs(files) do
        if f == file then
          others[#others + 1] = n
          break
        end
      end
    end
  end
  return others
end

-- One-pass ownership map: rel path -> { pkg = true, ... }.
-- -Delete builds this once per transaction; checking thousands of files then
-- costs a single hash lookup each instead of rescanning every package's file
-- list per file (which dominated deletion time on large packages).
function db.file_owner_index()
  ensure_migrated()
  local index = {}
  for _, n in ipairs(db.list()) do
    for _, f in ipairs(db.files(n)) do
      local e = index[f]
      if not e then e = {}; index[f] = e end
      e[n] = true
    end
  end
  return index
end

-- ---------------------------------------------------------------------------
-- Mutation
-- ---------------------------------------------------------------------------

-- Rewrite only the meta.lua of an installed entry (keeps `files` untouched).
local function write_meta(name, m)
  local t1 = db.meta_path(name) .. ".tmp"
  local f = io.open(t1, "wb")
  f:write("return " .. ser(m) .. "\n")
  f:close()
  os.rename(t1, db.meta_path(name))
end

-- Record an installed entry. Writes are atomic (write temp, then rename), so
-- an interrupted install never leaves a half-written database entry.
-- opts: { kind = "package" | "dependency", isolated = bool, reserve_root }.
-- Isolated entries go to the isolated/ registry and carry their store path;
-- they never migrate between registries and never mix with system entries.
-- An existing entry's `dependents` list is preserved across reinstalls.
function db.record(name, meta, files, opts)
  opts = opts or {}
  local kind = opts.kind == "dependency" and "dependency" or "package"
  ensure_migrated()

  local here, old
  if opts.isolated then
    here = db.isolated_dir()
    old = db.isolated_meta(name)
  else
    old = db.get(name)
    -- Re-classification moves the entry between registries; delete the stale
    -- location so a name never exists in both.
    here = kind == "dependency" and db.dependencies_dir() or db.packages_dir()
    local other = kind == "dependency" and db.packages_dir() or db.dependencies_dir()
    if path.exists(path.join(other, name, "meta.lua")) then
      path.run("rm -rf " .. path.quote(path.join(other, name)))
    end
  end
  local deps = {}
  for _, d in ipairs(meta.deps or {}) do
    deps[#deps + 1] = d.name
  end
  local m = {
    name = meta.name,
    version = meta.version,
    summary = meta.summary,
    url = meta.url,
    sha256 = meta.sha256,
    arch = meta.arch,
    prefix = meta.prefix,
    deps = deps,
    dependents = (old and old.dependents) or {},
    source = meta.source or "remote",
    installed_at = os.time(),
  }
  if opts.isolated then
    m.isolated = true
    m.reserve_root = opts.reserve_root
  end
  path.mkdir_p(path.join(here, name))
  local t1 = path.join(here, name, "meta.lua.tmp")
  local t2 = path.join(here, name, "files.tmp")
  local f = io.open(t1, "wb")
  f:write("return " .. ser(m) .. "\n")
  f:close()
  local g = io.open(t2, "wb")
  g:write(table.concat(files, "\n") .. "\n")
  g:close()
  os.rename(t1, path.join(here, name, "meta.lua"))
  os.rename(t2, path.join(here, name, "files"))
end

-- Record that `pkg` depends on `dep`. No-op when `dep` is not installed (the
-- dependent may record it afterwards, or never) or is already listed.
function db.add_dependent(dep, pkg)
  ensure_migrated()
  if not db.is_installed(dep) then return end
  local m = db.get(dep)
  if not m then return end
  for _, d in ipairs(m.dependents or {}) do
    if d == pkg then return end
  end
  local list = m.dependents or {}
  list[#list + 1] = pkg
  m.dependents = list
  write_meta(dep, m)
end

-- Drop `pkg` from `dep`'s dependents list. No-op when `dep` is not installed.
function db.delete_dependent(dep, pkg)
  ensure_migrated()
  if not db.is_installed(dep) then return end
  local m = db.get(dep)
  if not m then return end
  local list = {}
  local changed = false
  for _, d in ipairs(m.dependents or {}) do
    if d ~= pkg then list[#list + 1] = d else changed = true end
  end
  if changed then
    m.dependents = list
    write_meta(dep, m)
  end
end

function db.delete(name)
  ensure_migrated()
  path.run("rm -rf " .. path.quote(db.pkg_dir(name)))
end

-- Delete an isolated registry entry (the store itself is deleted by the
-- caller, which owns the reserve path).
function db.delete_isolated(name)
  path.run("rm -rf " .. path.quote(path.join(db.isolated_dir(), name)))
end

-- Return the name of the package that owns `rel`, or nil if untracked.
-- Used by hooks to validate that a hook's trigger targets its owning package.
function db.file_owner(rel)
  ensure_migrated()
  for _, n in ipairs(db.list()) do
    for _, f in ipairs(db.files(n)) do
      if f == rel then return n end
    end
  end
  return nil
end

return db
