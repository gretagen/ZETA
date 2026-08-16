-- db.lua suite -- the installed-package database: metadata round-trip, file
-- lists, the packages/dependencies registries, dependents back-references,
-- legacy migration, and removal.

local lib = require("lib")
local db = require("db")
local path = require("path")
local suite = lib.new_suite("db")

local function fresh()
  local root = lib.tmpdir("db")
  lib.use_root(root)
  return root
end

local function meta(name, over)
  local m = {
    name = name, version = "1.0", summary = "sum", url = "file:///x/" .. name .. ".tgz",
    sha256 = string.rep("a", 64), prefix = "/usr", deps = { { name = "libz" } },
    source = "local", installed_at = 1234567890,
  }
  if over then for k, v in pairs(over) do m[k] = v end end
  return m
end

suite:test("is_installed is false for an empty database", function()
  fresh()
  lib.assert_false(db.is_installed("nope"))
  lib.assert_eq(db.list(), {})
  lib.assert_eq(db.list_packages(), {})
  lib.assert_eq(db.list_dependencies(), {})
  lib.assert_nil(db.get("nope"))
  lib.assert_eq(db.files("nope"), {})
end)

suite:test("record + get round-trips the metadata", function()
  fresh()
  db.record("libz", meta("libz"), { "usr/lib/libz.so" })
  lib.assert_true(db.is_installed("libz"))
  local m = db.get("libz")
  lib.assert_true(m ~= nil)
  lib.assert_eq(m.name, "libz")
  lib.assert_eq(m.version, "1.0")
  lib.assert_eq(m.summary, "sum")
  lib.assert_eq(m.url, "file:///x/libz.tgz")
  lib.assert_eq(m.sha256, string.rep("a", 64))
  lib.assert_eq(m.prefix, "/usr")
  lib.assert_eq(m.deps[1], "libz") -- deps stored as plain names
  lib.assert_eq(m.source, "local")
  lib.assert_eq(type(m.installed_at), "number")
end)

suite:test("files round-trip line by line", function()
  fresh()
  db.record("libz", meta("libz"), { "usr/lib/libz.so", "usr/lib/libz.so.1" })
  lib.assert_eq(db.files("libz"), { "usr/lib/libz.so", "usr/lib/libz.so.1" })
end)

suite:test("list is sorted and includes multiple packages", function()
  fresh()
  db.record("zlib", meta("zlib"), { "usr/lib/x" })
  db.record("abc", meta("abc"), { "usr/bin/x" })
  db.record("mno", meta("mno"), { "usr/bin/y" })
  lib.assert_eq(db.list(), { "abc", "mno", "zlib" })
end)

suite:test("no .tmp files remain after record", function()
  fresh()
  db.record("x", meta("x"), { "a" })
  local dir = db.pkg_dir("x")
  local f = io.popen("ls -1 " .. path.quote(dir))
  local entries = {}
  for line in f:lines() do entries[#entries + 1] = line end
  f:close()
  lib.assert_eq(entries, { "files", "meta.lua" })
end)

suite:test("kind=dependency records into the dependencies registry", function()
  local root = fresh()
  db.record("hello", meta("hello", { deps = {} }), { "usr/bin/hello" }, { kind = "dependency" })
  lib.assert_false(lib.exists(path.join(root, "var/db/zeta/packages", "hello")))
  lib.assert_true(lib.exists(path.join(root, "var/db/zeta/dependencies", "hello")))
end)

suite:test("kind resolves packages vs dependencies", function()
  fresh()
  db.record("glib", meta("glib", { deps = {} }), { "usr/lib/x" })
  db.record("hello", meta("hello", { deps = {} }), { "usr/bin/hello" }, { kind = "dependency" })
  lib.assert_eq(db.kind("glib"), "package")
  lib.assert_eq(db.kind("hello"), "dependency")
  lib.assert_nil(db.kind("nope"))
  lib.assert_eq(db.list_packages(), { "glib" })
  lib.assert_eq(db.list_dependencies(), { "hello" })
  lib.assert_eq(db.list(), { "glib", "hello" })
end)

suite:test("add_dependent is idempotent and reverse_dependents reads the list", function()
  fresh()
  db.record("hello", meta("hello", { deps = {} }), { "usr/bin/hello" }, { kind = "dependency" })
  db.record("app", meta("app", { deps = {} }), { "usr/bin/app" })
  db.record("other", meta("other", { deps = {} }), { "usr/bin/other" })
  db.add_dependent("hello", "app")
  db.add_dependent("hello", "app")
  db.add_dependent("hello", "other")
  lib.assert_eq(db.reverse_dependents("hello"), { "app", "other" })
  lib.assert_eq(db.reverse_dependents("nope"), {})
end)

suite:test("add_dependent is a no-op for an uninstalled dependency", function()
  fresh()
  db.record("app", meta("app", { deps = {} }), { "usr/bin/app" })
  db.add_dependent("ghost", "app")
  lib.assert_eq(db.reverse_dependents("ghost"), {})
end)

suite:test("remove_dependent drops a dependent and leaves the rest", function()
  fresh()
  db.record("hello", meta("hello", { deps = {} }), { "usr/bin/hello" }, { kind = "dependency" })
  db.record("app", meta("app", { deps = {} }), { "usr/bin/app" })
  db.record("other", meta("other", { deps = {} }), { "usr/bin/other" })
  db.add_dependent("hello", "app")
  db.add_dependent("hello", "other")
  db.remove_dependent("hello", "app")
  lib.assert_eq(db.reverse_dependents("hello"), { "other" })
  db.remove_dependent("ghost", "app") -- no-op
end)

suite:test("reverse_dependents skips stale references to removed entries", function()
  fresh()
  db.record("hello", meta("hello", { deps = {} }), { "usr/bin/hello" }, { kind = "dependency" })
  db.record("app", meta("app", { deps = {} }), { "usr/bin/app" })
  db.record("gone", meta("gone", { deps = {} }), { "usr/bin/gone" })
  db.add_dependent("hello", "app")
  db.add_dependent("hello", "gone")
  db.remove("gone")
  lib.assert_eq(db.reverse_dependents("hello"), { "app" })
end)

suite:test("record preserves dependents on reinstall", function()
  fresh()
  db.record("hello", meta("hello", { deps = {} }), { "usr/bin/hello" }, { kind = "dependency" })
  db.add_dependent("hello", "app")
  db.record("hello", meta("hello", { deps = {} }), { "usr/bin/hello" }, { kind = "dependency" })
  local m = db.get("hello")
  lib.assert_eq(m.dependents, { "app" })
end)

suite:test("legacy database is migrated into packages/ with dependents wired", function()
  local root = fresh()
  local sd = path.join(root, "var/db/zeta")
  local function legacy(name, deps)
    local dir = path.join(sd, name)
    path.mkdir_p(dir)
    lib.write(path.join(dir, "meta.lua"),
      "return { name='" .. name .. "', version='1.0', deps=" .. deps .. ", installed_at=0 }\n")
    lib.write(path.join(dir, "files"), "usr/bin/" .. name .. "\n")
  end
  legacy("libz", "{}")
  legacy("app", "{ [1]='libz' }") -- stored metas carry deps as plain names

  db.list() -- triggers the lazy migration

  lib.assert_eq(db.list_packages(), { "app", "libz" })
  lib.assert_eq(db.list_dependencies(), {})
  lib.assert_eq(db.kind("libz"), "package")
  lib.assert_eq(db.reverse_dependents("libz"), { "app" })
  lib.assert_false(lib.exists(path.join(sd, "app")))
  lib.assert_false(lib.exists(path.join(sd, "libz")))
end)

suite:test("remove deletes the package directory and metadata", function()
  local root = fresh()
  db.record("gone", meta("gone"), { "usr/bin/gone" })
  lib.assert_true(db.is_installed("gone"))
  db.remove("gone")
  lib.assert_false(db.is_installed("gone"))
  lib.assert_eq(db.list(), {})
  lib.assert_false(lib.exists(path.join(root, "var/db/zeta/packages", "gone")))
end)

suite:test("db.get on a corrupt meta file returns nil", function()
  local root = fresh()
  db.record("broken", meta("broken"), {})
  local p = db.meta_path("broken")
  lib.write(p, "this is not lua")
  lib.assert_nil(db.get("broken"))
end)

return suite
