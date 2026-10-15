-- commit.lua -- merge a staged install root into the filesystem.
--
-- The staged tree is walked (via `find -printf`, available on all mainstream
-- find implementations), every entry is validated (symlink safety, path
-- hygiene) BEFORE anything is copied, and only then are files copied into
-- ZETA_ROOT. Zeta installs whatever a package ships; init-system and
-- distro-identity paths are not special-cased.

local commit = {}

local path = require("path")
local config = require("config")
local log = require("log")
local spinner = require("spinner")

-- ANSI color support for the progress line.
local function wants_color()
  local t = os.getenv("TERM")
  if not t or t == "" or t == "dumb" then return false end
  if os.getenv("NO_COLOR") then return false end
  return true
end
local COLOR = wants_color()
local C = {
  reset  = "\27[0m",
  blue   = "\27[34m",
  green  = "\27[32m",
  red    = "\27[31m",
  cyan   = "\27[36m",
  dim    = "\27[2m",
}
local function paint(color, s)
  if not COLOR then return s end
  return C[color] .. s .. C.reset
end

-- Walk a staged tree: returns entries { { rel, type, target } } where type is
-- "file", "dir" or "symlink". Uses find -printf ('%y|%l|%P') which gives
-- type, symlink target, and root-relative path on a single line.
local function walk_staging(staging)
  local f = path.popen("find " .. path.quote(staging)
    .. " -mindepth 1 -printf '%y|%l|%P\\n' 2>/dev/null")
  if not f then
    error(("could not scan staging directory %s"):format(staging), 0)
  end
  local out = {}
  for line in f:lines() do
    local typ, rest = line:match("^([%w])%|(.*)$")
      if typ then
        local link, rel = rest:match("^([^%|]*)%|(.*)$")
        if not link then link = "" end
        out[#out + 1] = {
          rel = rel,
          type = (typ == "d" and "dir" or (typ == "l" and "symlink" or "file")),
          target = (link ~= "" and link or nil),
        }
      end
  end
  f:close()
  return out
end

-- Normalize "dir/../dir2/./x" style paths to "dir2/x".
local function resolve_rel(rel, target)
  local dir = rel:match("^(.*)/[^/]+$") or ""
  local parts = {}
  for seg in (dir .. "/" .. target):gmatch("[^/]+") do
    if seg == ".." then
      parts[#parts] = nil
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return table.concat(parts, "/")
end

-- Verify that entries landed intact under `root`. `alt` is the other side of
-- the commit (the destination root before copying, the staging tree after):
-- a relative symlink is allowed to resolve there instead, because payloads
-- legitimately link to files another package or the base root owns (e.g.
-- usr/lib/systemd/systemd-udevd -> ../../bin/udevadm, where udevadm is
-- deliberately not shipped). A link resolving NOWHERE is refused — that is
-- the exact shape of a half-extracted payload whose boot-critical target
-- never landed. Two `find` passes total: per-file test spawns made installing
-- a 1000-file package noticeably slow.
-- Returns true, or nil, err naming the first offender.
local function verify_entries(root, entries, alt)
  local want = {}
  for _, e in ipairs(entries) do
    if e.type ~= "dir" then want[e.rel] = e end
  end

  -- Broken symlinks, one pass: find's -xtype l is exactly "target missing".
  local offenders = {}
  local f = path.popen("find " .. path.quote(root)
    .. " -xtype l -printf '%P\\t%l\\n' 2>/dev/null")
  if f then
    for line in f:lines() do
      local rel, target = line:match("^([^\t]+)\t(.*)$")
      if rel and want[rel] then
        offenders[#offenders + 1] = { rel = rel, target = target or "" }
      end
    end
    f:close()
  end
  for _, b in ipairs(offenders) do
    -- Only relative in-tree targets are judged: absolute ones (Arch
    -- payloads) resolve against the real root and may point at another
    -- package entirely.
    if b.target ~= "" and not b.target:match("^/")
        and not path.symlink_escapes(b.rel, b.target) then
      local elsewhere = alt
        and path.run("test -e " .. path.quote(path.join(alt, resolve_rel(b.rel, b.target))))
      if not elsewhere then
        return nil, ("symlink %q -> %q does not resolve (half-installed payload?)")
          :format(b.rel, b.target)
      end
    end
  end

  -- Empty files, one pass: warn only — some packages ship them deliberately.
  local empty = 0
  local g = path.popen("find " .. path.quote(root)
    .. " -type f -empty -printf '%P\\n' 2>/dev/null")
  if g then
    for line in g:lines() do
      if want[line] then empty = empty + 1 end
    end
    g:close()
  end
  if empty > 0 then
    log.warn(("%d committed file(s) are empty"):format(empty))
  end
  return true
end

-- apply(staging, opts) -> owned entries (files + symlinks + dirs).
-- opts: whitelist (list of rel paths to commit), force, pkg_name,
--       root (explicit install root — overrides config; set for isolated
--       installs so the host filesystem and linker cache are never touched).
function commit.apply(staging, opts)
  opts = opts or {}
  local entries = walk_staging(staging)

  -- Validate every staged entry BEFORE anything is copied: relative paths
  -- must never climb out of the install root, and symlink targets must not
  -- escape it (absolute targets are fine -- they resolve at runtime against
  -- the real root). Same rules archive.validate enforces on tarball members,
  -- enforced again here because commit.apply can be fed any staging tree.
  for _, e in ipairs(entries) do
    if e.rel == "" or e.rel:match("^/") or not path.relative_inside(e.rel) then
      error(("staging entry %q escapes the root"):format(e.rel), 0)
    end
    if e.type == "symlink" and path.symlink_escapes(e.rel, e.target) then
      error(("symlink %q -> %q escapes the root"):format(e.rel, e.target), 0)
    end
  end

  if opts.whitelist then
    local wl = {}
    for _, w in ipairs(opts.whitelist) do wl[w] = true end
    local filtered = {}
    for _, e in ipairs(entries) do
      if e.type == "dir" or wl[e.rel] then filtered[#filtered + 1] = e end
    end
    entries = filtered
  end

  local root = opts.root or config.get().root
  local isolated = opts.root ~= nil

  -- Owned entries are all concrete paths a package ships. Filter out directory
  -- entries that are prefixes of other entries: if a package owns usr/bin/hello,
  -- we don't record usr/ or usr/bin/ -- delete_files collects parents dynamically.
  -- This prevents removal from ever attempting to rmdir system directories.
  local non_dir = {}
  local dir_set = {}
  for _, e in ipairs(entries) do
    if e.type == "dir" then
      dir_set[e.rel] = true
    else
      non_dir[#non_dir + 1] = e
    end
  end
  -- Keep only directories that are NOT prefixes of any file/symlink entry.
  local owned = {}
  for _, e in ipairs(entries) do
    if e.type ~= "dir" then
      owned[#owned + 1] = e
    else
      local dominated = false
      for _, nd in ipairs(non_dir) do
        if nd.rel:sub(1, #e.rel + 1) == e.rel .. "/" then
          dominated = true
          break
        end
      end
      if not dominated then
        owned[#owned + 1] = e
      end
    end
  end

  -- Commit non-symlinks before symlinks: a library symlink (libfoo.so.1 ->
  -- libfoo.so.1.2.3) must never point at a file that has not been installed
  -- yet. During an upgrade the target filename may be new, so flipping the
  -- link first leaves a window where every binary that loads the library
  -- fails to exec (e.g. bash dies when libncursesw.so.6 dangles). Stable,
  -- so the walk order is preserved within each group.
  local non_sym, sym = {}, {}
  for _, e in ipairs(owned) do
    if e.type == "symlink" then sym[#sym + 1] = e else non_sym[#non_sym + 1] = e end
  end
  owned = non_sym
  for _, e in ipairs(sym) do owned[#owned + 1] = e end

  -- When the target path is a symlink (e.g. /sbin -> usr/sbin from the
  -- filesystem package), create the real directory the link points at
  -- instead: mkdir -p refuses to follow a dangling symlink. Targets are
  -- relative by construction (symlink_escapes rejects absolute ones), so
  -- resolving against the parent is safe.
  local function ensure_dir(d)
    local target = path.readlink(d)
    if target then
      d = path.join(path.dirname(d), target)
    end
    if not path.mkdir_p(d) then
      error(("failed to create directory %q"):format(d), 0)
    end
  end

  -- Copy phase. Non-verbose TTY mode shows a live updating progress line
  -- that overwrites itself in place. Verbose mode shows detailed per-file
  -- messages. Non-TTY mode skips per-file output entirely.
  -- Refuse to touch the root before the staging tree is proven intact: a
  -- half-extracted payload must fail loudly here, not dangle at boot.
  local vok, verr = verify_entries(staging, owned, root)
  if not vok then error(("staging check for %s: %s"):format(opts.pkg_name or "?", verr), 0) end
  local verbose = config.get().verbose
  local use_tty = spinner.enabled()
  local total = #owned
  local done = 0
  local file_count, sym_count, dir_count = 0, 0, 0

  for _, e in ipairs(owned) do
    local dest = path.join(root, e.rel)
    local src = path.join(staging, e.rel)
    if e.type == "dir" then
      ensure_dir(dest)
      dir_count = dir_count + 1
    else
      ensure_dir(path.dirname(dest))
      if e.type == "symlink" then
        -- uutils-coreutils ln (0.13, the GNU coreutils replacement) cannot
        -- `-f`-replace an existing destination whose parent is a symlinked
        -- directory: it reports ENOTDIR from the parent resolution instead of
        -- unlinking (e.g. replacing a plain file with `ctstat -> lnstat` under
        -- /sbin -> usr/sbin). Remove the old entry explicitly first so ln only
        -- ever creates a fresh link; harmless with GNU ln too.
        path.run("rm -f " .. path.quote(dest))
        if not path.run("ln -sfn " .. path.quote(e.target) .. " " .. path.quote(dest)) then
          error(("failed to create symlink %q"):format(dest), 0)
        end
        sym_count = sym_count + 1
      else
        local tmp = dest .. ".zeta-tmp-" .. tostring(math.random(100000, 999999))
        if not path.run("cp -a " .. path.quote(src) .. " " .. path.quote(tmp)) then
          os.remove(tmp)
          error(("failed to install %q"):format(e.rel), 0)
        end
        if not path.run("mv -f " .. path.quote(tmp) .. " " .. path.quote(dest)) then
          os.remove(tmp)
          error(("failed to install %q"):format(e.rel), 0)
        end
        file_count = file_count + 1
      end
    end

    -- Live progress line (TTY only, non-verbose, non-meta-package).
    if use_tty and not verbose and total > 0 then
      done = done + 1
      local n = paint("blue", tostring(done))
      local tot = paint("cyan", tostring(total))
      local p = paint("dim", e.rel)
      io.write(("\r\27[K  [ provided %s | %s entries ] %s"):format(n, tot, p))
      io.flush()
    end

    -- Verbose: detailed per-file output.
    if verbose then
      if e.type == "dir" then
        log.detail(("  mkdir %s"):format(dest))
      elseif e.type == "symlink" then
        log.detail(("  link %s -> %s"):format(dest, e.target))
      else
        log.detail(("  install %s -> %s"):format(src, dest))
      end
    end
  end

  -- Post-commit verification: everything just copied must be present in the
  -- real root too (catches a copy that silently vanished under a full disk).
  local rok, rerr = verify_entries(root, owned, staging)
  if not rok then error(("post-commit check for %s: %s"):format(opts.pkg_name or "?", rerr), 0) end

  -- Clear the progress line and show final count in green.
  if use_tty and not verbose and total > 0 then
    local n = paint("green", tostring(total))
    local tot = paint("cyan", tostring(total))
    io.write(("\r\27[K  [ provided %s | %s entries ]\n"):format(n, tot))
    io.flush()
  end

  -- Per-type summary.
  if file_count > 0 then
    log.info(("- committed %d files to %s"):format(file_count, root))
  end
  if sym_count > 0 then
    log.info(("- committed %d symlinks to %s"):format(sym_count, root))
  end
  if dir_count > 0 then
    log.info(("- committed %d dirs to %s"):format(dir_count, root))
  end

  -- Linker cache maintenance only applies to the real system root: an
  -- isolated store never touches the host's ld.so.conf or ld.so.cache (its
  -- binaries resolve libraries through their store RPATHs, with the profile
  -- wrapper's LD_LIBRARY_PATH as fallback).
  if not isolated then
    -- Ensure the dynamic linker knows about /usr/lib and /lib. The default
    -- ld.so.conf only lists /usr/local/lib and /opt/lib; without these paths
    -- ldconfig cannot populate the cache for libraries installed by ZETA.
    local ldconf = path.join(root, "etc/ld.so.conf.d/00-usr.conf")
    if not path.exists(ldconf) then
      path.mkdir_p(path.dirname(ldconf))
      local f = io.open(ldconf, "w")
      if f then
        f:write("/lib\n/usr/lib\n")
        f:close()
      end
    end

    -- Rebuild the shared library cache so newly installed libraries are found
    -- at runtime. ldconfig is idempotent and fast.
    log.step("Regenerating ldconfig cache")
    if path.run("ldconfig") then
      log.ok("ld.so.cache updated")
    else
      log.warn("ldconfig failed (non-fatal, but libraries may not be found at runtime)")
    end
  end

  -- Auto-compile GSettings schemas if any were installed (rooted at whatever
  -- root is in use, so isolated stores get their own gschemas.compiled).
  local schemas_dir = root .. "/usr/share/glib-2.0/schemas"
  local has_schema = false
  for _, e in ipairs(owned) do
    if e.rel:match("^usr/share/glib%-2%.0/schemas/.+%.gschema%.xml$") then
      has_schema = true
      break
    end
  end
  if has_schema then
    local compile = "glib-compile-schemas " .. path.quote(schemas_dir)
    log.step("compiling GSettings schemas")
    if path.run(compile) then
      log.ok("gschemas.compiled generated")
    else
      log.warn("glib-compile-schemas failed (non-fatal)")
    end
  end

  return owned
end

return commit
