-- db.lua -- the installed-package database.
--
-- State lives at <ZETA_ROOT>/var/db/zeta/ split into two registries:
--   packages/<name>/      explicitly installed packages (kind = "package")
--   dependencies/<name>/   packages pulled in automatically as dependencies
--                          (kind = "dependency")
-- Each entry contains:
--   meta.lua  -- a serialized manifest (return {...}), loaded under the sandbox
--   files     -- one owned relative path per line
--
-- A dependency's meta.lua also carries `dependents`, the list of installed
-- entries that depend on it. That back-reference is what lets -Remove decide
-- whether an entry is still required and lets --with-deps cascade safely.
--
-- Legacy databases (entries directly under <state_dir>/<name>) are migrated
-- lazily, once per state dir, into the packages/ registry.
--
-- The "files" list is the authoritative set of what -Remove may touch: removal
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

local migrated = {}
local migrating = {}

-- Move legacy entries directly under <state_dir>/ into packages/, then mirror
-- every installed entry's `deps` into the `dependents` list of its
-- dependencies. Keyed by state dir so tests and alternate roots each migrate
-- exactly once; a re-entrant call during migration is a no-op.
local function ensure_migrated()
  local sd = db.dir()
  if migrated[sd] or migrating[sd] then return end
  migrating[sd] = true

  local f = io.popen("ls -1 " .. path.quote(sd) .. " 2>/dev/null")
  if f then
    for line in f:lines() do
      if line ~= "" and line ~= "packages" and line ~= "dependencies" then
        local entry = path.join(sd, line)
        if path.exists(path.join(entry, "meta.lua")) then
          path.mkdir_p(db.packages_dir())
          path.run("mv " .. path.quote(entry) .. " " .. path.quote(path.join(db.packages_dir(), line)))
        end
      end
    end
    f:close()
  end

  for _, n in ipairs(db.list()) do
    local m = db.get(n)
    if m and m.deps then
      -- Stored metas carry deps as plain names; builder feeds manifests
      -- whose deps are { name=... } tables. Accept both.
      for _, d in ipairs(m.deps) do
        local dn = type(d) == "table" and d.name or d
        if dn then db.add_dependent(dn, n) end
      end
    end
  end

  migrating[sd] = nil
  migrated[sd] = true
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
  local f = io.popen("ls -1 " .. path.quote(dir) .. " 2>/dev/null")
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
-- pre-existing entries. Stale references to removed entries are dropped.
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
-- `file` in their files list. Used by -Remove to decide whether a shared
-- file can safely be deleted.
function db.other_owners(name, file)
  local others = {}
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
-- opts: { kind = "package" | "dependency" }. An existing entry's `dependents`
-- list is preserved across reinstalls.
function db.record(name, meta, files, opts)
  opts = opts or {}
  local kind = opts.kind == "dependency" and "dependency" or "package"
  ensure_migrated()
  local old = db.get(name)
  -- Re-classification moves the entry between registries; remove the stale
  -- location so a name never exists in both.
  local here = kind == "dependency" and db.dependencies_dir() or db.packages_dir()
  local other = kind == "dependency" and db.packages_dir() or db.dependencies_dir()
  if path.exists(path.join(other, name, "meta.lua")) then
    path.run("rm -rf " .. path.quote(path.join(other, name)))
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
function db.remove_dependent(dep, pkg)
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

function db.remove(name)
  ensure_migrated()
  path.run("rm -rf " .. path.quote(db.pkg_dir(name)))
end

-- Check if `rel` is tracked by any package (optionally excluding `exclude`).
-- Used by commit.lua to prevent overwriting untracked files.
function db.is_file_owned(rel, exclude)
  ensure_migrated()
  for _, n in ipairs(db.list()) do
    if n ~= exclude then
      for _, f in ipairs(db.files(n)) do
        if f == rel then return true end
      end
    end
  end
  return false
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
