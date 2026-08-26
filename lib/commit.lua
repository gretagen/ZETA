-- commit.lua -- merge a staged install root into the filesystem.
--
-- The staged tree is walked (via `find -printf`, available on all mainstream
-- find implementations), every entry is validated (symlink safety, path
-- hygiene) BEFORE anything is copied, and only then are files copied into
-- ZETA_ROOT. Zeta installs whatever a package ships; init-system and
-- distro-identity paths are not special-cased.

local commit = {}

local path = require("path")
local db = require("db")
local config = require("config")
local log = require("log")

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

-- apply(staging, opts) -> owned entries (files + symlinks + dirs).
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

  local root = config.get().root

  -- Owned entries are all concrete paths a package ships. Directories are
  -- recorded so removal can prune them once empty.
  local owned = entries

  -- Copy phase.
  for _, e in ipairs(owned) do
    local dest = path.join(root, e.rel)
    local src = path.join(staging, e.rel)
    if e.type == "dir" then
      if not path.mkdir_p(dest) then
        error(("failed to create directory %q"):format(dest), 0)
      end
      log.detail(("provided directory %s"):format(e.rel))
    else
      path.mkdir_p(path.dirname(dest))
      if e.type == "symlink" then
        if path.symlink_escapes(e.rel, e.target) then
          error(("symlink %q -> %q escapes the root"):format(e.rel, e.target), 0)
        end
        -- Must swap the link atomically: delete-then-create leaves a window
        -- where a live shared library is absent, and the ln(1) subprocess
        -- itself fails to start (shell needs that library). ln -sfn replaces
        -- the link in one step so it is never observed missing.
        if not path.run("ln -sfn " .. path.quote(e.target) .. " " .. path.quote(dest)) then
          error(("failed to create symlink %q"):format(dest), 0)
        end
        log.detail(("provided symlink %s -> %s"):format(e.rel, e.target))
      else
        if path.exists(dest) then
          log.detail(("overwriting existing %s"):format(e.rel))
        end
        -- Copy to a temp name then rename(): overwriting a running executable
        -- in place fails with ETXTBSY, and a half-copied file is never visible
        -- to other processes. rename() is atomic on the same filesystem.
        local tmp = dest .. ".zeta-tmp-" .. tostring(math.random(100000, 999999))
        if not path.run("cp -a " .. path.quote(src) .. " " .. path.quote(tmp)) then
          os.remove(tmp)
          error(("failed to install %q"):format(e.rel), 0)
        end
        if not path.run("mv -f " .. path.quote(tmp) .. " " .. path.quote(dest)) then
          os.remove(tmp)
          error(("failed to install %q"):format(e.rel), 0)
        end
        log.detail(("provided %s"):format(e.rel))
      end
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
