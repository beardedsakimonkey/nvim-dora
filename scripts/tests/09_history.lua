-- Window-local browser history: traversal, persistence, pruning, and renames.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/09_history.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local fs = h.fs
local prompt = h.prompt
local api = h.api
local store = h.store
local assert_eq = h.assert_eq
local assert_match = h.assert_match
local touch = h.touch
local clear_persisted_view_state = h.clear_persisted_view_state
local set_cursor_line = h.set_cursor_line
local current_line = h.current_line

do
    local tmp = vim.fn.tempname()
    assert(vim.fn.mkdir(tmp .. '/project/deep', 'p') == 1)
    assert(vim.loop.fs_mkdir(tmp .. '/other', tonumber('755', 8)))
    touch(tmp .. '/project/deep/file.txt')
    touch(tmp .. '/other/other.txt')

    clear_persisted_view_state()
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local root = fs.realpath(tmp)
    local project = root .. '/project'
    local deep = project .. '/deep'
    local other = root .. '/other'

    assert_eq(vim.fn.maparg('<', 'n', false, true).desc, 'Back')
    assert_eq(vim.fn.maparg('>', 'n', false, true).desc, 'Forward')
    assert_eq(vim.fn.maparg('m', 'n'), '', 'm should be unassigned by dora')
    assert_eq(vim.fn.maparg("'", 'n'), '', "' should be unassigned by dora")
    assert_eq(api.set_bookmark, nil, 'set_bookmark should no longer be a public action')
    assert_eq(api.jump_bookmark, nil, 'jump_bookmark should no longer be a public action')
    assert_eq(api.first_sibling, nil, 'first_sibling should no longer be a public action')
    assert_eq(api.last_sibling, nil, 'last_sibling should no longer be a public action')
    assert_eq(#state.history.entries, 1, 'opening dora should create the first history entry')
    assert_eq(state.history.entries[1].directory, root)
    assert_eq(state.history.index, 1)

    set_cursor_line('^project/$')
    api.open()
    set_cursor_line('^deep/$')
    api.open()
    set_cursor_line('file%.txt$')
    assert_eq(#state.history.entries, 3, 'directory navigation should append history entries')
    assert_eq(state.history.index, 3)

    api.history_back()
    assert_eq(state.cwd, project, 'back should traverse one history entry')
    assert_match(current_line(), '^deep/$', 'back should restore the previous directory cursor')
    api.history_back()
    assert_eq(state.cwd, root, 'back should support multi-step traversal')
    assert_match(current_line(), '^project/$', 'back should restore the root cursor')
    api.history_back()
    assert_eq(state.cwd, root, 'back at the boundary should be a no-op')
    assert_eq(state.history.index, 1)

    api.history_forward()
    assert_eq(state.cwd, project, 'forward should traverse one history entry')
    assert_match(current_line(), '^deep/$', 'forward should restore the saved cursor')
    api.history_forward()
    assert_eq(state.cwd, deep, 'forward should support multi-step traversal')
    assert_match(current_line(), 'file%.txt$', 'forward should restore the deepest saved cursor')
    local history_size = #state.history.entries
    vim.cmd('Dora ' .. vim.fn.fnameescape(deep))
    assert_eq(#state.history.entries, history_size, 're-entering the current cwd should not add a duplicate')

    vim.cmd('Dora ' .. vim.fn.fnameescape(root))
    assert_eq(#state.history.entries, 4, 'a non-consecutive repeated visit should be recorded')
    assert_eq(state.history.entries[4].directory, root)
    api.history_back()
    assert_eq(state.cwd, deep)
    vim.cmd('Dora ' .. vim.fn.fnameescape(other))
    assert_eq(#state.history.entries, 4, 'fresh navigation after back should replace the forward branch')
    assert_eq(state.history.entries[4].directory, other)
    api.history_forward()
    assert_eq(state.cwd, other, 'forward should no-op after branch truncation')
    assert_eq(state.history.index, 4)

    set_cursor_line('other%.txt$')
    local persisted_history = state.history
    api.quit()
    vim.cmd('Dora ' .. vim.fn.fnameescape(other))
    state = store.get()
    assert_eq(state.history, persisted_history, 'closing and reopening dora should preserve window history')
    assert_match(current_line(), 'other%.txt$', 'reopening should restore the current entry cursor')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Opening a file closes Dora; re-entering from that file should append its
    -- parent without losing the history or the row hovered before the open.
    local tmp = vim.fn.tempname()
    assert(vim.fn.mkdir(tmp .. '/sub', 'p') == 1)
    touch(tmp .. '/sub/file.txt')
    local root = fs.realpath(tmp)
    local sub = root .. '/sub'

    clear_persisted_view_state()
    vim.cmd('Dora ' .. vim.fn.fnameescape(root))
    set_cursor_line('^sub/$')
    api.fold_out()
    set_cursor_line('file%.txt$')
    api.open()
    assert_eq(vim.api.nvim_buf_get_name(0), sub .. '/file.txt')

    vim.cmd('Dora')
    local state = store.get()
    assert_eq(state.cwd, sub)
    assert_eq(#state.history.entries, 2, 're-entering from a file should append its parent directory')
    api.history_back()
    assert_eq(state.cwd, root)
    assert_match(current_line(), 'file%.txt$', 'back should restore the file hovered before opening it')

    api.quit()
    vim.cmd('Dora ' .. vim.fn.fnameescape(root))
    state = store.get()
    api.history_forward()
    assert_eq(state.cwd, sub, 'forward history should survive another close and reopen')

    api.quit()
    vim.cmd('bdelete!')
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- A directory opened into a split creates a new Dora session and a new
    -- window-owned history rather than sharing the source window's index.
    local tmp = vim.fn.tempname()
    assert(vim.fn.mkdir(tmp .. '/alpha', 'p') == 1)
    assert(vim.loop.fs_mkdir(tmp .. '/beta', tonumber('755', 8)))
    local root = fs.realpath(tmp)

    clear_persisted_view_state()
    vim.cmd('Dora ' .. vim.fn.fnameescape(root))
    local first_state = store.get()
    local first_win = vim.api.nvim_get_current_win()
    set_cursor_line('^alpha/$')
    api.open()
    api.history_back()
    set_cursor_line('^beta/$')
    api.open_vsplit()

    local split_state = store.get()
    local split_win = vim.api.nvim_get_current_win()
    assert(split_win ~= first_win, 'opening a directory in a split should create a window')
    assert(split_state ~= first_state, 'a split-created Dora should have a separate state')
    assert(split_state.history ~= first_state.history, 'Dora histories should be window-local')
    assert_eq(#split_state.history.entries, 1, 'the split history should start at its opened directory')
    assert_eq(split_state.history.entries[1].directory, root .. '/beta')

    api.history_back()
    assert_eq(split_state.cwd, root .. '/beta', 'the split history boundary should not use source-window entries')
    api.quit()
    vim.cmd('close!')
    vim.api.nvim_set_current_win(first_win)
    assert_eq(store.get().history, first_state.history)
    api.history_forward()
    assert_eq(first_state.cwd, root .. '/alpha', 'the source window should retain its own forward branch')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Missing paths and paths replaced by files stay in history until a
    -- traversal encounters them, then are discarded while searching onward.
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    for _, name in ipairs({'a', 'missing', 'not-dir', 'c'}) do
        assert(vim.loop.fs_mkdir(tmp .. '/' .. name, tonumber('755', 8)))
    end
    local root = fs.realpath(tmp)

    clear_persisted_view_state()
    vim.cmd('Dora ' .. vim.fn.fnameescape(root))
    local state = store.get()
    for _, name in ipairs({'a', 'missing', 'not-dir', 'c'}) do
        vim.cmd('Dora ' .. vim.fn.fnameescape(root .. '/' .. name))
    end
    assert_eq(#state.history.entries, 5)
    assert_eq(vim.fn.delete(root .. '/missing', 'd'), 0)
    assert_eq(vim.fn.delete(root .. '/not-dir', 'd'), 0)
    touch(root .. '/not-dir')
    assert_eq(#state.history.entries, 5, 'deleted destinations should remain until traversal')

    api.history_back()
    assert_eq(state.cwd, root .. '/a', 'back should skip missing and non-directory entries')
    assert_eq(#state.history.entries, 3, 'invalid destinations should be removed from history')
    assert_eq(state.history.index, 2)

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Renaming a directory subtree rewrites both entry directories and saved
    -- hovered paths, so later traversal follows the renamed tree.
    local tmp = vim.fn.tempname()
    assert(vim.fn.mkdir(tmp .. '/old/child', 'p') == 1)
    touch(tmp .. '/old/child/file.txt')
    local root = fs.realpath(tmp)
    local old = root .. '/old'
    local renamed = root .. '/renamed'

    clear_persisted_view_state()
    vim.cmd('Dora ' .. vim.fn.fnameescape(root))
    local state = store.get()
    set_cursor_line('^old/$')
    api.open()
    set_cursor_line('^child/$')
    api.open()
    set_cursor_line('file%.txt$')
    api.history_back()
    api.history_back()
    assert_eq(state.cwd, root)

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        cb('renamed', opts.validate('renamed'))
    end
    api.rename()
    prompt.input = old_input

    assert(not fs.exists(old), 'rename should remove the old directory path')
    assert(fs.exists(renamed .. '/child/file.txt'), 'rename should move the directory subtree')
    assert_eq(state.history.entries[1].hovered_path, renamed,
        'rename should update a stored hovered directory')
    assert_eq(state.history.entries[2].directory, renamed,
        'rename should update a stored directory')
    assert_eq(state.history.entries[2].hovered_path, renamed .. '/child',
        'rename should update a hovered descendant')
    assert_eq(state.history.entries[3].directory, renamed .. '/child',
        'rename should update a stored descendant directory')
    assert_eq(state.history.entries[3].hovered_path, renamed .. '/child/file.txt',
        'rename should update a hovered file under the subtree')

    api.history_forward()
    assert_eq(state.cwd, renamed)
    assert_match(current_line(), '^child/$', 'forward should restore the renamed child row')
    api.history_forward()
    assert_eq(state.cwd, renamed .. '/child')
    assert_match(current_line(), 'file%.txt$', 'forward should restore a file under the renamed subtree')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end
