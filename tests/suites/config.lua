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

-- Remote repository list. The client consults every configured repository in
-- order; ZETA_REPOS (space-separated) is the list form, ZETA_REPO the
-- single-URL form kept for back-compat.

suite:test("ZETA_REPOS splits into the repository list", function()
  config.reset()
  config.setenv("ZETA_ROOT", lib.tmpdir("cfg-root"))
  config.setenv("ZETA_REPOS", "/repo/a /repo/b /repo/c")
  local cfg = config.load()
  lib.assert_eq(#cfg.repos, 3)
  lib.assert_eq(cfg.repos[1], "/repo/a")
  lib.assert_eq(cfg.repos[2], "/repo/b")
  lib.assert_eq(cfg.repos[3], "/repo/c")
  lib.assert_eq(cfg.repo, "/repo/a")
end)

suite:test("ZETA_REPO wraps into a single-element list", function()
  config.reset()
  config.setenv("ZETA_ROOT", lib.tmpdir("cfg-root"))
  config.setenv("ZETA_REPO", "/repo/only")
  local cfg = config.load()
  lib.assert_eq(#cfg.repos, 1)
  lib.assert_eq(cfg.repos[1], "/repo/only")
  lib.assert_eq(cfg.repo, "/repo/only")
end)

suite:test("ZETA_REPOS beats ZETA_REPO", function()
  config.reset()
  config.setenv("ZETA_ROOT", lib.tmpdir("cfg-root"))
  config.setenv("ZETA_REPO", "/repo/old")
  config.setenv("ZETA_REPOS", "/repo/one /repo/two")
  local cfg = config.load()
  lib.assert_eq(#cfg.repos, 2)
  lib.assert_eq(cfg.repos[1], "/repo/one")
  lib.assert_eq(cfg.repos[2], "/repo/two")
end)

suite:test("repos defaults to the single zeta-index repository", function()
  config.reset()
  config.setenv("ZETA_ROOT", lib.tmpdir("cfg-root"))
  local cfg = config.load()
  lib.assert_eq(#cfg.repos, 1)
  lib.assert_eq(cfg.repos[1], "https://github.com/gretagen/zeta-index")
  lib.assert_eq(cfg.repo, "https://github.com/gretagen/zeta-index")
end)

-- do_not_solve: the packages -Solve must never reinstall. Replacing a base
-- library under a running system leaves every later shell printing
-- "no version information available", and ZETA shells out constantly.
suite:test("do_not_solve defaults cover the packages that break a running system", function()
  load(nil)
  local s = config.get().do_not_solve
  for _, n in ipairs({ "glibc", "ncurses", "libtinfo", "bash", "gcc", "openssl" }) do
    lib.assert_true(s[n] == true, n .. " must be on the default do_not_solve list")
  end
  lib.assert_nil(s.hello, "an ordinary package must not be protected")
end)

suite:test("a do_not_solve table in the config file replaces the defaults", function()
  local dir = lib.tmpdir("cfg-do-not-solve")
  local file = path.join(dir, "configuration.lua")
  local h = assert(io.open(file, "wb"))
  h:write('return { do_not_solve = { "foo", "bar" } }\n')
  h:close()

  config.reset()
  config.setenv("ZETA_ROOT", lib.tmpdir("cfg-dns-root"))
  config.set_config_file(file)
  local cfg = config.load(nil)

  lib.assert_true(cfg.do_not_solve.foo == true, "config entry is kept")
  lib.assert_true(cfg.do_not_solve.bar == true, "config entry is kept")
  lib.assert_nil(cfg.do_not_solve.glibc, "the config list replaces the defaults")

  -- Leave no residue for the rest of the suite: reset restores the default
  -- config file path as well as the caches.
  config.reset()
end)

suite:test("do_not_solve falls back to the defaults when the key is absent", function()
  local dir = lib.tmpdir("cfg-no-do-not-solve")
  local file = path.join(dir, "configuration.lua")
  local h = assert(io.open(file, "wb"))
  h:write('return { root = "/" }\n')
  h:close()

  config.reset()
  config.set_config_file(file)
  local cfg = config.load(nil)

  lib.assert_true(cfg.do_not_solve.glibc == true, "absent key keeps the defaults")
  lib.assert_true(cfg.do_not_solve.ncurses == true, "absent key keeps the defaults")

  config.reset()
end)

return suite
