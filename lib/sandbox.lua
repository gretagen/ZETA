-- sandbox.lua -- restricted environment for package.lua manifests.
--
-- This is the heart of Zeta's safety story. A manifest runs with NO access to
-- io, os, require, package, load, loadstring, dofile, loadfile, debug, or any
-- other escape hatch. It can only compute (tables, strings, math) and declare
-- an `install`/`build` function. The only way a package can touch the system
-- is through the `p` object Zeta hands to that function at install time --
-- and every `p` method is audited Zeta code. A malicious package.lua simply
-- cannot read or write a file or spawn a process on its own.
--
-- Note: the sandbox applies to the code the manifest *contains*; the `p`
-- methods it calls are implemented in builder.lua with normal privileges.

local sandbox = {}

local unpack = unpack or table.unpack

local env

local function make_env()
  if env then return env end
  env = {
    _VERSION = _VERSION,
    assert = assert,
    error = error,
    ipairs = ipairs,
    next = next,
    pairs = pairs,
    pcall = pcall,
    select = select,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    rawequal = rawequal,
    rawget = rawget,
    rawset = rawset,
    setmetatable = setmetatable,
    getmetatable = getmetatable,
    unpack = unpack,
    string = string,
    table = table,
    math = math,
  }
  if rawlen then env.rawlen = rawlen end
  return env
end

-- Compile Lua source under the sandbox. Returns a chunk or nil, err.
function sandbox.compile(src, name)
  local chunk, err
  if setfenv then
    -- Lua 5.1 / LuaJIT: load, then rebind the global environment.
    chunk, err = loadstring(src, name)
    if chunk then setfenv(chunk, make_env()) end
  else
    -- Lua 5.2+: load with an explicit environment.
    chunk, err = load(src, name, "t", make_env())
  end
  return chunk, err
end

-- Load a file under the sandbox. Returns a chunk or nil, err.
function sandbox.loadfile(filepath)
  local f, err = io.open(filepath, "rb")
  if not f then return nil, err end
  local src = f:read("*a")
  f:close()
  return sandbox.compile(src, "@" .. filepath)
end

return sandbox
