-- actions.lua -- command handlers. Thin wiring between the CLI, dependency
-- resolution, the builder, and the database. All confirmation prompts honor
-- the --pass flag (skip Y/N and proceed immediately).

local actions = {}

local config = require("config")
local log = require("log")
local path = require("path")
local db = require("db")
local repo = require("repo")
local deps = require("deps")
local builder = require("builder")
local manifest = require("manifest")

local HELP = [[
Zeta -- Zerene OS package manager

Usage: zeta <command> [argument] [flags]

Commands:
  -Provide <pkg>       Install <pkg> and its dependencies from the remote repository
  -ReProvide <pkg>     Reinstall <pkg> even if it is already installed
  -LocalProvide <pkg>  Install <pkg> from the local /packages tree
  -Remove <pkg>        Remove an installed <pkg>
  -List                List all installed packages
  -Localize <query>    Search the remote repository index for <query>
  -Test <pkg>          Verify <pkg> offline WITHOUT installing it
  -Help                Show this help

Flags:
  --pass               Skip the Y/N confirmation prompt and proceed immediately
  --force              Override file-conflict and reverse-dependency safety checks

Environment:
  ZETA_ROOT            Filesystem root packages are installed into   (default: /)
  ZETA_REPO            Remote repository base URL (github.com served via    (default: https://github.com/gretagen/zeta-packages)
                       raw.githubusercontent.com)
  ZETA_LOCAL_PACKAGES  Local /packages tree                          (default: /usr/share/packages)
  ZETA_CACHE           Download cache                                (default: $ZETA_ROOT/var/cache/zeta)
  ZETA_STATE           Package database                              (default: $ZETA_ROOT/var/db/zeta)

Package format (one package.lua per package, returning a table):
  return {
    name="glib", version="2.88.1", url="https://.../glib-2.88.1.tar.xz",
    sha256="...", deps={"libffi","pcre2"},
    archive={ strip=1 },          -- binary install: fetch, unpack, install
    -- or: install=function(p) ... end,   or: build=function(p) ... end
    test=function(p) ... end,     -- optional verification hook for -Test
  }

-Test runs the package's full pipeline (fetch, checksum, unpack/build) into a
scratch directory and then runs its `test` hook when declared; without a hook
it passes on payload integrity plus a non-empty staging tree. It is strictly
offline and never installs anything or touches the package database.

Zeta never reads or writes init-system configuration (systemd, OpenRC,
sysvinit) and never touches distro-identity files such as /etc/os-release.
]]

function actions.help()
  io.write(HELP)
end

-- Y/N confirmation. --pass skips it. Returns true to proceed.
local function confirm(msg, pass)
  if pass then return true end
  io.write(msg .. "  Proceed? [y/N] ")
  io.flush()
  local line = io.read("*l")
  if not line then return false end
  line = line:lower()
  return line == "y" or line == "yes"
end

-- Shared install flow for -Provide / -LocalProvide / -ReProvide.
function actions._install(name, flags, opts)
  local source = opts.source
  local base = config.get().local_packages

  local fetch_manifest
  if source == "local" then
    -- Local packages resolve from the local tree; deps missing there fall
    -- back to the remote repository, so mixed trees keep working.
    fetch_manifest = function(n)
      local m, err = manifest.load(path.join(base, n, "package.lua"))
      if m then
        local ok, cerr = manifest.check_name(m, n)
        if not ok then return nil, cerr end
        m._local_dir = path.join(base, n)
        return m
      end
      log.detail(("local package %q not found, falling back to remote"):format(n))
      return repo.fetch_manifest(n)
    end
  else
    fetch_manifest = function(n)
      return repo.fetch_manifest(n)
    end
  end

  local ok, plan = pcall(deps.resolve, name, {
    fetch_manifest = fetch_manifest,
    installed_version = function(n)
      local m = db.get(n)
      return m and m.version or nil
    end,
  })
  if not ok then
    log.error(tostring(plan))
    return 1
  end
  if #plan == 0 then return 0 end

  print("")
  for _, item in ipairs(plan) do
    print(("  will install %s-%s"):format(item.name, item.manifest.version))
  end
  print("")

  if not confirm(("Install %d package(s)?"):format(#plan), flags.pass) then
    log.info("aborted by user")
    return 0
  end

  for _, item in ipairs(plan) do
    if db.is_installed(item.name) and not flags.force then
      log.warn(("%s already installed, skipping"):format(item.name))
    else
      local iok, ierr = pcall(builder.install, item.manifest, {
        force = flags.force,
        source = source,
        local_dir = item.manifest._local_dir,
      })
      if not iok then
        log.error(tostring(ierr))
        return 1
      end
    end
  end
  return 0
end

function actions.provide(name, flags)
  name = path.sanitize_name(name)
  if not name then
    log.error("invalid package name")
    return 1
  end
  if not flags.force and db.is_installed(name) then
    local m = db.get(name)
    log.warn(("%s-%s is already installed -- use -ReProvide to reinstall"):format(
      name, m and m.version or "?"))
    return 0
  end
  return actions._install(name, flags, { source = "remote" })
end

function actions.reprovide(name, flags)
  name = path.sanitize_name(name)
  if not name then
    log.error("invalid package name")
    return 1
  end
  return actions._install(name, { pass = flags.pass, force = true }, { source = "remote" })
end

function actions.localprovide(name, flags)
  name = path.sanitize_name(name)
  if not name then
    log.error("invalid package name")
    return 1
  end
  if not flags.force and db.is_installed(name) then
    local m = db.get(name)
    log.warn(("%s-%s is already installed -- use -ReProvide to reinstall"):format(
      name, m and m.version or "?"))
    return 0
  end
  return actions._install(name, flags, { source = "local" })
end

function actions.list()
  local names = db.list()
  if #names == 0 then
    log.info("no packages installed")
    return 0
  end
  print(("%-20s %-16s %s"):format("PACKAGE", "VERSION", "DEPS"))
  print(string.rep("-", 60))
  for _, n in ipairs(names) do
    local m = db.get(n)
    local deps_str = (m and m.deps and #m.deps > 0) and table.concat(m.deps, " ") or "-"
    print(("%-20s %-16s %s"):format(n, m and m.version or "?", deps_str))
  end
  return 0
end

function actions.localize(query)
  local matches, err = repo.search(query)
  if not matches then
    log.error(tostring(err))
    return 1
  end
  if #matches == 0 then
    log.info(("no packages match %q"):format(query))
    return 0
  end
  print(("%-20s %-16s %s"):format("PACKAGE", "VERSION", "SUMMARY"))
  print(string.rep("-", 70))
  for _, m in ipairs(matches) do
    print(("%-20s %-16s %s"):format(m.name, m.version or "?", m.summary or ""))
  end
  return 0
end

-- -Test <pkg>: strictly offline validation. Resolution is local-tree only
-- (no remote fallback) and any manifest whose payload is a remote url is
-- refused. Nothing is installed, committed, or recorded -- build + test run
-- against a scratch tree that is discarded afterwards.
function actions.test(name, flags)
  name = path.sanitize_name(name)
  if not name then
    log.error("invalid package name")
    return 1
  end
  local base = config.get().local_packages

  local fetch_manifest = function(n)
    local dir = path.join(base, n)
    local m, err = manifest.load(path.join(dir, "package.lua"))
    if not m then
      return nil, ("package %q not found in local tree %s (offline test, no remote fallback)"):format(
        n, base)
    end
    local ok, cerr = manifest.check_name(m, n)
    if not ok then return nil, cerr end
    if m.url and m.url:match("^https?://") then
      return nil, ("offline test refused: %s-%s has a remote url %s"):format(
        m.name, m.version, m.url)
    end
    m._local_dir = dir
    return m
  end

  local ok, plan = pcall(deps.resolve, name, {
    fetch_manifest = fetch_manifest,
    installed_version = function(n)
      local m = db.get(n)
      return m and m.version or nil
    end,
  })
  if not ok then
    log.error(tostring(plan))
    return 1
  end
  if #plan == 0 then return 0 end

  print("")
  for _, item in ipairs(plan) do
    print(("  will test %s-%s"):format(item.name, item.manifest.version))
  end
  print("")

  for _, item in ipairs(plan) do
    local tok, terr = pcall(builder.test, item.manifest, {
      local_dir = item.manifest._local_dir,
    })
    if not tok then
      log.error(tostring(terr))
      return 1
    end
  end
  return 0
end

function actions.remove(name, flags)
  name = path.sanitize_name(name)
  if not name then
    log.error("invalid package name")
    return 1
  end
  if not db.is_installed(name) then
    log.error(("%s is not installed"):format(name))
    return 1
  end
  local rd = db.reverse_dependents(name)
  if #rd > 0 and not flags.force then
    log.error(("cannot remove %s: still required by %s (use --force to override)"):format(
      name, table.concat(rd, ", ")))
    return 1
  end
  local m = db.get(name)
  local files = db.files(name)
  log.step(("removing %s-%s (%d files)"):format(name, m and m.version or "?", #files))
  for _, rel in ipairs(files) do
    log.detail(("  remove %s"):format(rel))
  end
  if not confirm(("Remove %s?"):format(name), flags.pass) then
    log.info("aborted by user")
    return 0
  end
  local root = config.get().root
  local dirs = {}
  local seen = {}
  for _, rel in ipairs(files) do
    local p = path.join(root, rel)
    os.remove(p)
    local d = path.dirname(p)
    while d ~= "/" and d ~= "." and not seen[d] do
      seen[d] = true
      dirs[#dirs + 1] = d
      d = path.dirname(d)
    end
  end
  table.sort(dirs, function(a, b) return #a > #b end)
  for _, d in ipairs(dirs) do
    os.remove(d) -- rmdir; silently fails when non-empty
  end
  db.remove(name)
  log.ok(("removed %s"):format(name))
  return 0
end

return actions
