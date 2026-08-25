-- e2e.lua suite -- drives the real `zeta` binary offline: a generated fixture
-- repository (file:// urls), a fake ZETA_ROOT, and the local /packages tree.
-- Covers -Provide, -LocalProvide, -ReProvide, -Remove, -List, -Localize, dep
-- resolution, reverse-dependency protection, checksum failures, and
-- init-system paths.

local lib = require("lib")
local manifest = require("manifest")
local sha256 = require("sha256")
local path = require("path")
local suite = lib.new_suite("e2e")

local PKG = path.join(lib.root, "packages")

-- ---------------------------------------------------------------------------
-- Fixture repository
-- ---------------------------------------------------------------------------

local REPO = lib.tmpdir("e2e-repo")
local FIXT = lib.tmpdir("e2e-payloads")

local function tar_from(payload_root, top, out)
  os.execute("tar -czf " .. path.quote(out) .. " -C " .. path.quote(payload_root) .. " " .. path.quote(top) .. " 2>/dev/null")
end

local function make_payload(name, files)
  local root = path.join(FIXT, name .. "-root")
  for rel, content in pairs(files) do
    local full = path.join(root, rel)
    os.execute("mkdir -p " .. path.quote(path.dirname(full)))
    lib.write(full, content)
  end
  local tar = path.join(FIXT, name .. "-1.0.tar.gz")
  tar_from(path.dirname(root), path.basename(root), tar)
  return tar, sha256.file(tar)
end

-- app: tiny binary that depends on hello
local app_tar, app_sha = make_payload("app", { ["usr/bin/app"] = "#!/bin/sh\necho app\n" })

-- app2: depends on app (for package-level reverse-dependency protection)
local app2_tar, app2_sha = make_payload("app2", { ["usr/bin/app2"] = "#!/bin/sh\necho app2\n" })

-- app3: shares hello with app (for --with-deps shared-dependency handling)
local app3_tar, app3_sha = make_payload("app3", { ["usr/bin/app3"] = "#!/bin/sh\necho app3\n" })

-- evil: carries an init-system file (installs normally; no blocklist)
local evil_tar, evil_sha = make_payload("evil", { ["etc/init.d/evil"] = "#init\n" })

local function file_url(p)
  return "file://" .. p
end

-- A repo manifest is a copy of the sample manifest but with an absolute,
-- offline-safe url.
local function repo_manifest(name, over)
  local m = assert(manifest.load(path.join(PKG, name, "package.lua")))
  local t = {
    name = m.name, version = m.version, summary = m.summary,
    url = over and over.url or file_url(path.join(PKG, name, m.url)),
    sha256 = over and over.sha256 or m.sha256,
    deps = over and over.deps or m.deps or {},
  }
  if m.archive then t.archive = m.archive end
  if m.build then t.build = m.build end
  return t
end

-- Write a file inside the fixture repo, creating parent dirs as needed.
-- The repo layout mirrors Zeta's contract: <repo>/packages/<name>/package.lua.
local function repo_write(rel, content)
  local full = path.join(REPO, "packages", rel)
  os.execute("mkdir -p " .. path.quote(path.dirname(full)))
  lib.write(full, content)
end

repo_write("hello/package.lua",
  "return " .. require("ser").encode(repo_manifest("hello")) .. "\n")
repo_write("libz/package.lua",
  "return " .. require("ser").encode(repo_manifest("libz")) .. "\n")
repo_write("app/package.lua",
  "return { name='app', version='1.0', summary='depends on hello', url='"
    .. file_url(app_tar) .. "', sha256='" .. app_sha .. "', deps={'hello'}, archive={strip=1} }\n")
repo_write("app2/package.lua",
  "return { name='app2', version='1.0', summary='depends on app', url='"
    .. file_url(app2_tar) .. "', sha256='" .. app2_sha .. "', deps={'app'}, archive={strip=1} }\n")
repo_write("app3/package.lua",
  "return { name='app3', version='1.0', summary='depends on hello', url='"
    .. file_url(app3_tar) .. "', sha256='" .. app3_sha .. "', deps={'hello'}, archive={strip=1} }\n")
repo_write("evil/package.lua",
  "return { name='evil', version='1.0', url='" .. file_url(evil_tar) .. "', sha256='"
    .. evil_sha .. "', deps={}, archive={strip=1} }\n")
repo_write("badsha/package.lua",
  "return { name='badsha', version='1.0', url='" .. file_url(path.join(PKG, "hello", "hello-1.0.tar.gz"))
    .. "', sha256='" .. string.rep("0", 64) .. "', deps={}, archive={strip=1} }\n")
repo_write("index.lua",
  "return { {name='hello',version='1.0',summary='demo'}, {name='libz',version='1.3.1',summary='lib'}, "
    .. "{name='app',version='1.0',summary='needs hello'}, {name='app2',version='1.0',summary='needs app'}, "
     .. "{name='app3',version='1.0',summary='needs hello'}, {name='evil',version='1.0'}, {name='badsha',version='1.0'} }\n")

-- upgradable: v1.0 payload (what gets installed initially)
local upg1_tar, upg1_sha = make_payload("upgradable-v1", { ["usr/bin/upgradable"] = "#!/bin/sh\necho v1\n" })
-- upgradable: v2.0 payload (what -Elevate should upgrade to)
local upg2_tar, upg2_sha = make_payload("upgradable-v2", { ["usr/bin/upgradable"] = "#!/bin/sh\necho v2\n" })

-- shared1 and shared2: both install the same file (usr/lib/shared.so)
local shared_tar, shared_sha = make_payload("shared", { ["usr/lib/shared.so"] = "ELF shared lib\n" })

repo_write("upgradable/package.lua",
  "return { name='upgradable', version='1.0', summary='upgrade test', url='"
    .. file_url(upg1_tar) .. "', sha256='" .. upg1_sha .. "', deps={}, archive={strip=1} }\n")
repo_write("upgradable-v2/package.lua",
  "return { name='upgradable', version='2.0', summary='upgrade test v2', url='"
    .. file_url(upg2_tar) .. "', sha256='" .. upg2_sha .. "', deps={}, archive={strip=1} }\n")
repo_write("shared1/package.lua",
  "return { name='shared1', version='1.0', summary='shared file test', url='"
    .. file_url(shared_tar) .. "', sha256='" .. shared_sha .. "', deps={}, archive={strip=1} }\n")
repo_write("shared2/package.lua",
  "return { name='shared2', version='1.0', summary='shared file test 2', url='"
    .. file_url(shared_tar) .. "', sha256='" .. shared_sha .. "', deps={}, archive={strip=1} }\n")

-- Update index to include new packages
repo_write("index.lua",
  "return { {name='hello',version='1.0',summary='demo'}, {name='libz',version='1.3.1',summary='lib'}, "
    .. "{name='app',version='1.0',summary='needs hello'}, {name='app2',version='1.0',summary='needs app'}, "
    .. "{name='app3',version='1.0',summary='needs hello'}, {name='evil',version='1.0'}, {name='badsha',version='1.0'}, "
    .. "{name='upgradable',version='2.0',summary='upgrade test'}, "
    .. "{name='shared1',version='1.0',summary='shared file test'}, "
    .. "{name='shared2',version='1.0',summary='shared file test 2'} }\n")

-- ---------------------------------------------------------------------------
-- Runner helpers
-- ---------------------------------------------------------------------------

local function env(root)
  return {
    ZETA_ROOT = root,
    ZETA_REPO = REPO,
    ZETA_LOCAL_PACKAGES = PKG,
    ZETA_STATE = path.join(root, "var/db/zeta"),
    ZETA_CACHE = path.join(root, "var/cache/zeta"),
    ZETA_TMP = path.join(root, "var/tmp/zeta"),
    NO_COLOR = "1",
  }
end

local function fresh_env()
  return env(lib.tmpdir("e2e-root"))
end

-- env(root) with overrides merged in; a `false` value unsets the variable.
local function env_over(root, over)
  local e = env(root)
  for k, v in pairs(over or {}) do
    if v == false then e[k] = nil else e[k] = v end
  end
  return e
end

local function query_db(root)
  lib.use_root(root)
  return require("db")
end

-- A second, tiny local /packages tree with no test hooks (structural -Test)
-- and a package whose dependency is missing locally.
local OFF = lib.tmpdir("e2e-offline")
local nh_tar, nh_sha = make_payload("nohook", { ["usr/bin/nohook"] = "#!/bin/sh\necho nohook\n" })
local function off_write(rel, content)
  local full = path.join(OFF, rel)
  os.execute("mkdir -p " .. path.quote(path.dirname(full)))
  lib.write(full, content)
end
off_write("nohook/package.lua",
  "return { name='nohook', version='1.0', url='" .. file_url(nh_tar) .. "', sha256='"
    .. nh_sha .. "', deps={}, archive={strip=1} }\n")
off_write("pkgwithdep/package.lua",
  "return { name='pkgwithdep', version='1.0', url='" .. file_url(nh_tar) .. "', sha256='"
    .. nh_sha .. "', deps={'ghost'}, archive={strip=1} }\n")

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

suite:test("-Localize searches the remote index", function()
  local code, out = lib.run_zeta({ "-Localize", "hello" }, fresh_env())
  lib.assert_eq(code, 0)
  lib.assert_contains(out, "hello")
end)

suite:test("-Provide installs from the remote repository", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-Provide", "hello", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "installed hello-1.0")
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
  local db = query_db(e.ZETA_ROOT)
  lib.assert_true(db.is_installed("hello"))
  lib.assert_eq(db.files("hello"), { "usr/bin/hello" })
end)

suite:test("-Provide on an installed package warns", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "hello", "--pass" }, e)
  local code, out = lib.run_zeta({ "-Provide", "hello", "--pass" }, e)
  lib.assert_eq(code, 0)
  lib.assert_contains(out, "already installed")
end)

suite:test("dependency resolution pulls and orders packages", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-Provide", "app", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "will install hello-1.0")
  lib.assert_contains(out, "will install app-1.0")
  local db = query_db(e.ZETA_ROOT)
  lib.assert_true(db.is_installed("hello"))
  lib.assert_true(db.is_installed("app"))
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/app")))
end)

suite:test("dependencies are tracked separately from packages", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "app", "--pass" }, e)
  local db = query_db(e.ZETA_ROOT)
  lib.assert_eq(db.kind("app"), "package")
  lib.assert_eq(db.kind("hello"), "dependency")
  lib.assert_eq(db.list_packages(), { "app" })
  lib.assert_eq(db.list_dependencies(), { "hello" })
end)

suite:test("a package still required by another package is protected", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "app", "--pass" }, e)
  lib.run_zeta({ "-Provide", "app2", "--pass" }, e) -- app2 depends on app
  local code, out = lib.run_zeta({ "-Remove", "app", "--pass" }, e)
  lib.assert_eq(code, 1)
  lib.assert_contains(out, "still required by")
  lib.assert_contains(out, "app2")
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/app")))
  local code2, out2 = lib.run_zeta({ "-Remove", "app", "--pass", "--force" }, e)
  lib.assert_eq(code2, 0, out2)
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/app")))
end)

suite:test("removing a dependency still required prompts (y proceeds)", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "app", "--pass" }, e)
  local code, out = lib.run_zeta({ "-Remove", "hello" }, e, "y\n")
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "hello is a dependency of app, Proceed with removal?")
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/app")))
end)

suite:test("removing a dependency still required aborts on n", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "app", "--pass" }, e)
  local code, out = lib.run_zeta({ "-Remove", "hello" }, e, "n\n")
  lib.assert_eq(code, 0)
  lib.assert_contains(out, "aborted by user")
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
end)

suite:test("a dependency of several packages names the count in the prompt", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "app", "--pass" }, e)
  lib.run_zeta({ "-Provide", "app3", "--pass" }, e)
  local code, out = lib.run_zeta({ "-Remove", "hello" }, e, "y\n")
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "hello is a dependency of 2 packages, Proceed with removal?")
end)

suite:test("an orphaned dependency removes without prompting", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "app", "--pass" }, e)
  lib.run_zeta({ "-Remove", "app", "--pass" }, e) -- hello left orphaned
  local code, out = lib.run_zeta({ "-Remove", "hello" }, e) -- no --pass, no stdin
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "removed hello")
  lib.assert_not_contains(out, "aborted by user")
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
end)

suite:test("--with-deps cascades into orphaned dependencies", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "app", "--pass" }, e)
  local code, out = lib.run_zeta({ "-Remove", "app", "--pass", "--with-deps" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "removed app")
  lib.assert_contains(out, "removed hello")
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/app")))
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
end)

suite:test("--with-deps keeps dependencies shared with installed packages", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "app", "--pass" }, e)
  lib.run_zeta({ "-Provide", "app3", "--pass" }, e) -- both depend on hello
  local code, out = lib.run_zeta({ "-Remove", "app", "--pass", "--with-deps" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "skipping hello: still depended on by app3")
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/app")))
  lib.run_zeta({ "-Remove", "app3", "--pass", "--with-deps" }, e)
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
end)

suite:test("-Provide installs multiple packages", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-Provide", "hello", "libz", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/lib/libz.so")))
  local db = query_db(e.ZETA_ROOT)
  lib.assert_eq(db.kind("hello"), "package") -- explicit targets stay packages
  lib.assert_eq(db.kind("libz"), "package")
end)

suite:test("-Remove removes multiple packages", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "hello", "libz", "--pass" }, e)
  local code, out = lib.run_zeta({ "-Remove", "hello", "libz", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/lib/libz.so")))
  local db = query_db(e.ZETA_ROOT)
  lib.assert_false(db.is_installed("hello"))
  lib.assert_false(db.is_installed("libz"))
end)

suite:test("-Remove of a nonexistent package fails and stops", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "hello", "--pass" }, e)
  local code, out = lib.run_zeta({ "-Remove", "hello", "ghost", "--pass" }, e)
  lib.assert_eq(code, 1)
  lib.assert_contains(out, "ghost is not installed")
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
end)

suite:test("-List splits packages and dependencies into sections", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "app", "--pass" }, e)
  local code, out = lib.run_zeta({ "-List" }, e)
  lib.assert_eq(code, 0)
  lib.assert_contains(out, "PACKAGES (1)")
  lib.assert_contains(out, "DEPENDENCIES (1)")
  lib.assert_contains(out, "app")
  lib.assert_contains(out, "hello")
end)

suite:test("-LocalProvide installs a binary package with symlinks", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-LocalProvide", "libz", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_true(lib.is_symlink(path.join(e.ZETA_ROOT, "usr/lib/libz.so")))
  lib.assert_true(lib.is_symlink(path.join(e.ZETA_ROOT, "usr/lib/libz.so.1")))
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/lib/libz.so.1.3.1")))
end)

suite:test("-LocalProvide builds from source", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-LocalProvide", "libffi", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/lib/libffi.so")))
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/include/ffi/ffi.h")))
end)

suite:test("-ReProvide reinstalls an installed package", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "hello", "--pass" }, e)
  local code, out = lib.run_zeta({ "-ReProvide", "hello", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
end)

suite:test("-List reports installed packages", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "hello", "--pass" }, e)
  lib.run_zeta({ "-LocalProvide", "libz", "--pass" }, e)
  local code, out = lib.run_zeta({ "-List" }, e)
  lib.assert_eq(code, 0)
  lib.assert_contains(out, "hello")
  lib.assert_contains(out, "libz")
end)

suite:test("-Remove of a nonexistent package fails", function()
  local code, out = lib.run_zeta({ "-Remove", "ghost", "--pass" }, fresh_env())
  lib.assert_eq(code, 1)
  lib.assert_contains(out, "not installed")
end)

suite:test("checksum mismatch aborts the install", function()
  local code, out = lib.run_zeta({ "-Provide", "badsha", "--pass" }, fresh_env())
  lib.assert_eq(code, 1)
  lib.assert_contains(out, "sha256 mismatch")
end)

suite:test("init-system paths are installed normally", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-Provide", "evil", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "etc/init.d/evil")))
end)

suite:test("-Remove unlinks exactly the owned files", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "hello", "--pass" }, e)
  lib.run_zeta({ "-Remove", "hello", "--pass" }, e)
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
  local db = query_db(e.ZETA_ROOT)
  lib.assert_false(db.is_installed("hello"))
end)

-- ---------------------------------------------------------------------------
-- Offline discovery + -Test
-- ---------------------------------------------------------------------------

suite:test("-LocalProvide works offline via script_dir discovery", function()
  -- No ZETA_LOCAL_PACKAGES and no network: the binary must find the real
  -- sample /packages tree next to zeta.lua.
  local root = lib.tmpdir("e2e-root")
  local e = env_over(root, { ZETA_LOCAL_PACKAGES = false })
  local code, out = lib.run_zeta({ "-LocalProvide", "hello", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "installed hello-1.0")
  lib.assert_not_contains(out, "falling back to remote")
  lib.assert_true(lib.exists(path.join(root, "usr/bin/hello")))
end)

suite:test("-Test hello passes offline and installs nothing", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-Test", "hello" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "test passed for hello-1.0")
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "var/tmp/zeta")))
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "var/db/zeta/hello")))
end)

suite:test("-Test runs the package test hook (libz symlinks)", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-Test", "libz" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "test passed for libz-1.3.1")
end)

suite:test("-Test is structural without a test hook", function()
  local root = lib.tmpdir("e2e-root")
  local e = env_over(root, { ZETA_LOCAL_PACKAGES = OFF })
  local code, out = lib.run_zeta({ "-Test", "nohook" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "test passed for nohook-1.0")
end)

suite:test("-Test of a missing package fails offline", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-Test", "ghost" }, e)
  lib.assert_eq(code, 1)
  lib.assert_contains(out, "offline test")
  lib.assert_contains(out, "not found in local tree")
  lib.assert_not_contains(out, "https://")
end)

suite:test("-Test refuses a remote-url package (strictly offline)", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-Test", "glib" }, e)
  lib.assert_eq(code, 1)
  lib.assert_contains(out, "offline test refused")
  lib.assert_contains(out, "remote url")
end)

suite:test("-Test fails when a dependency is missing locally", function()
  local root = lib.tmpdir("e2e-root")
  local e = env_over(root, { ZETA_LOCAL_PACKAGES = OFF })
  local code, out = lib.run_zeta({ "-Test", "pkgwithdep" }, e)
  lib.assert_eq(code, 1)
  lib.assert_contains(out, "ghost")
  lib.assert_contains(out, "not found in local tree")
end)

-- ---------------------------------------------------------------------------
-- -Elevate tests
-- ---------------------------------------------------------------------------

suite:test("-Elevate upgrades packages to newer versions", function()
  local e = fresh_env()
  -- Install v1.0
  lib.run_zeta({ "-Provide", "upgradable", "--pass" }, e)
  local db = query_db(e.ZETA_ROOT)
  lib.assert_eq(db.get("upgradable").version, "1.0")
  -- Update repo to serve v2.0
  repo_write("upgradable/package.lua",
    "return { name='upgradable', version='2.0', summary='upgrade test v2', url='"
      .. file_url(upg2_tar) .. "', sha256='" .. upg2_sha .. "', deps={}, archive={strip=1} }\n")
  -- Run elevate
  local code, out = lib.run_zeta({ "-Elevate", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "will upgrade upgradable 1.0 -> 2.0")
  -- Verify updated
  local db2 = query_db(e.ZETA_ROOT)
  lib.assert_eq(db2.get("upgradable").version, "2.0")
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/upgradable")))
end)

suite:test("-Elevate reports up-to-date when nothing to upgrade", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "upgradable", "--pass" }, e)
  -- Upgrade to v2.0 via a second provide (repo has v2.0)
  repo_write("upgradable/package.lua",
    "return { name='upgradable', version='2.0', summary='upgrade test v2', url='"
      .. file_url(upg2_tar) .. "', sha256='" .. upg2_sha .. "', deps={}, archive={strip=1} }\n")
  lib.run_zeta({ "-ReProvide", "upgradable", "--pass" }, e)
  local code, out = lib.run_zeta({ "-Elevate", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "all packages are up to date")
end)

suite:test("-Elevate with no packages installed does nothing", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-Elevate", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "no packages installed")
end)

-- ---------------------------------------------------------------------------
-- Multi-ownership tests
-- ---------------------------------------------------------------------------

suite:test("two packages can own the same file without conflict", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-Provide", "shared1", "shared2", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/lib/shared.so")))
  local db = query_db(e.ZETA_ROOT)
  lib.assert_true(db.is_installed("shared1"))
  lib.assert_true(db.is_installed("shared2"))
end)

suite:test("removing one owner of a shared file keeps the file", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "shared1", "shared2", "--pass" }, e)
  local code, out = lib.run_zeta({ "-Remove", "shared1", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  -- File should still exist because shared2 owns it
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/lib/shared.so")))
  local db = query_db(e.ZETA_ROOT)
  lib.assert_false(db.is_installed("shared1"))
  lib.assert_true(db.is_installed("shared2"))
end)

suite:test("removing the last owner of a shared file deletes it", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "shared1", "shared2", "--pass" }, e)
  lib.run_zeta({ "-Remove", "shared1", "--pass" }, e)
  lib.run_zeta({ "-Remove", "shared2", "--pass" }, e)
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/lib/shared.so")))
  local db = query_db(e.ZETA_ROOT)
  lib.assert_false(db.is_installed("shared1"))
  lib.assert_false(db.is_installed("shared2"))
end)

suite:test("shared file is skipped with detail log during removal", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "shared1", "shared2", "--pass" }, e)
  local code, out = lib.run_zeta({ "-Remove", "shared1", "--pass" }, e)
  lib.assert_eq(code, 0, out)
  lib.assert_contains(out, "skipping")
  lib.assert_contains(out, "shared with")
end)

return suite
