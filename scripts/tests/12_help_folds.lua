-- Help window, function keymaps, sibling motions, fold actions, placeholders.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/12_help_folds.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local dora = h.dora
local fs = h.fs
local config = h.config
local keymaps = h.keymaps
local api = h.api
local store = h.store
local window = h.window
local cwd = h.cwd
local assert_eq = h.assert_eq
local assert_match = h.assert_match
local touch = h.touch
local lines = h.lines
local set_cursor_line = h.set_cursor_line
local current_line = h.current_line
local find_line_index = h.find_line_index
local set_cursor_pos = h.set_cursor_pos
local has_highlight = h.has_highlight
local has_high_priority_highlight = h.has_high_priority_highlight
local has_priority_highlight = h.has_priority_highlight
local assert_cursor_tree_highlights = h.assert_cursor_tree_highlights

do
    vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
    local origin_win = vim.api.nvim_get_current_win()
    api.help()
    local help_win = vim.api.nvim_get_current_win()
    local help_buf = vim.api.nvim_get_current_buf()
    assert(help_win ~= origin_win, 'help should open in a separate window')
    local help_lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
    local help_cfg = vim.api.nvim_win_get_config(help_win)
    assert_eq(help_cfg.relative, '', 'help should open in a split, not a float')
    assert(vim.api.nvim_win_get_position(help_win)[2] > vim.api.nvim_win_get_position(origin_win)[2],
        'help should open in a vertical split to the right of dora')
    assert(vim.api.nvim_win_is_valid(origin_win), 'help should keep the dora window open')
    assert_eq(vim.wo[help_win].cursorline, false, 'help should disable cursorline')
    assert_eq(vim.api.nvim_buf_get_name(help_buf), 'dora://help', 'help buffer should have a readable name')
    vim.api.nvim_set_current_win(origin_win)
    assert(vim.api.nvim_win_is_valid(help_win), 'help should stay open while using dora')
    vim.api.nvim_set_current_win(help_win)
    local expected_sections = {
        'General', 'Navigation', 'Open', 'File Operations',
        'View', 'Yank', 'Sort',
    }
    local previous_line = 0
    for _, section in ipairs(expected_sections) do
        local line = find_line_index(help_lines, '^' .. section .. '$')
        assert(line, 'help should include the ' .. section .. ' section')
        assert(previous_line < line, 'help sections should use cheat-sheet order')
        previous_line = line
    end
    assert(not find_line_index(help_lines, '^Other$'), 'help should omit empty sections')
    -- Every row carries a mode column ('n'/'nv') between the key and the
    -- description; %S+ matches it without coupling to the exact text.
    local enter_line = find_line_index(help_lines, '^%s+<CR>%s+%S+%s+Open$')
    local open_line = find_line_index(help_lines, '^%s+l%s+%S+%s+Open$')
    assert(enter_line < open_line,
        'help should sort mappings for the same action alphabetically')
    local general_line = find_line_index(help_lines, '^General$') - 1
    local quit_line = find_line_index(help_lines, '^%s+q%s+%S+%s+Quit$') - 1
    local section_highlight, key_highlight = false, false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(help_buf, -1, 0, -1, {details=true})) do
        if mark[2] == general_line and mark[4].hl_group == 'DoraHelpSection' then
            section_highlight = true
        elseif mark[2] == quit_line and mark[4].hl_group == 'DoraInfoLabel' then
            key_highlight = true
        end
    end
    assert(section_highlight, 'help should use a dedicated highlight for section titles')
    assert(key_highlight, 'help should keep key labels visually distinct from section titles')

    vim.api.nvim_feedkeys('q', 'xt', false)
    assert_eq(vim.api.nvim_get_current_win(), origin_win, 'closing help should restore origin window')
    api.quit()
end

do
    -- Regression: a global `-`/`<Cmd>Dora<CR>` mapping can run `:Dora` while
    -- the help window is focused. The help buffer is named `dora://help`
    -- (asserted above), whose `:p:h` expands to the bogus path `dora:`, so
    -- `:Dora` must fall back to the cwd instead of crashing in realpath.
    local help_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[help_buf].buftype = 'nofile'
    vim.api.nvim_buf_set_name(help_buf, 'dora://help')
    vim.api.nvim_set_current_buf(help_buf)
    local ok, err = pcall(vim.cmd --[[@as function]], 'Dora')
    assert(ok, 'running :Dora from a dora://help buffer should not error: ' .. tostring(err))
    assert_eq(store.get().cwd, fs.normalize_sep(assert(vim.loop.cwd())),
        ':Dora from a non-filesystem buffer should open at the cwd')
    api.quit()
end

do
    local old_keymaps = config.keymaps
    config.keymaps = {
        n = "yank_full_path",
        x = "<Cmd>lua vim.g.dora_smoke_legacy_keymap = 'normal'<CR>",
        z = {"<Cmd>lua vim.g.dora_smoke_legacy_keymap = 'normal-z'<CR>", desc="Normal Z"},
    }

    vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
    assert_eq(vim.fn.maparg('x', 'n', false, true).rhs, "<Cmd>lua vim.g.dora_smoke_legacy_keymap = 'normal'<CR>")
    api.help()
    local help_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local help_text = table.concat(help_lines, '\n')
    assert(help_text:match("x%s+%S+%s+<Cmd>lua vim%.g%.dora_smoke_legacy_keymap = 'normal'<CR>"), 'help should include legacy normal mappings')
    assert(find_line_index(help_lines, '^Yank$') < find_line_index(help_lines, '^%s+n%s+%S+%s+Yank full path$'),
        'help should categorize remapped built-in actions by action name')
    assert(find_line_index(help_lines, '^Other$'), 'help should group custom mappings under Other')
    assert(find_line_index(help_lines, "^%s+x%s+%S+%s+<Cmd>lua vim%.g%.dora_smoke_legacy_keymap = 'normal'<CR>$") < find_line_index(help_lines, '^%s+z%s+%S+%s+Normal Z$'),
        'help should sort custom mappings by key')
    vim.api.nvim_feedkeys('q', 'xt', false)
    api.quit()

    config.keymaps = old_keymaps
end

do
    local old_keymaps = config.keymaps
    local ctx
    config.keymaps = {
        e = {function(c) ctx = c end, desc = 'Capture context'},
    }

    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha', tonumber('755', 8)))
    touch(tmp .. '/top.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local root = fs.realpath(tmp)

    set_cursor_pos('alpha')
    vim.api.nvim_feedkeys('e', 'xt', false)
    assert_eq(ctx.cwd, root, 'function keymaps should receive the browsed directory')
    assert_eq(ctx.path, root .. '/alpha', 'function keymaps should receive the cursor entry path')
    assert_eq(ctx.type, 'directory', 'function keymaps should receive the cursor entry type')

    set_cursor_pos('top.txt')
    vim.api.nvim_feedkeys('e', 'xt', false)
    assert_eq(ctx.path, root .. '/top.txt', 'function keymap context should follow the cursor')
    assert_eq(ctx.type, 'file', 'function keymap context should report file rows')

    set_cursor_pos('alpha')
    api.fold_out()
    set_cursor_pos('(empty)')
    vim.api.nvim_feedkeys('e', 'xt', false)
    assert_eq(ctx.cwd, root, 'function keymap context should include cwd on placeholder rows')
    assert_eq(ctx.path, nil, 'function keymap context should omit path on placeholder rows')
    assert_eq(ctx.type, nil, 'function keymap context should omit type on placeholder rows')

    api.quit()
    config.keymaps = old_keymaps
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    assert_eq(vim.fn.maparg('J', 'x', false, true).desc, 'Next sibling')
    assert_eq(type(vim.fn.maparg('J', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('K', 'x', false, true).desc, 'Previous sibling')
    assert_eq(type(vim.fn.maparg('K', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('<', 'n', false, true).desc, 'Go backward in directory history')
    assert_eq(type(vim.fn.maparg('<', 'n', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('>', 'n', false, true).desc, 'Go forward in directory history')
    assert_eq(type(vim.fn.maparg('>', 'n', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('<', 'x'), '', 'visual history back should not be mapped')
    assert_eq(vim.fn.maparg('>', 'x'), '', 'visual history forward should not be mapped')
    assert_eq(vim.fn.maparg('d', 'x', false, true).desc, 'Move file to trash (macOS/Linux)')
    assert_eq(type(vim.fn.maparg('d', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('D', 'x', false, true).desc, 'Delete file permanently')
    assert_eq(type(vim.fn.maparg('D', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('<Tab>', 'x'), '', 'visual Tab should not be mapped')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha/nested', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/beta', tonumber('755', 8)))
    touch(tmp .. '/alpha/nested/deep.txt')
    touch(tmp .. '/alpha/file.txt')
    touch(tmp .. '/top.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))

    set_cursor_pos('alpha')
    api.fold_out()
    set_cursor_line('nested/$')
    api.fold_out()

    set_cursor_pos('alpha')
    api.next_sibling()
    assert_eq(current_line(), 'beta/', 'next sibling should jump to the next root sibling')
    api.next_sibling()
    assert_eq(current_line(), 'top.txt', 'next sibling should include file siblings')
    api.next_sibling()
    assert_eq(current_line(), 'top.txt', 'next sibling should not wrap from the last root sibling')
    api.prev_sibling()
    assert_eq(current_line(), 'beta/', 'previous sibling should jump to the previous sibling')
    api.prev_sibling()
    assert_eq(current_line(), 'alpha/', 'previous sibling should jump to the previous root sibling')
    api.prev_sibling()
    assert_eq(current_line(), 'alpha/', 'previous sibling should not wrap from the first root sibling')

    set_cursor_line('nested/$')
    api.prev_sibling()
    assert_match(current_line(), 'nested/$', 'previous sibling should not wrap from the first child sibling')

    set_cursor_line('nested/$')
    api.next_sibling()
    assert_match(current_line(), 'file%.txt$', 'next sibling should jump to the next nested sibling')
    api.prev_sibling()
    assert_match(current_line(), 'nested/$', 'previous sibling should jump to the previous nested sibling')
    api.next_sibling()
    assert_match(current_line(), 'file%.txt$', 'next sibling should jump to the next nested sibling')
    api.next_sibling()
    assert_match(current_line(), 'file%.txt$', 'next sibling should not wrap from the last child sibling')
    api.prev_sibling()
    assert_match(current_line(), 'nested/$', 'previous sibling should not wrap from the last child sibling')
    set_cursor_line('deep%.txt$')
    api.prev_sibling()
    assert_match(current_line(), 'deep%.txt$', 'previous sibling should stay on an only child sibling')
    api.next_sibling()
    assert_match(current_line(), 'deep%.txt$', 'next sibling should stay on an only child sibling')
    set_cursor_pos('alpha')
    vim.api.nvim_feedkeys('2J', 'xt', false)
    assert_eq(current_line(), 'top.txt', 'counted next sibling should move the requested number of siblings')
    vim.api.nvim_feedkeys('2K', 'xt', false)
    assert_eq(current_line(), 'alpha/', 'counted previous sibling should move the requested number of siblings')
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
    assert(vim.loop.fs_mkdir(tmp .. '/root', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/root/a', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/root/a/b', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/root/empty', tonumber('755', 8)))
    touch(tmp .. '/root/a/b/file.txt')

    local old_tree_indent = config.tree_indent
    config.tree_indent = 2
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local root = state.cwd

    set_cursor_pos('root')
    api.fold_out_recursive()
    assert(vim.tbl_contains(lines(), '├ a/'), 'custom tree indentation should apply to child directories')
    assert(vim.tbl_contains(lines(), '│ └ b/'), 'custom tree indentation should apply to nested directories')
    assert(vim.tbl_contains(lines(), '│   └ file.txt'), 'custom tree indentation should apply to nested files')
    assert(vim.tbl_contains(lines(), '└ empty/'), 'custom tree indentation should apply to last children')
    assert(vim.tbl_contains(lines(), '  └ (empty)'), 'custom tree indentation should apply to empty placeholders')
    assert(state.expanded_dirs[root .. '/root'], 'recursive expand should expand selected directory')
    assert(state.expanded_dirs[root .. '/root/a'], 'recursive expand should expand descendants')
    assert(state.expanded_dirs[root .. '/root/a/b'], 'recursive expand should expand nested descendants')
    assert(state.expanded_dirs[root .. '/root/empty'], 'recursive expand should expand empty descendants')

    set_cursor_pos('root')
    api.fold_in_recursive()
    assert(not state.expanded_dirs[root .. '/root'], 'recursive collapse should clear selected directory')
    assert(not state.expanded_dirs[root .. '/root/a'], 'recursive collapse should clear descendants')
    assert(not state.expanded_dirs[root .. '/root/a/b'], 'recursive collapse should clear nested descendants')
    assert(not state.expanded_dirs[root .. '/root/empty'], 'recursive collapse should clear empty descendants')
    assert(not vim.tbl_contains(lines(), '├ a/'), 'recursive collapse should hide children')

    api.fold_out()
    assert(vim.tbl_contains(lines(), '├ a/'), 'expand after recursive collapse should show one level')
    assert(not vim.tbl_contains(lines(), '│ └ b/'), 'expand after recursive collapse should not restore recursive state')

    config.tree_indent = 1
    set_cursor_pos('root')
    api.fold_out_recursive()
    assert(vim.tbl_contains(lines(), '├a/'), 'indent 1 should render connectors flush with child directories')
    assert(vim.tbl_contains(lines(), '│└b/'), 'indent 1 should render connectors flush with nested directories')
    assert(vim.tbl_contains(lines(), '│ └file.txt'), 'indent 1 should render connectors flush with nested files')
    assert(vim.tbl_contains(lines(), '└empty/'), 'indent 1 should render connectors flush with last children')
    assert(vim.tbl_contains(lines(), ' └(empty)'), 'indent 1 should render connectors flush with empty placeholders')

    api.quit()
    config.tree_indent = old_tree_indent
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha/one', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha/two', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/beta', tonumber('755', 8)))
    touch(tmp .. '/alpha/one/file.txt')
    touch(tmp .. '/root.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local root = state.cwd

    set_cursor_pos('alpha')
    vim.api.nvim_win_set_cursor(0, {vim.api.nvim_win_get_cursor(0)[1], 3})
    api.fold_out()
    assert_eq(vim.api.nvim_win_get_cursor(0)[2], 3, 'expand should keep the cursor column')
    assert(vim.tbl_contains(lines(), '├── one/'), 'first expand should show alpha children')
    assert(vim.tbl_contains(lines(), '└── two/'), 'first expand should show all alpha children')
    assert(not vim.tbl_contains(lines(), '│   └── file.txt'), 'first expand should not expand grandchildren')
    assert(has_highlight(state, 'DoraDirectory'), 'directory rows should be highlighted')
    assert(has_priority_highlight(state, 'DoraFile', 100), 'file row highlights should not cover yank highlights')
    assert(has_high_priority_highlight(state, 'DoraTree'), 'tree prefixes should be highlighted')
    assert(has_high_priority_highlight(state, 'DoraVirtText'), 'directory suffixes should be highlighted')

    set_cursor_line('one/$')
    assert_cursor_tree_highlights(state, 2)
    assert_eq(state.rows[vim.api.nvim_win_get_cursor(0)[1]].tree_connector_start_col, 0)

    api.fold_out()
    assert(vim.tbl_contains(lines(), '│   └── file.txt'), 'second expand should expand another level')
    assert_cursor_tree_highlights(state, 3)

    set_cursor_line('file%.txt$')
    assert_cursor_tree_highlights(state, 1)
    assert(state.rows[vim.api.nvim_win_get_cursor(0)[1]].tree_connector_start_col > 0)
    api.toggle_copy()
    assert_eq(state.marked_paths[root .. '/alpha/one/file.txt'], 'copy', 'nested row should mark its real path')

    set_cursor_pos('alpha')
    vim.api.nvim_win_set_cursor(0, {vim.api.nvim_win_get_cursor(0)[1], 3})
    api.fold_in()
    assert_eq(vim.api.nvim_win_get_cursor(0)[2], 3, 'collapse should keep the cursor column')
    assert(vim.tbl_contains(lines(), '├── one/'), 'collapse should keep the hovered directory open')
    assert(vim.tbl_contains(lines(), '└── two/'), 'collapse should keep shallow descendants visible')
    assert(not vim.tbl_contains(lines(), '│   └── file.txt'), 'collapse should hide the deepest visible level')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapse should leave the hovered directory expanded')
    assert(not state.expanded_dirs[root .. '/alpha/one'], 'collapse should fold deepest expanded descendants')

    api.fold_out()
    assert(vim.tbl_contains(lines(), '│   └── file.txt'), 're-expand should restore previous tree state')

    set_cursor_line('file%.txt$')
    api.fold_in()
    assert(not vim.tbl_contains(lines(), '│   └── file.txt'), 'collapsing file should hide sibling rows below its parent directory')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapsing file should leave grandparent expanded')
    assert(not state.expanded_dirs[root .. '/alpha/one'], 'collapsing file should fold its parent directory')
    assert_match(current_line(), 'one/$', 'collapsing file should move cursor to its parent directory')

    api.fold_in()
    assert(vim.tbl_contains(lines(), '├── one/'), 'collapsing a directory with no visible descendants should be a no-op')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapsing a directory with no visible descendants should leave ancestors expanded')
    assert_match(current_line(), 'one/$', 'collapsing a directory with no visible descendants should keep the cursor')

    set_cursor_pos('alpha')
    api.fold_in()
    assert(vim.tbl_contains(lines(), '├── one/'), 'collapse should remove the deepest remaining descendant level first')
    assert(vim.tbl_contains(lines(), '└── two/'), 'collapse should keep shallow descendants visible')
    assert(not vim.tbl_contains(lines(), '    └── (empty)'), 'collapse should hide empty placeholders at the deepest level')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapse should leave the hovered directory expanded while descendants remain visible')
    assert(not state.expanded_dirs[root .. '/alpha/two'], 'collapse should fold deepest empty descendants')

    api.fold_in()
    assert(not vim.tbl_contains(lines(), '├── one/'), 'collapsing one visible level should fold the hovered directory')
    assert(not state.expanded_dirs[root .. '/alpha'], 'collapsing one visible level should clear the hovered directory expansion')
    assert_match(current_line(), 'alpha/$', 'collapsing one visible level should keep cursor on the hovered directory')

    api.fold_out()
    api.fold_out()
    assert(vim.tbl_contains(lines(), '│   └── file.txt'), 'recursive state should be restorable after parent fallback collapse')

    set_cursor_line('one/$')
    api.fold_in()
    assert(not vim.tbl_contains(lines(), '│   └── file.txt'), 'collapsing child should hide child contents')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapsing child should leave parent expanded')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/empty', tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    set_cursor_pos('empty')
    api.fold_out()
    assert(vim.tbl_contains(lines(), '└── (empty)'), 'empty directories should render a placeholder')
    assert(has_highlight(state, 'DoraTree'), 'empty placeholder should be highlighted as tree text')

    set_cursor_pos('empty')
    api.fold_in()
    assert(not vim.tbl_contains(lines(), '└── (empty)'), 'collapsing empty directory should hide placeholder')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/unreadable', tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local old_list = fs.list
    ---@diagnostic disable-next-line: duplicate-set-field
    fs.list = function(path)
        if path:match('/unreadable$') then
            error('EPERM: operation not permitted')
        end
        return old_list(path)
    end

    set_cursor_pos('unreadable')
    local ok, msg = pcall(api.fold_out)
    fs.list = old_list
    assert(ok, msg)
    assert(vim.tbl_contains(lines(), '└── (not permitted)'), 'unreadable directories should render a placeholder')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end
