-- isolate.lua suite -- the --isolate feature: reserve config, explicit-root
-- commit, the isolated DB registry, and profile wrappers.

local lib = require("lib")
local path = require("path")
local cli = require("cli")
local config = require("config")
local commit = require("commit")
local db = require("db")
local reserve = require("reserve")
local suite = lib.new_suite("isolate")

local function fresh()
  local root = lib.tmpdir("isolate")
  lib.use_root(root)
  return root
end

suite:test("--isolate flag is parsed", function()
  local p = cli.parse({ "--isolate", "-Provide", "hello" })
  lib.assert_true(p, "parse should succeed")
  lib.assert_true(p.flags.isolate, "--isolate must set flags.isolate")

  local q = cli.parse({ "-Provide", "hello" })
  lib.assert_true(q, "parse should succeed")
  lib.assert_false(q.flags.isolate, "isolate defaults to false")
end)

suite:test("reserve_dir defaults under root and honors ZETA_RESERVE", function()
  local root = fresh()
  local cfg = config.get()
  lib.assert_eq(cfg.reserve_dir, path.join(root, "zeta/reserve"), "default reserve_dir")

  config.reset()
  config.setenv("ZETA_ROOT", root)
  config.setenv("ZETA_RESERVE", "/custom/reserve")
  lib.assert_eq(config.get().reserve_dir, "/custom/reserve", "ZETA_RESERVE override")
  config.reset()
  config.setenv("ZETA_ROOT", root)
end)

suite:test("commit.apply writes into opts.root, not config.root", function()
  local root = fresh()
  local store = path.join(config.get().reserve_dir, "pkg-1.0")

  local stage = path.join(lib.tmpdir("isolate-stage"), "stage")
  os.execute("mkdir -p " .. path.quote(stage .. "/usr/bin"))
  lib.write(path.join(stage, "usr/bin/app"), "#!/bin/sh\necho hi\n")

  local owned = commit.apply(stage, { pkg_name = "pkg", root = store })

  lib.assert_true(path.exists(path.join(store, "usr/bin/app")), "file must land in the store")
  lib.assert_false(path.exists(path.join(root, "usr/bin/app")), "host root must stay untouched")
  lib.assert_false(path.exists(path.join(root, "etc/ld.so.conf.d/00-usr.conf")),
    "isolated commit must not write the host ld.so.conf")
  lib.assert_true(#owned >= 1, "owned entries returned")
end)

suite:test("db.record isolated entries live in their own registry", function()
  local root = fresh()
  local store = path.join(config.get().reserve_dir, "hello-1.0")

  db.record("hello", { name = "hello", version = "1.0", deps = {} },
    { "usr/bin/hello" }, { isolated = true, reserve_root = store })

  lib.assert_true(db.isolated("hello"), "db.isolated sees the entry")
  lib.assert_nil(db.kind("hello"), "system view must not see isolated entries")
  lib.assert_false(db.is_installed("hello"), "is_installed stays false")
  local m = db.isolated_meta("hello")
  lib.assert_eq(m.reserve_root, store, "reserve_root recorded")
  lib.assert_true(m.isolated, "isolated flag recorded")
  lib.assert_eq(db.isolated_files("hello")[1], "usr/bin/hello", "files recorded")
  local names = db.list_isolated()
  local found = false
  for _, n in ipairs(names) do if n == "hello" then found = true end end
  lib.assert_true(found, "list_isolated contains hello")
  for _, n in ipairs(db.list_packages()) do
    lib.assert_false(n == "hello", "list_packages must not contain isolated hello")
  end

  -- A system package with the same name coexists.
  db.record("hello", { name = "hello", version = "2.0", deps = {} }, { "usr/bin/hello" }, {})
  lib.assert_eq(db.kind("hello"), "package", "system copy registered")
  lib.assert_true(db.isolated("hello"), "isolated copy still registered")

  db.remove_isolated("hello")
  lib.assert_false(db.isolated("hello"), "isolated entry removed")
  lib.assert_eq(db.kind("hello"), "package", "system copy untouched")
end)

suite:test("reserve.store_path joins and sanitizes the version", function()
  local root = fresh()
  local cfg = config.get()
  lib.assert_eq(reserve.store_path("wmaker", "0.96.0"),
    path.join(cfg.reserve_dir, "wmaker-0.96.0"))
  lib.assert_eq(reserve.store_path("pkg", "1.0/evil"),
    path.join(cfg.reserve_dir, "pkg-1.0_evil"), "version must not carry a path")
end)

suite:test("link_profile creates bare-name wrappers for the package's own binaries", function()
  local root = fresh()
  local cfg = config.get()
  local store = path.join(cfg.reserve_dir, "wmaker-0.96.0")

  local files = {
    "usr/bin/wmaker",
    "usr/bin/WPrefs",
    "usr/sbin/wm-helper",
    "usr/lib/libWINGs.so.3",   -- not a binary: no wrapper
    "usr/share/doc/readme",    -- nested + not a bin dir: no wrapper
  }
  local created = reserve.link_profile(store, files)

  local wrap = path.join(cfg.reserve_dir, "profile/bin/wmaker")
  lib.assert_true(path.exists(wrap), "wrapper created")
  local body = lib.read(wrap)
  lib.assert_contains(body, "LD_LIBRARY_PATH=", "wrapper sets LD_LIBRARY_PATH")
  lib.assert_contains(body, store .. "/usr/lib", "store lib dir in LD_LIBRARY_PATH")
  lib.assert_contains(body, path.join(store, "usr/bin/wmaker"), "wrapper execs the store binary")
  lib.assert_true(path.exists(path.join(cfg.reserve_dir, "profile/bin/WPrefs")), "second binary wrapped")
  lib.assert_true(path.exists(path.join(cfg.reserve_dir, "profile/bin/wm-helper")), "sbin wrapped")
  lib.assert_false(path.exists(path.join(cfg.reserve_dir, "profile/bin/libWINGs.so.3")), "libraries not wrapped")

  -- No -isolated suffix anywhere (nixpkgs behavior).
  local ls = path.popen("ls -1 " .. path.quote(path.join(cfg.reserve_dir, "profile/bin")))
  for line in ls:lines() do
    lib.assert_not_contains(line, "-isolated", "no -isolated prefix")
  end
  ls:close()
  lib.assert_eq(#created, 3, "three wrappers created")

  -- Executable bit set.
  local ok = os.execute("test -x " .. path.quote(wrap))
  if type(ok) == "number" then
    lib.assert_eq(ok, 0, "wrapper must be executable")
  else
    lib.assert_true(ok == true, "wrapper must be executable")
  end
end)

suite:test("unlink_profile only removes wrappers of the given store", function()
  local root = fresh()
  local cfg = config.get()
  local store_a = path.join(cfg.reserve_dir, "a-1.0")
  local store_b = path.join(cfg.reserve_dir, "b-1.0")

  reserve.link_profile(store_a, { "usr/bin/toola" })
  reserve.link_profile(store_b, { "usr/bin/toolb" })

  local removed = reserve.unlink_profile(store_a)
  lib.assert_eq(removed, 1, "one wrapper removed")
  lib.assert_false(path.exists(path.join(cfg.reserve_dir, "profile/bin/toola")), "a's wrapper gone")
  lib.assert_true(path.exists(path.join(cfg.reserve_dir, "profile/bin/toolb")), "b's wrapper kept")
end)

suite:test("remove_store refuses paths outside the reserve dir", function()
  local root = fresh()
  local cfg = config.get()

  local ok, err = reserve.remove_store("/etc")
  lib.assert_false(ok, "must refuse /etc")
  lib.assert_contains(tostring(err), "outside", "error explains the refusal")

  local ok2, err2 = reserve.remove_store(nil)
  lib.assert_false(ok2, "must refuse nil")

  local store = path.join(cfg.reserve_dir, "x-1.0")
  os.execute("mkdir -p " .. path.quote(store .. "/usr"))
  lib.write(path.join(store, "usr/file"), "x")
  local ok3 = reserve.remove_store(store)
  lib.assert_true(ok3, "store under reserve dir is removable")
  lib.assert_false(path.exists(store), "store removed")
end)

return suite
