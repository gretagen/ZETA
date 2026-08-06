-- sha256.lua -- pure-Lua SHA-256 (FIPS 180-4).
--
-- Zeta must not require any C library or distro package, so this provides a
-- self-contained implementation. It uses the `bit` module (LuaJIT), `bit32`
-- (Lua 5.2), or a pure-arithmetic fallback, so it runs unchanged on
-- Lua 5.1 through 5.5. checksum.lua normally prefers a native `sha256sum`
-- binary for speed and falls back to this module.

local sha256 = {}

-- ---------------------------------------------------------------------------
-- Bit-operation layer
-- ---------------------------------------------------------------------------

local bit
do
  local ok, lib = pcall(require, "bit")
  if ok and type(lib) == "table" and lib.band then
    bit = lib
  else
    local ok2, lib2 = pcall(require, "bit32")
    if ok2 and type(lib2) == "table" and lib2.band then
      bit = {
        band = lib2.band, bor = lib2.bor, bxor = lib2.bxor, bnot = lib2.bnot,
        rshift = lib2.rshift, lshift = lib2.lshift,
        ror = function(x, n) return lib2.ror(x, n) end,
      }
    else
      -- Pure-arithmetic fallback for Lua 5.3+ / 5.4 / 5.5 (no bit library).
      -- Slower, but only ever used if no native sha256 tool is available.
      local M = 4294967296.0
      local function band(a, b)
        local r, f = 0.0, 1.0
        for _ = 1, 32 do
          local ba = a - 2.0 * math.floor(a / 2.0)
          local bb = b - 2.0 * math.floor(b / 2.0)
          if ba >= 1.0 and bb >= 1.0 then r = r + f end
          a = math.floor(a / 2.0)
          b = math.floor(b / 2.0)
          f = f * 2.0
        end
        return r
      end
      local function bor(a, b)
        local r, f = 0.0, 1.0
        for _ = 1, 32 do
          local ba = a - 2.0 * math.floor(a / 2.0)
          local bb = b - 2.0 * math.floor(b / 2.0)
          if ba >= 1.0 or bb >= 1.0 then r = r + f end
          a = math.floor(a / 2.0)
          b = math.floor(b / 2.0)
          f = f * 2.0
        end
        return r
      end
      local function bxor(a, b)
        local r, f = 0.0, 1.0
        for _ = 1, 32 do
          local ba = a - 2.0 * math.floor(a / 2.0)
          local bb = b - 2.0 * math.floor(b / 2.0)
          if (ba >= 1.0) ~= (bb >= 1.0) then r = r + f end
          a = math.floor(a / 2.0)
          b = math.floor(b / 2.0)
          f = f * 2.0
        end
        return r
      end
      local function bnot(a)
        return M - 1.0 - (a % M)
      end
      local function lshift(a, n)
        return (a % M) * (2.0 ^ n) % M
      end
      local function rshift(a, n)
        return math.floor((a % M) / (2.0 ^ n))
      end
      bit = {
        band = band, bor = bor, bxor = bxor, bnot = bnot,
        lshift = lshift, rshift = rshift,
        ror = function(x, n)
          n = n % 32
          if n == 0 then return x % M end
          return bor(rshift(x, n), lshift(x, 32 - n))
        end,
      }
    end
  end
end

-- ---------------------------------------------------------------------------
-- SHA-256 constants and state
-- ---------------------------------------------------------------------------

-- First 32 bits of the fractional parts of the cube roots of the first 64
-- primes (per FIPS 180-4).
local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local H0 = {
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local unpack = unpack or table.unpack

local function be32(x)
  x = x % 4294967296.0
  return string.char(
    math.floor(x / 16777216) % 256,
    math.floor(x / 65536) % 256,
    math.floor(x / 256) % 256,
    x % 256)
end

-- Process one 512-bit block.
local function process_block(ctx, block)
  local w = {}
  for i = 0, 15 do
    local off = i * 4 + 1
    w[i + 1] = string.byte(block, off) * 16777216
      + string.byte(block, off + 1) * 65536
      + string.byte(block, off + 2) * 256
      + string.byte(block, off + 3)
  end
  for i = 16, 63 do
    local x, y = w[i - 14], w[i - 1]
    local s0 = bit.bxor(bit.bxor(bit.ror(x, 7), bit.ror(x, 18)), bit.rshift(x, 3))
    local s1 = bit.bxor(bit.bxor(bit.ror(y, 17), bit.ror(y, 19)), bit.rshift(y, 10))
    w[i + 1] = bit.band(w[i - 15] + s0 + w[i - 6] + s1, 0xFFFFFFFF)
  end
  local a, b, c, d, e, f, g, h = unpack(ctx.h, 1, 8)
  for i = 0, 63 do
    local s1 = bit.bxor(bit.bxor(bit.ror(e, 6), bit.ror(e, 11)), bit.ror(e, 25))
    local ch = bit.bxor(bit.band(e, f), bit.band(bit.bnot(e), g))
    local t1 = h + s1 + ch + K[i + 1] + w[i + 1]
    local s0 = bit.bxor(bit.bxor(bit.ror(a, 2), bit.ror(a, 13)), bit.ror(a, 22))
    local maj = bit.bxor(bit.bxor(bit.band(a, b), bit.band(a, c)), bit.band(b, c))
    local t2 = bit.band(s0 + maj, 0xFFFFFFFF)
    h, g, f, e, d, c, b, a = g, f, e, bit.band(d + t1, 0xFFFFFFFF), c, b, a, bit.band(t1 + t2, 0xFFFFFFFF)
  end
  ctx.h[1] = bit.band(ctx.h[1] + a, 0xFFFFFFFF)
  ctx.h[2] = bit.band(ctx.h[2] + b, 0xFFFFFFFF)
  ctx.h[3] = bit.band(ctx.h[3] + c, 0xFFFFFFFF)
  ctx.h[4] = bit.band(ctx.h[4] + d, 0xFFFFFFFF)
  ctx.h[5] = bit.band(ctx.h[5] + e, 0xFFFFFFFF)
  ctx.h[6] = bit.band(ctx.h[6] + f, 0xFFFFFFFF)
  ctx.h[7] = bit.band(ctx.h[7] + g, 0xFFFFFFFF)
  ctx.h[8] = bit.band(ctx.h[8] + h, 0xFFFFFFFF)
end

-- ---------------------------------------------------------------------------
-- Streaming context
-- ---------------------------------------------------------------------------

local CTX = {}
CTX.__index = CTX

function sha256.new()
  local ctx = setmetatable({ h = {}, buf = {}, len = 0 }, CTX)
  for i = 1, 8 do ctx.h[i] = H0[i] end
  return ctx
end

function CTX:update(data)
  self.len = self.len + #data
  local buf = table.concat(self.buf) .. data
  local full = math.floor(#buf / 64) * 64
  if full > 0 then
    for i = 1, full, 64 do
      process_block(self, buf:sub(i, i + 63))
    end
  end
  self.buf = { buf:sub(full + 1) }
end

function CTX:hexdigest()
  local lenbits = self.len * 8
  local hi = math.floor(lenbits / 4294967296.0)
  local lo = lenbits % 4294967296.0
  self:update("\128")
  local rem = #table.concat(self.buf) % 64
  local zeros = (56 - rem + 64) % 64
  if zeros > 0 then self:update(string.rep("\0", zeros)) end
  self:update(be32(hi) .. be32(lo))
  local hex = {}
  for i = 1, 8 do
    local x = self.h[i]
    hex[#hex + 1] = ("%02x%02x%02x%02x"):format(
      math.floor(x / 16777216) % 256,
      math.floor(x / 65536) % 256,
      math.floor(x / 256) % 256,
      x % 256)
  end
  return table.concat(hex)
end

-- ---------------------------------------------------------------------------
-- Convenience wrappers
-- ---------------------------------------------------------------------------

function sha256.sum(data)
  local ctx = sha256.new()
  ctx:update(data)
  return ctx:hexdigest()
end

-- Hash a file in 1 MiB chunks (bounded memory for large binary packages).
function sha256.file(filepath)
  local f, err = io.open(filepath, "rb")
  if not f then return nil, err end
  local ctx = sha256.new()
  while true do
    local chunk = f:read(1048576)
    if not chunk then break end
    ctx:update(chunk)
  end
  f:close()
  return ctx:hexdigest()
end

return sha256
