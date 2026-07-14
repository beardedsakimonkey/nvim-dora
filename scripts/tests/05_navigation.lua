-- Creating files/directories and navigating: nested creates, home/up, cursor anchors, hidden files, tree icons.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/05_navigation.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local bookmarks = h.bookmarks
local fs = h.fs
local config = h.config
local confirm_win = h.confirm_win
local prompt = h.prompt
local api = h.api
local store = h.store
local cwd = h.cwd
local assert_eq = h.assert_eq
local assert_match = h.assert_match
local touch = h.touch
local clear_persisted_view_state = h.clear_persisted_view_state
local lines = h.lines
local set_cursor_line = h.set_cursor_line
local current_line = h.current_line
local find_line_index = h.find_line_index
local set_cursor_pos = h.set_cursor_pos
local win_title = h.win_title
local has_high_priority_highlight = h.has_high_priority_highlight

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    local root = fs.realpath(tmp)

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local old_input = prompt.input

    -- Creating a nested directory expands the parents above it but leaves the
    -- lowest created directory collapsed.
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        local input = 'dir1/dir2/'
        cb(input, opts.validate(input))
    end
    api.add()

    assert(fs.is_dir(tmp .. '/dir1/dir2'), 'create should create the nested directory')
    assert_eq(store.get().expanded_dirs[root .. '/dir1'], true, 'create should expand the parent of a new directory')
    assert(not store.get().expanded_dirs[root .. '/dir1/dir2'], 'create should leave the lowest new directory collapsed')
    assert_match(current_line(), 'dir2/$', 'create should move cursor to the new directory')

    -- Creating a single top-level directory leaves it collapsed too.
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        local input = 'solo/'
        cb(input, opts.validate(input))
    end
    api.add()
    prompt.input = old_input

    assert(fs.is_dir(tmp .. '/solo'), 'create should create the top-level directory')
    assert(not store.get().expanded_dirs[root .. '/solo'], 'create should not expand a new top-level directory')
    assert_match(current_line(), 'solo/$', 'create should move cursor to the new top-level directory')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        local path = opts.validate('foo/bar/')
        cb('foo/bar/', path)
    end
    api.add()
    prompt.input = old_input

    assert(fs.is_dir(tmp .. '/foo/bar'), 'create should create nested directory paths')
    assert(vim.tbl_contains(lines(), '└── bar/'), 'create should expand newly created directory parents')
    assert_match(current_line(), 'bar/$', 'create should move cursor to the new directory')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local old_home = vim.env.HOME
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/home', tonumber('755', 8)))
    touch(tmp .. '/home/home-file.txt')
    touch(tmp .. '/other-file.txt')
    vim.env.HOME = tmp .. '/home'

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    api.home_dir()
    assert_eq(state.cwd, fs.realpath(tmp .. '/home'), 'home directory should navigate to $HOME')
    assert(vim.tbl_contains(lines(), 'home-file.txt'), 'home directory should render $HOME contents')

    api.quit()
    vim.env.HOME = old_home
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local old_home = vim.env.HOME
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/home', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/home/projects', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/home/projects/app', tonumber('755', 8)))
    touch(tmp .. '/home/home-file.txt')
    vim.env.HOME = tmp .. '/home'

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp .. '/home/projects/app'))
    local state = store.get()
    api.home_dir()
    assert_eq(state.cwd, fs.realpath(tmp .. '/home'), 'home directory should navigate to $HOME')
    assert_match(current_line(), 'projects/$', 'home directory should restore cursor to the top-level dir we came from')

    api.quit()
    vim.env.HOME = old_home
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/root', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/root/child', tonumber('755', 8)))
    touch(tmp .. '/root/child/existing.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('root')
    api.fold_out()
    set_cursor_line('child/$')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, 'root/', 'create should prefill the hovered directory parent path')
        local input = opts.initial_prompt .. 'file.txt'
        cb(input, opts.validate(input))
    end
    api.add()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/root/file.txt'), 'create should create beside the hovered directory')
    assert_match(current_line(), 'file%.txt$', 'cursor should move to the created sibling file')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/root', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/root/child', tonumber('755', 8)))
    touch(tmp .. '/root/child/existing.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('root')
    api.fold_out_recursive()
    set_cursor_line('existing%.txt$')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, 'root/child/', 'create should prefill the hovered file parent path')
        local input = opts.initial_prompt .. 'sibling.txt'
        cb(input, opts.validate(input))
    end
    api.add()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/root/child/sibling.txt'), 'create should create beside the hovered file')
    assert_match(current_line(), 'sibling%.txt$', 'cursor should move to the created sibling file')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    clear_persisted_view_state()
    vim.cmd('Dora ' .. vim.fn.fnameescape('/'))
    local state = store.get()
    local name = vim.api.nvim_buf_get_name(state.buf)

    api.up_dir()
    assert_eq(state.cwd, '/', 'up directory should no-op at root')
    assert_eq(vim.api.nvim_buf_get_name(state.buf), name, 'up directory should not rename the root buffer')
    assert_eq(state.bookmarks.previous_directory, nil, 'up directory at root should not update the previous-directory bookmark')

    api.quit()
end

do
    local parts = vim.tbl_filter(function(part) return part ~= '' end, vim.split(fs.realpath(cwd), '/', {plain=true}))
    assert(#parts >= 2, 'smoke cwd should have a top-level parent')
    local top_path = '/' .. parts[1]

    vim.cmd('Dora ' .. vim.fn.fnameescape(top_path))
    local state = store.get()
    api.up_dir()

    assert_eq(state.cwd, '/', 'up directory should navigate from a top-level directory to root')
    assert(state.expanded_dirs[top_path], 'up directory should preserve the top-level previous cwd expansion')
    assert_match(current_line(), vim.pesc(parts[1]) .. '/$', 'up directory should move cursor to the previous top-level cwd row')
    assert(find_line_index(lines(), vim.pesc(parts[2]) .. '/$'), 'up directory should keep top-level previous cwd children visible at root')

    api.quit()
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/beta', tonumber('755', 8)))
    touch(tmp .. '/alpha/duplicate.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('alpha')
    api.fold_out()
    set_cursor_pos('beta')
    api.fold_out()

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, nil, 'create should not prefill a root-level directory path')
        local input = 'duplicate.txt'
        cb(input, opts.validate(input))
    end
    api.add()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/duplicate.txt'), 'create should create beside the root-level directory')
    assert_match(current_line(), 'duplicate%.txt$', 'cursor should move to the newly created duplicate file')
    local row = store.get().rows[vim.api.nvim_win_get_cursor(0)[1]]
    assert_eq(row.path, store.get().cwd .. '/duplicate.txt')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/aaa', tonumber('755', 8)))
    touch(tmp .. '/init.lua')
    touch(tmp .. '/aaa/init.lua')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local root = store.get().cwd
    set_cursor_pos('aaa')
    api.fold_out()
    api.quit()

    vim.cmd('edit ' .. vim.fn.fnameescape(tmp .. '/init.lua'))
    vim.cmd('Dora')
    local state = store.get()
    local nested_visible = false
    for _, row in ipairs(state.rows) do
        if row.path == root .. '/aaa/init.lua' then
            nested_visible = true
            break
        end
    end
    assert(nested_visible, 'setup should show the duplicate filename from the expanded subdir')
    local cursor_row = state.rows[vim.api.nvim_win_get_cursor(0)[1]]
    assert_eq(cursor_row.path, root .. '/init.lua',
        'opening dora from a file should restore the cursor by full path when visible names duplicate')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/root', tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    assert_eq(vim.fn.maparg('A', 'n', false, true).desc, 'Add file under directory')
    set_cursor_pos('root')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, 'root/', 'create_under should prefill the hovered directory path')
        local input = opts.initial_prompt .. 'child.txt'
        cb(input, opts.validate(input))
    end
    api.add_under()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/root/child.txt'), 'create_under should create inside the hovered directory')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/secret', tonumber('755', 8)))
    touch(tmp .. '/secret/hidden.txt')
    assert(vim.loop.fs_chmod(tmp .. '/secret', tonumber('000', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('secret')
    api.fold_out()
    assert(find_line_index(lines(), '%(not permitted%)$'),
        'expanding an unreadable directory should show the not-permitted placeholder')
    assert(not find_line_index(lines(), 'hidden%.txt$'),
        'unreadable directory contents should not be listed')

    api.quit()
    assert(vim.loop.fs_chmod(tmp .. '/secret', tonumber('755', 8)))
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/root', tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('root')
    api.fold_out()
    set_cursor_line('%(empty%)$')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, 'root/', 'create on a placeholder should prefill its directory path')
        assert(opts.anchor, 'create on a placeholder should anchor the prompt to its row')
        assert_eq(opts.anchor.line, vim.api.nvim_win_get_cursor(0)[1])
        local input = opts.initial_prompt .. 'file.txt'
        cb(input, opts.validate(input))
    end
    api.add()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/root/file.txt'), 'create on a placeholder should create inside its directory')
    assert_match(current_line(), 'file%.txt$', 'cursor should move to the file created from a placeholder')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/anchor.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_pos('anchor.txt')
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = state.rows[cursor[1]]

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert(opts.anchor, 'create should anchor the prompt to the current row')
        assert_eq(opts.initial_prompt, nil, 'create should not prefill a root-level file path')
        assert_eq(opts.anchor.win, vim.api.nvim_get_current_win())
        assert_eq(opts.anchor.line, cursor[1])
        assert_eq(opts.anchor.col, row.name_start_col)
        cb(nil)
    end
    api.add()
    prompt.input = old_input

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha/one', tonumber('755', 8)))
    touch(tmp .. '/alpha/one/file.txt')
    touch(tmp .. '/alpha/top.txt')
    touch(tmp .. '/beta.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp .. '/alpha'))
    local state = store.get()
    local alpha = state.cwd
    local parent = fs.get_parent_dir(alpha)

    set_cursor_pos('one')
    api.fold_out()
    assert(state.expanded_dirs[alpha .. '/one'], 'setup should expand a nested subtree')
    assert(find_line_index(lines(), 'file%.txt$'), 'setup should show the expanded nested file')

    api.up_dir()
    assert_eq(state.cwd, parent)
    assert(state.expanded_dirs[alpha], 'up directory should expand the previous cwd under its parent')
    assert(state.expanded_dirs[alpha .. '/one'], 'up directory should preserve nested subtree state')
    assert_match(current_line(), 'alpha/$', 'up directory should move cursor to the previous cwd row')
    assert(find_line_index(lines(), 'one/$'), 'up directory should keep previous cwd children visible')
    assert(find_line_index(lines(), 'file%.txt$'), 'up directory should keep nested expanded rows visible')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/a', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/a/b', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/a/b/c', tonumber('755', 8)))
    touch(tmp .. '/a/b/c/deep.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp .. '/a/b/c'))
    local state = store.get()
    local start = state.cwd
    local b = fs.get_parent_dir(start)
    local a = fs.get_parent_dir(b)

    vim.api.nvim_feedkeys('2h', 'xt', false)
    assert_eq(state.cwd, a, 'counted up directory should ascend the requested number of levels')
    assert_match(current_line(), 'b/$', 'counted up directory should land on the child leading back to the previous cwd')
    assert(state.expanded_dirs[start], 'counted up directory should expand each visited directory')
    assert(state.expanded_dirs[b], 'counted up directory should expand each visited directory')
    -- Clear the pending count so it doesn't leak into later blocks that call
    -- api.fold_out()/api.fold_in() directly; those read vim.v.count1 and would
    -- otherwise inherit this 2 as an ambient count.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha/one', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha/one/two', tonumber('755', 8)))
    touch(tmp .. '/alpha/one/file.txt')
    touch(tmp .. '/alpha/one/two/deep.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local root = fs.realpath(tmp)
    assert_eq(vim.fn.maparg('<C-p>', 'n', false, true).desc, 'Parent directory')
    assert_eq(vim.fn.maparg('<C-p>', 'x', false, true).desc, 'Parent directory')
    assert_eq(vim.fn.maparg('P', 'n', false, true).desc, 'Paste')
    set_cursor_pos('alpha')
    api.fold_out()
    set_cursor_pos('one')
    api.fold_out()

    set_cursor_line('file%.txt$')
    api.parent_dir()
    assert_match(current_line(), 'one/$', 'parent jump should move from a nested file to its parent directory')
    assert(state.expanded_dirs[root .. '/alpha/one'], 'parent jump should not collapse the parent directory')
    assert(find_line_index(lines(), 'file%.txt$'), 'parent jump should keep the parent directory children visible')

    api.parent_dir()
    assert_match(current_line(), 'alpha/$', 'parent jump should move from a nested directory to its parent directory')
    assert(state.expanded_dirs[root .. '/alpha'], 'parent jump should not collapse visited parent directories')

    set_cursor_pos('two')
    api.fold_out()
    set_cursor_line('deep%.txt$')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('3<C-p>', true, false, true), 'xt', false)
    assert_match(current_line(), 'alpha/$', 'counted parent jump should move up the requested number of parents')

    set_cursor_line('file%.txt$')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('V<C-p>', true, false, true), 'xt', false)
    assert_match(current_line(), 'one/$', 'visual parent jump should use the visual cursor row')
    assert_eq(vim.api.nvim_get_mode().mode, 'V', 'visual parent jump should stay in visual mode')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)

    api.parent_dir()
    assert_match(current_line(), 'alpha/$', 'parent jump should move from a nested directory to its parent')

    api.parent_dir()
    assert_match(current_line(), 'alpha/$', 'parent jump should keep the cursor when the parent is not visible')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha/one', tonumber('755', 8)))
    touch(tmp .. '/alpha/one/file.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local root = fs.realpath(tmp)
    assert_eq(vim.fn.maparg('<BS>', 'n', false, true).desc, 'Close directory')
    assert_eq(vim.fn.maparg('<BS>', 'x', false, true).desc, 'Close directory')
    set_cursor_pos('alpha')
    api.fold_out()
    set_cursor_pos('one')
    api.fold_out()

    set_cursor_line('^alpha/$')
    api.close_dir()
    assert_match(current_line(), 'alpha/$', 'close should keep the cursor on the closed directory')
    assert(not state.expanded_dirs[root .. '/alpha'], 'close should collapse the hovered directory')
    assert(state.expanded_dirs[root .. '/alpha/one'], 'close should not touch expanded subdirectories')
    assert(not find_line_index(lines(), 'one/$'), 'close should hide the directory children')

    api.fold_out()
    assert(find_line_index(lines(), 'file%.txt$'), 're-expanding a closed directory should restore its expanded subtree')

    set_cursor_line('^alpha/$')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('Vj<BS>', true, false, true), 'xt', false)
    assert_eq(vim.api.nvim_get_mode().mode, 'n', 'visual close should leave visual mode')
    assert(not state.expanded_dirs[root .. '/alpha'], 'visual close should collapse a selected directory')
    assert(not state.expanded_dirs[root .. '/alpha/one'], 'visual close should collapse selected nested directories')
    assert_match(current_line(), 'alpha/$', 'visual close should keep the cursor on the first selected directory')

    api.fold_out()
    assert(find_line_index(lines(), 'one/$'), 'visual close should allow the selected parent directory to reopen')
    assert(not find_line_index(lines(), 'file%.txt$'), 'visual close should keep a selected nested directory closed')

    set_cursor_line('one/$')
    api.fold_out()
    set_cursor_line('file%.txt$')
    api.close_dir()
    assert(state.expanded_dirs[root .. '/alpha/one'], 'close should ignore file rows')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('b')
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = store.get().rows[cursor[1]]

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert(opts.anchor, 'create should anchor at the current row')
        assert_eq(opts.anchor.win, vim.api.nvim_get_current_win())
        assert_eq(opts.anchor.line, cursor[1])
        assert_eq(opts.anchor.col, row.name_start_col)
        cb(nil)
    end
    api.add()
    prompt.input = old_input

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/visible')
    touch(tmp .. '/.hidden')

    local old_show_hidden_files = config.show_hidden_files
    config.show_hidden_files = false

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    config.show_hidden_files = old_show_hidden_files
    assert(not vim.tbl_contains(lines(), '.hidden'), 'hidden files should be hidden when configured')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    local trash_tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(trash_tmp, tonumber('755', 8)))
    touch(tmp .. '/file.lua')
    touch(trash_tmp .. '/.gitignore(1)')

    local old_icons = config.icons
    local old_devicons = package.loaded['nvim-web-devicons']
    config.icons = 'nvim-web-devicons'
    package.loaded['nvim-web-devicons'] = {
        get_icon = function(name, ext, opts)
            assert_eq(opts.default, true)
            if name == 'file.lua' then
                assert_eq(ext, 'lua')
                return '[lua]', 'DoraIcon'
            end
            assert_eq(name, '.gitignore', 'restore previews should look up icons by the original basename')
            assert_eq(ext, vim.fn.fnamemodify(tmp .. '/.gitignore', ':e'))
            return '[git]', 'DoraIcon'
        end,
    }

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    assert(vim.tbl_contains(lines(), '[lua] file.lua'), 'icons should render before filenames')
    assert_eq(state.rows[1].name_start_col, #'[lua] ', 'icon rows should keep name column after the icon')
    assert(has_high_priority_highlight(state, 'DoraIcon'), 'icons should use the provider highlight')

    -- Trash can suffix a colliding entry. Its existing path supplies the file
    -- type, but the restore destination's basename must drive icon selection.
    local original = tmp .. '/.gitignore'
    local trashed = trash_tmp .. '/.gitignore(1)'
    confirm_win.show({original}, function() end, {types = {[original] = trashed}})
    assert_eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], '[git] .gitignore',
        'restore previews should not use a trash collision suffix for the icon')
    vim.api.nvim_feedkeys('n', 'xt', false)

    api.quit()
    config.icons = old_icons
    package.loaded['nvim-web-devicons'] = old_devicons
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
    assert_eq(vim.fn.delete(trash_tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    touch(tmp .. '/file.lua')
    local real_tmp = fs.realpath(tmp)

    local old_icons = config.icons
    local old_mini_icons = _G.MiniIcons
    config.icons = 'mini.icons'
    _G.MiniIcons = {
        get = function(category, path)
            if category == 'directory' then
                assert_eq(path, real_tmp .. '/dir')
                return '[dir]', 'DoraDirectory'
            end
            assert_eq(category, 'file')
            assert_eq(path, real_tmp .. '/file.lua')
            return '[mini]', 'DoraIcon'
        end,
    }

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    assert(vim.tbl_contains(lines(), '[dir] dir/'), 'mini.icons should render directory icons')
    assert(vim.tbl_contains(lines(), '[mini] file.lua'), 'mini.icons should render file icons')
    assert_eq(state.rows[2].name_start_col, #'[mini] ', 'mini.icons rows should keep name column after the icon')

    api.quit()
    config.icons = old_icons
    _G.MiniIcons = old_mini_icons
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/file.lua')

    local old_icons = config.icons
    config.icons = function()
        error('custom icon functions should not be called')
    end

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    assert(vim.tbl_contains(lines(), 'file.lua'), 'function-valued icons should be ignored')

    api.quit()
    config.icons = old_icons
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/single.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('single.txt')
    local origin_win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(origin_win)
    local row = store.get().rows[cursor[1]]
    local pos = vim.fn.screenpos(origin_win, cursor[1], row.name_start_col + 1)
    api.delete()

    local confirm_win = vim.api.nvim_get_current_win()
    local confirm_buf = vim.api.nvim_get_current_buf()
    local confirm_lines = vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)
    local first_item_pos = vim.fn.screenpos(confirm_win, 1, 1)
    assert_eq(first_item_pos.row, pos.row, 'delete confirmation should superimpose onto the deleted row')
    assert_eq(first_item_pos.col, pos.col, 'delete confirmation should align the filename with the deleted row')
    assert_match(win_title(confirm_win), 'Delete%?')
    assert_eq(confirm_lines[1], 'single.txt')

    vim.api.nvim_feedkeys('n', 'xt', false)
    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end
