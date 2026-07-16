-- Filtering: matches, highlights, inversion, persistence across navigation.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/13_filter.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local descriptions = h.actions.descriptions
local fs = h.fs
local prompt = h.prompt
local api = h.api
local store = h.store
local window = h.window
local cwd = h.cwd
local assert_eq = h.assert_eq
local touch = h.touch
local lines = h.lines
local buf_lines = h.buf_lines
local set_cursor_line = h.set_cursor_line
local current_line = h.current_line
local set_cursor_pos = h.set_cursor_pos
local win_title = h.win_title

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/beta', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/gamma', tonumber('755', 8)))
    touch(tmp .. '/alpha/match.txt')
    touch(tmp .. '/alpha/other.lua')
    touch(tmp .. '/beta/match.txt')
    touch(tmp .. '/gamma/match.txt')
    touch(tmp .. '/root-MATCH.txt')
    for i = 1, 40 do
        touch(('%s/filler-%02d.txt'):format(tmp, i))
    end

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local origin_win = vim.api.nvim_get_current_win()
    assert_eq(vim.fn.maparg('f', 'n', false, true).desc, descriptions.filter)
    assert_eq(vim.fn.maparg('F', 'n', false, true).desc, descriptions.clear_filter)

    set_cursor_pos('alpha')
    api.fold_out()
    set_cursor_pos('gamma')
    api.fold_out()

    vim.api.nvim_win_set_cursor(origin_win, {#state.rows, 0})
    vim.api.nvim_win_call(origin_win, function()
        vim.cmd'normal! zt'
    end)
    local scrolled_view = vim.api.nvim_win_call(origin_win, function()
        return vim.fn.winsaveview()
    end)
    assert(scrolled_view.topline > 1, 'filter test should begin with Dora scrolled down')

    api.filter()
    local filter = assert(state.filter_window)
    local filter_cfg = vim.api.nvim_win_get_config(filter.win)
    assert_eq(vim.api.nvim_get_current_win(), filter.win, 'filter should receive focus while editing')
    assert_eq(filter_cfg.relative, 'win', 'filter should be positioned relative to the Dora window')
    assert_eq(filter_cfg.win, origin_win, 'filter should be attached to the Dora window')
    assert_eq(filter_cfg.anchor, 'NW', 'filter should be anchored from its top-left corner')
    assert_eq(filter_cfg.row, 0, 'filter should be aligned with the top of Dora')
    assert_eq(filter_cfg.col, 0, 'filter should be aligned with the left of Dora')
    assert_eq(filter_cfg.border, 'none', 'filter should be borderless')
    assert_eq(win_title(filter.win), '', 'filter should not have a title')
    -- The prompt label and the empty-state placeholder are both inline marks,
    -- distinguished by gravity: the label sticks left of the caret, the
    -- placeholder ghost-text right of it.
    local function inline_mark(right_gravity)
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(filter.buf, filter.ns, 0, -1, {details = true})) do
            if mark[4].virt_text_pos == 'inline' and mark[4].right_gravity == right_gravity then
                return mark
            end
        end
    end
    local prefix_mark = assert(inline_mark(false), 'filter should render a prefix')
    assert_eq(prefix_mark[4].virt_text[1][1], 'Filter›')
    local placeholder_mark = assert(inline_mark(true), 'an empty filter should show the invert placeholder')
    assert_eq(placeholder_mark[4].virt_text[1][1], ' <c-i> to invert')
    local spacer_marks = vim.tbl_filter(function(mark)
        return mark[4].virt_lines ~= nil
    end, vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true}))
    assert_eq(#spacer_marks, 1, 'filter should add one virtual spacer above the results')
    assert_eq(#spacer_marks[1][4].virt_lines, 1, 'filter spacer should be exactly one line')
    assert_eq(spacer_marks[1][4].virt_lines_above, true)

    filter:set_input('MATCH')
    assert(not inline_mark(true), 'a non-empty filter should hide the invert placeholder')
    local filtered_view = vim.api.nvim_win_call(origin_win, function()
        return vim.fn.winsaveview()
    end)
    assert_eq(vim.api.nvim_get_current_win(), filter.win, 'live filtering should keep focus in the filter window')
    assert_eq(vim.api.nvim_win_get_cursor(origin_win)[1], 1, 'live filtering should move Dora to the first result')
    assert_eq(filtered_view.topline, 1, 'live filtering should scroll the Dora window to the top')
    assert_eq(filtered_view.topfill, 1, 'live filtering should reveal the virtual spacer')
    local filtered_lines = buf_lines(state.buf)
    assert(vim.tbl_contains(filtered_lines, 'alpha/match.txt'), 'filter should show nested matches as relative paths')
    assert(vim.tbl_contains(filtered_lines, 'gamma/match.txt'), 'filter should distinguish duplicate basenames by parent path')
    assert(vim.tbl_contains(filtered_lines, 'root-MATCH.txt'), 'filter matching should be case-insensitive')
    assert(not vim.tbl_contains(filtered_lines, 'beta/match.txt'), 'filter should exclude rows under collapsed directories')
    assert(not table.concat(filtered_lines, '\n'):find('├──', 1, true), 'filter results should not include tree connectors')
    local match_marks = {}
    local directory_marks = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})) do
        if mark[4].hl_group == 'DoraFilterMatch' then
            match_marks[#match_marks+1] = mark
        elseif mark[4].hl_group == 'DoraFilterPath' then
            directory_marks[#directory_marks+1] = mark
        end
    end
    assert_eq(#match_marks, 3, 'filter should highlight each visible basename match')
    for _, mark in ipairs(match_marks) do
        local line = filtered_lines[mark[2] + 1]
        assert_eq(line:sub(mark[3] + 1, mark[4].end_col):lower(), 'match',
            'filter match highlight should cover the matching basename letters')
        assert_eq(mark[4].priority, 10001)
    end
    assert_eq(#directory_marks, 2, 'filter should highlight nested directory prefixes')
    for _, mark in ipairs(directory_marks) do
        local line = filtered_lines[mark[2] + 1]
        local directory = line:sub(mark[3] + 1, mark[4].end_col)
        assert(directory == 'alpha/' or directory == 'gamma/',
            'directory highlight should include the separator before the basename')
        assert_eq(mark[4].priority, 10000)
    end
    assert_eq(state.filter_preview, 'MATCH')

    filter:confirm()
    assert_eq(vim.api.nvim_get_current_win(), origin_win, 'confirming should return focus to Dora')
    assert_eq(state.filter_text, 'MATCH')
    assert_eq(state.filter_preview, nil)
    assert_eq(state.filter_window, filter, 'confirming should retain the filter window')
    assert_eq(state.filter_editing, false)
    assert(window.valid_win(filter.win), 'confirming should keep the filter window visible')
    assert_eq(vim.bo[filter.buf].modifiable, false, 'confirming should lock the filter input')
    local remaining_spacers = vim.tbl_filter(function(mark)
        return mark[4].virt_lines ~= nil
    end, vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true}))
    assert_eq(#remaining_spacers, 1, 'confirming should retain the virtual spacer')
    local locked_view = vim.api.nvim_win_call(origin_win, function()
        return vim.fn.winsaveview()
    end)
    assert_eq(locked_view.topline, 1, 'confirming should keep results at the top')
    assert_eq(locked_view.topfill, 1, 'confirming should keep the virtual spacer visible')
    assert_eq(current_line(), 'alpha/match.txt', 'confirming should select the first result')

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
    local escaped_view = vim.api.nvim_win_call(origin_win, function()
        return vim.fn.winsaveview()
    end)
    assert_eq(escaped_view.topfill, 1, 'escape should keep the virtual spacer visible')

    api.toggle_copy()
    assert_eq(state.marked_paths[fs.realpath(tmp) .. '/alpha/match.txt'], 'copy',
        'actions on filtered rows should use their real paths')
    local toggled_view = vim.api.nvim_win_call(origin_win, function()
        return vim.fn.winsaveview()
    end)
    assert_eq(toggled_view.topfill, 1, 'toggling a paste mark should keep the virtual spacer visible')
    api.next_sibling()
    assert_eq(current_line(), 'gamma/match.txt', 'filtered navigation should treat results as peers')
    api.next_sibling()
    assert_eq(current_line(), 'root-MATCH.txt', 'filtered next-sibling navigation should reach the final result')
    api.prev_sibling()
    api.prev_sibling()
    assert_eq(current_line(), 'alpha/match.txt', 'filtered previous-sibling navigation should reach the first result')

    set_cursor_line('root%-MATCH%.txt$')
    api.filter()
    local reopened_filter = assert(state.filter_window)
    assert_eq(reopened_filter, filter, 'reopening should reuse the visible filter window')
    assert_eq(vim.api.nvim_get_current_win(), reopened_filter.win, 'reopening should focus the filter window')
    assert_eq(reopened_filter:get_input(), 'MATCH', 'reopening should preload the committed filter')
    assert_eq(vim.api.nvim_win_get_cursor(reopened_filter.win)[2], #'MATCH',
        'reopening should place the cursor at the end')
    reopened_filter:set_input('other')
    assert_eq(buf_lines(state.buf)[1], 'alpha/other.lua', 'typing should update results live')
    reopened_filter:cancel()
    assert_eq(state.filter_text, 'MATCH', 'cancel should restore the committed filter')
    assert_eq(current_line(), 'root-MATCH.txt', 'cancel should restore the previous result cursor')
    assert_eq(state.filter_window, reopened_filter, 'cancel should retain the locked filter window')
    assert(window.valid_win(reopened_filter.win), 'cancel should keep the committed filter visible')
    assert_eq(reopened_filter:get_input(), 'MATCH', 'cancel should restore the committed filter text')
    assert_eq(vim.bo[reopened_filter.buf].modifiable, false, 'cancel should lock the filter input')
    local cancelled_view = vim.api.nvim_win_call(origin_win, function()
        return vim.fn.winsaveview()
    end)
    assert_eq(cancelled_view.topline, 1, 'cancel should keep results at the top')
    assert_eq(cancelled_view.topfill, 1, 'cancel should keep the virtual spacer visible')

    api.filter()
    local dismissed_filter = assert(state.filter_window)
    dismissed_filter:set_input('other')
    vim.api.nvim_win_close(dismissed_filter.win, true)
    assert(vim.wait(1000, function()
        return state.filter_window == nil
    end), 'externally closing the filter window should clear its handle')
    assert_eq(state.filter_text, 'MATCH', 'externally closing should preserve the committed filter')
    assert_eq(current_line(), 'root-MATCH.txt', 'externally closing should restore the previous result cursor')

    api.filter()
    local amended_filter = assert(state.filter_window)
    amended_filter:set_input('missing')
    assert_eq(#state.rows, 0, 'a filter with no matches should have no result rows')
    assert_eq(buf_lines(state.buf)[1], '', 'a filter with no matches should render a blank buffer')
    amended_filter:confirm()
    assert_eq(current_line(), '')
    assert(window.valid_win(amended_filter.win), 'confirming an amended filter should retain its window')
    api.clear_filter()
    assert_eq(state.filter_text, nil)
    assert_eq(state.filter_window, nil)
    assert(not window.valid_win(amended_filter.win), 'clearing should close the filter window')
    assert(vim.tbl_contains(lines(), 'alpha/'), 'clearing should restore the tree listing')

    api.filter()
    local cancelled_filter = assert(state.filter_window)
    cancelled_filter:set_input('other')
    cancelled_filter:cancel()
    assert_eq(state.filter_text, nil, 'cancelling a new filter should leave filtering disabled')
    assert_eq(state.filter_window, nil)
    assert(not window.valid_win(cancelled_filter.win), 'cancelling a new filter should close its window')

    api.filter()
    local empty_filter = assert(state.filter_window)
    empty_filter:set_input('match')
    empty_filter:set_input('')
    empty_filter:confirm()
    assert_eq(state.filter_text, nil, 'confirming an empty filter should clear filtering')
    assert_eq(state.filter_window, nil)
    assert(not window.valid_win(empty_filter.win), 'confirming an empty filter should hide its window')

    api.filter()
    local directory_filter = assert(state.filter_window)
    directory_filter:set_input('alpha')
    directory_filter:confirm()
    assert(window.valid_win(directory_filter.win), 'a committed directory filter should remain visible')
    assert_eq(current_line(), 'alpha/')
    api.open()
    assert_eq(state.cwd, fs.realpath(tmp .. '/alpha'), 'opening a filtered directory should navigate normally')
    assert_eq(state.filter_text, 'alpha', 'navigation should preserve the committed filter')
    assert_eq(state.filter_window, directory_filter, 'navigation should keep the filter window')
    assert(window.valid_win(directory_filter.win), 'navigation should keep the filter window visible')
    assert_eq(#state.rows, 0, 'the preserved filter should re-apply in the new directory')
    local navigated_view = vim.api.nvim_win_call(origin_win, function()
        return vim.fn.winsaveview()
    end)
    assert_eq(navigated_view.topfill, 1, 'navigation should keep the filter spacer visible')
    api.up_dir()
    assert_eq(state.cwd, fs.realpath(tmp), 'going up should return to the parent directory')
    assert_eq(state.filter_text, 'alpha', 'going up should preserve the committed filter')
    assert(window.valid_win(directory_filter.win), 'going up should keep the filter window visible')
    assert_eq(current_line(), 'alpha/', 'the preserved filter should match again after going up')
    api.clear_filter()
    assert_eq(state.filter_text, nil)
    assert(not window.valid_win(directory_filter.win), 'clearing should close the filter window')

    api.filter()
    local quit_filter = assert(state.filter_window)
    quit_filter:set_input('match')
    quit_filter:confirm()
    api.quit()
    assert(not window.valid_win(quit_filter.win), 'quitting Dora should close the filter window')
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/İmage.png')  -- 'İ' (U+0130) is 2 bytes but lowercases to 1-byte 'i'

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    local function match_highlight()
        local marks = vim.tbl_filter(function(mark)
            return mark[4].hl_group == 'DoraFilterMatch'
        end, vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true}))
        assert_eq(#marks, 1, 'multibyte filter should highlight the single match')
        local mark = marks[1]
        return buf_lines(state.buf)[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col)
    end

    api.filter()
    local filter = assert(state.filter_window)
    filter:set_input('png')
    assert_eq(match_highlight(), 'png',
        'match highlight should stay byte-accurate after case folding shrinks earlier characters')
    filter:set_input('image')
    assert_eq(match_highlight(), 'İmage',
        'match highlight should span multibyte characters whose case folding shrinks')
    filter:cancel()

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/init.lua')
    touch(tmp .. '/notes.lua.bak')
    touch(tmp .. '/readme.md')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    local function visible_names()
        return vim.tbl_filter(function(line) return line ~= '' end, buf_lines(state.buf))
    end

    api.filter()
    local filter = assert(state.filter_window)

    -- The filter is a Vim regex: `$` anchors to the end of the basename.
    filter:set_input('lua$')
    local anchored = visible_names()
    assert(vim.tbl_contains(anchored, 'init.lua'), 'anchored regex should match names ending in .lua')
    assert(not vim.tbl_contains(anchored, 'notes.lua.bak'),
        'anchored regex should exclude names where .lua is not at the end')
    assert(not vim.tbl_contains(anchored, 'readme.md'), 'anchored regex should exclude non-matching names')

    -- An incomplete/invalid pattern (common mid-typing) matches nothing rather
    -- than erroring.
    filter:set_input('init\\(')
    assert_eq(#visible_names(), 0, 'invalid regex should show no matches without erroring')

    -- <C-i> inverts the filter: the prompt gains a `!` marker and the result
    -- set flips to the rows that do not match.
    local function prefix_text()
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(filter.buf, filter.ns, 0, -1, {details = true})) do
            if mark[4].virt_text_pos == 'inline' and mark[4].right_gravity == false then
                return mark[4].virt_text[1][1]
            end
        end
    end
    filter:set_input('lua$')
    assert_eq(prefix_text(), 'Filter›', 'a non-inverted filter shows the plain prompt')
    filter:toggle_invert()
    assert(state.filter_inverted, 'toggling should invert the filter state')
    assert_eq(prefix_text(), 'Filter!›', 'an inverted filter marks the prompt with !')
    local inverted = visible_names()
    assert(not vim.tbl_contains(inverted, 'init.lua'), 'inverting should drop the matching rows')
    assert(vim.tbl_contains(inverted, 'notes.lua.bak'), 'inverting should keep the non-matching rows')
    assert(vim.tbl_contains(inverted, 'readme.md'), 'inverting should keep the non-matching rows')

    -- No basename span is highlighted for inverted (non-matching) rows.
    local match_marks = vim.tbl_filter(function(mark)
        return mark[4].hl_group == 'DoraFilterMatch'
    end, vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true}))
    assert_eq(#match_marks, 0, 'inverted rows should not highlight a match span')

    filter:toggle_invert()
    assert(not state.filter_inverted, 'toggling again should clear the inverted state')

    filter:cancel()
    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end
