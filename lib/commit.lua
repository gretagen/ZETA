-- commit.lua -- merge a staged install root into the filesystem.
--
-- Zeta's hard design constraint is enforced here: NO package may ever place
-- a file in an init-system path (systemd, OpenRC, sysvinit, runit, ...) or
-- claim distro identity (/etc/os-release etc.). Those paths are reserved for
-- the distribution itself. Combined with the manifest sandbox and the p API
-- in builder.lua, this is what keeps Zeta init- and distro-agnostic.
--
-- The staged tree is walked (via `find -printf`, available on all mainstream
-- find implementations), every file is scanned against the blocklist BEFORE
-- anything is copied, cross-package file conflicts abort the install, and
-- only then are files copied into ZETA_ROOT.

local commit = {}

local path = require("path")
local db = require("db")
local config = require("config")
local log = require("log")

-- Files under these prefixes would wire a package into a specific init system.
local BLOCKED_PREFIXES = {
  "etc/systemd",
  "usr/lib/systemd",
  "lib/systemd",
  "etc/init.d",
  "etc/rc.d",
  "etc/init",
  "lib/rc",
  "usr/lib/rc",
  "etc/runlevels",
}

-- Files that would claim or override distribution identity / boot policy.
local BLOCKED_EXACT = {
  "etc/rc.conf",
  "etc/rc.local",
  "etc/rc.shutdown",
  "etc/inittab",
  "etc/os-release",
  "etc/lsb-release",
}

-- systemd unit file extensions: hooking these would assume systemd.
local BLOCKED_SUFFIXES = {
  ".service", ".timer", ".socket", ".path", ".mount",
  ".target", ".unit", ".automount", ".device", ".slice", ".scope",
}

local function blocked(rel)
  for _, p in ipairs(BLOCKED_PREFIXES) do
    if rel == p or rel:sub(1, #p + 1) == p .. "/" then
      return "reserved init-system path: " .. rel
    end
  end
  for _, e in ipairs(BLOCKED_EXACT) do
    if rel == e then
      return "reserved distro-identity path: " .. rel
    end
  end
  for _, s in ipairs(BLOCKED_SUFFIXES) do
    if rel:sub(-#s) == s then
      return "init unit file: " .. rel
    end
  end
  return nil
end

-- Walk a staged tree: returns entries { { rel, type, target } } where type is
-- "file", "dir" or "symlink". Uses find -printf ('%y|%l|%P') which gives
-- type, symlink target, and root-relative path on a single line.
local function walk_staging(staging)
  local f = io.popen("find " .. path.quote(staging)
    .. " -mindepth 1 -printf '%y|%l|%P\\n' 2>/dev/null")
  if not f then
    error(("could not scan staging directory %s"):format(staging), 0)
  end
  local out = {}
  for line in f:lines() do
    local typ, rest = line:match("^([%w])%|(.*)$")
      if typ then
        local link, rel = rest:match("^([^%|]*)%|(.*)$")
        if not link then link = "" end
        out[#out + 1] = {
          rel = rel,
          type = (typ == "d" and "dir" or (typ == "l" and "symlink" or "file")),
          target = (link ~= "" and link or nil),
        }
      end
  end
  f:close()
  return out
end

-- apply(staging, opts) -> owned entries (files + symlinks).
-- opts: whitelist (list of rel paths to commit), force, pkg_name.
function commit.apply(staging, opts)
  opts = opts or {}
  local entries = walk_staging(staging)

  if opts.whitelist then
    local wl = {}
    for _, w in ipairs(opts.whitelist) do wl[w] = true end
    local filtered = {}
    for _, e in ipairs(entries) do
      if e.type == "dir" or wl[e.rel] then filtered[#filtered + 1] = e end
    end
    entries = filtered
  end

  -- Ownership index for conflict detection (excluding this package itself,
  -- which may legitimately overwrite its own previously installed files).
  local owners = {}
  for _, n in ipairs(db.list()) do
    if n ~= opts.pkg_name then
      for _, rel in ipairs(db.files(n)) do owners[rel] = n end
    end
  end

  local root = config.get().root

  -- Pre-flight: enforcement scan + conflict check, BEFORE copying anything,
  -- so a bad package leaves the filesystem untouched.
  local owned = {}
  for _, e in ipairs(entries) do
    if e.type ~= "dir" then
      local why = blocked(e.rel)
      if why then
        error(("refusing to install %q from %s: %s (Zeta is init- and distro-agnostic; init hooks and distro-identity files are never installed)"):format(
          e.rel, opts.pkg_name or "package", why), 0)
      end
      local who = owners[e.rel]
      if who and not opts.force then
        error(("file conflict: %s is already owned by installed package %s (use --force to override)"):format(
          e.rel, who), 0)
      end
      owned[#owned + 1] = e
    end
  end

  -- Copy phase.
  for _, e in ipairs(owned) do
    local dest = path.join(root, e.rel)
    local src = path.join(staging, e.rel)
    path.mkdir_p(path.dirname(dest))
    if e.type == "symlink" then
      if path.symlink_escapes(e.rel, e.target) then
        error(("symlink %q -> %q escapes the root"):format(e.rel, e.target), 0)
      end
      os.remove(dest)
      if not path.run("ln -s " .. path.quote(e.target) .. " " .. path.quote(dest)) then
        error(("failed to create symlink %q"):format(dest), 0)
      end
      log.detail(("installed symlink %s -> %s"):format(e.rel, e.target))
    else
      if owners[e.rel] then
        log.warn(("overwriting %q owned by %q"):format(e.rel, owners[e.rel]))
      end
      if not path.run("cp -a " .. path.quote(src) .. " " .. path.quote(dest)) then
        error(("failed to install %q"):format(e.rel), 0)
      end
      log.detail(("installed %s"):format(e.rel))
    end
  end

  log.ok(("committed %d file(s) to %s"):format(#owned, root))

  -- Auto-compile GSettings schemas if any were installed.
  local schemas_dir = root .. "/usr/share/glib-2.0/schemas"
  local has_schema = false
  for _, e in ipairs(owned) do
    if e.rel:match("^usr/share/glib%-2%.0/schemas/.+%.gschema%.xml$") then
      has_schema = true
      break
    end
  end
  if has_schema then
    local compile = "glib-compile-schemas " .. path.quote(schemas_dir)
    log.step("compiling GSettings schemas")
    if path.run(compile) then
      log.ok("gschemas.compiled generated")
    else
      log.warn("glib-compile-schemas failed (non-fatal)")
    end
  end

  return owned
end

return commit
