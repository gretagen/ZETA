-- e2e.lua suite -- drives the real `zeta` binary offline: a generated fixture
-- repository (file:// urls), a fake ZETA_ROOT, and the local /packages tree.
-- Covers -Provide, -LocalProvide, -ReProvide, -Remove, -List, -Localize, dep
-- resolution, reverse-dependency protection, checksum failures, and the
-- init/distro-identity blocklist.

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

-- evil: carries an init-system file (must be refused)
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
repo_write("evil/package.lua",
  "return { name='evil', version='1.0', url='" .. file_url(evil_tar) .. "', sha256='"
    .. evil_sha .. "', deps={}, archive={strip=1} }\n")
repo_write("badsha/package.lua",
  "return { name='badsha', version='1.0', url='" .. file_url(path.join(PKG, "hello", "hello-1.0.tar.gz"))
    .. "', sha256='" .. string.rep("0", 64) .. "', deps={}, archive={strip=1} }\n")
repo_write("index.lua",
  "return { {name='hello',version='1.0',summary='demo'}, {name='libz',version='1.3.1',summary='lib'}, "
    .. "{name='app',version='1.0',summary='needs hello'}, {name='evil',version='1.0'}, {name='badsha',version='1.0'} }\n")

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

suite:test("reverse-dependency protects a package from removal", function()
  local e = fresh_env()
  lib.run_zeta({ "-Provide", "app", "--pass" }, e)
  local code, out = lib.run_zeta({ "-Remove", "hello", "--pass" }, e)
  lib.assert_eq(code, 1)
  lib.assert_contains(out, "still required by")
  lib.assert_true(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
  local code2, out2 = lib.run_zeta({ "-Remove", "hello", "--pass", "--force" }, e)
  lib.assert_eq(code2, 0, out2)
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "usr/bin/hello")))
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

suite:test("init-system paths are never installed", function()
  local e = fresh_env()
  local code, out = lib.run_zeta({ "-Provide", "evil", "--pass" }, e)
  lib.assert_eq(code, 1)
  lib.assert_contains(out, "refusing")
  lib.assert_contains(out, "init")
  lib.assert_false(lib.exists(path.join(e.ZETA_ROOT, "etc/init.d")))
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

return suite
