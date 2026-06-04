local util = require'dora.util'
local uv = vim.loop

local M = {}

---@param src string
---@param dest string
local function move(src, dest)
    assert(uv.fs_rename(src, dest))
    if not M.is_dir(src) then
        util.rename_buffers(src, dest)
    end
end

---@param src string
---@param dest string
local function copy_file(src, dest)
    assert(uv.fs_copyfile(src, dest))
end

---@param src string
---@param dest string
local function copy_dir(src, dest)
    local stat = assert(uv.fs_stat(src))
    assert(uv.fs_mkdir(dest, stat.mode))
    for name, type in vim.fs.dir(src) do
        local copy = type == 'directory' and copy_dir or copy_file
        copy(util.join_path(src, name), util.join_path(dest, name))
    end
end

---@param path string
---@return boolean
local function exists(path)
    return uv.fs_access(path, '') == true
end

---@param path string
---@return string
local function parent_dir(path)
    while #path > 1 and vim.endswith(path, util.sep) do
        path = path:sub(1, -2)
    end
    if path == util.sep then
        return util.sep
    end
    for i = #path, 1, -1 do
        if path:sub(i, i) == util.sep then
            return i == 1 and util.sep or path:sub(1, i - 1)
        end
    end
    return ''
end

---@param dir string
---@param basename string
---@return string
local function unused_child_path(dir, basename)
    local path = util.join_path(dir, basename)
    if not exists(path) then
        return path
    end
    for i = 1, 1000 do
        path = util.join_path(dir, basename .. ' ' .. i)
        if not exists(path) then
            return path
        end
    end
    error('Could not find an unused trash destination for ' .. basename)
end

---@param path string
---@return boolean
function M.exists(path)
    return exists(path)
end

---@param path string
---@param cwd string
---@return string
function M.normalize_path(path, cwd)
    assert(path, 'Empty path')
    path = util.trim_start(path)
    assert(path ~= '', 'Empty path')
    path = path:gsub('^~', os.getenv'HOME' or '')
    return path:sub(1, 1) == '/' and path or util.join_path(cwd, path)
end

---@param path string
---@return string
function M.realpath(path)
    return assert(uv.fs_realpath(path))
end

---@param path string
---@return string
function M.strip_trailing_sep(path)
    while #path > 1 and vim.endswith(path, util.sep) do
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

---@param path string
---@return DoraFile[]
function M.list(path)
    local ret = {}
    for basename, file_type in vim.fs.dir(path) do
        local full_path = util.join_path(path, basename)
        table.insert(ret, M.file_from_path(full_path, file_type))
    end
    return ret
end

---@param dir string
---@return string
function M.get_parent_dir(dir)
    local parent = parent_dir(dir)
    assert(exists(parent))
    return parent
end

---@param path string
---@return string
function M.parent_dir(path)
    return parent_dir(path)
end

---@param path string
---@return string
function M.basename(path)
    if vim.endswith(path, util.sep) then  -- strip trailing slash
        path = path:sub(1, -2)
    end
    local parts = vim.split(path, util.sep)
    return parts[#parts]
end

---@param path string
function M.delete(path)
    local is_symlink = uv.fs_readlink(path) ~= nil
    local flags = (M.is_dir(path) and not is_symlink) and 'rf' or ''
    local ret = vim.fn.delete(path, flags)
    assert(ret == 0)
end

---@param path string
---@return boolean?
function M.trash(path)
    assert(exists(path), ("%s doesn't exist"):format(path))
    local sysname = uv.os_uname().sysname
    local trash_dir
    if sysname:match('Windows') then
        util.err('Trash is not currently supported on Windows')
        return
    elseif sysname == 'Darwin' then
        trash_dir = util.join_path(assert(os.getenv'HOME'), '.Trash')
    else
        local data_home = os.getenv'XDG_DATA_HOME' or util.join_path(assert(os.getenv'HOME'), '.local/share')
        trash_dir = util.join_path(data_home, 'Trash/files')
    end
    assert(vim.fn.mkdir(trash_dir, 'p') == 1)
    move(path, unused_child_path(trash_dir, M.basename(path)))
end

---@param path string
function M.create_dir(path)
    assert(not exists(path), ('%q already exists'):format(path))
    -- 755 = RWX for owner, RX for group/other
    assert(vim.fn.mkdir(path, 'p') == 1)
end

---@param path string
function M.create_file(path)
    assert(not exists(path), ('%q already exists'):format(path))
    local parent = parent_dir(path)
    assert(vim.fn.mkdir(parent, 'p') == 1)
    -- 644 = RW for owner, R for group/other
    local fd = assert(uv.fs_open(path, 'w', tonumber('644', 8)))
    assert(uv.fs_close(fd))
end

---@param input string
---@param cwd string
---@return string path
function M.validate_create(input, cwd)
    assert(input, 'Empty path')
    input = util.trim_start(input)
    assert(input ~= '', 'Empty path')
    assert(input:sub(1, 1) ~= util.sep, 'Create paths must be relative')
    local path = util.join_path(cwd, input)
    assert(not exists(path), ('%q already exists'):format(path))
    local path_for_parent = vim.endswith(path, util.sep) and path:sub(1, -2) or path
    local parent = parent_dir(path_for_parent)
    while not exists(parent) do
        parent = parent_dir(parent)
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
    assert(not input:find(util.sep, 1, true), 'Rename cannot move files between directories')
    local parent = parent_dir(src)
    local path = util.join_path(parent, input)
    assert(src ~= path, '`src` equals `dest`')
    assert(not exists(path), ('%q already exists'):format(path))
    return path
end

---@param src string
---@param dest string
function M.rename(src, dest)
    assert(exists(src), ("%s doesn't exist"):format(src))
    assert(src ~= dest, '`src` equals `dest`')
    local parent = parent_dir(dest)
    assert(exists(parent), ('%q does not exist'):format(parent))
    assert(M.is_dir(parent), ('%q is not a directory'):format(parent))
    assert(not exists(dest), ('%q already exists'):format(dest))
    move(src, dest)
end

---@param src string
---@param dest string
---@param cwd string
---@return string dest
function M.resolve_copy_or_move_dest(src, dest, cwd)
    assert(exists(src), ("%s doesn't exist"):format(src))
    dest = M.normalize_path(dest, cwd)
    assert(src ~= dest, '`src` equals `dest`')
    if M.is_dir(dest) then
        dest = util.join_path(dest, M.basename(src))
    end
    return dest
end

-- Mimics the semantics of `mv` / `cp -R`
---@param is_move boolean
---@param src string
---@param dest string
---@param cwd string
function M.copy_or_move(is_move, src, dest, cwd)
    dest = M.resolve_copy_or_move_dest(src, dest, cwd)
    local op = is_move and move or M.is_dir(src) and copy_dir or copy_file
    -- Note: Moving from a file to a file should overwrite the file
    op(src, dest)
end

return M
