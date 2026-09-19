-- log.lua -- always-verbose logging.
--
-- Design decision: Zeta prints every operation (dependency resolution,
-- downloads, checksum verification, build steps, install steps, removal) so
-- the user always knows what it is doing. Output is plain print() calls which
-- stream through a child process's stdout/stderr unchanged -- there are no
-- pipes or buffering layers, which keeps things fast.

local log = {}

local quiet = false

-- Per-file output suppression (--silence): kills the "provided file ..."
-- chatter and the tar -v extraction listing, without touching errors or the
-- normal step/ok/info summary lines. Zeta stays verbose by design; --silence
-- only trims per-file noise, primarily to speed up slow terminals.
local file_silent = false

-- Test harness hook: suppress all log output.
function log.set_quiet(q)
  quiet = q and true or false
end

-- Enable/disable per-file output suppression. Returns the previous value.
function log.set_file_silent(s)
  local prev = file_silent
  file_silent = s and true or false
  return prev
end

function log.is_file_silent()
  return file_silent
end

local function wants_color()
  local t = os.getenv("TERM")
  if not t or t == "" or t == "dumb" then return false end
  if os.getenv("NO_COLOR") then return false end
  return true
end

local COLOR = wants_color()

local C = {
  reset = "\27[0m",
  cyan = "\27[36m",
  green = "\27[32m",
  yellow = "\27[33m",
  red = "\27[31m",
  dim = "\27[2m",
}

local function paint(color, s)
  if not COLOR then return s end
  return C[color] .. s .. C.reset
end

function log.step(msg)
  if quiet then return end
  print(paint("cyan", "==> " .. msg))
end

function log.ok(msg)
  if quiet then return end
  print(paint("green", " ok  " .. msg))
end

function log.warn(msg)
  if quiet then return end
  io.stderr:write(paint("yellow", "warn ") .. msg .. "\n")
end

function log.error(msg)
  if quiet then return end
  io.stderr:write(paint("red", "error") .. " " .. msg .. "\n")
end

function log.info(msg)
  if quiet then return end
  print(" -   " .. msg)
end

function log.detail(msg)
  if quiet then return end
  print(paint("dim", " .   " .. msg))
end

-- Print multiple detail messages in a single print() call for instant output.
function log.detail_batch(msgs)
  if quiet or #msgs == 0 then return end
  local buf = {}
  for _, msg in ipairs(msgs) do
    buf[#buf + 1] = " .   " .. msg
  end
  print(paint("dim", table.concat(buf, "\n")))
end

-- Always print, even under --silence. Used for the startup banner so the user
-- always sees where Zeta will operate regardless of output suppression.
function log.banner(msg)
  print(" -   " .. msg)
end

return log
