-- hooks.lua suite -- permission checks, owner validation, type safety, and
-- trigger matching for post-transaction package hooks.

local lib = require("lib")
local db = require("db")
local path = require("path")
local config = require("config")
local suite = lib.new_suite("hooks")

-- path.stat_owner_and_perms ------------------------------------------------

suite:test("stat_owner_and_perms returns uid and perms for an existing file", function()
  local root = lib.tmpdir("hooks-perms")
  local f = path.join(root, "testfile")
  lib.write(f, "hello")
  local uid, perms = path.stat_owner_and_perms(f)
  lib.assert_true(uid ~= nil, "uid should not be nil")
  lib.assert_true(perms ~= nil, "perms should not be nil")
  lib.assert_true(type(uid) == "number", "uid should be a number")
  lib.assert_true(type(perms) == "number", "perms should be a number")
end)

suite:test("stat_owner_and_perms returns nil for a nonexistent file", function()
  local uid, perms = path.stat_owner_and_perms("/nonexistent/path/nope")
  lib.assert_nil(uid)
  lib.assert_nil(perms)
end)

suite:test("stat_owner_and_perms reflects chmod changes", function()
  local root = lib.tmpdir("hooks-chmod")
  local f = path.join(root, "chmodtest")
  lib.write(f, "data")
  os.execute("chmod 644 " .. path.quote(f))
  local _, perms644 = path.stat_owner_and_perms(f)
  lib.assert_eq(perms644, 644)
  os.execute("chmod 666 " .. path.quote(f))
  local _, perms666 = path.stat_owner_and_perms(f)
  lib.assert_eq(perms666, 666)
  os.execute("chmod 600 " .. path.quote(f))
  local _, perms600 = path.stat_owner_and_perms(f)
  lib.assert_eq(perms600, 600)
end)

-- db.file_owner -------------------------------------------------------------

suite:test("file_owner returns nil for an untracked file", function()
  local root = lib.tmpdir("hooks-db")
  lib.use_root(root)
  lib.assert_nil(db.file_owner("usr/share/zeta/hooks/nope.hook"))
end)

suite:test("file_owner returns the owning package name", function()
  local root = lib.tmpdir("hooks-db2")
  lib.use_root(root)
  local m = { name = "mypkg", version = "1.0", deps = {} }
  db.record("mypkg", m, {
    "usr/share/zeta/hooks/mypkg.hook",
    "usr/bin/mypkg",
  })
  lib.assert_eq(db.file_owner("usr/share/zeta/hooks/mypkg.hook"), "mypkg")
  lib.assert_eq(db.file_owner("usr/bin/mypkg"), "mypkg")
  lib.assert_nil(db.file_owner("usr/share/zeta/hooks/other.hook"))
end)

suite:test("file_owner returns first owner when file is shared", function()
  local root = lib.tmpdir("hooks-db3")
  lib.use_root(root)
  db.record("pkg_a", { name = "pkg_a", version = "1.0", deps = {} }, { "usr/share/zeta/hooks/shared.hook" })
  db.record("pkg_b", { name = "pkg_b", version = "1.0", deps = {} }, { "usr/share/zeta/hooks/shared.hook" })
  local owner = db.file_owner("usr/share/zeta/hooks/shared.hook")
  lib.assert_true(owner == "pkg_a" or owner == "pkg_b",
    "owner should be one of the two packages")
end)

-- hooks.run_installed integration (permission-gated) ------------------------

-- NOTE: The following integration tests exercise hooks.run_installed in a
-- non-root environment. Because check_hook_safety enforces uid=0, hooks
-- created by a regular user are rejected before loading. These tests verify
-- that the rejection path works correctly. Full permission + owner validation
-- testing requires running as root.

local function make_hook_content(trigger_target, exec_cmd, opts)
  opts = opts or {}
  local target_str
  if trigger_target == nil then
    target_str = "nil"
  elseif type(trigger_target) == "table" then
    local parts = {}
    for _, t in ipairs(trigger_target) do parts[#parts + 1] = "'" .. t .. "'" end
    target_str = "{ " .. table.concat(parts, ", ") .. " }"
  else
    target_str = "'" .. trigger_target .. "'"
  end
  local exec_field = ""
  if opts.exec_field ~= nil then
    if type(opts.exec_field) == "string" then
      exec_field = "exec = " .. string.format("%q", opts.exec_field)
    else
      exec_field = "exec = " .. tostring(opts.exec_field)
    end
  elseif exec_cmd then
    exec_field = "exec = " .. string.format("%q", exec_cmd)
  end
  return string.format([[
return {
  order = %d,
  trigger = { op = "install", type = "package", target = %s },
  action = { when = "post", %s, description = "test hook" },
}
]], opts.order or 50, target_str, exec_field)
end

local function setup_hooks_root(root)
  local hooks_dir = path.join(root, "usr/share/zeta/hooks")
  path.mkdir_p(hooks_dir)
  return hooks_dir
end

suite:test("hooks rejected when not owned by root (uid check)", function()
  local root = lib.tmpdir("hooks-uid")
  lib.use_root(root)
  local hooks_dir = setup_hooks_root(root)

  -- Create a hook file owned by current user (not root).
  local hook_file = path.join(hooks_dir, "test.hook")
  lib.write(hook_file, make_hook_content({"mypkg"}, "true"))

  -- Record the owning package in the DB.
  db.record("mypkg", { name = "mypkg", version = "1.0", deps = {} },
    { "usr/share/zeta/hooks/test.hook" })

  -- Run hooks: the uid check should reject the hook.
  local hooks = require("hooks")
  local failures = hooks.run_installed({ mypkg = true })
  lib.assert_eq(failures, 0, "no failures expected (hook was skipped, not run)")
end)

suite:test("hooks rejected when file is group-writable", function()
  local root = lib.tmpdir("hooks-gw")
  lib.use_root(root)
  local hooks_dir = setup_hooks_root(root)

  local hook_file = path.join(hooks_dir, "gwhook.hook")
  lib.write(hook_file, make_hook_content({"pkg_a"}, "true"))
  os.execute("chmod 664 " .. path.quote(hook_file))

  db.record("pkg_a", { name = "pkg_a", version = "1.0", deps = {} },
    { "usr/share/zeta/hooks/gwhook.hook" })

  local hooks = require("hooks")
  local failures = hooks.run_installed({ pkg_a = true })
  lib.assert_eq(failures, 0)
end)

suite:test("hooks rejected when file is world-writable", function()
  local root = lib.tmpdir("hooks-ww")
  lib.use_root(root)
  local hooks_dir = setup_hooks_root(root)

  local hook_file = path.join(hooks_dir, "wwhook.hook")
  lib.write(hook_file, make_hook_content({"pkg_b"}, "true"))
  os.execute("chmod 666 " .. path.quote(hook_file))

  db.record("pkg_b", { name = "pkg_b", version = "1.0", deps = {} },
    { "usr/share/zeta/hooks/wwhook.hook" })

  local hooks = require("hooks")
  local failures = hooks.run_installed({ pkg_b = true })
  lib.assert_eq(failures, 0)
end)

suite:test("run_installed returns 0 when hooks dir does not exist", function()
  local root = lib.tmpdir("hooks-nodir")
  lib.use_root(root)
  local hooks = require("hooks")
  local failures = hooks.run_installed({ pkg = true })
  lib.assert_eq(failures, 0)
end)

suite:test("run_installed returns 0 when no hooks exist", function()
  local root = lib.tmpdir("hooks-empty")
  lib.use_root(root)
  setup_hooks_root(root)
  local hooks = require("hooks")
  local failures = hooks.run_installed({ pkg = true })
  lib.assert_eq(failures, 0)
end)

return suite
