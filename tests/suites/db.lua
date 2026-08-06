-- db.lua suite -- the installed-package database: metadata round-trip, file
-- lists, reverse dependencies, and removal.

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

suite:test("reverse_dependents finds dependents", function()
  fresh()
  db.record("libz", meta("libz", { deps = {} }), { "usr/lib/x" })
  db.record("glib", meta("glib", { deps = { { name = "libz" } } }), { "usr/lib/y" })
  db.record("app", meta("app", { deps = { { name = "libz" } } }), { "usr/bin/app" })
  local rd = db.reverse_dependents("libz")
  table.sort(rd)
  lib.assert_eq(rd, { "app", "glib" })
  lib.assert_eq(db.reverse_dependents("nope"), {})
end)

suite:test("remove deletes the package directory and metadata", function()
  local root = fresh()
  db.record("gone", meta("gone"), { "usr/bin/gone" })
  lib.assert_true(db.is_installed("gone"))
  db.remove("gone")
  lib.assert_false(db.is_installed("gone"))
  lib.assert_eq(db.list(), {})
  lib.assert_false(lib.exists(path.join(root, "var/db/zeta", "gone")))
end)

suite:test("db.get on a corrupt meta file returns nil", function()
  local root = fresh()
  db.record("broken", meta("broken"), {})
  local p = db.meta_path("broken")
  lib.write(p, "this is not lua")
  lib.assert_nil(db.get("broken"))
end)

return suite
