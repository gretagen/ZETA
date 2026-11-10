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
  spinner.start_row("", " - Extracting dependencies... [ 0/1 ]")
  lib.assert_eq(spinner.stop(), nil, "no error from stop after no-op start")
end)

-- start_row is what the dependency-extraction row uses: an exact prefix (so
-- it lines up with log.step's `==> ` shape) animated with BLA_metro.
suite:test("build_row takes an exact prefix, frames and interval", function()
  local prefix = "==> Extracting dependencies... - [ 1/2 ] glibc-2.44-2.gz "
  local s = spinner.build_row(prefix, "", spinner.METRO, 0.2)
  lib.assert_true(s:find("\\r", 1, true) ~= nil, "redraws with \\r")
  lib.assert_true(s:find("while :", 1, true) ~= nil, "runs in a loop")
  lib.assert_true(s:find(prefix, 1, true) ~= nil, "uses the prefix verbatim")
  for _, f in ipairs(spinner.METRO) do
    lib.assert_true(s:find(f, 1, true) ~= nil, "contains frame '" .. f .. "'")
  end
  lib.assert_true(s:find("sleep 0.2", 1, true) ~= nil, "honours the interval it was given")
end)

suite:test("every meter frame is the same width (no redraw residue)", function()
  lib.assert_true(#spinner.METRO >= 2, "the meter has at least two frames")
  local w = #spinner.METRO[1]
  for i, f in ipairs(spinner.METRO) do
    lib.assert_eq(#f, w, ("frame %d is %d bytes, expected %d"):format(i, #f, w))
  end
end)

return suite
