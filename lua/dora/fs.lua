-- Filesystem operations: listing and watching directories, create/rename/
-- delete, trash/untrash, and synchronous + asynchronous copy/move/remove.
-- Everything is path-based; the only editor state touched is renaming buffers
-- to follow moved files (see move below).
local buffer = require'dora.buffer'
local util = require'dora.util'
local uv = vim.uv

local M = {}

local iswin = uv.os_uname().sysname:match('Windows') ~= nil

-- NOTE: Backslash is a separator only on Windows; on POSIX it's a valid
-- filename character.
---@param char string
---@return boolean
local function is_separator(char)
    return char == '/' or (iswin and char == '\\')
end

---@param path string
---@return boolean
local function is_absolute(path)
    if iswin then
        return is_separator(path:sub(1, 1)) or path:match('^%a:[/\\]') ~= nil
    end
    return vim.startswith(path, '/') or path:match('^%a:/') ~= nil
end

---@param src string
---@param dest string
local function copy_file(src, dest)
    assert(uv.fs_copyfile(src, dest))
end

---@param src string
---@param dest string
local function copy_link(src, dest)
    local target = assert(uv.fs_readlink(src))
    assert(uv.fs_symlink(target, dest))
end

---@param src string
---@param dest string
local function copy_dir(src, dest)
    local stat = assert(uv.fs_stat(src))
    assert(uv.fs_mkdir(dest, stat.mode))
    for name, type in vim.fs.dir(src) do
        local copy = type == 'directory' and copy_dir
            or type == 'link' and copy_link
            or copy_file
        copy(vim.fs.joinpath(src, name), vim.fs.joinpath(dest, name))
    end
end

---@param src string
---@param dest string
local function copy_any(src, dest)
    if uv.fs_readlink(src) then
        copy_link(src, dest)
    elseif M.is_dir(src) then
        copy_dir(src, dest)
    else
        copy_file(src, dest)
    end
end

-- NOTE: This deliberately reaches into the editor layer: any buffer editing
-- `src` is renamed to follow the file, so open buffers stay attached after a
-- rename/move. The async variant (move_a below) runs in a libuv fast context
-- where that isn't allowed, so it returns the pending rename for paste_async's
-- completion handler to apply instead.
---@param src string
---@param dest string
local function move(src, dest)
    local src_is_dir = M.is_dir(src)
    local ok, err, errname = uv.fs_rename(src, dest)
    if not ok then
        -- fs_rename cannot cross filesystems, e.g. moving to a trash
        -- directory on another mount, so fall back to copy+delete.
        if errname ~= 'EXDEV' then
            error(err)
        end
        copy_any(src, dest)
        M.delete(src)
    end
    if not src_is_dir then
        buffer.rename_buffers(src, dest)
    end
end

-- NOTE: Uses lstat so that dangling symlinks are considered to exist
---@param path string
---@return boolean
function M.exists(path)
    return uv.fs_lstat(path) ~= nil
end

-- Whether two paths resolve to the same filesystem object. On case-insensitive
-- filesystems this is true for case-only variants (e.g. README and readme),
-- which lets a case-only rename be distinguished from overwriting a sibling.
---@param a string
---@param b string
---@return boolean
function M.same_file(a, b)
    local sa = uv.fs_lstat(a)
    local sb = uv.fs_lstat(b)
    return sa ~= nil and sb ~= nil and sa.ino == sb.ino and sa.dev == sb.dev
end

-- Split a basename into its stem and extension at the first interior dot, so a
-- counter inserted between them lands before the extension (report.txt ->
-- report, .txt; archive.tar.gz -> archive, .tar.gz). A leading dot (dotfiles)
-- stays in the stem, so .gitignore has no extension.
---@param basename string
---@return string stem
---@return string ext
local function split_ext(basename)
    local dot = basename:find('%.', 2)
    if not dot then
        return basename, ''
    end
    return basename:sub(1, dot - 1), basename:sub(dot)
end

-- Given a destination path, return a sibling path that does not yet exist by
-- inserting "(N)" before the extension, so a paste keeps both files instead of
-- overwriting (report.txt -> report(1).txt), incrementing an existing suffix
-- rather than nesting it (report(1).txt -> report(2).txt), until the name is
-- free. Returns the path unchanged when nothing exists there. Also used to pick
-- a free name when trashing into an occupied trash directory.
---@param path string
---@param reserved? table<string, boolean> Paths planned by earlier operations
---@return string
function M.nonclobber_dest(path, reserved)
    local function occupied(candidate)
        return M.exists(candidate) or (reserved and reserved[candidate]) or false
    end
    if not occupied(path) then
        return path
    end
    local dir = M.parent_dir(path)
    local stem, ext = split_ext(M.basename(path))
    local base, suffix = stem:match('^(.*)%((%d+)%)$')
    local first = 1
    if suffix then
        stem = base
        first = assert(tonumber(suffix)) + 1
    end
    for i = first, first + 999 do
        local candidate = vim.fs.joinpath(dir, stem .. '(' .. i .. ')' .. ext)
        if not occupied(candidate) then
            return candidate
        end
    end
    error('Could not find a non-clobbering destination for ' .. path)
end

---@param path string
---@param cwd string
---@return string
function M.normalize_path(path, cwd)
    path = util.trim_start(path)
    assert(path ~= '', 'Empty path')
    path = vim.fs.normalize(path)
    if is_absolute(path) then
        return path
    end
    return vim.fs.normalize(vim.fs.joinpath(cwd, path), {expand_env = false})
end

---@param path string Symlink path
---@param target string Target returned by readlink()
---@return string
function M.display_symlink_target(path, target)
    if iswin or not vim.startswith(target, '/') then
        return target
    end
    -- Find the nearest parent shared by the symlink and its absolute target.
    local base = M.parent_dir(path)
    local relative = vim.fs.relpath(base, target)
    local prefix = ''
    for parent in vim.fs.parents(base) do
        if relative then
            break
        end
        prefix = prefix .. '../'
        relative = vim.fs.relpath(parent, target)
    end
    if not relative then
        return target
    end
    return relative == '.' and (prefix ~= '' and prefix:sub(1, -2) or '.') or prefix .. relative
end

-- Paths from the OS (fs_realpath, uv.cwd) are backslash-separated on Windows,
-- while every path built internally uses '/' (vim.fs.joinpath/normalize), so
-- convert to '/' for prefix and equality checks to work.
---@param path string
---@return string
function M.normalize_sep(path)
    return iswin and (path:gsub('\\', '/')) or path
end

-- Like realpath(), but returns nil and a message instead of erroring
---@param path string
---@return string? path
---@return string? msg
function M.try_realpath(path)
    local resolved, msg = uv.fs_realpath(path)
    if not resolved then
        return nil, msg
    end
    return M.normalize_sep(resolved)
end

---@param path string
---@return string
function M.realpath(path)
    return (assert(M.try_realpath(path)))
end

---@param path string
---@return boolean
function M.is_root(path)
    if not iswin then
        return path == '/'
    end
    local normalized = path:gsub('\\', '/')
    return normalized == '/'
        or normalized:match('^%a:/$') ~= nil
        or normalized:match('^//[^/]+/[^/]+/?$') ~= nil
end

---@param path string
---@return string
function M.strip_trailing_sep(path)
    while not M.is_root(path) and is_separator(path:sub(-1)) do
        path = path:sub(1, -2)
    end
    return path
end

-- NOTE: Symlink dirs are considered directories
---@param path string
---@return boolean
function M.is_dir(path)
    local file_info = uv.fs_stat(path)
    return file_info and file_info.type == 'directory' or false
end

---@param path string
---@param fallback_type? DoraFileType
---@return DoraFile
function M.file_from_path(path, fallback_type)
    local stat = uv.fs_lstat(path) or {}
    return {
        name = M.basename(path),
        type = stat.type or fallback_type or 'file',
        size = stat.size or 0,
        mtime = stat.mtime,
        birthtime = stat.birthtime,
    }
end

-- Debounce window for coalescing bursts of filesystem events. A single
-- logical change often emits several events, and constrained filesystems
-- (e.g. the overlay mounts used by sandboxes) can fire them continuously.
-- Without coalescing, every event triggers a full re-render, which can
-- saturate the event loop and stall.
local WATCH_DEBOUNCE_MS = 50

-- Watch a directory for changes. `on_change` is called on the main loop
-- once a burst of events settles, and the watcher stops itself; watch again
-- for further changes. Returns a function that cancels the watch, or nil when
-- the directory can't be watched.
---@param dir string
---@param on_change fun()
---@return fun()? cancel
function M.watch_dir(dir, on_change)
    local watcher = uv.new_fs_event()
    if not watcher then
        return nil
    end
    local timer
    local function stop_timer()
        if timer then
            timer:stop()
            if not timer:is_closing() then
                timer:close()
            end
            timer = nil
        end
    end
    local function cancel()
        stop_timer()
        if not watcher:is_closing() then
            watcher:stop()
            watcher:close()
        end
    end
    local fire = vim.schedule_wrap(function()
        -- The watch may have been cancelled while the debounce timer was
        -- pending, or before this ran on the main loop.
        if watcher:is_closing() then
            return
        end
        cancel()
        on_change()
    end)
    local ok = watcher:start(dir, {}, function(err)
        if err or watcher:is_closing() then
            return
        end
        -- Coalesce this event with any others that arrive within the debounce
        -- window so a burst (or storm) causes a single refresh rather than one
        -- re-render per event.
        if not timer then
            timer = uv.new_timer()
        end
        timer:start(WATCH_DEBOUNCE_MS, 0, fire)
    end)
    if not ok then
        watcher:close()
        return nil
    end
    return cancel
end

---@param path string
---@return DoraFile[]
function M.list(path)
    -- vim.fs.dir() silently yields nothing when the directory can't be
    -- scanned, so use fs_scandir directly to surface errors like EPERM.
    local handle, err = uv.fs_scandir(path)
    if not handle then
        error(err, 0)
    end
    local ret = {}
    while true do
        local basename, file_type = uv.fs_scandir_next(handle)
        if not basename then
            break
        end
        local full_path = vim.fs.joinpath(path, basename)
        table.insert(ret, M.file_from_path(full_path, file_type))
    end
    return ret
end

---@param path string
---@return string
function M.parent_dir(path)
    path = M.strip_trailing_sep(path)
    if M.is_root(path) then
        return path
    end
    local parent = assert(vim.fs.dirname(path))
    return parent == '.' and '' or parent
end

---@param dir string
---@return string
function M.get_parent_dir(dir)
    local parent = M.parent_dir(dir)
    assert(M.exists(parent))
    return parent
end

---@param path string
---@return string
function M.basename(path)
    return assert(vim.fs.basename(M.strip_trailing_sep(path)))
end

---@param path string
function M.delete(path)
    vim.fs.rm(path, {recursive = M.is_dir(path)})
end

-- Where trashed files go on this platform, or nil (with a message) where
-- trashing is unsupported (Windows).
---@return string? dir
---@return string? err
local function trash_dir()
    local sysname = uv.os_uname().sysname
    if sysname:match('Windows') then
        return nil, 'Trash is not currently supported on Windows'
    end
    if sysname == 'Darwin' then
        return vim.fs.joinpath(assert(os.getenv'HOME'), '.Trash')
    end
    local data_home = os.getenv'XDG_DATA_HOME' or vim.fs.joinpath(assert(os.getenv'HOME'), '.local/share')
    return vim.fs.joinpath(data_home, 'Trash/files')
end

-- Restore a trashed entry to where it came from, undoing a trash. The original
-- location may now be occupied (something new took the name) or its parent dir
-- may have been removed since, so restore to a non-clobbering sibling and
-- recreate any missing parents. Returns the path it was restored to.
---@param trashed string Entry inside the trash directory
---@param original string Path it was trashed from
---@return string dest
function M.untrash(trashed, original)
    assert(M.exists(trashed), ("%s is no longer in the trash"):format(trashed))
    local parent = M.parent_dir(original)
    if not M.exists(parent) then
        assert(vim.fn.mkdir(parent, 'p') == 1)
    end
    local dest = M.nonclobber_dest(original)
    move(trashed, dest)
    return dest
end

---@param path string
function M.create_dir(path)
    assert(not M.exists(path), ('%q already exists'):format(path))
    -- 755 = RWX for owner, RX for group/other
    assert(vim.fn.mkdir(path, 'p') == 1)
end

---@param path string
function M.create_file(path)
    assert(not M.exists(path), ('%q already exists'):format(path))
    local parent = M.parent_dir(path)
    assert(vim.fn.mkdir(parent, 'p') == 1)
    -- 644 = RW for owner, R for group/other
    local fd = assert(uv.fs_open(path, 'w', tonumber('644', 8)))
    assert(uv.fs_close(fd))
end

---@param target string
---@param path string
function M.create_symlink(target, path)
    assert(not M.exists(path), ('%q already exists'):format(path))
    -- The dir flag only matters on Windows
    assert(uv.fs_symlink(target, path, {dir = M.is_dir(target)}))
end

---@param input string
---@param cwd string
---@return string path
function M.validate_create(input, cwd)
    assert(input, 'Empty path')
    input = util.trim_start(input)
    assert(input ~= '', 'Empty path')
    assert(not is_absolute(input), 'Create paths must be relative')
    local path = vim.fs.joinpath(cwd, input)
    assert(not M.exists(path), ('%q already exists'):format(path))
    local path_for_parent = is_separator(path:sub(-1)) and path:sub(1, -2) or path
    local parent = M.parent_dir(path_for_parent)
    while not M.exists(parent) do
        parent = M.parent_dir(parent)
    end
    assert(M.is_dir(parent), ('%q is not a directory'):format(parent))
    return path
end

---@param input string
---@param src string
---@return string path
function M.validate_rename(input, src)
    assert(input, 'Empty filename')
    input = util.trim_start(input)
    assert(input ~= '', 'Empty filename')
    assert(not input:find(iswin and '[/\\]' or '/'), 'Rename cannot move files between directories')
    local parent = M.parent_dir(src)
    local path = vim.fs.joinpath(parent, input)
    assert(src ~= path, '`src` equals `dest`')
    local dest_stat = uv.fs_lstat(path)
    if dest_stat and not M.same_file(src, path) then
        local src_stat = uv.fs_lstat(src)
        assert(src_stat and src_stat.type == 'file' and dest_stat.type == 'file',
            ('%q already exists'):format(path))
    end
    return path
end

---@param input string
---@param cwd string
---@return string path
function M.validate_symlink(input, cwd)
    assert(input, 'Empty path')
    local path = M.normalize_path(input, cwd)
    assert(not M.exists(path), ('%q already exists'):format(path))
    local parent = M.parent_dir(path)
    assert(M.exists(parent), ('%q does not exist'):format(parent))
    assert(M.is_dir(parent), ('%q is not a directory'):format(parent))
    return path
end

---@param src string
---@param dest string
function M.rename(src, dest)
    local src_stat = uv.fs_lstat(src)
    assert(src_stat, ("%s doesn't exist"):format(src))
    assert(src ~= dest, '`src` equals `dest`')
    local parent = M.parent_dir(dest)
    assert(M.exists(parent), ('%q does not exist'):format(parent))
    assert(M.is_dir(parent), ('%q is not a directory'):format(parent))
    local dest_stat = uv.fs_lstat(dest)
    if dest_stat and not M.same_file(src, dest) then
        assert(src_stat.type == 'file' and dest_stat.type == 'file',
            ('%q already exists'):format(dest))
    end
    move(src, dest)
end

---@param src string
---@param dest string
---@param cwd string
---@param allow_same boolean Permit a paste to resolve to its own source
---@return string dest
local function resolve_copy_or_move_dest(src, dest, cwd, allow_same)
    assert(M.exists(src), ("%s doesn't exist"):format(src))
    dest = M.normalize_path(dest, cwd)
    assert(src ~= dest, '`src` equals `dest`')
    if M.is_dir(dest) then
        dest = vim.fs.joinpath(dest, M.basename(src))
        if not allow_same then
            assert(src ~= dest, '`src` equals `dest`')
        end
    end
    assert(not vim.startswith(dest, src .. '/'),
        ('Cannot copy or move %q into itself'):format(src))
    return dest
end

---@param src string
---@param dest string
---@param cwd string
---@return string dest
function M.resolve_copy_or_move_dest(src, dest, cwd)
    return resolve_copy_or_move_dest(src, dest, cwd, false)
end

-- Whether pasting `src` into the directory `dest_dir` would resolve back onto the
-- source itself or somewhere inside it.
-- rejects.
---@param src string
---@param dest_dir string
---@param cwd string
---@return boolean
function M.paste_into_self(src, dest_dir, cwd)
    local dest = M.normalize_path(dest_dir, cwd)
    return src == dest
        or vim.startswith(vim.fs.joinpath(dest, M.basename(src)), src .. '/')
end

-- Mimics the semantics of `mv` / `cp -R`
---@param is_move boolean
---@param src string
---@param dest string
---@param cwd string
---@return string dest
function M.copy_or_move(is_move, src, dest, cwd)
    dest = M.resolve_copy_or_move_dest(src, dest, cwd)
    -- Replace an existing destination when a directory is involved so the paste
    -- overwrites instead of erroring on mkdir/rename. A file replacing a file is
    -- already overwritten in place by copyfile/rename. resolve_copy_or_move_dest
    -- rejects src == dest, and same_file guards aliases, so we never delete the
    -- source itself.
    if M.exists(dest) and not M.same_file(src, dest)
        and (M.is_dir(src) or M.is_dir(dest)) then
        M.delete(dest)
    end
    local op = is_move and move or copy_any
    op(src, dest)
    return dest
end

-- Asynchronous copy/move ------------------------------------------------------
--
-- The synchronous helpers above block Neovim's main loop for the entire
-- duration of a copy -- a 1 GiB recursive copy freezes the editor with no
-- feedback. The functions below do the same work through libuv's asynchronous
-- fs API, so the byte-copying happens on libuv's threadpool and the editor
-- stays responsive.
---@param body fun(): ...
---@param on_done fun(ok: boolean, ...)
local function run(body, on_done)
    local co = coroutine.create(body)
    local function step(...)
        local results = {coroutine.resume(co, ...)}
        if not results[1] then
            on_done(false, results[2])
        elseif coroutine.status(co) == 'dead' then
            on_done(true, unpack(results, 2))
        else
            local thunk = results[2]
            thunk(step)
        end
    end
    step()
end

-- Suspends the running coroutine until `thunk`'s callback fires, returning the
-- callback's result.
---@param thunk fun(cb: fun(err: string?, value: any))
---@return any
local function await(thunk)
    local err, value = coroutine.yield(thunk)
    if err then
        error(err, 0)
    end
    return value
end

local function a_lstat(path) return function(cb) uv.fs_lstat(path, cb) end end
local function a_scandir(path) return function(cb) uv.fs_scandir(path, cb) end end
local function a_readlink(path) return function(cb) uv.fs_readlink(path, cb) end end
local function a_mkdir(path, mode) return function(cb) uv.fs_mkdir(path, mode, cb) end end
local function a_copyfile(src, dest) return function(cb) uv.fs_copyfile(src, dest, nil, cb) end end
local function a_symlink(target, dest) return function(cb) uv.fs_symlink(target, dest, nil, cb) end end
local function a_unlink(path) return function(cb) uv.fs_unlink(path, cb) end end
local function a_rmdir(path) return function(cb) uv.fs_rmdir(path, cb) end end
local function a_rename(src, dest) return function(cb) uv.fs_rename(src, dest, cb) end end

---@class DoraPasteProgress
---@field files integer Files and symlinks copied so far
---@field bytes integer Total bytes of files copied so far

-- Async analogue of copy_any/copy_dir/copy_link/copy_file. Uses lstat (not
-- stat) so a symlink is recreated as a link rather than followed, matching
-- copy_any's semantics.
---@param src string
---@param dest string
---@param progress DoraPasteProgress
local function copy_entry_a(src, dest, progress)
    local st = await(a_lstat(src))
    if st.type == 'link' then
        local target = await(a_readlink(src))
        await(a_symlink(target, dest))
        progress.files = progress.files + 1
    elseif st.type == 'directory' then
        await(a_mkdir(dest, st.mode))
        local handle = await(a_scandir(src))
        while true do
            local name = uv.fs_scandir_next(handle)
            if not name then
                break
            end
            copy_entry_a(vim.fs.joinpath(src, name), vim.fs.joinpath(dest, name), progress)
        end
    else
        await(a_copyfile(src, dest))
        progress.files = progress.files + 1
        progress.bytes = progress.bytes + (st.size or 0)
    end
end

-- Async recursive delete, used to overwrite an existing destination and for the
-- cross-filesystem move fallback below.
---@param path string
local function rm_a(path)
    local st = await(a_lstat(path))
    if st.type == 'directory' then
        local handle = await(a_scandir(path))
        while true do
            local name = uv.fs_scandir_next(handle)
            if not name then
                break
            end
            rm_a(vim.fs.joinpath(path, name))
        end
        await(a_rmdir(path))
    else
        await(a_unlink(path))
    end
end

-- Async analogue of move(). Even a same-filesystem rename goes through the
-- async API: it is normally instant, but a stalled syscall (a network mount, a
-- macOS privacy consultation on e.g. ~/.Trash) must not block the main loop.
-- Returns a pending buffer rename to apply on the main loop, mirroring move()'s
-- buffer.rename_buffers call -- which can't run here because this executes in a
-- libuv "fast" callback context.
---@param src string
---@param dest string
---@param progress DoraPasteProgress
---@return {src: string, dest: string}?
local function move_a(src, dest, progress)
    local src_is_dir = M.is_dir(src)
    -- A raw yield instead of await: an EXDEV failure is expected (the rename
    -- crossed filesystems) and falls back to copy+delete rather than erroring.
    local err = coroutine.yield(a_rename(src, dest))
    if err then
        if not vim.startswith(err, 'EXDEV') then
            error(err, 0)
        end
        copy_entry_a(src, dest, progress)
        rm_a(src)
    end
    if not src_is_dir then
        return {src = src, dest = dest}
    end
end

-- Asynchronously copy/move each op into `dest_dir`, mimicking `cp -R` / `mv`
-- exactly as M.copy_or_move does but off the main loop. `progress` is mutated
-- in place as work proceeds so callers can render a live indicator. With
-- `overwrite` a conflicting destination is replaced; otherwise the paste keeps
-- both files by landing beside it under a free name (report.txt -> report(1).txt).
---@param ops {is_move: boolean, src: string}[]
---@param dest_dir string
---@param cwd string
---@param progress DoraPasteProgress
---@param overwrite boolean Replace existing destinations instead of keeping both
---@param on_done fun(ok: boolean, result: string)
function M.paste_async(ops, dest_dir, cwd, progress, overwrite, on_done)
    run(function()
        local first_dest
        local buffer_renames = {}
        for _, op in ipairs(ops) do
            -- Unlike the general copy/move helper, paste permits resolving to
            -- the source itself. Keep-both gives it a free sibling name; an
            -- overwrite of the exact same object is a safe no-op.
            local dest = resolve_copy_or_move_dest(op.src, dest_dir, cwd, true)
            local dest_is_src = M.same_file(op.src, dest)
            if M.exists(dest) then
                if dest_is_src then
                    if not overwrite then
                        dest = M.nonclobber_dest(dest)
                    end
                elseif overwrite then
                    -- Replace an existing destination when a directory is
                    -- involved so the paste overwrites instead of erroring on
                    -- mkdir/rename, mirroring M.copy_or_move. A file replacing a
                    -- file is overwritten in place by copyfile/rename.
                    if M.is_dir(op.src) or M.is_dir(dest) then
                        rm_a(dest)
                    end
                else
                    -- Keep both: paste beside the existing entry under a free name.
                    dest = M.nonclobber_dest(dest)
                end
            end
            first_dest = first_dest or dest
            if not (dest_is_src and overwrite) then
                if op.is_move then
                    local rename = move_a(op.src, dest, progress)
                    if rename then
                        buffer_renames[#buffer_renames + 1] = rename
                    end
                else
                    copy_entry_a(op.src, dest, progress)
                end
            end
        end
        return first_dest, buffer_renames
    end, function(ok, result, buffer_renames)
        -- libuv callbacks run in a "fast" context; defer to a normal one so the
        -- completion handler and util.rename_buffers can touch the editor.
        vim.schedule(function()
            if ok then
                for _, rename in ipairs(buffer_renames) do
                    buffer.rename_buffers(rename.src, rename.dest)
                end
            end
            on_done(ok, result)
        end)
    end)
end

-- The results of a remove_async batch, mutated in place as paths complete so a
-- mid-batch failure still reports the entries that were removed.
---@class DoraRemoveResults
---@field removed string[] Paths no longer at their original location
---@field undo_batch {original: string, trashed: string}[] Trash entries, for M.untrash

-- Asynchronously trash or permanently delete each path -- the removal analogue
-- of paste_async. The work runs through libuv's async fs API so a slow
-- filesystem (a network mount, a macOS privacy consultation, a large recursive
-- delete) doesn't freeze the editor.
---@param paths string[]
---@param mode 'trash'|'delete'
---@param results DoraRemoveResults
---@param on_done fun(ok: boolean, err?: string)
function M.remove_async(paths, mode, results, on_done)
    -- Collected outside the coroutine so buffers editing files trashed before a
    -- mid-batch failure still follow them into the trash.
    local buffer_renames = {}
    run(function()
        local dest_dir
        if mode == 'trash' then
            local dir, err = trash_dir()
            if not dir then
                error(err, 0)
            end
            -- Before the first await, so still on the main loop where vim.fn
            -- is allowed.
            assert(vim.fn.mkdir(dir, 'p') == 1)
            dest_dir = dir
        end
        local progress = {files = 0, bytes = 0}
        for _, path in ipairs(paths) do
            assert(M.exists(path), ("%s doesn't exist"):format(path))
            if mode == 'trash' then
                local dest = M.nonclobber_dest(vim.fs.joinpath(dest_dir, M.basename(path)))
                local rename = move_a(path, dest, progress)
                if rename then
                    buffer_renames[#buffer_renames+1] = rename
                end
                results.undo_batch[#results.undo_batch+1] = {original = path, trashed = dest}
            else
                rm_a(path)
            end
            results.removed[#results.removed+1] = path
        end
    end, function(ok, err)
        -- libuv callbacks run in a "fast" context; defer to a normal one so the
        -- completion handler and buffer.rename_buffers can touch the editor.
        vim.schedule(function()
            for _, rename in ipairs(buffer_renames) do
                buffer.rename_buffers(rename.src, rename.dest)
            end
            on_done(ok, err)
        end)
    end)
end

return M
