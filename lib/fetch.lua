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
-- equivalent. We pin the ref to refs/heads/main instead of the symbolic
-- "HEAD": the raw CDN caches the HEAD ref and can serve stale content long
-- after a push (observed: manifest fetched via /HEAD still had a previous
-- url). refs/heads/main is what the package manifests already use.
function fetch.raw_github(url)
  url = url:gsub("^https?://www%.github%.com/", "https://github.com/")
  local owner, repo, rest = url:match("^https?://github%.com/([^/]+)/([^/]+)(.*)$")
  if owner and repo then
    return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo .. "/refs/heads/main" .. rest
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

-- Progress bar rendering. Draws `[=====----- /]` in place with a rotating
-- spinner character at the end. pct is 0-100, label is printed above the bar.
local BAR_WIDTH = 35
local SPIN_FRAMES = { "/", "-", "\\", "|" }
local spin_idx = 0

local function render_bar(pct, label)
  if label then
    io.write("  " .. label .. "\n")
  end
  local filled = math.floor(BAR_WIDTH * math.min(pct, 100) / 100)
  local empty = BAR_WIDTH - filled
  spin_idx = (spin_idx % #SPIN_FRAMES) + 1
  local spinner_char = SPIN_FRAMES[spin_idx]
  io.write("\r\27[K  [" .. string.rep("=", filled) .. spinner_char .. string.rep(" ", empty) .. "]")
  io.flush()
end

-- Finalize the progress bar line (move to next line, keeping the bar).
local function clear_bar()
  io.write("\n")
  io.flush()
end

-- Download with a progress bar. Runs curl/wget in the background, monitors
-- stderr for progress updates, and renders a bar. Falls back to an
-- indeterminate animated bar for wget (no clean percentage parsing).
function fetch.get_with_progress(url, dest, label)
  local dl = fetch.downloader()
  if not dl then
    return nil, "no downloader found (install curl or wget)"
  end

  local progress_file = dest .. ".progress"
  local script_file = dest .. ".sh"
  local tmp = dest .. ".part"
  path.mkdir_p(path.dirname(dest))

  local script
  if dl == "curl" then
    script = [[#!/bin/sh
URL="$1"
LABEL="$2"
PROG="$3"
TMP="$4"

to_bytes() {
  echo "$1" | awk '
    { v=$1 }
    v ~ /G$/ { gsub(/G/,"",v); printf "%d\n", v*1073741824; next }
    v ~ /M$/ { gsub(/M/,"",v); printf "%d\n", v*1048576; next }
    v ~ /k$/ { gsub(/k/,"",v); printf "%d\n", v*1024; next }
    { gsub(/[^0-9]/,"",v); printf "%d\n", v }
  '
}

BAR_WIDTH=35
FRAMES="/ - \ |"
FI=0

curl -L --fail --show-error -o "$TMP" "$URL" 2>"$PROG" &
CURL_PID=$!

while kill -0 $CURL_PID 2>/dev/null; do
  LINE=$(tr "\r" "\n" < "$PROG" 2>/dev/null | grep -v "^$" | grep -v "^  % Total" | grep -v "^                                 Dload" | tail -1)
  PCT=$(echo "$LINE" | awk '{print $1}')
  TOTAL_RAW=$(echo "$LINE" | awk '{print $2}')
  DL_RAW=$(echo "$LINE" | awk '{print $4}')
  SPD_RAW=$(echo "$LINE" | awk '{print $NF}')
  [ -z "$PCT" ] && PCT=0
  [ -z "$DL_RAW" ] && DL_RAW=0
  [ -z "$TOTAL_RAW" ] && TOTAL_RAW=0
  DL_BYTES=$(to_bytes "$DL_RAW")
  TOTAL_BYTES=$(to_bytes "$TOTAL_RAW")
  SPD_BYTES=$(to_bytes "$SPD_RAW")
  if [ "$TOTAL_BYTES" -gt 0 ] 2>/dev/null; then
    FILLED=$(echo "$DL_BYTES $TOTAL_BYTES $BAR_WIDTH" | awk '{printf "%d", $1 / $2 * $3}')
    PCT=$(echo "$DL_BYTES $TOTAL_BYTES" | awk '{printf "%.1f", $1 * 100 / $2}')
  else
    FILLED=0
    PCT=0
  fi
  EMPTY=$((BAR_WIDTH - FILLED))
  REP=$(printf "%0.s=" $(seq 1 $FILLED 2>/dev/null))
  EMP=$(printf "%0.s " $(seq 1 $EMPTY 2>/dev/null))
  FI=$((FI % 4 + 1))
  SC=$(echo $FRAMES | cut -d" " -f$FI)
  printf "\r\033[K  [%s%s%s] %s/%s  %s%%" "$REP" "$SC" "$EMP" "$DL_RAW" "$TOTAL_RAW" "$PCT"
  # Speed-proportional spinner: faster download = faster rotation.
  if [ "$SPD_BYTES" -gt 1048576 ] 2>/dev/null; then
    sleep 0.03
  elif [ "$SPD_BYTES" -gt 102400 ] 2>/dev/null; then
    sleep 0.06
  else
    sleep 0.1
  fi
done

printf "\n"
wait $CURL_PID
echo $? > "]]  .. dest .. ".rc" .. [["
]]
  else
    -- wget: suppress output, show indeterminate animated bar.
    script = [[#!/bin/sh
URL="$1"
LABEL="$2"
PROG="$3"
TMP="$4"

BAR_WIDTH=35
FRAMES="/ - \ |"
FI=0
FILL=0

wget -q -O "$TMP" "$URL" &
WGET_PID=$!

while kill -0 $WGET_PID 2>/dev/null; do
  FILL=$((FILL + 2))
  if [ $FILL -gt $BAR_WIDTH ]; then FILL=0; fi
  EMPTY=$((BAR_WIDTH - FILL))
  REP=$(printf "%0.s=" $(seq 1 $FILL 2>/dev/null))
  EMP=$(printf "%0.s " $(seq 1 $EMPTY 2>/dev/null))
  FI=$((FI % 4 + 1))
  SC=$(echo $FRAMES | cut -d" " -f$FI)
  printf "\r\033[K  [%s%s%s]" "$REP" "$SC" "$EMP"
  sleep 0.1
done

printf "\n"
wait $WGET_PID
echo $? > "]]  .. dest .. ".rc" .. [["
]]
  end

  local sf = io.open(script_file, "w")
  if not sf then return nil, "cannot create progress script" end
  sf:write(script)
  sf:close()
  os.execute("chmod +x " .. path.quote(script_file))

  -- Run the script: $1=URL $2=LABEL $3=progress_file $4=tmp $5=downloader
  local cmd = path.quote(script_file) .. " "
    .. path.quote(url) .. " "
    .. path.quote(label or "") .. " "
    .. path.quote(progress_file) .. " "
    .. path.quote(tmp) .. " "
    .. path.quote(dl)

  -- Show label above bar if on a terminal.
  if spinner.enabled() and label then
    render_bar(0, label)
  end

  local a, b, c = os.execute(cmd)

  -- Read exit code saved by the script.
  local rc = 1
  local rf = io.open(dest .. ".rc", "r")
  if rf then
    rc = tonumber(rf:read("*a")) or 1
    rf:close()
  end

  -- Clear bar and clean up temp files.
  clear_bar()
  os.remove(progress_file)
  os.remove(script_file)
  os.remove(dest .. ".rc")

  if rc ~= 0 then
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

-- Resolve `url` into a local file at `dest`. Returns dest or nil, err.
-- When `label` is given and stdout is a terminal, shows a progress bar
-- instead of the plain spinner.
function fetch.get(url, dest, label)
  url = fetch.raw_github(url)
  if url:match("^https?://") then
    path.mkdir_p(path.dirname(dest))
    local dl = fetch.downloader()
    if not dl then
      return nil, "no downloader found (install curl or wget)"
    end
    -- When a label is given and stdout is a terminal, show a progress bar
    -- instead of the plain spinner.
    if label and spinner.enabled() then
      return fetch.get_with_progress(url, dest, label)
    end
    -- Fallback: spinner (or plain log line when piped).
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
function fetch.read(url, label)
  local name = url:match("[^/]+$") or "zeta"
  local tmp = path.join("/tmp", "zeta-" .. name .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999)))
  local dest, err = fetch.get(url, tmp, label)
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
