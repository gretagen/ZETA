-- profile.lua -- wall-clock phase timings for the install pipeline.
--
-- -Provide and -Transcend walk a fixed sequence of phases (resolve, fetch,
-- verify, extract, commit); this module measures where the wall clock went
-- and formats one receipt line:
--
--   timings: resolve 1.25s | fetch 0.40s | verify 0.10s | extract 4.90s | commit 2.40s (count 0.20s, pool 2.20s)
--
-- Design notes:
--   * The clock reads /proc/uptime (0.01s resolution, no fork) and falls
--     back to os.time() when /proc is unavailable. os.clock() would be wrong
--     here: it measures only this process's CPU time, and every phase we
--     care about is dominated by children (tar, cp, curl, the commit
--     workers).
--   * Durations accumulate per phase NAME, so a multi-package run
--     (`zeta -Provide a b`) reports one summed entry per phase instead of
--     interleaved repeats.
--   * Sub-phases (commit's count/pool) nest under the phase that is open
--     when they start; a submark with no phase open simply becomes a phase.
--   * report() returns nil when nothing was ever marked, so a command that
--     never enters the pipeline prints no line at all (wired in zeta.lua).
--
-- Tests inject a fake clock through set_clock() and call reset() between
-- cases; set_clock(nil) restores the real clock.

local profile = {}

local order      -- phase names, first-seen order
local totals     -- phase name -> accumulated seconds
local sub_order  -- phase name -> sub names, first-seen order
local sub_totals -- phase name -> { sub name -> seconds }
local open       -- { name =, t0 = } of the phase currently open, or nil
local open_sub   -- { name =, t0 = } of the sub-phase currently open, or nil
local clock      -- time source: () -> seconds

local function default_clock()
  local f = io.open("/proc/uptime", "rb")
  if f then
    local up = f:read("*l")
    f:close()
    local sec = up and tonumber(up:match("^[%d.]+"))
    if sec then return sec end
  end
  return os.time()
end

local function reset_state()
  order, totals, sub_order, sub_totals = {}, {}, {}, {}
  open, open_sub = nil, nil
end

reset_state()
clock = default_clock

local function close_sub(t)
  if not open_sub then return end
  local e = open_sub
  open_sub = nil
  local parent = open and open.name
  if not parent then return end
  if not sub_order[parent] then
    sub_order[parent], sub_totals[parent] = {}, {}
  end
  if sub_totals[parent][e.name] == nil then
    sub_order[parent][#sub_order[parent] + 1] = e.name
    sub_totals[parent][e.name] = 0
  end
  sub_totals[parent][e.name] = sub_totals[parent][e.name] + (t - e.t0)
end

local function close_phase(t)
  if not open then return end
  local e = open
  open = nil
  if totals[e.name] == nil then
    order[#order + 1] = e.name
    totals[e.name] = 0
  end
  totals[e.name] = totals[e.name] + (t - e.t0)
end

-- mark(name) -- close whatever is open (sub first, then phase) and open
-- this phase. The gap between two marks is deliberately unattributed: user
-- think time at a confirmation prompt is not Zeta's time to report.
function profile.mark(name)
  local t = clock()
  close_sub(t)
  close_phase(t)
  open = { name = name, t0 = t }
end

-- submark(name) -- open a sub-phase under the currently open phase (e.g.
-- commit's count and pool halves). With no phase open it becomes a phase.
function profile.submark(name)
  local t = clock()
  close_sub(t)
  if not open then
    open = { name = name, t0 = t }
    return
  end
  open_sub = { name = name, t0 = t }
end

-- close() -- close the current sub-phase and phase; later time is
-- unattributed until the next mark.
function profile.close()
  local t = clock()
  close_sub(t)
  close_phase(t)
end

-- close_sub() -- end the current sub-phase but keep the phase open. Used by
-- commit_all so wire/system time stays in the phase without inflating pool.
function profile.close_sub()
  close_sub(clock())
end

local function fmt(secs)
  return string.format("%.2fs", secs)
end

-- report() -> "resolve 1.25s | ... | commit 2.40s (count 0.20s, pool 2.20s)"
-- Closes anything still open, so an early-return path is reported too.
-- Returns nil when nothing was ever marked.
function profile.report()
  profile.close()
  if #order == 0 then return nil end
  local parts = {}
  for _, name in ipairs(order) do
    local part = name .. " " .. fmt(totals[name])
    local so = sub_order[name]
    if so and #so > 0 then
      local sp = {}
      for _, sn in ipairs(so) do
        sp[#sp + 1] = sn .. " " .. fmt(sub_totals[name][sn])
      end
      part = part .. " (" .. table.concat(sp, ", ") .. ")"
    end
    parts[#parts + 1] = part
  end
  return table.concat(parts, " | ")
end

-- reset() -- forget all recorded phases (tests).
function profile.reset()
  reset_state()
end

-- set_clock(fn) -- replace the time source (tests); nil restores /proc/uptime.
function profile.set_clock(fn)
  clock = fn or default_clock
end

return profile
