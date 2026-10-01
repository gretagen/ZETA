-- quotes.lua suite -- quote group integrity and the startup selection rule.

local lib = require("lib")
local quotes = require("quotes")
local suite = lib.new_suite("quotes")

local GROUPS = {
  "transcend", "remove", "forget", "list", "default", "localize",
  "help", "reprovide", "slowdownload", "isolate",
}

suite:test("every quote group is a non-empty list of non-empty strings", function()
  for _, g in ipairs(GROUPS) do
    local t = quotes[g]
    lib.assert_true(type(t) == "table", "group '" .. g .. "' must exist")
    lib.assert_true(#t > 0, "group '" .. g .. "' must not be empty")
    for i, q in ipairs(t) do
      lib.assert_true(type(q) == "string" and q ~= "",
        ("group '%s'[%d] must be a non-empty string"):format(g, i))
    end
  end
end)

suite:test("pick returns a member of the list, nil for empty", function()
  local list = { "alpha", "beta", "gamma" }
  local got = quotes.pick(list)
  lib.assert_true(got == "alpha" or got == "beta" or got == "gamma",
    "pick must return a member")
  lib.assert_nil(quotes.pick({}), "empty list -> nil")
  lib.assert_nil(quotes.pick(nil), "nil list -> nil")
  lib.assert_nil(quotes.pick("not a table"), "non-table -> nil")
end)

suite:test("for_command: isolate quotes only for -Provide --isolate", function()
  lib.assert_eq(quotes.for_command("provide", true), quotes.isolate)
  lib.assert_eq(quotes.for_command("reprovide", true), quotes.reprovide)
  -- no dedicated localprovide group: falls back to default
  lib.assert_eq(quotes.for_command("localprovide", true), quotes.default)
  lib.assert_eq(quotes.for_command("remove", true), quotes.remove)
  lib.assert_eq(quotes.for_command("transcend", true), quotes.transcend)
  lib.assert_eq(quotes.for_command("provide", false), quotes.default)
  lib.assert_eq(quotes.for_command("list", false), quotes.list)
  lib.assert_eq(quotes.for_command("nonsense", false), quotes.default)
end)

suite:test("set_enabled toggles is_enabled", function()
  lib.assert_true(quotes.is_enabled(), "enabled by default")
  quotes.set_enabled(false)
  lib.assert_false(quotes.is_enabled(), "set_enabled(false)")
  quotes.set_enabled(true)
  lib.assert_true(quotes.is_enabled(), "set_enabled(true) restores")
end)

return suite
