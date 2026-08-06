-- vercmp.lua -- rpm-style version comparison, used for dependency constraints
-- like "pcre2>=10.42". Splits versions into alternating digit and letter
-- segments; digit segments compare numerically (leading zeros ignored),
-- letter segments compare lexically.

local vercmp = {}

local function is_digit(c)
  return c:match("%d") ~= nil
end

local function is_letter(c)
  return c:match("%a") ~= nil
end

-- Read the next digit/letter segment starting at index i, skipping
-- separators. Returns segment, next_index (or nil, next_index at end).
local function next_segment(s, i)
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    if is_digit(c) or is_letter(c) then break end
    i = i + 1
  end
  if i > n then return nil, i end
  local digit = is_digit(s:sub(i, i))
  local j = i + 1
  while j <= n do
    local c = s:sub(j, j)
    if digit and not is_digit(c) then break end
    if not digit and not is_letter(c) then break end
    j = j + 1
  end
  return s:sub(i, j - 1), j
end

local function cmp_numeric(a, b)
  local x = a:gsub("^0+", "")
  if x == "" then x = "0" end
  local y = b:gsub("^0+", "")
  if y == "" then y = "0" end
  if #x > #y then return 1 elseif #x < #y then return -1 end
  if x > y then return 1 elseif x < y then return -1 end
  return 0
end

-- compare(a, b) -> -1, 0, or 1
function vercmp.compare(a, b)
  a = a:gsub("%s+", "")
  b = b:gsub("%s+", "")
  local ia, ib = 1, 1
  while true do
    local sa, na = next_segment(a, ia)
    local sb, nb = next_segment(b, ib)
    if not sa or not sb then
      if not sa and not sb then return 0 end
      if not sa then return -1 end
      return 1
    end
    ia, ib = na, nb
    local c
    if is_digit(sa:sub(1, 1)) and is_digit(sb:sub(1, 1)) then
      c = cmp_numeric(sa, sb)
    else
      if sa < sb then c = -1 elseif sa > sb then c = 1 else c = 0 end
    end
    if c ~= 0 then return c end
  end
end

local OPS = { ">=", "<=", "==", "~=", ">", "<", "=" }

-- parse_dep("pcre2>=10.42") -> { name="pcre2", op=">=", version="10.42" }
-- parse_dep("libffi")       -> { name="libffi", op=nil, version=nil }
function vercmp.parse_dep(spec)
  local name = spec:match("^%s*([%w%._%+%-]+)")
  if not name then
    return nil, ("bad dependency %q"):format(tostring(spec))
  end
  local rest = spec:match("^%s*[%w%._%+%-]+%s*(.*)$") or ""
  if rest == "" then
    return { name = name, op = nil, version = nil }
  end
  local op = rest:match("^([<>=~]+)%s*")
  local version = rest:match("^[<>=~]+%s*([%w%._%+%-]+)%s*$")
  if not op or not version then
    return nil, ("bad dependency constraint %q (expected NAME OP VERSION)"):format(spec)
  end
  if op == "=" then op = "==" end
  return { name = name, op = op, version = version }
end

-- satisfies(installed_version, parsed_dep) -> boolean
function vercmp.satisfies(installed, dep)
  if not dep.op then return true end
  local c = vercmp.compare(installed, dep.version)
  if dep.op == "==" then return c == 0 end
  if dep.op == "~=" then return c ~= 0 end
  if dep.op == ">=" then return c >= 0 end
  if dep.op == "<=" then return c <= 0 end
  if dep.op == ">" then return c > 0 end
  if dep.op == "<" then return c < 0 end
  return false
end

return vercmp
