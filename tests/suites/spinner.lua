-- spinner.lua suite -- the /-\| loading animation.

local lib = require("lib")
local spinner = require("spinner")
local suite = lib.new_suite("spinner")

suite:test("build_script animates the / - \\ | frames on one line", function()
  local s = spinner.build_script("downloading x")
  lib.assert_true(s:find("\\r", 1, true) ~= nil, "redraws with \\r")
  lib.assert_true(s:find("while :", 1, true) ~= nil, "runs in a loop")
  for _, f in ipairs({ "/", "-", "\\", "|" }) do
    lib.assert_true(s:find(f, 1, true) ~= nil, "contains frame '" .. f .. "'")
  end
  lib.assert_true(s:find("sleep 0.1", 1, true) ~= nil, "ticks at 100ms")
end)

suite:test("enabled() is false when stdout is not a terminal", function()
  -- The test harness captures stdout, so `test -t 1` must fail here.
  lib.assert_false(spinner.enabled())
end)

suite:test("start/stop are no-ops off a terminal", function()
  lib.assert_false(spinner.enabled())
  spinner.start("downloading x")
  lib.assert_eq(spinner.stop(), nil, "no error from stop after no-op start")
end)

return suite
