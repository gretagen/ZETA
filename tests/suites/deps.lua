-- deps.lua suite -- dependency resolution: ordering, cycles, constraints,
-- installed-package short-circuiting, and memoization.

local lib = require("lib")
local deps = require("deps")
local suite = lib.new_suite("deps")

local function manifest(name, deps_list)
  return { name = name, version = "1.0", deps = deps_list or {} }
end

local function ctx(tree, installed)
  return {
    fetch_manifest = function(n)
      local m = tree[n]
      lib.assert_true(m ~= nil, "unexpected fetch of " .. tostring(n))
      return m
    end,
    installed_version = function(n)
      return installed and installed[n]
    end,
  }
end

local function resolve(target, c)
  local ok, order = pcall(deps.resolve, target, c)
  lib.assert_true(ok, "deps.resolve raised: " .. tostring(order))
  local names = {}
  for _, item in ipairs(order) do names[#names + 1] = item.name end
  return names
end

suite:test("leaf package resolves alone", function()
  lib.assert_eq(resolve("b", ctx({ b = manifest("b") })), { "b" })
end)

suite:test("dependencies come before dependents", function()
  lib.assert_eq(
    resolve("a", ctx({ a = manifest("a", { { name = "b" } }), b = manifest("b") })),
    { "b", "a" })
end)

suite:test("transitive chain is fully ordered", function()
  lib.assert_eq(
    resolve("a", ctx({
      a = manifest("a", { { name = "b" } }),
      b = manifest("b", { { name = "c" } }),
      c = manifest("c"),
    })),
    { "c", "b", "a" })
end)

suite:test("shared dependencies are included once", function()
  local names = resolve("a", ctx({
    a = manifest("a", { { name = "b" }, { name = "c" } }),
    b = manifest("b", { { name = "c" } }),
    c = manifest("c"),
  }))
  lib.assert_eq(names, { "c", "b", "a" })
end)

suite:test("cycle is detected with the full chain", function()
  local ok, err = pcall(deps.resolve, "a", ctx({
    a = manifest("a", { { name = "b" } }),
    b = manifest("b", { { name = "a" } }),
  }))
  lib.assert_false(ok, "expected a cycle error")
  lib.assert_contains(err, "cycle")
end)

suite:test("self-loop is a cycle", function()
  local ok, err = pcall(deps.resolve, "a", ctx({ a = manifest("a", { { name = "a" } }) }))
  lib.assert_false(ok, "expected a cycle error")
end)

suite:test("installed satisfying dep is skipped", function()
  local names = resolve("a", ctx({
    a = manifest("a", { { name = "b", op = ">=", version = "1.0" } }),
    b = manifest("b"),
  }, { b = "1.5" }))
  lib.assert_eq(names, { "a" })
end)

suite:test("installed-but-too-old dep is refused", function()
  local ok, err = pcall(deps.resolve, "a", ctx({
    a = manifest("a", { { name = "b", op = ">=", version = "1.0" } }),
    b = manifest("b"),
  }, { b = "0.9" }))
  lib.assert_false(ok)
  lib.assert_contains(err, "does not satisfy")
end)

suite:test("missing manifest is an error", function()
  local ok, err = pcall(deps.resolve, "ghost", ctx({}))
  lib.assert_false(ok)
  lib.assert_contains(err, "ghost")
end)

suite:test("manifests are fetched once (memoized)", function()
  local calls = {}
  local c = {
    fetch_manifest = function(n)
      calls[#calls + 1] = n
      return manifest(n)
    end,
    installed_version = function() end,
  }
  resolve("a", c) -- a has no deps here
  lib.assert_eq(calls, { "a" })
end)

suite:test("re-resolving a diamond fetches each package once", function()
  local tree = {
    a = manifest("a", { { name = "b" }, { name = "c" } }),
    b = manifest("b", { { name = "d" } }),
    c = manifest("c"),
    d = manifest("d"),
  }
  local calls = {}
  local c = {
    fetch_manifest = function(n)
      calls[#calls + 1] = n
      return tree[n]
    end,
    installed_version = function() end,
  }
  resolve("a", c)
  lib.assert_eq(calls, { "a", "b", "d", "c" })
end)

return suite
