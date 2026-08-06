-- config.lua -- all roots and locations, derived exclusively from environment
-- variables.
--
-- Zeta must not depend on any specific distribution: it never reads
-- /etc/os-release, /etc/rc.*, or any init-system state. Everything is
-- configured by these environment variables (all optional):
--
--   ZETA_ROOT            filesystem root packages are installed into  (default /)
--   ZETA_REPO            remote repository base URL                     (default https://github.com/gretagen/zeta-packages;
--                        github.com URLs are fetched via raw.githubusercontent.com)
--   ZETA_LOCAL_PACKAGES  directory tree of local packages              (default <root>/usr/share/packages,
--                        else <script_dir>/packages so an unpacked checkout works with no env)
--   ZETA_CACHE           download cache                                 (default <root>/var/cache/zeta)
--   ZETA_STATE           installed-package database                    (default <root>/var/db/zeta)
--   ZETA_TMP             staging + build work area                     (default <root>/var/tmp/zeta)
--
-- ZETA_ROOT is how Zeta stays "rooted" and testable: point it at a scratch
-- directory and every install, database write, and removal happens under it.

local config = {}

local path = require("path")

-- Environment overrides. Tests (and only tests) use config.setenv to inject
-- values portably on Lua 5.1, which has no os.setenv.
local _overrides = {}
local _cfg
local _script_dir

function config.setenv(k, v)
  _overrides[k] = v
end

function config.reset()
  _overrides = {}
  _cfg = nil
  _script_dir = nil
end

local function getenv(k)
  local v = _overrides[k]
  if v ~= nil then return v end
  return os.getenv(k)
end

-- Resolve the local package tree. ZETA_LOCAL_PACKAGES is authoritative when
-- set; otherwise the documented default <root>/usr/share/packages wins if it
-- exists, and only then we fall back to <script_dir>/packages so an unpacked
-- checkout works offline with no environment at all.
local function resolve_local_packages(root, under)
  local env = getenv("ZETA_LOCAL_PACKAGES")
  if env then return env end
  local sys = under("usr/share/packages")
  if path.exists(sys) then return sys end
  if _script_dir then
    local checkout = path.join(_script_dir, "packages")
    if path.exists(checkout) then return checkout end
  end
  return sys
end

function config.load(script_dir)
  if script_dir then _script_dir = script_dir end
  local root = getenv("ZETA_ROOT") or "/"
  if root == "" then root = "/" end
  local function under(p)
    if path.is_abs(p) then return p end
    return path.join(root, p)
  end
  _cfg = {
    root = root,
    repo = getenv("ZETA_REPO") or "https://github.com/gretagen/zeta-packages",
    local_packages = resolve_local_packages(root, under),
    cache_dir = getenv("ZETA_CACHE") or under("var/cache/zeta"),
    state_dir = getenv("ZETA_STATE") or under("var/db/zeta"),
    tmp_dir = getenv("ZETA_TMP") or under("var/tmp/zeta"),
  }
  return _cfg
end

function config.get()
  if not _cfg then config.load() end
  return _cfg
end

return config
