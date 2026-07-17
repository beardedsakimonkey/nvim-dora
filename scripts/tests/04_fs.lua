-- fs helpers: path validation and normalization, nonclobber names, trash and untrash.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/04_fs.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local config = h.config
local fs = h.fs
local prompt = h.prompt
local api = h.api
local store = h.store
local cwd = h.cwd
local assert_eq = h.assert_eq
local assert_match = h.assert_match
local touch = h.touch
local lines = h.lines
local set_cursor_line = h.set_cursor_line
local current_line = h.current_line
local find_line_index = h.find_line_index

assert_match(fs.validate_create('x-new-file', cwd), 'x%-new%-file$')
assert_match(fs.validate_create('x-new-dir/', cwd), 'x%-new%-dir/$')
assert_match(fs.validate_create('x-new-parent/x-new-file', cwd), 'x%-new%-parent/x%-new%-file$')
assert(not pcall(fs.validate_create, '/tmp/x', cwd), 'create paths should stay relative')
assert_match(fs.validate_rename('renamed.txt', cwd .. '/old.txt'), 'renamed%.txt$')
assert(not pcall(fs.validate_rename, '', cwd .. '/old.txt'), 'empty rename filenames should be rejected')
assert(not pcall(fs.validate_rename, 'nested/renamed.txt', cwd .. '/old.txt'), 'rename should reject directory separators')
assert(not pcall(fs.validate_rename, 'old.txt', cwd .. '/old.txt'), 'rename should reject unchanged filenames')
assert_match(fs.resolve_copy_or_move_dest(cwd, '/tmp', cwd), '/tmp/[^/]+$')
assert_eq(fs.normalize_path('./foo/../bar', cwd), vim.fs.joinpath(cwd, 'bar'),
    'normalize_path should resolve relative dot components')
assert_eq(fs.parent_dir('/'), '/', 'parent_dir should not go above root')
assert_eq(fs.parent_dir('/tmp'), '/', 'parent_dir should keep root for top-level paths')
assert_eq(fs.get_parent_dir('/tmp'), '/', 'get_parent_dir should allow top-level paths')
assert_eq(fs.parent_dir('/tmp/foo/'), '/tmp', 'parent_dir should ignore a trailing separator')
assert_eq(fs.basename('/tmp/foo/'), 'foo', 'basename should ignore a trailing separator')
assert_eq(fs.strip_trailing_sep('/tmp/foo/'), '/tmp/foo', 'strip_trailing_sep should trim one or more trailing separators')

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))

    fs.create_file(tmp .. '/foo/bar.txt')
    assert(fs.exists(tmp .. '/foo/bar.txt'), 'create_file should create missing parent directories')
    assert(fs.is_dir(tmp .. '/foo'), 'create_file should create the parent directory')

    fs.create_dir(tmp .. '/alpha/beta/')
    assert(fs.is_dir(tmp .. '/alpha/beta'), 'create_dir should create missing parent directories')

    touch(tmp .. '/blocked')
    assert(not pcall(fs.validate_create, 'blocked/child.txt', tmp), 'create should reject paths below files')

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/target', tonumber('755', 8)))
    touch(tmp .. '/target/file.txt')
    assert(vim.loop.fs_symlink(tmp .. '/target', tmp .. '/link'))

    fs.delete(tmp .. '/link')
    assert(fs.is_dir(tmp .. '/target'), 'delete should not follow directory symlinks')
    assert(not fs.exists(tmp .. '/link'), 'delete should remove directory symlinks')

    fs.delete(tmp .. '/target')
    assert(not fs.exists(tmp .. '/target'), 'delete should recursively remove directories')
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local old_home = vim.env.HOME
    local old_data_home = vim.env.XDG_DATA_HOME
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/home', tonumber('755', 8)))
    vim.env.HOME = tmp .. '/home'
    vim.env.XDG_DATA_HOME = tmp .. '/data'
    local trash_dir
    if vim.loop.os_uname().sysname == 'Darwin' then
        trash_dir = tmp .. '/home/.Trash'
    else
        trash_dir = tmp .. '/data/Trash/files'
    end
    assert(vim.fn.mkdir(trash_dir, 'p') == 1)
    touch(tmp .. '/foo')
    touch(trash_dir .. '/foo')
    assert(vim.loop.fs_mkdir(trash_dir .. '/bar', tonumber('755', 8)))
    touch(tmp .. '/bar')

    local results = {removed = {}, undo_batch = {}}
    local done
    fs.remove_async({tmp .. '/foo', tmp .. '/bar'}, 'trash', results, function(ok, err)
        done = ok or err
    end)
    assert(vim.wait(5000, function() return done ~= nil end), 'trash should finish')
    assert_eq(done, true)
    assert(not fs.exists(tmp .. '/foo'), 'trash should remove source files')
    assert(not fs.exists(tmp .. '/bar'), 'trash should remove source files when destination name collides with a directory')
    assert(fs.exists(trash_dir .. '/foo'), 'trash should preserve existing trash entries')
    assert(fs.exists(trash_dir .. '/foo(1)'), 'trash should suffix colliding file names')
    assert(fs.exists(trash_dir .. '/bar'), 'trash should preserve existing trash directories')
    assert(fs.exists(trash_dir .. '/bar(1)'), 'trash should suffix colliding directory names')
    assert_eq(#results.removed, 2, 'trash should report each removed path')
    assert_eq(results.undo_batch[1].trashed, trash_dir .. '/foo(1)', 'trash should pair each file with its trash entry')
    assert_eq(results.undo_batch[2].trashed, trash_dir .. '/bar(1)', 'trash should pair each directory with its trash entry')

    vim.env.HOME = old_home
    vim.env.XDG_DATA_HOME = old_data_home
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/nvim-dora', tonumber('755', 8)))
    touch(tmp .. '/nvim-dora/existing.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    -- The cursor stays on the top-level nvim-dora/ row, so the typed path
    -- resolves beside it, directly in the cwd.
    set_cursor_line('nvim%-dora/$')
    api.fold_out()
    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.width, 32, 'create prompt should match the default delete window width')
        local path = opts.validate('foo/bar/a')
        cb('foo/bar/a', path)
    end
    api.add()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/foo/bar/a'), 'create should create a nested file path')
    assert(vim.tbl_contains(lines(), 'foo/'), 'create should render the new top-level parent')
    assert(vim.tbl_contains(lines(), '└── bar/'), 'create should expand the parents above the new file')
    assert(vim.tbl_contains(lines(), '    └── a'), 'create should reveal the created nested file')
    assert_match(current_line(), 'a$', 'create should move cursor to the created nested file')
    local row = store.get().rows[vim.api.nvim_win_get_cursor(0)[1]]
    assert_eq(row.path, fs.realpath(tmp) .. '/foo/bar/a')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/nvim-dora', tonumber('755', 8)))
    touch(tmp .. '/nvim-dora/existing.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_line('nvim%-dora/$')
    api.fold_out()
    set_cursor_line('existing%.txt$')
    local old_input = prompt.input
    local old_icons = config.icons
    config.icons = false
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, nil, 'create should not prefill the hovered file parent path')
        assert_eq(opts.icon, nil, 'create prompt should not pass an icon when icons are disabled')
        local input = 'foo/bar'
        cb(input, opts.validate(input))
    end
    api.add()
    prompt.input = old_input
    config.icons = old_icons

    assert(fs.exists(tmp .. '/nvim-dora/foo/bar'), 'create should create nested paths inside expanded directories')
    assert(vim.tbl_contains(lines(), '│   └── bar'), 'create should expand the parent under expanded directories')
    assert_match(current_line(), 'bar$', 'create should move cursor to the created nested file')
    local row = store.get().rows[vim.api.nvim_win_get_cursor(0)[1]]
    assert_eq(row.path, fs.realpath(tmp) .. '/nvim-dora/foo/bar')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local old_input = prompt.input
    local old_icons = config.icons
    local old_mini_icons = _G.MiniIcons
    config.icons = 'mini.icons'
    _G.MiniIcons = {
        get = function(category, path)
            return '[' .. category .. ':' .. path .. ']',
                category == 'directory' and 'DoraDirectory' or 'DoraIcon'
        end,
    }
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(type(opts.icon), 'function', 'create prompt should pass a live icon when icons are enabled')
        local icon, hl = opts.icon('foo/bar/a')
        assert_eq(icon, '[file:a]', 'create prompt icon should look up the typed basename as a file')
        assert_eq(hl, 'DoraIcon')
        icon, hl = opts.icon('foo/bar/')
        assert_eq(icon, '[directory:bar]', 'a trailing slash should look up a directory icon')
        assert_eq(hl, 'DoraDirectory')
        icon = opts.icon('')
        assert_eq(icon, '[file:]', 'an empty input should fall back to a generic file icon')
        cb(nil)
    end
    api.add()
    prompt.input = old_input
    config.icons = old_icons
    _G.MiniIcons = old_mini_icons

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- On macOS libuv registers an fs-event handle synchronously, then rebuilds
-- its process-wide FSEventStream on a separate CF thread. Produce probe
-- changes until one is delivered so watcher assertions don't race startup.
local function wait_for_watch_delivery(is_delivered, probe_prefix)
    local probe_count = 0
    return vim.wait(5000, function()
        if is_delivered() then
            return true
        end
        probe_count = probe_count + 1
        touch(probe_prefix .. probe_count)
        return false
    end, 100)
end

-- watch_tree reports changes anywhere under the root as absolute paths and
-- keeps watching after delivering a batch.
if fs.HAS_RECURSIVE_WATCH then
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/a', tonumber('755', 8)))
    local root = fs.realpath(tmp)

    local got = {}
    local delivered = false
    local cancel = assert(fs.watch_tree(root, function(paths)
        delivered = true
        vim.list_extend(got, paths)
    end))
    assert(wait_for_watch_delivery(function()
        return delivered
    end, tmp .. '/a/.watch-ready-'), 'watch_tree should start delivering changes')
    got = {}

    touch(tmp .. '/a/nested.txt')
    local nested_path = root .. '/a/nested.txt'
    assert(vim.wait(5000, function()
        return vim.tbl_contains(got, nested_path)
    end), 'watch_tree should report nested changes with absolute paths; got ' .. vim.inspect(got))

    touch(tmp .. '/a/second.txt')
    assert(vim.wait(5000, function()
        return vim.tbl_contains(got, root .. '/a/second.txt')
    end), 'watch_tree should keep reporting after the first batch')

    cancel()
    cancel()  -- cancelling twice is harmless
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- An external change inside an expanded directory reaches the session's
-- watcher, drops the cached listing, and re-renders with the new file.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))
    touch(tmp .. '/sub/before.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_line('sub/$')
    api.fold_out()
    assert(find_line_index(lines(), 'before%.txt'), 'expanded dir should list its files')

    assert(wait_for_watch_delivery(function()
        return find_line_index(lines(), 'watch%-ready%-') ~= nil
    end, tmp .. '/sub/watch-ready-'), 'session watcher should start delivering changes')

    touch(tmp .. '/sub/created-outside.txt')
    assert(vim.wait(5000, function()
        return find_line_index(lines(), 'created%-outside%.txt') ~= nil
    end), 'external create should refresh the expanded listing')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end
