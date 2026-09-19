-- config.lua -- configuration with layered precedence:
--   1. Environment variables (highest priority)
--   2. /etc/zeta/configuration.lua (config file)
--   3. Built-in defaults (lowest priority)
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
local _config_file = "/etc/zeta/configuration.lua"

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

-- Load a Lua config file that returns a table. Returns the table or nil.
local function load_config_file(filepath)
  local ok, result = pcall(dofile, filepath)
  if ok and type(result) == "table" then
    return result
  end
  return nil
end

-- Resolve the local package tree. ZETA_LOCAL_PACKAGES is authoritative when
-- set; otherwise the documented default <root>/usr/share/packages wins if it
-- exists, and only then we fall back to <script_dir>/packages so an unpacked
-- checkout works offline with no environment at all.
local function resolve_local_packages(root, under, cfg_file)
  local env = getenv("ZETA_LOCAL_PACKAGES")
  if env then return env end
  if cfg_file and cfg_file.local_packages then return cfg_file.local_packages end
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

  -- Layer 1: Load config file.
  local cfg_file = load_config_file(_config_file)

  -- Layer 2: Resolve root (env > config file > default).
  local root = getenv("ZETA_ROOT") or (cfg_file and cfg_file.root) or "/"
  if root == "" then root = "/" end
  local function under(p)
    if path.is_abs(p) then return p end
    return path.join(root, p)
  end

  -- Layer 3: Build full config table with env > file > defaults.
  _cfg = {
    root = root,
    repo = getenv("ZETA_REPO") or (cfg_file and cfg_file.repo) or "https://github.com/gretagen/zeta-index",
    local_packages = resolve_local_packages(root, under, cfg_file),
    cache_dir = getenv("ZETA_CACHE") or (cfg_file and cfg_file.cache_dir) or under("var/cache/zeta"),
    state_dir = getenv("ZETA_STATE") or (cfg_file and cfg_file.state_dir) or under("var/db/zeta"),
    tmp_dir = getenv("ZETA_TMP") or (cfg_file and cfg_file.tmp_dir) or under("var/tmp/zeta"),
    verbose = (getenv("ZETA_VERBOSE") == "1" or getenv("ZETA_VERBOSE") == "true")
              or (cfg_file and cfg_file.verbose == true)
              or false,
    quotes = not (
      (getenv("ZETA_QUOTES") == "false" or getenv("ZETA_QUOTES") == "0")
      or (cfg_file and cfg_file.quotes == false)
    ),
  }
  return _cfg
end

function config.get()
  if not _cfg then config.load() end
  return _cfg
end

return config
