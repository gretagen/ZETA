-- profile.lua suite -- phase-timing accumulation, sub-phases, and report
-- formatting, all against a scripted clock (no real time is spent).

local lib = require("lib")
local profile = require("profile")
local suite = lib.new_suite("profile")

-- Scripted clock: tests advance `t` explicitly between marks so every
-- duration in the report is exact.
local t
local function clock() return t end

-- Fresh state + fake clock for one test body; always restores the real
-- clock and clears state afterwards so a failed test cannot leak marks
-- into the next one.
local function with_clock(fn)
  profile.reset()
  t = 0
  profile.set_clock(clock)
  local ok, err = pcall(fn)
  profile.set_clock(nil)
  profile.reset()
  if not ok then error(err, 0) end
end

suite:test("report is nil when nothing was marked", function()
  with_clock(function()
    lib.assert_nil(profile.report())
  end)
end)

suite:test("marks accumulate durations in order", function()
  with_clock(function()
    profile.mark("resolve")           -- opens at t=0
    t = 1.25
    profile.mark("fetch")             -- resolve closes: 1.25s
    t = 2.25
    profile.mark("verify")            -- fetch closes: 1.00s
    t = 2.5
    profile.close()                   -- verify closes: 0.25s
    lib.assert_eq(profile.report(),
      "resolve 1.25s | fetch 1.00s | verify 0.25s")
  end)
end)

suite:test("report closes a phase left open", function()
  with_clock(function()
    profile.mark("extract")
    t = 4
    lib.assert_eq(profile.report(), "extract 4.00s")
  end)
end)

suite:test("repeated phase names aggregate into one entry", function()
  with_clock(function()
    profile.mark("resolve")   -- 0
    t = 1
    profile.mark("fetch")     -- resolve += 1
    t = 2
    profile.mark("resolve")   -- fetch += 1
    t = 3.5
    profile.mark("fetch")     -- resolve += 1.5
    t = 4
    profile.close()           -- fetch += 0.5
    -- resolve = 1 + 1.5 = 2.5; fetch = 1 + 0.5 = 1.5; first-seen order kept
    lib.assert_eq(profile.report(), "resolve 2.50s | fetch 1.50s")
  end)
end)

suite:test("sub-phases nest under the open phase", function()
  with_clock(function()
    profile.mark("commit")          -- t=0
    t = 0.2
    profile.submark("count")        -- commit accrues 0.2 first, count opens
    t = 1.2
    profile.submark("pool")         -- count closes: 1.00s
    t = 3.7
    profile.close()                 -- pool closes 2.50s, commit closes 3.70s
    lib.assert_eq(profile.report(),
      "commit 3.70s (count 1.00s, pool 2.50s)")
  end)
end)

suite:test("close_sub ends the sub-phase but keeps the phase running", function()
  with_clock(function()
    profile.mark("commit")      -- t=0
    t = 1
    profile.submark("pool")     -- commit 1.0 so far
    t = 2
    profile.close_sub()         -- pool closes: 1.00s
    t = 5
    profile.close()             -- commit keeps accruing: 5.00s total
    -- wire/system time (2 -> 5) lands in commit but not in pool
    lib.assert_eq(profile.report(), "commit 5.00s (pool 1.00s)")
  end)
end)

suite:test("submark with no open phase becomes a top-level phase", function()
  with_clock(function()
    profile.submark("count")
    t = 0.5
    lib.assert_eq(profile.report(), "count 0.50s")
  end)
end)

suite:test("time between close and the next mark is unattributed", function()
  with_clock(function()
    profile.mark("resolve")   -- 0
    t = 1
    profile.close()           -- resolve 1.00s
    t = 61                    -- a minute of "user thinking": billed to no one
    profile.mark("fetch")
    t = 61.25
    profile.close()           -- fetch 0.25s
    lib.assert_eq(profile.report(), "resolve 1.00s | fetch 0.25s")
  end)
end)

suite:test("reset forgets all recorded phases", function()
  with_clock(function()
    profile.mark("resolve")
    t = 2
    profile.close()
    profile.reset()
    lib.assert_nil(profile.report())
  end)
end)

suite:test("set_clock(nil) restores the real clock", function()
  with_clock(function()
    profile.set_clock(nil)
    profile.mark("resolve")
    profile.close()
    local r = profile.report()
    -- Real seconds: a well-formed "name N.NNs" regardless of resolution.
    lib.assert_true(r:match("^resolve %d+%.%d+s$") ~= nil,
      "real-clock report must be well-formed, got: " .. tostring(r))
  end)
end)

return suite
