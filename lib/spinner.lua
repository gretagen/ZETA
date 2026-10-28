-- spinner.lua -- live terminal rows for blocking operations.
--
-- Long operations (network downloads) produce no output of their own, so a
-- lightweight spinner keeps the terminal alive. It runs as a tiny background
-- shell loop that redraws one line with \r; Lua never has to tick it, which
-- means blocking subprocesses still animate. The spinner only renders when
-- stdout is a terminal -- piped/redirected output stays clean, so the test
-- harness never sees it.
--
-- A row owns the terminal until something else needs it: a \r redraw is not
-- newline-terminated, so printing straight over it glues the two together
-- ("Resolving dependencies / .   dependency ..."). suspend() erases the row
-- right before output and resume() lets it come back on its next tick. zeta.lua
-- wires both into print/io.write so no call site can forget to do it.
--
-- Frame sequences adapted from bash_loading_animations (MIT),
-- Copyright (c) 2022 Silejonu. See THIRD_PARTY_NOTICES.

local spinner = {}

local path = require("path")

-- Captured before zeta.lua wraps io.write: the row writer has to bypass that
-- wrapper or suspend/resume would re-enter themselves through it.
local raw_write = io.write

local CLASSIC = { "/", "-", "\\", "|" }

-- The braille "loading blocks" cycle, used by progress counters. Adapted from
-- bash_loading_animations' BLA_braille_whitespace (MIT, Silejonu).
spinner.BRAILLE = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }

local tty
local active = false
local pidfile
local pid
local cleared = false

local function is_tty()
  if tty == nil then tty = path.run("test -t 1") end
  return tty
end

-- Build the shell command that redraws one row in the background:
--   printf '\r<pre><frame><post>'; sleep <interval>
-- The format is a fixed literal, so pre/post/frame can never be read as
-- conversion specifications -- every % that reaches printf stays a literal.
-- Exported for tests; start() runs it with `&` and remembers the pid.
function spinner.build_row(pre, post, frames, interval)
  local script = "trap 'kill 0; exit 130' INT; while :; do "
  for _, f in ipairs(frames) do
    script = script .. string.format("printf '\\r%%s%%s%%s' %s %s %s 2>/dev/null; sleep %s;",
      path.quote(pre), path.quote(f), path.quote(post), tostring(interval))
  end
  script = script .. " done"
  return script
end

-- The classic / - \ | spinner row, byte-identical to the original format.
function spinner.build_script(msg)
  return spinner.build_row("  " .. msg .. " ", "", CLASSIC, 0.1)
end

-- Erase the row so the caller's output lands on a clean line. The clear is
-- deliberately not flushed: stdout is line-buffered on a terminal, so it
-- merges with whatever the caller writes next into a single write(), and the
-- background loop cannot slip a frame in between. No-op with no live row.
function spinner.suspend()
  if not active or cleared then return end
  cleared = true
  raw_write("\r\27[K")
end

-- Re-arm for the next output. The background loop redraws itself on its own
-- tick, so nothing has to be restarted here.
function spinner.resume()
  cleared = false
end

-- True when a spinner can actually render (stdout is a terminal).
function spinner.enabled()
  return is_tty()
end

-- Start animating `msg` on its own line. No-op when stdout is not a terminal.
function spinner.start(msg)
  if not is_tty() or active then return end
  active = true
  cleared = false
  pidfile = path.join("/tmp", "zeta-spinner-" .. tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999)))
  path.run(spinner.build_script(msg) .. " & echo $! > " .. path.quote(pidfile))
  local f = io.open(pidfile, "rb")
  if f then
    pid = tonumber(f:read("*a")) or nil
    f:close()
  end
  path.on_cleanup(spinner._cleanup_hook)
end

-- Stop animating and clear the spinner line.
function spinner.stop()
  if not active then return end
  active = false
  cleared = false
  path.remove_cleanup(spinner._cleanup_hook)
  if pid then
    path.run("kill " .. tostring(pid) .. " 2>/dev/null")
    pid = nil
  end
  if pidfile then
    os.remove(pidfile)
    pidfile = nil
  end
  raw_write("\r\27[K")
  io.flush()
end

-- Internal cleanup hook: kills the spinner process tree on signal.
function spinner._cleanup_hook()
  if pid then
    path.run("kill " .. tostring(pid) .. " 2>/dev/null")
    pid = nil
  end
  if pidfile then
    os.remove(pidfile)
    pidfile = nil
  end
end

return spinner
