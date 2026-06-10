local util = require'dora.util'
local uv = vim.uv

local M = {}

---@param path string
---@return boolean
local function is_absolute(path)
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
        util.rename_buffers(src, dest)
    end
end

-- NOTE: Uses lstat so that dangling symlinks are considered to exist
---@param path string
---@return boolean
local function exists(path)
    return uv.fs_lstat(path) ~= nil
end

---@param path string
---@return string
local function parent_dir(path)
    local parent = assert(vim.fs.dirname(M.strip_trailing_sep(path)))
    return parent == '.' and '' or parent
end

---@param dir string
---@param basename string
---@return string
local function unused_child_path(dir, basename)
    local path = vim.fs.joinpath(dir, basename)
    if not exists(path) then
        return path
    end
    for i = 1, 1000 do
        path = vim.fs.joinpath(dir, basename .. ' ' .. i)
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
    path = util.trim_start(path)
    assert(path ~= '', 'Empty path')
    path = vim.fs.normalize(path)
    if is_absolute(path) then
        return path
    end
    return vim.fs.normalize(vim.fs.joinpath(cwd, path), {expand_env = false})
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
        local full_path = vim.fs.joinpath(path, basename)
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
    return assert(vim.fs.basename(M.strip_trailing_sep(path)))
end

---@param path string
function M.delete(path)
    vim.fs.rm(path, {recursive = M.is_dir(path)})
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
        trash_dir = vim.fs.joinpath(assert(os.getenv'HOME'), '.Trash')
    else
        local data_home = os.getenv'XDG_DATA_HOME' or vim.fs.joinpath(assert(os.getenv'HOME'), '.local/share')
        trash_dir = vim.fs.joinpath(data_home, 'Trash/files')
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
    local path = vim.fs.joinpath(cwd, input)
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
    local path = vim.fs.joinpath(parent, input)
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
        dest = vim.fs.joinpath(dest, M.basename(src))
        assert(src ~= dest, '`src` equals `dest`')
    end
    assert(not vim.startswith(dest, src .. util.sep),
        ('Cannot copy or move %q into itself'):format(src))
    return dest
end

-- Mimics the semantics of `mv` / `cp -R`
---@param is_move boolean
---@param src string
---@param dest string
---@param cwd string
---@return string dest
function M.copy_or_move(is_move, src, dest, cwd)
    dest = M.resolve_copy_or_move_dest(src, dest, cwd)
    -- Note: Moving from a file to a file should overwrite the file
    local op = is_move and move or copy_any
    op(src, dest)
    return dest
end

return M
