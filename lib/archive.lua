-- archive.lua -- tar inspection, safe extraction, and Debian (.deb) payloads.
--
-- Extraction is a two-phase process: list the archive and validate every
-- member (no absolute paths, no ".." escapes, symlink targets that stay
-- inside the root) BEFORE extracting anything. A hostile or malformed archive
-- is therefore rejected without touching the filesystem. Symlink detection
-- relies on the `name -> target` form printed by tar for symbolic links.
--
-- A .deb is an ar(1) container holding debian-binary, control.tar.*, and
-- data.tar.*. Zeta only extracts the data member (a plain tar) -- maintainer
-- scripts are out of scope, superseded by Zeta's own manifest and hooks. The
-- ar container is parsed in pure Lua so no ar/dpkg dependency is dragged in.

local archive = {}

local path = require("path")
local log = require("log")
local config = require("config")

local function rel_of(member)
  local rel = member:gsub("^%./+", "")
  rel = rel:gsub("/+$", "")
  return rel
end

-- Classify the members of a tar archive.
-- Returns entries = { { path=rel, type="file"|"dir"|"symlink", target=.. } }.
--
-- Plain `tar -tf` prints names only (no link targets), so symlink safety
-- could not be checked from it. We therefore run TWO passes and walk them in
-- lockstep (both list members in archive order): `tar -tf` for the clean
-- member names, `tar -tvf` for the file type (verbose mode's leading char)
-- and, for symlinks, the `name -> target` marker.
function archive.entries(archive_file)
  local nf = io.popen("tar -tf " .. path.quote(archive_file) .. " 2>/dev/null")
  if not nf then return nil, "could not run tar" end
  local names = {}
  for line in nf:lines() do
    local name = line
    local is_dir = name:sub(-1) == "/"
    if is_dir then name = name:sub(1, -2) end
    names[#names + 1] = { name = name, dir = is_dir }
  end
  nf:close()

  local vf = io.popen("tar -tvf " .. path.quote(archive_file) .. " 2>/dev/null")
  local entries = {}
  local i = 0
  if vf then
    for line in vf:lines() do
      i = i + 1
      local info = names[i]
      if info then
        local typc = line:sub(1, 1)
        local target
        local typ
        if typc == "l" then
          typ = "symlink"
          target = line:match(" -> (%S+)$") or ""
        elseif typc == "d" then
          typ = "dir"
        else
          typ = "file"
        end
        local rel = rel_of(info.name)
        if rel ~= "" then
          entries[#entries + 1] = { path = rel, type = typ, target = target }
        end
      end
    end
    vf:close()
  end
  return entries
end

-- Validate that no member escapes the extraction root. Returns true or nil, err.
function archive.validate(entries)
  for _, e in ipairs(entries) do
    if e.path == "" or e.path:match("^/") or not path.relative_inside(e.path) then
      return nil, ("archive member %q escapes the root"):format(e.path)
    end
    if e.type == "symlink" and path.symlink_escapes(e.path, e.target) then
      return nil, ("symlink %q -> %q escapes the root"):format(e.path, e.target)
    end
  end
  return true
end

-- Extract `archive_file` into `dest`. Returns the validated entries, or
-- nil, err if validation or extraction fails.
function archive.extract(archive_file, dest, opts)
  opts = opts or {}
  if path.basename(archive_file):match("%.deb$") then
    return archive.extract_deb(archive_file, dest, opts)
  end
  local entries, err = archive.entries(archive_file)
  if not entries then return nil, err end
  local ok, verr = archive.validate(entries)
  if not ok then return nil, verr end
  local strip = opts.strip or 0
  -- --silence drops the -v member listing: "provided" chatter is the only
  -- thing TTYs struggle to render, so suppression is scoped to per-file noise.
  local listing = log.is_file_silent() and "-xf" or "-xvf"
  local cmd = "tar " .. listing .. " " .. path.quote(archive_file)
    .. " -C " .. path.quote(dest) .. " --no-same-owner"
  if strip > 0 then
    cmd = cmd .. " --strip-components=" .. tostring(strip)
  end
  log.detail(("archive: extracting %s into %s%s"):format(
    path.basename(archive_file), dest,
    strip > 0 and (" (strip " .. strip .. ")") or ""))
  if not path.run(cmd) then
    return nil, ("failed to extract %s"):format(archive_file)
  end
  return entries
end

-- Locate the `data.tar.*` member of an ar (deb) container. ar member layout:
--   magic  "!<arch>\n"
--   header 60 bytes: name (16), mtime (12), owner (6), group (6), mode (8),
--                    size (10), trailer "`\n" (2)
--   data   `size` bytes, then one padding byte when size is odd.
-- Returns { offset, size } of the data member, or nil, err.
local function find_deb_data(deb_file)
  local f = io.open(deb_file, "rb")
  if not f then return nil, ("cannot open %s"):format(deb_file) end
  local magic = f:read(8)
  if magic ~= "!<arch>\n" then
    f:close()
    return nil, ("%s is not a Debian package (bad ar magic)"):format(deb_file)
  end
  local pos = 8
  while true do
    f:seek("set", pos)
    local hdr = f:read(60)
    if not hdr or #hdr < 60 then break end
    local name = hdr:sub(1, 16):gsub("%s+$", ""):gsub("/$", "")
    local size = tonumber(hdr:sub(49, 58)) or 0
    if name:match("^data%.tar") then
      f:close()
      return { offset = pos + 60, size = size }
    end
    pos = pos + 60 + size
    if size % 2 == 1 then pos = pos + 1 end
  end
  f:close()
  return nil, ("no data.tar member found in %s"):format(deb_file)
end

-- Copy `member` bytes out of the deb into `tmp`. Returns true on success.
local function extract_member(deb_file, member, tmp)
  local fi = io.open(deb_file, "rb")
  if not fi then return false end
  fi:seek("set", member.offset)
  local fo = io.open(tmp, "wb")
  if not fo then fi:close() return false end
  local remaining = member.size
  while remaining > 0 do
    local chunk = fi:read(math.min(remaining, 65536))
    if not chunk then break end
    fo:write(chunk)
    remaining = remaining - #chunk
  end
  fo:close()
  fi:close()
  return remaining == 0
end

-- Extract a Debian package. Pulls the `data.tar.*` payload out of the ar
-- container and delegates to archive.extract() for validation + strip, so
-- .debs get exactly the same two-phase safety as plain tars.
-- opts: strip, tmp_dir (where the data.tar temp lands; default config tmp).
function archive.extract_deb(deb_file, dest, opts)
  opts = opts or {}
  local member, err = find_deb_data(deb_file)
  if not member then return nil, err end

  local tmp_dir = opts.tmp_dir or config.get().tmp_dir
  path.mkdir_p(tmp_dir)
  local tmp = path.join(tmp_dir, "zeta-deb-" .. tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999)))

  log.detail(("archive: %s is a .deb, extracting data.tar (%d bytes)"):format(
    path.basename(deb_file), member.size))

  if not extract_member(deb_file, member, tmp) then
    os.remove(tmp)
    return nil, ("failed to read data.tar from %s"):format(deb_file)
  end

  -- Deb-aware strip adjustment: inspect the raw first member of data.tar.
  -- .deb data.tar entries may use ./usr/... (dot-prefixed, strip works)
  -- or usr/... (non-prefixed, strip would eat the real first component).
  local strip = opts.strip or 0
  if strip > 0 then
    local rf = io.popen("tar -tf " .. path.quote(tmp) .. " 2>/dev/null")
    local first = rf and rf:read("*l") or ""
    if rf then rf:close() end
    if first ~= "" and not first:match("^%./") then
      log.detail("archive: data.tar has no ./ prefix, disabling strip")
      strip = 0
    end
  end

  local eopts = { strip = strip, tmp_dir = opts.tmp_dir }
  local entries, xerr = archive.extract(tmp, dest, eopts)
  os.remove(tmp)
  return entries, xerr
end

return archive
