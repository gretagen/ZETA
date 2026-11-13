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
local config = require("config")

local downloader

-- Network flags appended to every curl/wget invocation.
--
-- ZETA used to pass none, so a stalled transfer waited out wget's default
-- 900-second read timeout and its default 20 retries -- the reports of
-- waiting 20 minutes for a single tarball. There is deliberately no
-- --max-time: a global cap would punish exactly the slow links these users
-- have, so every guard below is per-condition instead.
--
-- --speed-limit/--speed-time abort a transfer that stops delivering for 30s.
-- The threshold is 10 KB/s rather than the 1 byte/s this guard originally
-- shipped with, so a link crawling at a trickle gives up and retries instead
-- of hanging -- a deliberate choice, taken knowing that a link sustained
-- below 10 KB/s will be aborted and retried into failure.
--
-- `--retry` deliberately omits `--retry-all-errors` so a plain 404 still
-- fails immediately instead of being retried three times on the way to
-- "package not found".
local CURL_FLAGS = "--connect-timeout 10 --retry 3 --retry-delay 1 "
  .. "--retry-max-time 60 --speed-limit 10240 --speed-time 30"
local WGET_FLAGS = "--timeout=15 --tries=3 --waitretry=1 "
  .. "--speed-limit=10240 --speed-time=30"

-- Resume only when a partial file is already on disk: a fresh download must
-- not send a Range header, because a server without byte-range support would
-- fail the request outright. `style` is the flag for the downloader in use.
-- io.open + seek, so no fork.
local function resume_flag(pathname, style)
  local f = io.open(pathname, "rb")
  if not f then return "" end
  local sz = f:seek("end")
  f:close()
  if not sz or sz == 0 then return "" end
  return style
end

-- Only payloads in the cache are worth resuming: they are the 800 MB ones and
-- they are sha256-verified right after the download. Manifests and indexes
-- live in tmp_dir, change between runs, and carry no checksum -- stitching two
-- versions together from a stale partial is worse than re-fetching 1 KB.
local function resumable(dest)
  local cache = config.get().cache_dir
  return cache ~= nil and cache ~= "" and dest:sub(1, #cache) == cache
end

local quotes = require("quotes")

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
    -- Paths under known GitHub router segments are NOT raw tree paths and
    -- must be left untouched: release assets (releases/download/...) 302 to
    -- the CDN blob store (curl -L follows), and blob/tree/raw/archive/wiki
    -- each have their own resolver. Rewriting them into
    -- raw.githubusercontent.com/OWNER/REPO/refs/heads/main/... yields a
    -- 404 (observed with the libreoffice release asset).
    local kind = rest:match("^/([^/]+)/") or rest:match("^/([^/]+)$") or ""
    if kind == "releases" or kind == "archive" or kind == "blob"
       or kind == "raw" or kind == "tree" or kind == "wiki" then
      return url
    end
    return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo .. "/refs/heads/main" .. rest
  end
  return url
end

local function have(cmd)
  local f = path.popen("command -v " .. cmd .. " 2>/dev/null")
  if not f then return false end
  local out = f:read("*l")
  f:close()
  return out ~= nil and out ~= ""
end

-- The downloader's *name* only. Consumers branch on `dl == "curl"`, so this
-- must stay a bare name: commit 2f5ddf2 changed it to "curl --silent" to quiet
-- the output and silently made every curl branch dead code -- ZETA fell
-- through to wget (and failed outright on a curl-only host). The commands
-- below carry their own -sS/-q already.
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

-- One batch progress line: `[=====----- /] name  done/total`. Shared by the
-- parallel batch and the streaming prefetch so both read identically.
local function draw_batch(done, total, last_name)
  local pct = math.floor(100 * done / math.max(total, 1))
  local filled = math.floor(BAR_WIDTH * math.min(pct, 100) / 100)
  local empty = BAR_WIDTH - filled
  spin_idx = (spin_idx % #SPIN_FRAMES) + 1
  io.write(("\r\27[K  [" .. string.rep("=", filled) .. "%s" .. string.rep(" ", empty)
    .. "] %s  %d/%d"):format(SPIN_FRAMES[spin_idx], last_name, done, total))
  io.flush()
end

-- Slow-download taunts. make_slow_ticker(after, every, active, list) returns
-- a tick() closure that yields a quote string when one is due (first after
-- `after` seconds, then every `every` seconds) and nil otherwise. Never
-- repeats the previous quote back-to-back. Returns an always-nil tick when
-- inactive so call sites stay branch-free.
local SLOW_AFTER = 10
local SLOW_EVERY = 15

local function make_slow_ticker(after, every, active, list)
  if not active or type(list) ~= "table" or #list == 0 then
    return function() return nil end
  end
  local next_at = os.time() + after
  local last
  return function()
    local now = os.time()
    if now < next_at then return nil end
    next_at = now + every
    local idx = math.random(#list)
    -- Never serve the same quote twice in a row (walks at most one full
    -- revolution; a list of identical entries is a no-op).
    for _ = 1, #list do
      if list[idx] ~= last then break end
      idx = (idx % #list) + 1
    end
    last = list[idx]
    return last
  end
end
-- Exposed for the test suite; not part of the public API.
fetch._slow_ticker = make_slow_ticker

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

  -- Same resume rule as fetch.get: only a payload sitting in the cache is
  -- continued, and only when bytes of it are already on disk.
  local resume = resumable(dest) and resume_flag(tmp, "-C - ") or ""

  local script
  if dl == "curl" then
    script = "#!" .. path.shell .. "\n"
      .. "FLAGS=" .. path.quote(CURL_FLAGS) .. "\n"
      .. "RESUME=" .. path.quote(resume) .. "\n"
      .. [[trap 'kill 0; exit 130' INT
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

curl -L --fail --show-error $FLAGS $RESUME -o "$TMP" "$URL" 2>"$PROG" &
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
    -- wget: suppress output, show indeterminate animated bar. No resume here:
    -- wget's continue flag is not reliable together with -O.
    script = "#!" .. path.shell .. "\n"
      .. "FLAGS=" .. path.quote(WGET_FLAGS) .. "\n"
      .. [[trap 'kill 0; exit 130' INT
URL="$1"
LABEL="$2"
PROG="$3"
TMP="$4"

BAR_WIDTH=35
FRAMES="/ - \ |"
FI=0
FILL=0

wget -q $FLAGS -O "$TMP" "$URL" &
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

  -- Run it through the shell rather than chmod +x + execute: one fork fewer
  -- per download, and no dependency on the script's exec bit.
  -- $1=URL $2=LABEL $3=progress_file $4=tmp $5=downloader
  local cmd = path.shell .. " " .. path.quote(script_file) .. " "
    .. path.quote(url) .. " "
    .. path.quote(label or "") .. " "
    .. path.quote(progress_file) .. " "
    .. path.quote(tmp) .. " "
    .. path.quote(dl)

  -- Show label above bar if on a terminal.
  local use_tty = spinner.enabled()
  if use_tty and label then
    render_bar(0, label)
  end

  -- Detached background job: Lua ticks slow-download quotes while the
  -- script's own shell loop draws the bar, and cleanup can kill the whole
  -- tree on Ctrl+C (see path.spawn_bg).
  local pid = path.spawn_bg(cmd, dest .. ".pid")

  local function progress_cleanup()
    path.kill_tree(pid)
    pid = nil
    os.remove(script_file)
    os.remove(progress_file)
    os.remove(dest .. ".rc")
  end
  path.on_cleanup(progress_cleanup)

  local slow_tick = make_slow_ticker(SLOW_AFTER, SLOW_EVERY,
    use_tty and quotes.is_enabled(), quotes.slowdownload)
  -- path.alive/path.sleep instead of path.run(os.execute): system(3) blocks
  -- SIGINT, which is exactly where Ctrl+C used to be swallowed.
  while pid and path.alive(pid) do
    local q = slow_tick()
    if q then
      io.write("\n")
      log.detail(q)
    end
    path.sleep(0.1)
  end
  path.remove_cleanup(progress_cleanup)

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
    -- run_interruptible, not path.run: system(3) blocks SIGINT for the whole
    -- call, which is why Ctrl+C did nothing during a download.
    local keep = resumable(dest)
    local ok
    if dl == "curl" then
      ok = path.run_interruptible("curl -L --fail --show-error -sS " .. CURL_FLAGS .. " "
        .. (keep and resume_flag(tmp, "-C - ") or "")
        .. "-o " .. path.quote(tmp) .. " " .. path.quote(url))
    else
      -- wget's -c is unreliable together with -O, so curl carries the resume
      -- and wget only gets the bounds.
      local flags = spin and "-q " or ""
      ok = path.run_interruptible("wget " .. flags .. WGET_FLAGS .. " "
        .. "-O " .. path.quote(tmp) .. " " .. path.quote(url))
    end
    spinner.stop()
    if not ok then
      -- A resumable partial is deliberately left behind: that is what the next
      -- attempt continues from. Anything else is discarded as before.
      if not keep then os.remove(tmp) end
      return nil, ("download failed: %s"):format(url)
    end
    local r, e = os.rename(tmp, dest)
    if not r then
      if not keep then os.remove(tmp) end
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
  -- config.tmp_dir, not a hardcoded /tmp: ZETA_TMP deserves to be honoured and
  -- the directory is already resolved to one this user can actually write.
  local tmp = path.join(config.get().tmp_dir,
    "read-" .. name .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999)))
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

-- Download multiple files in parallel. `items` is a list of
--   { url = string, dest = string, label = string (optional) }
-- Optional `opts`: { label = string } overrides the default progress label.
-- Returns a list of results in the same order:
--   { dest = string } on success, or { err = string } on failure.
-- Local/file:// URLs are copied directly (not parallelized).
-- Shows a progress counter: "<label>... [done/total] /"
function fetch.get_parallel(items, opts)
  opts = opts or {}
  local progress_label = opts.label or ("downloading %d packages")
  local dl = fetch.downloader()
  if not dl then
    local results = {}
    for i = 1, #items do
      results[i] = { err = "no downloader found (install curl or wget)" }
    end
    return results
  end

  local remote = {}
  local results = {}
  local tmp_suffix = "-parallel-" .. tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))

  for i, item in ipairs(items) do
    local url = fetch.raw_github(item.url)
    local dest = item.dest
    path.mkdir_p(path.dirname(dest))

    if not url:match("^https?://") then
      local src = url:gsub("^file://", "")
      local ok, err = fetch.copy(src, dest)
      results[i] = ok and { dest = dest } or { err = err }
    else
      -- A cached payload gets a stable .part name so an interrupted 800 MB
      -- transfer can be resumed; anything else keeps a per-run name, so a
      -- stale partial can never be stitched into a manifest that changed.
      local tmp = resumable(dest) and (dest .. ".part") or (dest .. tmp_suffix)
      remote[#remote + 1] = { url = url, dest = dest, tmp = tmp, idx = i, label = item.label }
      results[i] = { pending = true }
    end
  end

  if #remote == 0 then
    return results
  end

  local progress_file = "/tmp/zeta-progress-" .. tmp_suffix
  local done_file = "/tmp/zeta-done-" .. tmp_suffix
  local rc_file = "/tmp/zeta-rc-" .. tmp_suffix

  -- Bounded fan-out. A huge transaction used to fork every curl/wget of the
  -- batch at once -- on -Transcend that is one process, socket and stalled
  -- connection per installed package, and the peak is exactly where a big
  -- run used to fall over. ZETA_FETCH_JOBS overrides the default.
  local max_jobs = tonumber(os.getenv("ZETA_FETCH_JOBS") or "") or 8

  local script_lines = {
    "#!" .. path.shell,
    "trap 'kill 0; exit 130' INT",
    "fail=0",
    "progress=" .. path.quote(progress_file),
    "done=" .. path.quote(done_file),
    "> \"$progress\"",
    "> \"$done\"",
    "launched=0",
  }

  -- Verbose: show all download URLs before starting.
  if config.get().verbose then
    for _, r in ipairs(remote) do
      log.detail(("  fetch %s -> %s"):format(r.url, r.tmp))
    end
  end

  for _, r in ipairs(remote) do
    local dl_cmd
    if dl == "curl" then
      dl_cmd = "curl -L --fail --show-error -sS " .. CURL_FLAGS .. " "
        .. resume_flag(r.tmp, "-C - ")
        .. "-o " .. path.quote(r.tmp) .. " " .. path.quote(r.url)
    else
      -- No -c here: wget's continue flag is not reliable with -O, so only
      -- curl resumes. wget still gets the timeout/retry/stall bounds.
      dl_cmd = "wget -q " .. WGET_FLAGS .. " -O " .. path.quote(r.tmp) .. " " .. path.quote(r.url)
    end
    -- Slot gate: wait while `max_jobs` transfers are still in flight. The
    -- done file gets a line per transfer whether it succeeded or not, so a
    -- failed download can never stall the count (progress, which records
    -- successes only, would have).
    script_lines[#script_lines + 1] = "while [ $(( launched - $(wc -l < \"$done\") )) -ge "
      .. max_jobs .. " ]; do sleep 0.1; done"
    -- The done-append sits inside the same subshell as the transfer so it
    -- always runs; progress stays success-only (results are decided from
    -- it below).
    script_lines[#script_lines + 1] = "( " .. dl_cmd .. " && echo " .. r.idx
      .. " >> \"$progress\"; echo . >> \"$done\" ) &"
    script_lines[#script_lines + 1] = "PID_" .. r.idx .. "=$!"
    script_lines[#script_lines + 1] = "launched=$((launched + 1))"
  end
  for _, r in ipairs(remote) do
    script_lines[#script_lines + 1] = "wait $PID_" .. r.idx .. " || fail=1"
  end
  script_lines[#script_lines + 1] = "echo $fail > " .. path.quote(rc_file)
  script_lines[#script_lines + 1] = "exit $fail"

  local script_path = path.join("/tmp", "zeta-parallel" .. tmp_suffix .. ".sh")
  local sf = io.open(script_path, "w")
  if not sf then
    for _, r in ipairs(remote) do
      results[r.idx] = { err = "cannot create parallel download script" }
    end
    return results
  end
  sf:write(table.concat(script_lines, "\n") .. "\n")
  sf:close()
  -- Run it through the shell rather than chmod +x + execute: one fork fewer
  -- per batch, and no dependency on the script's exec bit.
  local run_cmd = path.shell .. " " .. path.quote(script_path)

  -- Registered on both paths: an interrupted run must not strand the
  -- script/progress/rc files in /tmp. Killing the job tree is the tty path's
  -- job -- the synchronous path gets that from run_interruptible's own hook.
  local scratch_cleanup = function()
    os.remove(script_path)
    os.remove(progress_file)
    os.remove(done_file)
    os.remove(rc_file)
  end
  path.on_cleanup(scratch_cleanup)

  -- Progress display
  local completed = 0
  local total = #remote
  local use_spinner = spinner.enabled()
  local seen = {}
  local last_name = ""
  local pid, parallel_cleanup

  if use_spinner then
    pid = path.spawn_bg(run_cmd, "/tmp/zeta-pid" .. tmp_suffix)

    -- Ctrl+C has to take the download *and* everything it spawned with it.
    parallel_cleanup = function()
      path.kill_tree(pid)
      pid = nil
    end
    path.on_cleanup(parallel_cleanup)

    -- Print the header line once.
    io.write("  " .. progress_label:format(total) .. "...\n")
    io.flush()
  else
    -- Nothing to draw, so no background job and no polling loop: one blocking
    -- wait instead of a `kill -0` + `sleep` pair forked twice per tick, and no
    -- up-to-100ms tail latency on every batch.
    path.run_interruptible(run_cmd)
  end

  local slow_tick = make_slow_ticker(SLOW_AFTER, SLOW_EVERY,
    use_spinner and quotes.is_enabled(), quotes.slowdownload)

  -- path.alive/path.sleep instead of path.run(os.execute): system(3) blocks
  -- SIGINT, which is exactly where Ctrl+C used to be swallowed.
  while pid and path.alive(pid) do
    -- Count completed downloads and find the newest completion.
    local f = io.open(progress_file, "r")
    if f then
      local count = 0
      for line in f:lines() do
        count = count + 1
        local idx = tonumber(line)
        if idx and not seen[idx] then
          seen[idx] = true
          last_name = remote[idx].label or ""
        end
      end
      f:close()
      if count > completed then
        completed = count
      end
    end

    if use_spinner then
      draw_batch(completed, total, last_name)
    end
    -- Slow-download taunt: leave the progress line, quote above it; the next
    -- tick redraws the bar on the line below.
    local q = slow_tick()
    if q then
      io.write("\n")
      log.detail(q)
    end
    path.sleep(0.05)
  end

  if parallel_cleanup then path.remove_cleanup(parallel_cleanup) end
  path.remove_cleanup(scratch_cleanup)

  -- Final count.
  local f = io.open(progress_file, "r")
  if f then
    local count = 0
    for line in f:lines() do
      count = count + 1
      local idx = tonumber(line)
      if idx and not seen[idx] then
        seen[idx] = true
        last_name = remote[idx].label or ""
      end
    end
    f:close()
    completed = count
  end

  if use_spinner then
    local filled = BAR_WIDTH
    io.write(("\r\27[K  [" .. string.rep("=", filled) .. "] %s  %d/%d\n"):format(last_name, completed, total))
    io.flush()
  else
    log.step(progress_label:format(total) .. "... [" .. completed .. "/" .. total .. "]")
  end

  -- Cleanup
  os.remove(script_path)
  os.remove(progress_file)
  os.remove(done_file)
  os.remove(rc_file)

  -- Decide per item from the script's own completion file: it records a
  -- transfer only when that transfer exited 0. So a file that succeeded is
  -- kept even when a sibling failed, an interrupted payload keeps its partial
  -- on disk for the next run to resume, and only a transfer that never
  -- completed is reported as an error.
  for _, r in ipairs(remote) do
    if seen[r.idx] then
      local renamed, ren_err = os.rename(r.tmp, r.dest)
      if renamed then
        results[r.idx] = { dest = r.dest }
      else
        if not resumable(r.dest) then os.remove(r.tmp) end
        results[r.idx] = { err = ren_err or ("could not store download: %s"):format(r.url) }
      end
    else
      if not resumable(r.dest) then os.remove(r.tmp) end
      results[r.idx] = { err = ("download failed: %s"):format(r.url) }
    end
  end

  return results
end

return fetch
