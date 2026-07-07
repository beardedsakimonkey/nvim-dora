local uv = vim.uv

local api = require'dora.api'
local fs = require'dora.fs'
local store = require'dora.store'

assert(uv.os_uname().sysname:match('Windows'), 'Windows smoke suite must run on Windows')

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(('%sexpected %s, got %s'):format(
            msg and msg .. ': ' or '', vim.inspect(expected), vim.inspect(actual)))
    end
end

local function touch(path, contents)
    local fd = assert(uv.fs_open(path, 'w', tonumber('644', 8)))
    if contents then
        assert(uv.fs_write(fd, contents, 0))
    end
    assert(uv.fs_close(fd))
end

-- Paste copies asynchronously; pump the loop until it finishes before asserting.
local function wait_for_paste()
    assert(vim.wait(5000, function()
        return not store.get().paste_in_progress
    end), 'paste did not finish')
end

-- Find a row by its path relative to the listing root, so that a name
-- appearing in several expanded directories can't match the wrong row.
local function row_line(relative_path)
    local state = store.get()
    local target = vim.fs.joinpath(state.cwd, relative_path)
    for i, row in ipairs(state.rows) do
        if row.path == target then
            return i
        end
    end
    error('could not find row ' .. relative_path)
end

local function set_cursor(relative_path)
    vim.api.nvim_win_set_cursor(0, {row_line(relative_path), 0})
end

local tmp = vim.fn.tempname()
assert(uv.fs_mkdir(tmp, tonumber('755', 8)))
local sub = vim.fs.joinpath(tmp, 'sub')
local dest = vim.fs.joinpath(tmp, 'dest')
assert(uv.fs_mkdir(sub, tonumber('755', 8)))
assert(uv.fs_mkdir(dest, tonumber('755', 8)))
touch(vim.fs.joinpath(tmp, 'alpha.txt'), 'alpha')
touch(vim.fs.joinpath(sub, 'child.txt'), 'child')

vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
assert(vim.api.nvim_buf_get_var(0, 'is_dora'), 'Dora buffer should be identified')
assert(row_line('alpha.txt'), 'Dora should render files')
set_cursor('sub')
api.fold_out()
assert(row_line('sub/child.txt'), 'Dora should expand directories')

set_cursor('alpha.txt')
api.toggle_copy()
set_cursor('dest')
api.paste_under()
vim.api.nvim_feedkeys('y', 'xt', false)
wait_for_paste()
assert(fs.exists(vim.fs.joinpath(dest, 'alpha.txt')), 'paste should copy files on Windows')
api.quit()

local created = vim.fs.joinpath(tmp, 'nested', 'created.txt')
fs.create_file(created)
assert(fs.exists(created), 'create_file should create parent directories on Windows')
local renamed = vim.fs.joinpath(tmp, 'nested', 'renamed.txt')
fs.rename(created, renamed)
assert(fs.exists(renamed) and not fs.exists(created), 'rename should move files on Windows')
fs.delete(renamed)
assert(not fs.exists(renamed), 'delete should remove files on Windows')

local absolute_ok = pcall(fs.validate_create, tmp, tmp)
assert(not absolute_ok, 'create should reject absolute Windows paths')
assert(not pcall(fs.validate_rename, 'nested/file.txt', vim.fs.joinpath(tmp, 'old.txt')),
    'rename should reject forward-slash paths on Windows')
assert(not pcall(fs.validate_rename, 'nested\\file.txt', vim.fs.joinpath(tmp, 'old.txt')),
    'rename should reject backslash paths on Windows')

local root = fs.realpath(tmp)
while not fs.is_root(root) do
    root = fs.parent_dir(root)
end
assert_eq(fs.parent_dir(root), root, 'parent_dir should not go above a Windows drive root')
assert_eq(fs.strip_trailing_sep(root), root, 'strip_trailing_sep should preserve a Windows drive root')
assert_eq(
    fs.display_symlink_target('C:\\project\\links\\link', 'C:\\project\\targets\\file.txt'),
    'C:\\project\\targets\\file.txt',
    'Windows symlink targets should remain unchanged'
)

local trash_path = vim.fs.joinpath(tmp, 'trash.txt')
touch(trash_path)
local trash_err
fs.remove_async({trash_path}, 'trash', {removed = {}, undo_batch = {}}, function(ok, err)
    trash_err = not ok and err or 'unexpected success'
end)
assert(vim.wait(5000, function() return trash_err ~= nil end), 'trash should finish')
assert(fs.exists(trash_path), 'unsupported trash should leave the file in place')
assert(trash_err:find('not currently supported on Windows', 1, true) ~= nil,
    'trash should explain that Windows is unsupported')

vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
set_cursor('alpha.txt')
api.open()
assert_eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), fs.realpath(vim.fs.joinpath(tmp, 'alpha.txt')),
    'open should edit selected files on Windows')
vim.cmd'bdelete!'

assert_eq(vim.fn.delete(tmp, 'rf'), 0)
print('Windows smoke ok\n')
