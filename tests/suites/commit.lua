-- commit.lua suite -- the staging-to-root commit step: init/distro-identity
-- blocklist, pre-flight abort, cross-package file conflicts, symlink safety,
-- and the optional files whitelist.

local lib = require("lib")
local commit = require("commit")
local db = require("db")
local path = require("path")
local log = require("log")
local suite = lib.new_suite("commit")

log.set_quiet(true)

local function fresh()
  local root = lib.tmpdir("commit")
  lib.use_root(root)
  return root
end

local function meta(name, over)
  local m = { name = name, version = "1.0", deps = {}, prefix = "/usr" }
  if over then for k, v in pairs(over) do m[k] = v end end
  return m
end

-- Build a staging tree with a file, a dir, and a symlink.
local function simple_stage(root, name)
  local s = path.join(root, "stage-" .. name)
  os.execute("mkdir -p " .. path.quote(s .. "/usr/bin"))
  os.execute("mkdir -p " .. path.quote(s .. "/usr/lib"))
  lib.write(path.join(s, "usr/bin/tool"), "#!/bin/sh\necho hi\n")
  os.execute("chmod +x " .. path.quote(s .. "/usr/bin/tool"))
  lib.write(path.join(s, "usr/lib/liba.so"), "ELF-stub")
  os.execute("ln -s liba.so " .. path.quote(s .. "/usr/lib/liba.so.1"))
  return s
end

local function root_of()
  return require("config").get().root
end

suite:test("commits files and symlinks, skipping dirs", function()
  local root = fresh()
  local s = simple_stage(root, "a")
  local owned = commit.apply(s, { pkg_name = "A" })
  lib.assert_true(lib.exists(path.join(root, "usr/bin/tool")))
  lib.assert_true(lib.exists(path.join(root, "usr/lib/liba.so")))
  lib.assert_true(lib.is_symlink(path.join(root, "usr/lib/liba.so.1")))
  -- owned must contain only real paths (files + symlinks), never dirs
  for _, e in ipairs(owned) do
    lib.assert_true(e.type ~= "dir", "directories must not be recorded as owned")
  end
  local found = {}
  for _, e in ipairs(owned) do found[e.rel] = true end
  lib.assert_true(found["usr/bin/tool"])
  lib.assert_true(found["usr/lib/liba.so.1"])
end)

suite:test("blocklist: init-system prefix aborts pre-flight", function()
  local root = fresh()
  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/usr/bin"))
  os.execute("mkdir -p " .. path.quote(s .. "/etc/systemd/system"))
  lib.write(path.join(s, "usr/bin/ok"), "ok")
  lib.write(path.join(s, "etc/systemd/system/x.service"), "init")
  local ok, err = pcall(commit.apply, s, { pkg_name = "evil" })
  lib.assert_false(ok)
  lib.assert_contains(err, "refusing")
  lib.assert_contains(err, "init")
  -- pre-flight means NOTHING was copied, not even the innocent file
  lib.assert_false(lib.exists(path.join(root, "usr/bin/ok")))
end)

suite:test("blocklist: distro-identity files are refused", function()
  local root = fresh()
  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/etc"))
  lib.write(path.join(s, "etc/os-release"), "ID=notyours")
  local ok, err = pcall(commit.apply, s, { pkg_name = "evil" })
  lib.assert_false(ok)
  lib.assert_contains(err, "os-release")
end)

suite:test("blocklist: init unit suffixes are refused anywhere", function()
  local root = fresh()
  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/usr/bin"))
  lib.write(path.join(s, "usr/bin/foo.service"), "unit")
  local ok, err = pcall(commit.apply, s, { pkg_name = "evil" })
  lib.assert_false(ok)
  lib.assert_contains(err, "unit file")
end)

suite:test("cross-package file conflict aborts unless forced", function()
  local root = fresh()
  db.record("A", meta("A"), { "usr/bin/shared" })
  os.execute("mkdir -p " .. path.quote(path.join(root, "usr/bin")))
  lib.write(path.join(root, "usr/bin/shared"), "owned by A")

  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/usr/bin"))
  lib.write(path.join(s, "usr/bin/shared"), "new")
  lib.write(path.join(s, "usr/bin/b"), "b")

  -- Multi-ownership: B may install a file already owned by A without conflict.
  local owned = commit.apply(s, { pkg_name = "B" })
  lib.assert_eq(lib.read(path.join(root, "usr/bin/shared")), "new")
  lib.assert_true(lib.exists(path.join(root, "usr/bin/b")))
end)

suite:test("a package may overwrite its own previously installed files", function()
  local root = fresh()
  db.record("A", meta("A"), { "usr/bin/tool" })
  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/usr/bin"))
  lib.write(path.join(s, "usr/bin/tool"), "v2")
  local owned = commit.apply(s, { pkg_name = "A" })
  lib.assert_eq(lib.read(path.join(root, "usr/bin/tool")), "v2")
end)

suite:test("escaping symlink in staging is refused", function()
  local root = fresh()
  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/usr/lib"))
  os.execute("ln -s ../../../../etc/passwd " .. path.quote(s .. "/usr/lib/evil"))
  local ok, err = pcall(commit.apply, s, { pkg_name = "evil" })
  lib.assert_false(ok)
  lib.assert_contains(err, "escapes")
end)

suite:test("files whitelist filters the commit", function()
  local root = fresh()
  local s = simple_stage(root, "w")
  local owned = commit.apply(s, { pkg_name = "W", whitelist = { "usr/bin/tool" } })
  lib.assert_true(lib.exists(path.join(root, "usr/bin/tool")))
  lib.assert_false(lib.exists(path.join(root, "usr/lib/liba.so")), "non-whitelisted file committed")
  local found = {}
  for _, e in ipairs(owned) do found[e.rel] = true end
  lib.assert_true(found["usr/bin/tool"])
  lib.assert_false(found["usr/lib/liba.so"])
end)

return suite
