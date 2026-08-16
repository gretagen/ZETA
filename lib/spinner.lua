-- spinner.lua -- a /-\| style progress spinner for blocking operations.
--
-- Long operations (network downloads) produce no output of their own, so a
-- lightweight spinner keeps the terminal alive. It runs as a tiny background
-- shell loop that redraws one line with \r; Lua never has to tick it, which
-- means blocking subprocesses still animate. The spinner only renders when
-- stdout is a terminal -- piped/redirected output stays clean, so the test
-- harness never sees it.

local spinner = {}

local path = require("path")

local FRAMES = { "/", "-", "\\", "|" }

local tty
local active = false
local pidfile
local pid

local function is_tty()
  if tty == nil then tty = path.run("test -t 1") end
  return tty
end

-- Build the shell command that animates `msg` on one line in the background.
-- Exported for tests; start() runs it with `&` and remembers the pid.
function spinner.build_script(msg)
  local script = "while :; do "
  for _, f in ipairs(FRAMES) do
    script = script .. string.format("printf '\\r  %%s %%s' %s %s 2>/dev/null; sleep 0.1;",
      path.quote(msg), path.quote(f))
  end
  script = script .. " done"
  return script
end

-- True when a spinner can actually render (stdout is a terminal).
function spinner.enabled()
  return is_tty()
end

-- Start animating `msg` on its own line. No-op when stdout is not a terminal.
function spinner.start(msg)
  if not is_tty() or active then return end
  active = true
  pidfile = path.join("/tmp", "zeta-spinner-" .. tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999)))
  os.execute(spinner.build_script(msg) .. " & echo $! > " .. path.quote(pidfile))
  local f = io.open(pidfile, "rb")
  if f then
    pid = tonumber(f:read("*a")) or nil
    f:close()
  end
end

-- Stop animating and clear the spinner line.
function spinner.stop()
  if not active then return end
  active = false
  if pid then
    path.run("kill " .. tostring(pid) .. " 2>/dev/null")
    pid = nil
  end
  if pidfile then
    os.remove(pidfile)
    pidfile = nil
  end
  io.write("\r\27[K")
  io.flush()
end

return spinner
