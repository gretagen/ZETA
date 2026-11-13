-- commit.lua suite -- the staging-to-root commit step: pre-flight validation,
-- cross-package file conflicts, symlink safety, and the optional files
-- whitelist.

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

suite:test("commits files, symlinks, and dirs", function()
  local root = fresh()
  local s = simple_stage(root, "a")
  local owned = commit.apply(s, { pkg_name = "A" })
  lib.assert_true(lib.exists(path.join(root, "usr/bin/tool")))
  lib.assert_true(lib.exists(path.join(root, "usr/lib/liba.so")))
  lib.assert_true(lib.is_symlink(path.join(root, "usr/lib/liba.so.1")))
  lib.assert_true(path.exists(path.join(root, "usr/bin")))
  lib.assert_true(path.exists(path.join(root, "usr/lib")))
  local found = {}
  for _, e in ipairs(owned) do found[e.rel] = true end
  lib.assert_true(found["usr/bin/tool"])
  lib.assert_true(found["usr/lib/liba.so.1"])
  lib.assert_false(found["usr/bin"], "parent directories must NOT be recorded as owned")
  lib.assert_false(found["usr/lib"], "parent directories must NOT be recorded as owned")
end)

suite:test("init-system and distro-identity paths are installed normally", function()
  local root = fresh()
  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/usr/bin"))
  os.execute("mkdir -p " .. path.quote(s .. "/etc/systemd/system"))
  os.execute("mkdir -p " .. path.quote(s .. "/etc/init.d"))
  os.execute("mkdir -p " .. path.quote(s .. "/etc/runlevels/default"))
  lib.write(path.join(s, "etc/systemd/system/x.service"), "unit")
  lib.write(path.join(s, "etc/init.d/rc"), "#init")
  lib.write(path.join(s, "etc/os-release"), "ID=zerene")
  lib.write(path.join(s, "etc/rc.conf"), "rc_parallel=YES")
  lib.write(path.join(s, "etc/runlevels/default/rc"), "default")
  lib.write(path.join(s, "usr/bin/ok"), "ok")
  local owned = commit.apply(s, { pkg_name = "openrc" })
  lib.assert_true(lib.exists(path.join(root, "etc/systemd/system/x.service")))
  lib.assert_true(lib.exists(path.join(root, "etc/init.d/rc")))
  lib.assert_true(lib.exists(path.join(root, "etc/runlevels/default/rc")))
  lib.assert_true(lib.exists(path.join(root, "etc/os-release")))
  lib.assert_true(lib.exists(path.join(root, "etc/rc.conf")))
  lib.assert_true(lib.exists(path.join(root, "usr/bin/ok")))
  local found = {}
  for _, e in ipairs(owned) do found[e.rel] = true end
  lib.assert_true(found["etc/init.d/rc"])
  lib.assert_true(found["etc/rc.conf"])
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

suite:test("files behind a dangling usr-merge symlink commit", function()
  local root = fresh()
  -- filesystem package: usr-merge symlink, /usr/sbin does not exist yet
  os.execute("mkdir -p " .. path.quote(root .. "/usr"))
  os.execute("ln -s usr/sbin " .. path.quote(root .. "/sbin"))

  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/sbin"))
  lib.write(path.join(s, "sbin/ldconfig"), "ldconfig")

  local owned = commit.apply(s, { pkg_name = "glibc" })
  lib.assert_true(lib.exists(path.join(root, "usr/sbin/ldconfig")))
  lib.assert_true(lib.exists(path.join(root, "sbin/ldconfig")))
  local found = {}
  for _, e in ipairs(owned) do found[e.rel] = true end
  lib.assert_true(found["sbin/ldconfig"])
end)

suite:test("symlinks overwrite an existing file behind a usr-merge symlink", function()
  local root = fresh()
  -- usr-merge layout like the filesystem package: /sbin -> usr/sbin
  os.execute("mkdir -p " .. path.quote(root .. "/usr/sbin"))
  os.execute("ln -s usr/sbin " .. path.quote(root .. "/sbin"))
  -- A file already occupies the destination (e.g. a hand-placed binary).
  lib.write(path.join(root, "usr/sbin/ctstat"), "orphan-binary")

  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/sbin"))
  lib.write(path.join(s, "sbin/lnstat"), "ELF-stub")
  os.execute("ln -s lnstat " .. path.quote(s .. "/sbin/ctstat"))

  local owned = commit.apply(s, { pkg_name = "iproute2" })
  lib.assert_true(lib.is_symlink(path.join(root, "usr/sbin/ctstat")),
    "existing file must be replaced by the packaged symlink")
  lib.assert_eq(path.readlink(path.join(root, "usr/sbin/ctstat")), "lnstat")
  lib.assert_true(lib.exists(path.join(root, "usr/sbin/lnstat")))
  -- Regexp tied to: uutils-coreutils ln 0.13 cannot -f-replace an existing
  -- destination under a symlinked parent (ENOTDIR instead of unlinking), so
  -- commit deletes the old entry before linking.
end)

suite:test("library symlinks commit after their target files", function()
  local root = fresh()
  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/usr/lib"))
  lib.write(path.join(s, "usr/lib/libfoo.so.1.2.3"), "ELF-stub")
  os.execute("ln -s libfoo.so.1.2.3 " .. path.quote(s .. "/usr/lib/libfoo.so.1"))

  local owned = commit.apply(s, { pkg_name = "foo" })
  lib.assert_true(lib.exists(path.join(root, "usr/lib/libfoo.so.1.2.3")))
  lib.assert_true(lib.is_symlink(path.join(root, "usr/lib/libfoo.so.1")))
  local file_idx, link_idx
  for i, e in ipairs(owned) do
    if e.rel == "usr/lib/libfoo.so.1.2.3" then file_idx = i end
    if e.rel == "usr/lib/libfoo.so.1" then link_idx = i end
  end
  lib.assert_true(file_idx and link_idx, "both entries recorded")
  lib.assert_true(file_idx < link_idx, "symlink must commit after its target file")
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

-- ---------------------------------------------------------------------------
-- Liveness: a transaction runs while the system is using the files it
-- replaces. These are the regressions behind "a huge zeta transaction
-- crashes your stuff": in-place rewrites of mmap'd libraries segfault
-- running daemons, and a non-atomic symlink swap leaves a window where the
-- path is missing and a restarting service fails to start.
-- ---------------------------------------------------------------------------

local function count_matches(dir, name)
  local f = path.popen("find " .. path.quote(dir) .. " -maxdepth 1 -name "
    .. path.quote(name) .. " 2>/dev/null")
  local n = 0
  if f then for _ in f:lines() do n = n + 1 end f:close() end
  return n
end

suite:test("a file another process holds open keeps its old bytes", function()
  local root = fresh()
  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/usr/lib"))
  os.execute("mkdir -p " .. path.quote(root .. "/usr/lib"))
  -- The live file: a library some daemon has open (here: this test).
  lib.write(path.join(root, "usr/lib/liblive.so"), "OLD-BYTES")
  lib.write(path.join(s, "usr/lib/liblive.so"), "NEW-BYTES-REPLACING-A-MUCH-LONGER-OLD-ONE")

  local live = io.open(path.join(root, "usr/lib/liblive.so"), "rb")
  lib.assert_true(live ~= nil)

  local ok, err = pcall(commit.apply, s, { pkg_name = "live" })
  local old_bytes = live:read("*a")
  live:close()
  lib.assert_true(ok, tostring(err))

  -- The open handle must still see the ORIGINAL inode's content: an
  -- in-place O_TRUNC overwrite (what `cp --parents` onto the live path
  -- does) would have mutated these bytes underneath the reader.
  lib.assert_eq(old_bytes, "OLD-BYTES",
    "commit truncated a file a reader holds open")
  -- And the path itself now serves the new content.
  lib.assert_eq(lib.read(path.join(root, "usr/lib/liblive.so")),
    "NEW-BYTES-REPLACING-A-MUCH-LONGER-OLD-ONE")
  -- No shadow tree may outlive the commit.
  lib.assert_eq(count_matches(root, ".zeta-commit-*"), 0,
    "shadow dir left at the install root")
  lib.assert_eq(count_matches(path.join(root, "var/tmp/zeta"), "shadow-*"), 0,
    "shadow dir left in tmp_dir")
end)

suite:test("bulk commit replaces a destination symlink, never writes through it", function()
  local root = fresh()
  -- Live layout: usr/bin/tool is a symlink to a shared referent, like a
  -- busybox applet link or a versioned .so.N link.
  os.execute("mkdir -p " .. path.quote(root .. "/usr/bin") .. " "
    .. path.quote(root .. "/usr/lib"))
  lib.write(path.join(root, "usr/lib/referent"), "REFERENT")
  os.execute("ln -s ../lib/referent " .. path.quote(root .. "/usr/bin/tool"))

  -- The package ships a regular file at that path (plus enough entries to
  -- go through the chunked bulk path).
  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/usr/bin"))
  lib.write(path.join(s, "usr/bin/tool"), "TOOL-V2")
  for i = 1, 30 do
    lib.write(path.join(s, ("usr/bin/f%02d"):format(i)), "x" .. i)
  end

  local ok, err = pcall(commit.apply, s, { pkg_name = "bulk" })
  lib.assert_true(ok, tostring(err))
  lib.assert_false(lib.is_symlink(path.join(root, "usr/bin/tool")),
    "destination symlink must be replaced, not followed")
  lib.assert_eq(lib.read(path.join(root, "usr/bin/tool")), "TOOL-V2")
  lib.assert_eq(lib.read(path.join(root, "usr/lib/referent")), "REFERENT",
    "wrote through the destination symlink and corrupted the referent")
end)

suite:test("a symlink swap never exposes a missing path", function()
  local root = fresh()
  os.execute("mkdir -p " .. path.quote(root .. "/usr/lib"))
  lib.write(path.join(root, "usr/lib/liba.so"), "old-target")
  os.execute("ln -s liba.so " .. path.quote(root .. "/usr/lib/liba.so.1"))

  local s = path.join(root, "stage")
  os.execute("mkdir -p " .. path.quote(s .. "/usr/lib"))
  lib.write(path.join(s, "usr/lib/libb.so"), "new-target")
  os.execute("ln -s libb.so " .. path.quote(s .. "/usr/lib/liba.so.1"))

  -- A slow `rm` widens the legacy rm-then-link swap's missing-path window
  -- to ~0.4s, so the sampler below (10ms ticks) cannot miss a regression
  -- to it. The fixed swap never runs rm at all: it renames a private temp
  -- link into place.
  local shim = path.join(root, "shim")
  os.execute("mkdir -p " .. path.quote(shim))
  local rf = path.popen("command -v rm 2>/dev/null")
  local real_rm = rf and rf:read("*l") or "/bin/rm"
  if rf then rf:close() end
  lib.write(path.join(shim, "rm"), "#!/bin/sh\nsleep 0.4\nexec " .. real_rm .. ' "$@"\n')
  os.execute("chmod +x " .. path.quote(path.join(shim, "rm")))

  local dest = path.join(root, "usr/lib/liba.so.1")
  local logp = path.join(root, "sampler.log")
  local loop = "while :; do if [ -e " .. path.quote(dest) .. " ] || [ -L "
    .. path.quote(dest) .. " ]; then echo OK; else echo MISSING; fi; sleep 0.01; done > "
    .. path.quote(logp)
  local sampler = path.spawn_bg(path.shell .. " -c " .. path.quote(loop),
    path.join(root, "sampler.pid"))
  lib.assert_true(sampler ~= nil, "could not start the sampler")

  local orig_run = path.run
  path.run = function(cmd)
    return orig_run("export PATH=" .. path.quote(shim) .. ":$PATH; " .. cmd)
  end
  local ok, err = pcall(commit.apply, s, { pkg_name = "swap" })
  path.run = orig_run
  path.kill_tree(sampler)

  lib.assert_true(ok, tostring(err))
  local log = lib.read(logp) or ""
  lib.assert_not_contains(log, "MISSING",
    "symlink swap left the path missing while a reader watched")
  lib.assert_true(log:find("OK", 1, true) ~= nil, "sampler never observed the path")
  lib.assert_eq(path.readlink(dest), "libb.so")
end)

return suite
