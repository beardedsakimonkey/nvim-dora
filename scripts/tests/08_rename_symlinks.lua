-- Directory rename preserving expanded state, and symlink target display.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/08_rename_symlinks.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local descriptions = h.actions.descriptions
local fs = h.fs
local config = h.config
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
local set_cursor_pos = h.set_cursor_pos

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir/child', tonumber('755', 8)))
    touch(tmp .. '/dir/child/file.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_pos('dir')
    api.fold_out()
    set_cursor_line('child/$')
    api.fold_out()
    set_cursor_pos('dir')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, 'dir', 'rename should not append a slash for directories')
        cb('renamed', opts.validate('renamed'))
    end
    api.rename()
    prompt.input = old_input

    assert(not fs.exists(tmp .. '/dir'), 'rename should remove the old directory')
    assert(fs.exists(tmp .. '/renamed/child/file.txt'), 'rename should move the directory subtree')
    assert(state.expanded_dirs[state.cwd .. '/renamed'], 'rename should preserve expanded directory state')
    assert(state.expanded_dirs[state.cwd .. '/renamed/child'], 'rename should preserve expanded descendant state')
    assert(find_line_index(lines(), 'file%.txt$'), 'rename should render preserved expanded descendants')
    assert_match(current_line(), 'renamed/$', 'rename should move cursor to the renamed directory')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/targets', tonumber('755', 8)))
    touch(tmp .. '/targets/file.txt')
    local real_tmp = fs.realpath(tmp)
    assert(vim.loop.fs_symlink(real_tmp .. '/targets/file.txt', tmp .. '/absolute-link'))
    assert(vim.loop.fs_symlink('./targets/file.txt', tmp .. '/relative-link'))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local marks = vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    local has_absolute_link = false ---@type boolean?
    local has_relative_link = false ---@type boolean?
    for _, mark in ipairs(marks) do
        local details = mark[4]
        ---@cast details -nil  -- always present with {details = true}
        local virt_text = details.virt_text
        has_absolute_link = has_absolute_link
            or virt_text and virt_text[1] and virt_text[1][1] == '@ → targets/file.txt'
                and details.hl_mode == 'combine'
        has_relative_link = has_relative_link
            or virt_text and virt_text[1] and virt_text[1][1] == '@ → ./targets/file.txt'
    end
    assert(has_absolute_link, 'absolute symlink targets should render relative to the symlink')
    assert(has_relative_link, 'relative symlink targets should remain unchanged')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/target-dir', tonumber('755', 8)))
    touch(tmp .. '/target-dir/inside.txt')
    assert(vim.loop.fs_symlink(tmp .. '/target-dir', tmp .. '/dir-link'))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    assert_eq(vim.fn.maparg('gf', 'n'), '', 'gf should remain available for users')

    set_cursor_line('dir%-link$')
    api.open()
    assert_eq(state.cwd, fs.realpath(tmp .. '/target-dir'), 'open should navigate to symlinked directories')
    assert(vim.tbl_contains(lines(), 'inside.txt'), 'open should render symlinked directory contents')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/target.txt')
    assert(vim.loop.fs_symlink(tmp .. '/target.txt', tmp .. '/file-link'))
    local swap_dir = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(swap_dir, tonumber('755', 8)))
    local old_directory = vim.o.directory
    vim.o.directory = fs.realpath(swap_dir) .. '//'

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local dora_buf = vim.api.nvim_get_current_buf()
    set_cursor_line('file%-link$')
    api.open()
    assert_eq(vim.api.nvim_buf_get_name(0), fs.realpath(tmp .. '/target.txt'), 'open should edit symlinked files')
    assert_eq(vim.fn.bufexists(dora_buf), 0, 'opening a symlinked file should close Dora')

    vim.cmd('bdelete!')
    vim.o.directory = old_directory
    assert_eq(vim.fn.delete(swap_dir, 'rf'), 0)
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    touch(tmp .. '/dir/child.txt')
    touch(tmp .. '/a.txt')
    touch(tmp .. '/b.txt')
    local root = fs.realpath(tmp)

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local dora_buf = state.buf
    set_cursor_line('^dir/$')
    api.fold_out()
    set_cursor_line('^dir/$')
    for lhs, action in pairs({
        l = 'open',
        s = 'open_split',
        v = 'open_vsplit',
        t = 'open_tab',
        ['<C-s>'] = 'open_split_stay',
        ['<C-v>'] = 'open_vsplit_stay',
        ['<C-t>'] = 'open_tab_stay',
    }) do
        assert_eq(vim.fn.maparg(lhs, 'x', false, true).desc, descriptions[action])
    end
    vim.api.nvim_feedkeys('V3jl', 'xt', false)

    assert_eq(vim.api.nvim_get_mode().mode, 'n', 'visual open should return to normal mode')
    assert_eq(vim.api.nvim_buf_get_name(0), root .. '/b.txt',
        'visual open should leave the last selected file current')
    assert(vim.fn.bufexists(root .. '/dir/child.txt') ~= 0,
        'visual open should load nested selected files')
    assert(vim.fn.bufexists(root .. '/a.txt') ~= 0,
        'visual open should load every selected file')
    assert_eq(vim.fn.bufexists(root .. '/dir'), 0,
        'visual open should ignore selected directories')
    assert_eq(vim.fn.bufexists(dora_buf), 0, 'visual open should close Dora')

    for _, path in ipairs({'dir/child.txt', 'a.txt', 'b.txt'}) do
        pcall(vim.cmd --[[@as function]], 'bdelete! ' .. vim.fn.fnameescape(root .. '/' .. path))
    end
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- The create_symlink prompt always creates a link, so it carries the fixed
-- symlink icon when icons are enabled and none when they are disabled.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/target.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_line('target%.txt$')

    local old_input = prompt.input
    local old_icons = config.icons
    local captured_icon, captured_hl
    -- Cancel rather than confirm: confirming re-renders the tree, and with
    -- icons enabled that would consult whatever provider stub an earlier
    -- test left cached in the icons module.
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        captured_icon, captured_hl = opts.icon, opts.icon_hl
        cb(nil)
    end
    config.icons = true
    api.create_symlink()
    config.icons = old_icons
    assert_eq(captured_icon, '', 'the symlink prompt should hardcode the symlink icon')
    assert_eq(captured_hl, 'DoraSymlink', 'the symlink prompt icon should use the symlink highlight')

    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        captured_icon, captured_hl = opts.icon, opts.icon_hl
        cb('new-link', opts.validate('new-link'))
    end
    api.create_symlink()
    prompt.input = old_input
    assert_eq(captured_icon, nil, 'disabled icons should leave the symlink prompt icon unset')
    assert_eq(captured_hl, nil, 'disabled icons should leave the symlink prompt icon highlight unset')
    local stat = vim.loop.fs_lstat(state.cwd .. '/new-link')
    assert(stat and stat.type == 'link', 'confirming the prompt should create the symlink')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end
