-- Bookmarks: setting, jumping, previous-directory tracking.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/09_bookmarks.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local bookmarks = h.bookmarks
local fs = h.fs
local keymaps = h.keymaps
local api = h.api
local store = h.store
local window = h.window
local cwd = h.cwd
local assert_eq = h.assert_eq
local assert_match = h.assert_match
local touch = h.touch
local clear_persisted_view_state = h.clear_persisted_view_state
local lines = h.lines
local set_cursor_line = h.set_cursor_line
local current_line = h.current_line
local find_line_index = h.find_line_index

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/project', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/other', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/other/nested', tonumber('755', 8)))

    local other_win = vim.api.nvim_get_current_win()
    clear_persisted_view_state(other_win)
    vim.cmd('new')
    local bookmark_win = vim.api.nvim_get_current_win()
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local root = fs.realpath(tmp)
    local project = fs.realpath(tmp .. '/project')

    local set_map = vim.fn.maparg('m', 'n', false, true)
    local jump_map = vim.fn.maparg("'", 'n', false, true)
    assert_eq(set_map.desc, 'Set bookmark')
    assert_eq(type(set_map.callback), 'function')
    assert_eq(jump_map.desc, 'Jump to bookmark')
    assert_eq(type(jump_map.callback), 'function')
    assert_eq(vim.fn.maparg('M', 'n'), '', 'move should not be mapped')

    set_cursor_line('^project/$')
    vim.api.nvim_feedkeys('a', 't', false)
    set_map.callback()
    assert_eq(state.bookmarks.paths.a.directory, root, 'ma should bookmark the current directory')
    assert_eq(state.bookmarks.paths.a.hovered_path, project, 'ma should record the hovered file')

    set_cursor_line('^other/$')
    api.fold_out()
    assert(state.expanded_dirs[root .. '/other'], 'setup should expand a directory before quitting')

    set_cursor_line('^project/$')
    api.open()
    assert_eq(state.cwd, project)
    assert_eq(state.bookmarks.previous_directory.directory, root, 'directory changes should update the builtin bookmark')

    vim.api.nvim_feedkeys('b', 't', false)
    set_map.callback()
    assert_eq(state.bookmarks.paths.b.directory, project, 'mb should bookmark the new current directory')

    local old_open = keymaps.open_hint_window
    local captured_prefix
    local captured_rows
    ---@diagnostic disable-next-line: duplicate-set-field
    keymaps.open_hint_window = function(prefix, rows)
        captured_prefix = prefix
        captured_rows = rows
        return old_open(prefix, rows)
    end
    vim.defer_fn(function()
        vim.api.nvim_feedkeys('a', 't', false)
    end, 250)
    jump_map.callback()
    assert_eq(state.cwd, root, "'a should jump to bookmark a")
    assert_eq(state.bookmarks.previous_directory.directory, project, 'jumping to a bookmark should update the previous directory')
    assert_eq(captured_prefix, "'", 'delayed bookmark jumps should open mark hints')
    assert_eq(captured_rows[1].lhs, "''")
    assert_eq(captured_rows[2].lhs, "'a")
    assert_eq(captured_rows[3].lhs, "'b")

    captured_prefix = nil
    vim.api.nvim_feedkeys("'", 't', false)
    jump_map.callback()
    assert_eq(state.cwd, project, "'' should jump to the previous directory")
    assert_eq(state.bookmarks.previous_directory.directory, root, "'' should toggle the previous directory")
    assert_eq(captured_prefix, nil, "fast bookmark jumps should not open mark hints")
    keymaps.open_hint_window = old_open

    local old_notify = vim.notify
    local notification
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg)
        notification = msg
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 't', false)
    jump_map.callback()
    vim.notify = old_notify
    assert_eq(notification, nil, "escape should cancel a bookmark jump without notifying")

    api.help()
    local help_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local help_text = table.concat(help_lines, '\n')
    local navigation_line = find_line_index(help_lines, '^Navigation$')
    assert(navigation_line, 'help should include a navigation section')
    assert(not find_line_index(help_lines, '^Bookmarks$'), 'help should not include a bookmarks section')
    assert(navigation_line < find_line_index(help_lines, "^%s+m%s+%S+%s+Set bookmark$"),
        'help should show bookmark mappings under the navigation title')
    assert(find_line_index(help_lines, "^%s+'%s+%S+%s+Jump to bookmark$") < find_line_index(help_lines, "^%s+''%s+%S+%s+Jump to previous directory$"),
        'help should show saved bookmark targets after bookmark mappings')
    assert(help_text:find("''", 1, true), "help should include the builtin previous-directory bookmark")
    assert(help_text:find("'a", 1, true), 'help should include bookmark a')
    assert(help_text:find("'b", 1, true), 'help should include bookmark b')
    assert(help_text:find(root, 1, true), 'help should include the bookmarked root directory')
    assert(help_text:find(project, 1, true), 'help should include the bookmarked project directory')

    vim.api.nvim_feedkeys('q', 'xt', false)
    api.quit()

    vim.cmd('Dora ' .. vim.fn.fnameescape(project))
    local reopened_state = store.get()
    assert_eq(reopened_state.bookmarks.paths.a.directory, root,
        'reopening Dora should preserve bookmark a')
    assert_eq(reopened_state.bookmarks.paths.b.directory, project,
        'reopening Dora should preserve bookmark b')
    assert_eq(reopened_state.bookmarks.previous_directory.directory, project,
        "reopening Dora should point '' at the last session's directory")
    vim.api.nvim_feedkeys('a', 't', false)
    jump_map = vim.fn.maparg("'", 'n', false, true)
    jump_map.callback()
    assert_eq(reopened_state.cwd, root, "'a should jump to bookmark a after reopening Dora")
    assert_match(current_line(), 'project/$',
        "'a should restore the cursor to the bookmarked hovered file")
    assert_eq(reopened_state.bookmarks.previous_directory.directory, project,
        'jumping to a bookmark after reopening should update the previous directory')
    assert(reopened_state.expanded_dirs[root .. '/other'],
        'reopening Dora in the same window should preserve expanded directories')
    assert(find_line_index(lines(), '^└── nested/$'),
        'restored expanded directories should be visible after returning to their parent')
    set_cursor_line('^other/$')
    api.fold_in_recursive()
    assert_eq(reopened_state.expanded_dirs[root .. '/other'], nil)
    api.quit()

    vim.cmd('Dora ' .. vim.fn.fnameescape(root))
    assert_eq(store.get().expanded_dirs[root .. '/other'], nil,
        'collapsed directories should remain collapsed after reopening Dora')
    set_cursor_line('^other/$')
    api.fold_out()
    api.quit()

    vim.api.nvim_set_current_win(other_win)
    vim.cmd('Dora ' .. vim.fn.fnameescape(project))
    local other_state = store.get()
    assert_eq(other_state.bookmarks.paths.a.directory, root,
        'bookmark a should be shared with another window')
    assert_eq(other_state.bookmarks.paths.b.directory, project,
        'bookmark b should be shared with another window')
    assert_eq(other_state.bookmarks.previous_directory, nil,
        "the '' bookmark should not be shared with another window")
    assert(other_state.expanded_dirs[root .. '/other'],
        'expanded directories should be shared with another window')
    api.quit()

    vim.api.nvim_set_current_win(bookmark_win)
    vim.cmd('close!')
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    clear_persisted_view_state()
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))
    touch(tmp .. '/sub/file.txt')
    local root = fs.realpath(tmp)
    local sub = fs.realpath(tmp .. '/sub')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_line('^sub/$')
    api.fold_out()
    set_cursor_line('file%.txt$')
    api.open()
    assert_eq(vim.api.nvim_buf_get_name(0), sub .. '/file.txt', 'open should edit the selected file')

    vim.cmd('Dora')
    local state = store.get()
    assert_eq(state.cwd, sub)
    assert_eq(state.bookmarks.previous_directory.directory, root,
        "opening a file should record the session's directory as the previous directory")
    assert_eq(state.bookmarks.previous_directory.hovered_path, sub .. '/file.txt',
        'opening a file should record the hovered file for the previous directory')
    local jump_map = vim.fn.maparg("'", 'n', false, true)
    vim.api.nvim_feedkeys("'", 't', false)
    jump_map.callback()
    assert_eq(state.cwd, root, "'' should jump back to where the file was opened from")
    assert_match(current_line(), 'file%.txt$', "'' should restore the cursor to the hovered file")

    api.quit()
    vim.cmd('bdelete!')
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end
