-- config.lua suite -- local package-tree discovery: ZETA_LOCAL_PACKAGES is
-- authoritative when set; otherwise <root>/usr/share/packages wins if it
-- exists; otherwise <script_dir>/packages is used so an unpacked checkout
-- works offline with no environment at all.

local lib = require("lib")
local config = require("config")
local path = require("path")
local suite = lib.new_suite("config")

-- Fresh config with a scratch root, no ZETA_LOCAL_PACKAGES set. `script_dir`
-- defaults to nil unless the test provides one.
local function load(script_dir)
  local root = lib.tmpdir("cfg-root")
  config.reset()
  config.setenv("ZETA_ROOT", root)
  config.setenv("ZETA_STATE", path.join(root, "var/db/zeta"))
  config.setenv("ZETA_CACHE", path.join(root, "var/cache/zeta"))
  config.setenv("ZETA_TMP", path.join(root, "var/tmp/zeta"))
  return config.load(script_dir), root
end

suite:test("env ZETA_LOCAL_PACKAGES is authoritative", function()
  local root = lib.tmpdir("cfg-env")
  config.reset()
  config.setenv("ZETA_ROOT", root)
  config.setenv("ZETA_LOCAL_PACKAGES", "/opt/packages")
  local cfg = config.load("/tmp/script")
  lib.assert_eq(cfg.local_packages, "/opt/packages")
end)

suite:test("default <root>/usr/share/packages is used when nothing exists", function()
  local cfg, root = load(nil)
  lib.assert_eq(cfg.local_packages, path.join(root, "usr/share/packages"))
end)

suite:test("script_dir/packages is discovered when it exists", function()
  local script = lib.tmpdir("cfg-script")
  os.execute("mkdir -p " .. path.quote(path.join(script, "packages", "hello")))
  local cfg, _ = load(script)
  lib.assert_eq(cfg.local_packages, path.join(script, "packages"))
end)

suite:test("<root>/usr/share/packages beats script_dir discovery", function()
  local script = lib.tmpdir("cfg-script")
  os.execute("mkdir -p " .. path.quote(path.join(script, "packages")))
  local root = lib.tmpdir("cfg-root")
  os.execute("mkdir -p " .. path.quote(path.join(root, "usr/share/packages")))
  config.reset()
  config.setenv("ZETA_ROOT", root)
  local cfg = config.load(script)
  lib.assert_eq(cfg.local_packages, path.join(root, "usr/share/packages"))
end)

suite:test("env beats both existing discovery directories", function()
  local script = lib.tmpdir("cfg-script")
  os.execute("mkdir -p " .. path.quote(path.join(script, "packages")))
  local root = lib.tmpdir("cfg-root")
  os.execute("mkdir -p " .. path.quote(path.join(root, "usr/share/packages")))
  config.reset()
  config.setenv("ZETA_ROOT", root)
  config.setenv("ZETA_LOCAL_PACKAGES", "/custom/packages")
  local cfg = config.load(script)
  lib.assert_eq(cfg.local_packages, "/custom/packages")
end)

suite:test("discovery falls back to default when script_dir has no packages", function()
  local script = lib.tmpdir("cfg-script")
  local cfg, root = load(script)
  lib.assert_eq(cfg.local_packages, path.join(root, "usr/share/packages"))
end)

suite:test("reset clears the cached script dir", function()
  local script = lib.tmpdir("cfg-script")
  os.execute("mkdir -p " .. path.quote(path.join(script, "packages")))
  local root = lib.tmpdir("cfg-root")
  config.reset()
  config.setenv("ZETA_ROOT", root)
  config.load(script)
  config.reset()
  config.setenv("ZETA_ROOT", root)
  local cfg = config.load()
  lib.assert_eq(cfg.local_packages, path.join(root, "usr/share/packages"))
end)

return suite
