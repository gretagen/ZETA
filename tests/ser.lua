-- ser.lua -- minimal Lua table serializer for building fixture manifests in
-- the e2e suite. Emits `return { ... }`-shaped literal expressions.
-- (Mirrors db.lua's local serializer; kept here so test fixtures don't depend
-- on an internals export.)

local ser = {}

function ser.encode(v)
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return string.format("%q", v) end
  if t == "table" then
    local parts = {}
    for k, val in pairs(v) do
      local key
      if type(k) == "number" then
        key = "[" .. tostring(k) .. "]"
      elseif type(k) == "string" and k:match("^[%a_][%w_]*$") then
        key = k
      else
        key = "[" .. string.format("%q", tostring(k)) .. "]"
      end
      parts[#parts + 1] = key .. " = " .. ser.encode(val)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  return "nil"
end

return ser
