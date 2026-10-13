-- isolate.lua suite -- the --isolate feature: reserve config, explicit-root
-- commit, the isolated DB registry, and profile wrappers.

local lib = require("lib")
local path = require("path")
local cli = require("cli")
local config = require("config")
local commit = require("commit")
local db = require("db")
local reserve = require("reserve")
local actions = require("actions")
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

suite:test("link_system mirrors bins into usr/bin and usr/sbin", function()
  local root = fresh()
  local cfg = config.get()
  local store = path.join(cfg.reserve_dir, "tool-1.0")
  local files = { "usr/bin/tool", "usr/sbin/admin", "usr/lib/libx.so" }

  reserve.link_profile(store, files)
  local res = reserve.link_system(store, files)

  lib.assert_eq(res.linked, 2, "two links created")
  lib.assert_eq(res.skipped, 0, "nothing skipped")
  lib.assert_eq(path.readlink(path.join(root, "usr/bin/tool")),
    path.join(cfg.reserve_dir, "profile/bin/tool"), "usr/bin link points at wrapper")
  lib.assert_eq(path.readlink(path.join(root, "usr/sbin/admin")),
    path.join(cfg.reserve_dir, "profile/bin/admin"), "usr/sbin link points at wrapper")
  lib.assert_nil(path.readlink(path.join(root, "usr/bin/libx.so")), "libraries never linked")
end)

suite:test("link_system skips names occupied by a real file", function()
  local root = fresh()
  local cfg = config.get()
  local store = path.join(cfg.reserve_dir, "app-1.0")
  os.execute("mkdir -p " .. path.quote(path.join(root, "usr/bin")))
  lib.write(path.join(root, "usr/bin/app"), "#!/bin/sh\necho system\n")

  reserve.link_profile(store, { "usr/bin/app" })
  local res = reserve.link_system(store, { "usr/bin/app" })

  lib.assert_eq(res.linked, 0, "no link created")
  lib.assert_eq(res.skipped, 1, "reported as skipped")
  lib.assert_nil(path.readlink(path.join(root, "usr/bin/app")), "still a regular file")
  lib.assert_contains(lib.read(path.join(root, "usr/bin/app")), "echo system",
    "system copy untouched")
end)

suite:test("link_system replaces another store's reserve link", function()
  local root = fresh()
  local cfg = config.get()
  local store_a = path.join(cfg.reserve_dir, "app-1.0")
  local store_b = path.join(cfg.reserve_dir, "app-2.0")

  reserve.link_profile(store_a, { "usr/bin/app" })
  reserve.link_system(store_a, { "usr/bin/app" })
  reserve.link_profile(store_b, { "usr/bin/app" })
  local res = reserve.link_system(store_b, { "usr/bin/app" })

  lib.assert_eq(res.linked, 1, "reserve-owned link replaced")
  lib.assert_eq(path.readlink(path.join(root, "usr/bin/app")),
    path.join(cfg.reserve_dir, "profile/bin/app"), "same profile target")
  lib.assert_contains(lib.read(path.join(cfg.reserve_dir, "profile/bin/app")),
    store_b, "wrapper now belongs to store b")
end)

suite:test("unlink_system removes only the given store's links", function()
  local root = fresh()
  local cfg = config.get()
  local store_a = path.join(cfg.reserve_dir, "a-1.0")
  local store_b = path.join(cfg.reserve_dir, "b-1.0")
  os.execute("mkdir -p " .. path.quote(path.join(root, "usr/bin")))
  lib.write(path.join(root, "usr/bin/real"), "#!/bin/sh\n")

  reserve.link_profile(store_a, { "usr/bin/tool" })
  reserve.link_system(store_a, { "usr/bin/tool" })
  reserve.link_profile(store_b, { "usr/bin/other" })
  reserve.link_system(store_b, { "usr/bin/other" })

  local removed = reserve.unlink_system(store_a)

  lib.assert_eq(removed, 1, "only a's link removed")
  lib.assert_nil(path.readlink(path.join(root, "usr/bin/tool")), "a's link gone")
  lib.assert_eq(path.readlink(path.join(root, "usr/bin/other")),
    path.join(cfg.reserve_dir, "profile/bin/other"), "b's link kept")
  lib.assert_nil(path.readlink(path.join(root, "usr/bin/real")), "real file not a link")
  lib.assert_contains(lib.read(path.join(root, "usr/bin/real")), "#!/bin/sh",
    "real file untouched")
end)

suite:test("-Solve targets the matching registry", function()
  local p = cli.parse({ "-Solve", "pkg", "--isolate" })
  lib.assert_true(p ~= nil, "parse should succeed")
  lib.assert_eq(p.command, "solve")
  lib.assert_true(p.flags.isolate)

  local root = fresh()
  db.record("hello", { name = "hello", version = "1.0", deps = {} },
    { "usr/bin/hello" }, { isolated = true, reserve_root = path.join(config.get().reserve_dir, "hello-1.0") })
  db.record("world", { name = "world", version = "1.0", deps = {} },
    { "usr/bin/world" }, {})

  -- System mode refuses an isolated-only package; isolate mode refuses a
  -- package that only exists system-side; unknown names are refused outright.
  lib.assert_eq(actions.solve({ "hello" }, { pass = true }), 1,
    "isolated-only package needs --isolate")
  lib.assert_eq(actions.solve({ "world" }, { isolate = true, pass = true }), 1,
    "system-only package cannot be solved isolated")
  lib.assert_eq(actions.solve({ "ghost" }, { pass = true }), 1,
    "unknown package refused")
end)

local function cmd_ok(cmd)
  local ok = os.execute(cmd)
  if type(ok) == "number" then return ok == 0 end
  return ok == true
end

suite:test("patch_rpaths stamps ELF objects and keeps wrappers env-free", function()
  if not cmd_ok("command -v patchelf >/dev/null 2>&1") then
    print("    [skip] patchelf not installed -- skipping RPATH test")
    return
  end

  local root = fresh()
  local cfg = config.get()
  local store = path.join(cfg.reserve_dir, "tool-1.0")
  os.execute("mkdir -p " .. path.quote(path.join(store, "usr/bin")) .. " "
    .. path.quote(path.join(store, "usr/lib")))

  -- A real ELF binary (named "true" so multicall coreutils still behaves)
  -- and a real shared library (needs a SONAME to be recognized as one). If
  -- /bin/true is not a patchable ELF here, there is nothing to test.
  if not cmd_ok("cp /bin/true " .. path.quote(path.join(store, "usr/bin/true"))
      .. " 2>/dev/null || cp /usr/bin/true " .. path.quote(path.join(store, "usr/bin/true")))
    or not cmd_ok("patchelf --print-rpath " .. path.quote(path.join(store, "usr/bin/true"))
      .. " >/dev/null 2>&1") then
    print("    [skip] no patchable ELF /bin/true available to stage a test object")
    return
  end
  local have_lib = cmd_ok("cp $(find /lib /lib64 /usr/lib /usr/lib64 -maxdepth 2 -name libc.so.6 2>/dev/null | head -1) "
    .. path.quote(path.join(store, "usr/lib/libfake.so.1")) .. " 2>/dev/null")

  -- Only executables are stamped: libraries resolve through the inherited
  -- DT_RPATH and must never be rewritten (fragile prebuilt layouts break).
  local patched = reserve.patch_rpaths(store)
  lib.assert_eq(patched, 1, "only the executable is stamped")

  -- Idempotent: nothing left to patch on a second run.
  lib.assert_eq(reserve.patch_rpaths(store), 0, "second run patches nothing")

  -- The binary resolves its libraries from the store on its own; the
  -- library stays untouched.
  local f = path.popen("patchelf --print-rpath "
    .. path.quote(path.join(store, "usr/bin/true")))
  local rpath = f and f:read("*l") or ""
  if f then f:close() end
  lib.assert_contains(rpath, store, "RPATH points into the store")

  if have_lib then
    local g = path.popen("patchelf --print-rpath "
      .. path.quote(path.join(store, "usr/lib/libfake.so.1")))
    local lib_rpath = g and g:read("*l") or ""
    if g then g:close() end
    lib.assert_eq(lib_rpath, "", "library RPATH untouched")
  end

  -- So its wrapper is a bare exec: no environment export, no leak.
  reserve.link_profile(store, { "usr/bin/true" })
  local body = lib.read(path.join(cfg.reserve_dir, "profile/bin/true"))
  lib.assert_not_contains(body, "LD_LIBRARY_PATH", "wrapper must not export LD_LIBRARY_PATH")
  lib.assert_contains(body, "exec " .. path.join(store, "usr/bin/true"),
    "wrapper execs the store binary")

  -- And it actually runs.
  lib.assert_true(cmd_ok(path.quote(path.join(cfg.reserve_dir, "profile/bin/true"))),
    "bare wrapper runs the ELF binary")
end)

suite:test("bare wrappers are still recognized by unlink_profile/unlink_system", function()
  if not cmd_ok("command -v patchelf >/dev/null 2>&1") then
    print("    [skip] patchelf not installed -- skipping bare-wrapper unlink test")
    return
  end

  local root = fresh()
  local cfg = config.get()
  local store = path.join(cfg.reserve_dir, "tool-1.0")
  os.execute("mkdir -p " .. path.quote(path.join(store, "usr/bin")))
  if not cmd_ok("cp /bin/true " .. path.quote(path.join(store, "usr/bin/tool"))
      .. " 2>/dev/null || cp /usr/bin/true " .. path.quote(path.join(store, "usr/bin/tool"))) then
    print("    [skip] no /bin/true available to stage an ELF test object")
    return
  end

  reserve.patch_rpaths(store)
  reserve.link_profile(store, { "usr/bin/tool" })
  reserve.link_system(store, { "usr/bin/tool" })

  local removed_links = reserve.unlink_system(store)
  lib.assert_eq(removed_links, 1, "system link removed via bare wrapper")
  lib.assert_nil(path.readlink(path.join(root, "usr/bin/tool")), "system link gone")

  local removed_wraps = reserve.unlink_profile(store)
  lib.assert_eq(removed_wraps, 1, "bare wrapper removed")
  lib.assert_false(path.exists(path.join(cfg.reserve_dir, "profile/bin/tool")),
    "wrapper file gone")
end)

return suite
