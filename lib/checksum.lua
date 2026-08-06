-- checksum.lua -- sha256 verification.
--
-- Speed matters: a 100 MiB binary package hashes in a fraction of a second
-- with a native tool but takes several seconds in pure Lua. We therefore
-- prefer a system `sha256sum`/`shasum`/`openssl` binary when present (all
-- produce the identical hex digest) and fall back to the bundled pure-Lua
-- implementation otherwise. Whichever path is taken, the result is the same,
-- so this is purely an optimization -- not a dependency. Pass opts.pure to
-- force the pure-Lua path (used by tests).

local checksum = {}

local path = require("path")
local log = require("log")

local tool

local function probe()
  local candidates = {
    { name = "sha256sum", cmd = "sha256sum",
      parse = function(line) return line:match("^(%x+)") end },
    { name = "shasum -a 256", cmd = "shasum -a 256",
      parse = function(line) return line:match("^(%x+)") end },
    { name = "openssl dgst -sha256", cmd = "openssl dgst -sha256",
      parse = function(line) return line:match("=(%x+)") end },
  }
  for _, c in ipairs(candidates) do
    local f = io.popen("command -v " .. c.cmd:match("^%S+") .. " 2>/dev/null")
    if f then
      local out = f:read("*l")
      f:close()
      if out and out ~= "" then return c end
    end
  end
  return nil
end

local function hash_with_tool(c, file)
  local f = io.popen(c.cmd .. " " .. path.quote(file) .. " 2>/dev/null")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  if not line then return nil end
  return c.parse(line)
end

-- verify(file, expected_hex) -> true, computed_hex | nil, errmsg
function checksum.verify(file, expected, opts)
  opts = opts or {}
  expected = expected:lower()
  if not tool then tool = probe() end
  local got
  local via
  if tool and not opts.pure then
    got = hash_with_tool(tool, file)
    via = tool.name
  end
  if not got then
    got = require("sha256").file(file)
    via = "pure-Lua sha256"
  end
  if not got then
    return nil, ("could not compute sha256 for %s"):format(file)
  end
  log.detail(("checksum: %s = %s (%s)"):format(path.basename(file), got, via))
  if got ~= expected then
    return nil, ("sha256 mismatch for %s:\n  expected %s\n  got      %s"):format(
      path.basename(file), expected, got)
  end
  return true, got
end

return checksum
