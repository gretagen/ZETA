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

-- The progress-counter cycle, adapted from bash_loading_animations' BLA_box
-- (MIT, Silejonu) and shown bracketed. It is still called BRAILLE because it
-- started out as BLA_braille_whitespace; the frames changed, the name didn't.
spinner.BRAILLE = { "[┤]", "[┴]", "[├]", "[┬]", }

-- A bracketed meter derived from bash_loading_animations' BLA_metro (MIT,
-- Silejonu): fills left-to-right, then starts over, on METRO_INTERVAL's tick.
-- Every frame must be exactly the same width -- a \r redraw does not erase, so
-- a shorter frame leaves the tail of the previous one on screen. Used by the
-- dependency-extraction row, which already carries a counter and only needs to
-- show that work is still happening. Upstream pads with U+00A0; plain spaces
-- render identically and keep invisible characters out of source.
spinner.METRO = { "[   ]", "[=  ]", "[== ]", "[===]", }
local METRO_INTERVAL = 0.1

-- One braille frame per redraw. Progress counters redraw on their own tick
-- (0.1s in the commit pool, once per entry otherwise), so advancing here is
-- what animates the glyph -- no background process of its own. The cycle is
-- shared: -Provide and -Delete never run at once, and a multi-package -Delete
-- keeps animating across package boundaries instead of restarting.
local braille_i = 0
function spinner.next_frame()
  braille_i = braille_i % #spinner.BRAILLE + 1
  return spinner.BRAILLE[braille_i]
end

local tty
local active = false
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
-- Exported for tests; build_script()/start_row() run it with `&` and remember
-- the pid.
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

-- Spawn a background loop that redraws `script` forever. No-op when stdout is
-- not a terminal or another row is already live.
local function launch_script(script)
  if not is_tty() or active then return end
  active = true
  cleared = false
  -- spawn_bg hands the loop its own process group, so the cleanup hook takes
  -- the whole row loop with it instead of orphaning it; it also owns the
  -- pidfile, which it consumes while reading. The row is a shell fragment, so
  -- it goes in via `shell -c` rather than being exec'd directly.
  pid = path.spawn_bg(path.shell .. " -c " .. path.quote(script),
    path.join("/tmp", "zeta-spinner-" .. tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))))
  path.on_cleanup(spinner._cleanup_hook)
end

-- Start animating `msg` on its own indented line, `  <msg> <frame>`. No-op
-- when stdout is not a terminal.
function spinner.start(msg)
  launch_script(spinner.build_script(msg))
end

-- Start a row whose prefix and suffix are used verbatim, for progress lines
-- that carry their own lead-in instead of the indented spinner layout. The
-- meter sits wherever the two put it, and runs at BLA_metro's authored 0.2s.
function spinner.start_row(pre, post)
  launch_script(spinner.build_row(pre, post, spinner.METRO, METRO_INTERVAL))
end

-- Stop animating and clear the spinner line. With `keep_row`, the loop is
-- killed but whatever it last drew stays put and is newline-terminated --
-- used by rows that must survive as a record of what just finished.
function spinner.stop(keep_row)
  if not active then return end
  active = false
  cleared = false
  path.remove_cleanup(spinner._cleanup_hook)
  path.kill_tree(pid)
  pid = nil
  if keep_row then
    raw_write("\n")
  else
    raw_write("\r\27[K")
  end
  io.flush()
end

-- Internal cleanup hook: kills the spinner process tree on signal.
function spinner._cleanup_hook()
  path.kill_tree(pid)
  pid = nil
end

return spinner
