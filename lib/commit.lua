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

-- collect_owned(staging, whitelist) -> owned entries, ordered
--
-- The staged-tree walk, validation, whitelist filter and owned-entry
-- computation shared by apply and count_owned. Non-symlinks come before
-- symlinks (see the note below), so the caller can commit in this order.
local function collect_owned(staging, whitelist)
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

  if whitelist then
    local wl = {}
    for _, w in ipairs(whitelist) do wl[w] = true end
    local filtered = {}
    for _, e in ipairs(entries) do
      if e.type == "dir" or wl[e.rel] then filtered[#filtered + 1] = e end
    end
    entries = filtered
  end

  -- Owned entries are all concrete paths a package ships. Filter out directory
  -- entries that are prefixes of other entries: if a package owns usr/bin/hello,
  -- we don't record usr/ or usr/bin/ -- delete_files collects parents dynamically.
  -- This prevents deletion from ever attempting to rmdir system directories.
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

  return owned
end

-- count_owned(staging, whitelist) -> number of entries apply would commit.
-- The batch commit draws one aggregate counter across every package and
-- needs the denominator before the first file moves.
function commit.count_owned(staging, whitelist)
  return #collect_owned(staging, whitelist)
end

-- counter(done, total, final, rel) -- the live progress line the batch commit
-- redraws across the whole transaction: glyph, count, then the entry that was
-- just placed. Written in place, and settled with a newline when final -- the
-- path is a live detail, so it drops off the settled summary line. The braille
-- glyph leads so the row shows something is still moving between entries.
function commit.counter(done, total, final, rel)
  local n = paint(final and "green" or "blue", tostring(done))
  local tot = paint("cyan", tostring(total))
  local g = spinner.next_frame()
  local where = (not final and rel) and (" " .. paint("dim", rel)) or ""
  if final then
    io.write(("\r\27[K%s - [ provided %s | %s entries ]%s\n"):format(g, n, tot, where))
  else
    io.write(("\r\27[K%s - [ provided %s | %s entries ]%s"):format(g, n, tot, where))
  end
  io.flush()
end

-- apply(staging, opts) -> owned entries (files + symlinks + dirs).
-- opts: whitelist (list of rel paths to commit), force, pkg_name,
--       root (explicit install root — overrides config; set for isolated
--       installs so the host filesystem and linker cache are never touched),
--       defer_system (skip the linker-cache/schema work here; the caller runs
--       commit.run_system_ops once at the end of the transaction),
--       on_progress (called as (done, total, rel) after every committed
--       entry, rel being the root-relative path that just landed; when set,
--       the caller owns all progress output and the per-type summary, and
--       apply prints neither).
function commit.apply(staging, opts)
  opts = opts or {}
  local owned = collect_owned(staging, opts.whitelist)

  local root = opts.root or config.get().root
  local isolated = opts.root ~= nil

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
  -- messages. Non-TTY mode skips per-file output entirely. With an
  -- on_progress callback the caller owns all progress output.
  local verbose = config.get().verbose
  local use_tty = spinner.enabled()
  local batch = opts.on_progress ~= nil
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
        -- /sbin -> usr/sbin). Delete the old entry explicitly first so ln only
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

    -- Progress: the caller's counter (batch mode) or a live TTY line.
    done = done + 1
    if opts.on_progress then
      opts.on_progress(done, total, e.rel)
    elseif use_tty and not verbose and total > 0 then
      local n = paint("blue", tostring(done))
      local tot = paint("cyan", tostring(total))
      local p = paint("dim", path.join(root, e.rel))
      io.write(("\r\27[K%s - [ provided %s | %s entries ] %s"):format(spinner.next_frame(), n, tot, p))
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

  -- Final count line, replacing the live line in place. Batch mode leaves the
  -- counter to the caller.
  if not batch and not verbose and total > 0 and use_tty then
    local n = paint("green", tostring(total))
    local tot = paint("cyan", tostring(total))
    io.write(("\r\27[K%s - [ provided %s | %s entries ]\n"):format(spinner.next_frame(), n, tot))
    io.flush()
  end

  -- Per-type summary (batch mode: the caller prints one aggregate summary).
  if not batch then
    if file_count > 0 then
      log.info(("- committed %d files to %s"):format(file_count, root))
    end
    if sym_count > 0 then
      log.info(("- committed %d symlinks to %s"):format(sym_count, root))
    end
    if dir_count > 0 then
      log.info(("- committed %d dirs to %s"):format(dir_count, root))
    end
  end

  -- Whether any GSettings schemas shipped (the compile itself is part of the
  -- system ops below).
  local has_schema = false
  for _, e in ipairs(owned) do
    if e.rel:match("^usr/share/glib%-2%.0/schemas/.+%.gschema%.xml$") then
      has_schema = true
      break
    end
  end

  -- System-wide side effects run once per transaction (see run_system_ops);
  -- a pool commit defers them so two workers can never collide.
  if not opts.defer_system then
    commit.run_system_ops({ root = root, isolated = isolated, schemas = has_schema })
  end

  return owned
end

-- run_system_ops(opts) -- opts: { root, isolated, schemas }
--
-- The system-wide side effects of a commit, run ONCE per transaction after
-- every package is in place: the linker cache (ld.so.conf snippet + ldconfig)
-- and GSettings schema compilation. Two concurrent commits must never race on
-- /etc/ld.so.cache~ or gschemas.compiled, so the commit pool defers these
-- here instead of running them per package.
function commit.run_system_ops(opts)
  opts = opts or {}
  local root = opts.root or config.get().root

  -- Linker cache maintenance only applies to the real system root: an
  -- isolated store never touches the host's ld.so.conf or ld.so.cache (its
  -- binaries resolve libraries through their store RPATHs, with the profile
  -- wrapper's LD_LIBRARY_PATH as fallback).
  if not opts.isolated then
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

    -- Image-loader / desktop caches, regenerated per install so a fresh
    -- system reaches full icon and menu state without manual steps: only
    -- png/jpeg loaders are builtin to gdk-pixbuf (svg/gif/tiff resolve
    -- through the loaders cache), and desktop/menu association lookups
    -- read the desktop database. Best-effort, like ldconfig above.
    log.step("Regenerating gdk-pixbuf loaders cache")
    if path.run("gdk-pixbuf-query-loaders --update-cache") then
      log.ok("gdk-pixbuf loaders.cache updated")
    else
      log.warn("gdk-pixbuf-query-loaders failed (non-fatal, dynamic loaders may be unreachable)")
    end

    log.step("Updating desktop database")
    if path.run("update-desktop-database /usr/share/applications") then
      log.ok("desktop database updated")
    else
      log.warn("update-desktop-database failed (non-fatal, menu associations may be stale)")
    end

    log.step("Updating icon theme caches")
    if path.run("for d in /usr/share/icons/*/; do if [ -f \"$d/index.theme\" ]; then gtk-update-icon-cache -q -f -t \"$d\" || true; fi; done") then
      log.ok("icon theme caches updated")
    else
      log.warn("gtk-update-icon-cache failed (non-fatal)")
    end
  end

  -- Auto-compile GSettings schemas if any were installed (rooted at whatever
  -- root is in use, so isolated stores get their own gschemas.compiled).
  if opts.schemas then
    local schemas_dir = root .. "/usr/share/glib-2.0/schemas"
    local compile = "glib-compile-schemas " .. path.quote(schemas_dir)
    log.step("compiling GSettings schemas")
    if path.run(compile) then
      log.ok("gschemas.compiled generated")
    else
      log.warn("glib-compile-schemas failed (non-fatal)")
    end
  end

  -- The distro convention keeps package configs under usr/etc (prefix-owned
  -- tree), but nothing reads them there: XDG, dhcpcd, avahi et al all look
  -- in /etc. Mirror every file from <root>/usr/etc into <root>/etc as a
  -- RELATIVE symlink so isolated stores stay self-contained and package
  -- upgrades take effect through the same path. Never overwrites an
  -- existing /etc file (other packages own those directly), and is
  -- idempotent — it also heals systems installed before this hook existed.
  local usretc = root .. "/usr/etc"
  if path.exists(usretc) then
    log.step("mirroring usr/etc configs into /etc")
    local mirror = string.format([[
R=%s
R=${R%/}
find "$R/usr/etc" -type f 2>/dev/null | while IFS= read -r f; do
  rel=${f#"$R/usr/etc/"}
  dest="$R/etc/$rel"
  [ -e "$dest" ] && continue
  mkdir -p "$(dirname "$dest")"
  n=$(printf '%%s' "$rel" | tr -cd / | wc -c)
  ups="../"
  i=$n
  while [ "$i" -gt 0 ]; do ups="../$ups"; i=$((i-1)); done
  ln -s "${ups}usr/etc/$rel" "$dest" || exit 1
done
]], path.quote(root))
    if path.run(mirror) then
      log.ok("usr/etc configs linked into /etc (absent files only)")
    else
      log.warn("usr/etc mirroring failed (non-fatal, /etc configs may be absent)")
    end
  end
end

return commit
