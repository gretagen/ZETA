-- fetch.lua -- downloads and local file resolution.
--
-- Distro-agnostic by construction: we detect curl or wget at runtime rather
-- than assuming one exists, and plain local paths (or file:// URLs) are
-- handled with a straight file copy so offline repositories and local
-- packages need no network at all.

local fetch = {}

local path = require("path")
local log = require("log")
local spinner = require("spinner")

local downloader

-- GitHub serves raw file bytes from raw.githubusercontent.com, not from
-- github.com (which returns HTML). Rewrite a github.com repo URL to its raw
-- equivalent using the "HEAD" ref, which resolves to the default branch, so
-- manifests, indexes, and payloads download as actual content.
function fetch.raw_github(url)
  url = url:gsub("^https?://www%.github%.com/", "https://github.com/")
  local owner, repo, rest = url:match("^https?://github%.com/([^/]+)/([^/]+)(.*)$")
  if owner and repo then
    return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo .. "/HEAD" .. rest
  end
  return url
end

local function have(cmd)
  local f = io.popen("command -v " .. cmd .. " 2>/dev/null")
  if not f then return false end
  local out = f:read("*l")
  f:close()
  return out ~= nil and out ~= ""
end

function fetch.downloader()
  if not downloader then
    if have("curl") then
      downloader = "curl"
    elseif have("wget") then
      downloader = "wget"
    else
      downloader = false
    end
  end
  return downloader or nil
end

-- Copy a file, creating parent directories. Used for file:// and local urls.
function fetch.copy(src, dest)
  local f, err = io.open(src, "rb")
  if not f then return nil, err end
  local parts = {}
  while true do
    local chunk = f:read(1048576)
    if not chunk then break end
    parts[#parts + 1] = chunk
  end
  f:close()
  path.mkdir_p(path.dirname(dest))
  local o, oerr = io.open(dest, "wb")
  if not o then return nil, oerr end
  o:write(table.concat(parts))
  o:close()
  return dest
end

-- Resolve `url` into a local file at `dest`. Returns dest or nil, err.
function fetch.get(url, dest)
  url = fetch.raw_github(url)
  if url:match("^https?://") then
    path.mkdir_p(path.dirname(dest))
    local dl = fetch.downloader()
    if not dl then
      return nil, "no downloader found (install curl or wget)"
    end
    -- On a terminal the spinner replaces the (noisy) curl/wget progress
    -- output; when piped we fall back to a plain announcement line.
    local spin = spinner.enabled()
    if spin then
      spinner.start(("downloading %s"):format(url))
    else
      log.step(("downloading %s"):format(url))
    end
    local tmp = dest .. ".part"
    local ok
    if dl == "curl" then
      ok = path.run("curl -L --fail --show-error -sS -o " .. path.quote(tmp) .. " " .. path.quote(url))
    else
      local flags = spin and "-q " or ""
      ok = path.run("wget " .. flags .. "-O " .. path.quote(tmp) .. " " .. path.quote(url))
    end
    spinner.stop()
    if not ok then
      os.remove(tmp)
      return nil, ("download failed: %s"):format(url)
    end
    local r, e = os.rename(tmp, dest)
    if not r then
      os.remove(tmp)
      return nil, e
    end
    return dest
  end
  -- file:// prefix, absolute path, or bare relative path
  local src = url:gsub("^file://", "")
  return fetch.copy(src, dest)
end

-- Fetch a small text resource (package.lua, index.lua) and return its
-- contents. The temporary file is removed before returning.
function fetch.read(url)
  local name = url:match("[^/]+$") or "zeta"
  local tmp = path.join("/tmp", "zeta-" .. name .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999)))
  local dest, err = fetch.get(url, tmp)
  if not dest then return nil, err end
  local f = io.open(dest, "rb")
  local content
  if f then
    content = f:read("*a")
    f:close()
  end
  os.remove(dest)
  return content, nil
end

return fetch
