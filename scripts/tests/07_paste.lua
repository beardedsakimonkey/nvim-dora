-- Cut/copy marks and paste: confirmations and conflicts, multi-window refresh, async copy/move.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/07_paste.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local dora = h.dora
local fs = h.fs
local confirm_win = h.confirm_win
local prompt = h.prompt
local api = h.api
local store = h.store
local window = h.window
local cwd = h.cwd
local assert_eq = h.assert_eq
local assert_match = h.assert_match
local touch = h.touch
local write_file = h.write_file
local marked_path_count = h.marked_path_count
local wait_for_paste = h.wait_for_paste
local set_cursor_line = h.set_cursor_line
local current_line = h.current_line
local set_cursor_pos = h.set_cursor_pos
local win_title = h.win_title
local has_high_priority_highlight = h.has_high_priority_highlight
local has_sign_highlight = h.has_sign_highlight

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')
    touch(tmp .. '/bravo.txt')
    touch(tmp .. '/charlie.txt')
    touch(tmp .. '/delta.txt')
    touch(tmp .. '/echo.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    assert_eq(vim.fn.maparg(']m', 'n', false, true).desc, 'Next paste mark')
    assert_eq(vim.fn.maparg('[m', 'n', false, true).desc, 'Previous paste mark')
    assert_eq(vim.fn.maparg(']m', 'x', false, true).desc, 'Next paste mark')
    assert_eq(vim.fn.maparg('[m', 'x', false, true).desc, 'Previous paste mark')

    -- Mark non-adjacent rows with a mix of cut and copy.
    set_cursor_line('bravo%.txt$')
    api.toggle_cut()
    set_cursor_line('delta%.txt$')
    api.toggle_copy()
    set_cursor_line('echo%.txt$')
    api.toggle_copy()
    assert_eq(marked_path_count(state), 3)

    set_cursor_line('alpha%.txt$')
    api.next_paste_mark()
    assert_match(current_line(), 'bravo%.txt$', 'next mark should jump to the first paste mark below the cursor')
    api.next_paste_mark()
    assert_match(current_line(), 'delta%.txt$', 'next mark should skip unmarked rows to the following mark')
    api.next_paste_mark()
    assert_match(current_line(), 'echo%.txt$', 'next mark should jump to copy marks as well as cut marks')
    api.next_paste_mark()
    assert_match(current_line(), 'echo%.txt$', 'next mark should stay put when no further mark exists')

    api.prev_paste_mark()
    assert_match(current_line(), 'delta%.txt$', 'previous mark should jump to the closest mark above the cursor')

    set_cursor_line('alpha%.txt$')
    vim.api.nvim_feedkeys('2]m', 'xt', false)
    assert_match(current_line(), 'delta%.txt$', 'counted next mark should skip the requested number of marks')

    set_cursor_line('echo%.txt$')
    vim.api.nvim_feedkeys('2[m', 'xt', false)
    assert_match(current_line(), 'bravo%.txt$', 'counted previous mark should skip the requested number of marks')

    set_cursor_line('alpha%.txt$')
    vim.api.nvim_feedkeys('V2]m', 'xt', false)
    assert_match(current_line(), 'delta%.txt$', 'visual next mark should support counts')
    assert_eq(vim.api.nvim_get_mode().mode, 'V', 'visual next mark should keep the selection active')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)

    set_cursor_line('echo%.txt$')
    vim.api.nvim_feedkeys('V2[m', 'xt', false)
    assert_match(current_line(), 'bravo%.txt$', 'visual previous mark should support counts')
    assert_eq(vim.api.nvim_get_mode().mode, 'V', 'visual previous mark should keep the selection active')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local old_notify = vim.notify
    local notifications = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
        notifications[#notifications+1] = {msg = msg, level = level}
    end
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_line('alpha%.txt$')
    api.toggle_copy()
    assert_eq(marked_path_count(state), 1)
    assert_eq(state.marked_paths[state.cwd .. '/alpha.txt'], 'copy', 'copy should mark the current file')
    assert(has_sign_highlight(state, 'DoraCopy'), 'copy should use a distinct sign highlight')
    assert(has_high_priority_highlight(state, 'DoraCopy'), 'copy should highlight filenames like the copy sign')

    api.toggle_copy()
    assert_eq(marked_path_count(state), 0, 'copy should toggle off an existing copy mark')

    api.toggle_cut()
    assert_eq(state.marked_paths[state.cwd .. '/alpha.txt'], 'cut', 'cut should replace a missing mark')
    assert(has_sign_highlight(state, 'DoraCut'), 'cut should use a distinct sign highlight')
    api.toggle_copy()
    assert_eq(state.marked_paths[state.cwd .. '/alpha.txt'], 'copy', 'copy should replace an existing cut mark')

    set_cursor_pos('dest')
    api.paste_under()

    local paste_win = vim.api.nvim_get_current_win()
    assert_match(win_title(paste_win), 'Paste%?')
    local paste_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert_eq(paste_lines[1], 'alpha.txt', 'paste confirmation should list the source file')
    assert_eq(paste_lines[2], '↓', 'paste confirmation should show a down-arrow separator')
    assert_eq(paste_lines[3], 'dest/', 'paste confirmation should show the target path relative to the root')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert(fs.exists(tmp .. '/alpha.txt'), 'single-file copy should leave the source file')
    assert(fs.exists(tmp .. '/dest/alpha.txt'), 'paste should copy into the hovered directory')
    assert_eq(marked_path_count(state), 0)
    assert(state.expanded_dirs[state.cwd .. '/dest'], 'paste should expand the destination directory')
    assert_match(current_line(), 'alpha%.txt$', 'paste should move cursor to the pasted file')
    assert_eq(notifications[#notifications].msg, 'dora: Pasted 1 item to ' .. state.cwd .. '/dest')
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)

    api.quit()
    vim.notify = old_notify
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')
    touch(tmp .. '/dest/beta.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_line('alpha%.txt$')
    api.toggle_copy()
    set_cursor_pos('dest')
    api.fold_out()
    set_cursor_line('beta%.txt$')
    api.paste_under()
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert(fs.exists(tmp .. '/dest/alpha.txt'), 'paste over a plain file should copy into its parent directory')
    assert_eq(marked_path_count(state), 0)
    assert_match(current_line(), 'alpha%.txt$', 'paste should move cursor to the pasted file')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/sub/a.c')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('sub')
    api.fold_out()
    set_cursor_line('a%.c$')
    api.toggle_copy()
    set_cursor_pos('dest')
    api.paste_under()

    assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1], 'sub/a.c',
        'paste confirmation should list source files relative to the root')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert(fs.exists(tmp .. '/dest/a.c'), 'paste should copy the nested source file')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))
    touch(tmp .. '/a.c')
    touch(tmp .. '/sub/b.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local root = state.cwd
    set_cursor_line('a%.c$')
    api.toggle_copy()
    set_cursor_pos('sub')
    api.open()
    assert_eq(state.cwd, root .. '/sub', 'opening a directory should descend into it')

    set_cursor_line('b%.txt$')
    api.paste_under()

    -- The absolute path may be too long for the window and get middle-elided;
    -- accept that as long as the surviving head and tail come from it (and it is
    -- the absolute path, not a `../`-relative one).
    local confirm_line = vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]
    local expected_abs = root .. '/a.c'
    local head, tail = confirm_line:match('^(.*)…(.*)$')
    local shows_absolute = confirm_line == expected_abs
        or (head ~= nil and expected_abs:sub(1, #head) == head
            and (tail == '' or expected_abs:sub(-#tail) == tail))
    assert(shows_absolute, 'paste confirmation should list marks above the root as absolute paths')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert(fs.exists(root .. '/sub/a.c'), 'paste should copy a mark from above the root')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Pasting in one dora window refreshes every other dora window: marks are
-- shared across windows, so the window where a file was marked must drop the
-- now-consumed cut/copy highlight (and a cut's vanished rows) without a manual
-- reload.
local function has_mark_sign(buf, ns)
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details = true})) do
        -- Neovim pads sign_text to two cells, so match the glyph as a prefix.
        if mark[4] and mark[4].sign_text and mark[4].sign_text:find('▌', 1, true) then
            return true
        end
    end
    return false
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')

    -- Window 1 owns the mark, so it is the window that renders the highlight.
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local buf1 = vim.api.nvim_get_current_buf()
    local state1 = store.get(buf1)
    set_cursor_line('alpha%.txt$')
    api.toggle_copy()
    assert(has_mark_sign(buf1, state1.ns), 'marking a file should sign it in the originating window')

    -- Window 2 is a separate dora session on the same directory.
    vim.cmd('new')
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local buf2 = vim.api.nvim_get_current_buf()
    assert(buf2 ~= buf1, 'a second Dora window should be a separate session')

    set_cursor_pos('dest')
    api.paste_under()
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert(fs.exists(tmp .. '/dest/alpha.txt'), 'paste should copy the marked file')
    -- The source is untouched by a copy, so no directory watcher fires for
    -- window 1; only the paste's explicit refresh can clear its stale mark.
    assert(not has_mark_sign(buf1, state1.ns),
        'pasting in another window should clear the originating window\'s mark')

    api.quit()
    vim.cmd('bwipeout! ' .. buf1)
    vim.cmd('silent! only')
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Toggling a mark in one dora window refreshes the others. Marks are shared, so
-- a window showing the same path must paint (and later drop) the cut/copy sign
-- without waiting for a manual reload.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local buf1 = vim.api.nvim_get_current_buf()
    local state1 = store.get(buf1)
    assert(not has_mark_sign(buf1, state1.ns), 'no mark should show before toggling')

    -- A second session on the same directory becomes the active window.
    vim.cmd('new')
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local buf2 = vim.api.nvim_get_current_buf()
    assert(buf2 ~= buf1, 'a second Dora window should be a separate session')

    set_cursor_line('alpha%.txt$')
    api.toggle_copy()
    assert(has_mark_sign(buf2, store.get(buf2).ns), 'marking should sign the active window')
    assert(has_mark_sign(buf1, state1.ns),
        'toggling a mark should refresh the other dora window\'s sign')

    api.toggle_copy()
    assert(not has_mark_sign(buf1, state1.ns),
        'un-toggling a mark should clear the other window\'s sign too')

    api.quit()
    vim.cmd('bwipeout! ' .. buf1)
    vim.cmd('silent! only')
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local old_notify = vim.notify
    local notifications = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
        notifications[#notifications+1] = {msg = msg, level = level}
    end
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local reload_map = vim.fn.maparg('<C-r>', 'n', false, true)
    assert_eq(reload_map.desc, 'Reload listing')
    assert_eq(type(reload_map.callback), 'function')
    set_cursor_line('alpha%.txt$')
    api.toggle_copy()
    assert_eq(marked_path_count(state), 1)

    assert_eq(vim.fn.delete(tmp .. '/alpha.txt'), 0)
    reload_map.callback()
    assert_eq(marked_path_count(state), 0, 'reload should clear marks for files deleted externally')
    api.paste_under()
    assert_eq(notifications[#notifications].msg, 'dora: Nothing to paste')
    assert_eq(notifications[#notifications].level, vim.log.levels.ERROR)

    api.quit()
    vim.notify = old_notify
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    write_file(tmp .. '/alpha.txt', 'new')
    write_file(tmp .. '/dest/alpha.txt', 'old')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_line('^alpha%.txt$')
    api.toggle_copy()
    set_cursor_pos('dest')
    api.fold_out()
    set_cursor_line('alpha%.txt$')
    local origin_win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(origin_win)
    local cursor_pos = vim.fn.screenpos(origin_win, cursor[1], cursor[2] + 1)
    api.paste()

    local confirm_win = vim.api.nvim_get_current_win()
    local confirm_cfg = vim.api.nvim_win_get_config(confirm_win)
    assert_match(win_title(confirm_win), 'Paste%?')
    assert(not win_title(confirm_win):match('overwrite'),
        'paste confirmation should keep the overwrite hint out of the title')
    assert_match(vim.wo[confirm_win].winhighlight, 'FloatBorder:DoraPromptBorderWarn',
        'a conflicting paste confirmation should warn on its border')
    local confirm_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local confirm_width = confirm_cfg.width
    local function pad_for(text)
        return math.max(0, math.floor((confirm_width - vim.fn.strdisplaywidth(text)) / 2))
    end
    local function centered(text)
        return string.rep(' ', pad_for(text)) .. text
    end
    local hint_str = 'r rename   o overwrite'
    assert_eq(confirm_lines[1], centered('⚠ 1 conflict'),
        'a centered conflict count should head the confirmation')
    assert_eq(confirm_lines[2], centered(hint_str),
        'a centered both-keys hint should sit below the count')
    assert_eq(confirm_lines[3], string.rep('─', confirm_width),
        'a full-width divider should separate the header from the list')
    assert_eq(confirm_lines[4], 'alpha.txt → alpha(1).txt (rename)',
        'a conflict row should preview the kept-both name and tag its fate')
    assert_eq(confirm_lines[5], '↓', 'paste confirmation should show a down-arrow separator')
    assert_eq(confirm_lines[6], 'dest/', 'paste confirmation should show the target path relative to the root')
    assert_eq(confirm_cfg.row, cursor_pos.row,
        'paste confirmation should anchor below the cursorline')

    -- The count and each row's fate are colored; the hint spotlights both
    -- mnemonic keys and underlines just the active mode's name (rename, by
    -- default); the previewed name keeps its file-type color while the arrow reads
    -- in the normal color (not muted).
    local warn_pad, hint_pad = pad_for('⚠ 1 conflict'), pad_for(hint_str)
    local key_r, key_o = hint_pad, hint_pad + #'r rename   '
    local warn, hint_keys, rename_underlined, divider_muted, suffix_warn, arrow_muted, preview_name =
        false, 0, false, false, false, false, false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {details = true})) do
        local row, col, details = mark[2], mark[3], mark[4]
        ---@cast details -nil
        if row == 0 and col == warn_pad and details.hl_group == 'DoraWarn' then
            warn = true
        end
        if row == 2 and col == 0 and details.hl_group == 'DoraMutedText' then
            divider_muted = true
        end
        if row == 1 and details.hl_group == 'DoraInfoValue' and details.end_col == col + 1
            and (col == key_o or col == key_r) then
            hint_keys = hint_keys + 1
        end
        if row == 1 and col == hint_pad + #'r ' and details.end_col == hint_pad + #'r rename'
            and details.hl_group == 'DoraUnderline' then
            rename_underlined = true
        end
        if row == 3 and col == #'alpha.txt → alpha(1).txt' and details.hl_group == 'DoraWarn' then
            suffix_warn = true
        end
        if row == 3 and details.hl_group == 'DoraVirtText' then
            arrow_muted = true
        end
        if row == 3 and col == #'alpha.txt → ' and details.hl_group == 'DoraCopy' then
            preview_name = true
        end
    end
    assert(warn, 'the centered conflict count should be highlighted')
    assert_eq(hint_keys, 2, 'both mnemonic keys should be highlighted')
    assert(rename_underlined, 'keep-both mode should underline the rename name')
    assert(divider_muted, 'the header divider should be muted')
    assert(suffix_warn, 'each conflict row should tag its fate in the warning color')
    assert(not arrow_muted, 'the rename preview arrow should read in the normal color')
    assert(preview_name, 'the rename preview name should match the marked file color (copy)')

    -- `o` switches to overwrite mode in place: the border keeps warning, the
    -- rename preview collapses to the conflicting name (still tagged), the static
    -- hint is unchanged, and the underline moves to the overwrite name.
    vim.api.nvim_feedkeys('o', 'xt', false)
    assert_match(vim.wo[confirm_win].winhighlight, 'FloatBorder:DoraPromptBorderWarn',
        'overwrite mode should keep the warning border')
    local overwrite_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert_eq(overwrite_lines[1], centered('⚠ 1 conflict'),
        'overwrite mode should keep the centered conflict count')
    assert_eq(overwrite_lines[2], centered(hint_str),
        'the both-keys hint should not change with the mode')
    assert_eq(overwrite_lines[4], 'alpha.txt (overwrite)',
        'overwrite mode should drop the preview and tag the row as overwritten')
    local overwrite_underlined = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {details = true})) do
        local row, col, details = mark[2], mark[3], mark[4]
        ---@cast details -nil
        if row == 1 and col == hint_pad + #'r rename   o ' and details.end_col == hint_pad + #hint_str
            and details.hl_group == 'DoraUnderline' then
            overwrite_underlined = true
        end
    end
    assert(overwrite_underlined, 'overwrite mode should underline the overwrite name')
    vim.api.nvim_feedkeys('r', 'xt', false)
    assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[4], 'alpha.txt → alpha(1).txt (rename)',
        'r should switch back to keep-both mode')

    vim.api.nvim_feedkeys('n', 'xt', false)

    assert_eq(vim.fn.readfile(tmp .. '/dest/alpha.txt')[1], 'old',
        'declining paste should preserve the destination file')
    assert_eq(marked_path_count(state), 1,
        'declining paste should preserve paste marks')

    for _, lhs in ipairs({'p', 'P'}) do
        api.paste()
        local paste_confirm_win = vim.api.nvim_get_current_win()
        assert_match(win_title(paste_confirm_win), 'Paste%?')
        vim.api.nvim_feedkeys(lhs, 'xt', false)
        assert(not vim.api.nvim_win_is_valid(paste_confirm_win),
            lhs .. ' should close the paste confirmation')
        assert_eq(vim.api.nvim_get_current_win(), origin_win,
            lhs .. ' should restore focus after closing the paste confirmation')
        assert_eq(marked_path_count(state), 1,
            lhs .. ' should cancel paste without clearing marks')
    end

    api.paste()
    assert_match(win_title(vim.api.nvim_get_current_win()), 'Paste%?')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert_eq(vim.fn.readfile(tmp .. '/dest/alpha.txt')[1], 'old',
        'keep-both paste should preserve the existing destination file')
    assert_eq(vim.fn.readfile(tmp .. '/dest/alpha(1).txt')[1], 'new',
        'keep-both paste should land beside the conflict under a free name')
    assert(fs.exists(tmp .. '/alpha.txt'), 'copy should preserve the source file')
    assert_eq(marked_path_count(state), 0,
        'successful paste should clear paste marks')
    assert_match(current_line(), 'alpha%(1%)%.txt$',
        'successful paste should move the cursor to the kept-both file')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Pasting a directory into itself would throw mid-copy, so the confirmation
    -- blocks it: an "Error" title, a red border, a centered error (padded off the
    -- border) heading the list above a divider, and confirm keys that only dismiss.
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/foo', tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_pos('foo')
    api.toggle_copy()
    local origin_win = vim.api.nvim_get_current_win()
    api.paste_under()

    local confirm_win = vim.api.nvim_get_current_win()
    local confirm_cfg = vim.api.nvim_win_get_config(confirm_win)
    assert_match(win_title(confirm_win), 'Paste Error')
    assert_match(vim.wo[confirm_win].winhighlight, 'FloatBorder:DoraPromptBorderInvalid',
        'a paste into itself should flag the error on its border')
    local confirm_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local confirm_width = confirm_cfg.width
    -- A leading space keeps the error icon off the left border; RIGHT_PADDING
    -- balances the right, so the centered line carries one space on each side.
    local error_text = ' ✗ Cannot paste a directory into itself'
    local error_pad = math.max(0, math.floor((confirm_width - vim.fn.strdisplaywidth(error_text)) / 2))
    assert_eq(confirm_lines[1], string.rep(' ', error_pad) .. error_text,
        'a centered error should head the blocked paste confirmation')
    assert_eq(confirm_lines[2], string.rep('─', confirm_width),
        'a full-width divider should separate the error from the list')
    assert_eq(confirm_lines[3], 'foo/', 'the blocked paste should still list the source')
    assert_eq(confirm_lines[4], '↓', 'the blocked paste should show a down-arrow separator')
    assert_eq(confirm_lines[5], 'foo/', 'the blocked paste should show the destination')

    local error_hl, error_bold = false, false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {details = true})) do
        local row, col, details = mark[2], mark[3], mark[4]
        ---@cast details -nil
        if row == 0 and col == error_pad and details.hl_group == 'DoraError' then
            error_hl = true
        end
        if row == 0 and col == error_pad and details.hl_group == 'DoraBold' then
            error_bold = true
        end
    end
    assert(error_hl, 'the centered error should be highlighted')
    assert(error_bold, 'the centered error should be bold')

    -- A blocking error has nothing to confirm, so <CR> just dismisses the window
    -- without pasting, leaving the mark intact and restoring focus.
    vim.api.nvim_feedkeys('\r', 'xt', false)
    assert(not vim.api.nvim_win_is_valid(confirm_win),
        'a blocked paste should dismiss on the confirm key')
    assert(not fs.exists(tmp .. '/foo/foo'),
        'a blocked paste should not copy the directory into itself')
    assert_eq(marked_path_count(state), 1, 'a blocked paste should preserve the mark')
    assert_eq(vim.api.nvim_get_current_win(), origin_win,
        'dismissing should restore focus to the tree')

    -- Esc cancels the reopened confirmation just the same.
    set_cursor_pos('foo')
    api.paste_under()
    local cancel_win = vim.api.nvim_get_current_win()
    assert(cancel_win ~= origin_win, 'the blocked paste should reopen')
    vim.api.nvim_feedkeys('\27', 'xt', false)
    assert(not vim.api.nvim_win_is_valid(cancel_win),
        'cancelling should close the blocked paste confirmation')
    assert_eq(vim.api.nvim_get_current_win(), origin_win,
        'cancelling should restore focus to the tree')
    assert_eq(marked_path_count(state), 1, 'cancelling a blocked paste should keep the mark')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Pasting into the source directory is still a conflict: keep-both copies
    -- or moves to a free sibling name, while overwrite safely leaves the exact
    -- same filesystem object in place.
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    write_file(tmp .. '/.luarc(1).json', 'luarc')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_line('^%.luarc%(1%)%.json$')
    api.toggle_copy()
    api.paste()

    local confirm_win = vim.api.nvim_get_current_win()
    assert_match(vim.wo[confirm_win].winhighlight, 'FloatBorder:DoraPromptBorderWarn',
        'a same-directory copy should be detected as a conflict')
    assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[4],
        '.luarc(1).json → .luarc(2).json (rename)',
        'a same-directory copy should increment an existing numeric suffix')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert_eq(vim.fn.readfile(tmp .. '/.luarc(1).json')[1], 'luarc',
        'same-directory keep-both copy should preserve the source')
    assert_eq(vim.fn.readfile(tmp .. '/.luarc(2).json')[1], 'luarc',
        'same-directory keep-both copy should use the incremented suffix')
    assert(not fs.exists(tmp .. '/.luarc(1)(1).json'),
        'same-directory keep-both copy should not nest numeric suffixes')

    set_cursor_line('^%.luarc%(1%)%.json$')
    api.toggle_cut()
    api.paste()
    assert_match(vim.wo[vim.api.nvim_get_current_win()].winhighlight,
        'FloatBorder:DoraPromptBorderWarn',
        'a same-directory cut should be detected as a conflict')
    assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[4],
        '.luarc(1).json → .luarc(3).json (rename)',
        'a same-directory cut should preview its kept-both name')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert(not fs.exists(tmp .. '/.luarc(1).json'),
        'same-directory keep-both cut should move the source')
    assert_eq(vim.fn.readfile(tmp .. '/.luarc(3).json')[1], 'luarc',
        'same-directory keep-both cut should use the previewed free sibling')

    set_cursor_line('^%.luarc%(2%)%.json$')
    api.toggle_copy()
    api.paste()
    vim.api.nvim_feedkeys('o', 'xt', false)
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert_eq(vim.fn.readfile(tmp .. '/.luarc(2).json')[1], 'luarc',
        'same-directory overwrite should leave the source intact')
    assert(not fs.exists(tmp .. '/.luarc(2)(1).json'),
        'same-directory overwrite should not create a sibling')
    assert_eq(marked_path_count(state), 0,
        'successful same-directory overwrite should clear paste marks')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Conflict previews reserve generated names across the whole paste batch,
    -- matching the sequential names chosen during execution.
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    write_file(tmp .. '/AGENTS(1).md', 'one')
    write_file(tmp .. '/AGENTS(2).md', 'two')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_line('^AGENTS%(1%)%.md$')
    api.toggle_copy()
    set_cursor_line('^AGENTS%(2%)%.md$')
    api.toggle_copy()
    api.paste()

    local confirm_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert_eq(confirm_lines[4], 'AGENTS(1).md → AGENTS(3).md (rename)',
        'the first conflict should preview the first free suffix')
    assert_eq(confirm_lines[5], 'AGENTS(2).md → AGENTS(4).md (rename)',
        'the second conflict should reserve and skip the first previewed suffix')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert_eq(vim.fn.readfile(tmp .. '/AGENTS(3).md')[1], 'one',
        'the first conflict should use its previewed destination')
    assert_eq(vim.fn.readfile(tmp .. '/AGENTS(4).md')[1], 'two',
        'the second conflict should use its previewed destination')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Overwriting (o) replaces the existing file instead of keeping both.
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    write_file(tmp .. '/alpha.txt', 'new')
    write_file(tmp .. '/dest/alpha.txt', 'old')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_line('^alpha%.txt$')
    api.toggle_copy()
    set_cursor_pos('dest')
    api.paste_under()
    assert_match(win_title(vim.api.nvim_get_current_win()), 'Paste%?')
    vim.api.nvim_feedkeys('o', 'xt', false)
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert_eq(vim.fn.readfile(tmp .. '/dest/alpha.txt')[1], 'new',
        'overwriting paste should replace the destination file')
    assert(not fs.exists(tmp .. '/dest/alpha(1).txt'),
        'overwriting paste should not leave a kept-both copy')
    assert(fs.exists(tmp .. '/alpha.txt'), 'copy overwrite should preserve the source file')
    assert_eq(marked_path_count(state), 0,
        'successful overwrite should clear paste marks')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/foo', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest/foo', tonumber('755', 8)))
    write_file(tmp .. '/foo/new.txt', 'new')
    write_file(tmp .. '/dest/foo/old.txt', 'old')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('foo')
    api.toggle_copy()
    set_cursor_pos('dest')
    api.paste_under()

    assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[4], 'foo/ → foo(1)/ (rename)',
        'pasting a directory onto an existing one should preview a kept-both name with a trailing slash on the rename')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert(fs.exists(tmp .. '/dest/foo(1)/new.txt'),
        'keep-both directory paste should copy contents beside the existing directory')
    assert(fs.exists(tmp .. '/dest/foo/old.txt'),
        'keep-both directory paste should preserve the existing directory')
    assert(fs.exists(tmp .. '/foo'), 'copying should preserve the source directory')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Overwriting a directory replaces the existing one outright.
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/foo', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest/foo', tonumber('755', 8)))
    write_file(tmp .. '/foo/new.txt', 'new')
    write_file(tmp .. '/dest/foo/old.txt', 'old')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('foo')
    api.toggle_copy()
    set_cursor_pos('dest')
    api.paste_under()
    vim.api.nvim_feedkeys('o', 'xt', false)
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert(fs.exists(tmp .. '/dest/foo/new.txt'),
        'overwriting should copy the pasted directory contents')
    assert(not fs.exists(tmp .. '/dest/foo/old.txt'),
        'overwriting a directory should replace the existing directory')
    assert(not fs.exists(tmp .. '/dest/foo(1)'),
        'overwriting should not leave a kept-both directory')
    assert(fs.exists(tmp .. '/foo'), 'copying should preserve the source directory')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')
    touch(tmp .. '/c')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    set_cursor_line('a$')
    api.toggle_cut()
    assert_eq(state.marked_paths[state.cwd .. '/a'], 'cut', 'cut should mark a file')
    set_cursor_line('c$')
    api.toggle_copy()
    assert_eq(state.marked_paths[state.cwd .. '/c'], 'copy', 'copy should mark another file independently')
    assert_eq(marked_path_count(state), 2)
    assert(has_sign_highlight(state, 'DoraCut'), 'cut marks should use the cut sign')
    assert(has_high_priority_highlight(state, 'DoraCut'), 'cut marks should highlight filenames like the cut sign')
    assert(has_sign_highlight(state, 'DoraCopy'), 'copy marks should use the copy sign')
    assert(has_high_priority_highlight(state, 'DoraCopy'), 'copy marks should highlight filenames like the copy sign')

    api.clear_cut()
    assert_eq(state.marked_paths[state.cwd .. '/a'], nil, 'clear_cut should drop cut marks')
    assert_eq(state.marked_paths[state.cwd .. '/c'], 'copy', 'clear_cut should keep copy marks')
    assert_eq(marked_path_count(state), 1)

    api.clear_copy()
    assert_eq(marked_path_count(state), 0, 'clear_copy should drop the remaining copy marks')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    set_cursor_pos('a')
    api.toggle_cut()
    set_cursor_pos('b')
    api.toggle_copy()
    assert_eq(marked_path_count(state), 2)

    set_cursor_pos('dest')
    api.fold_out()
    api.paste_under()
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert(not fs.exists(tmp .. '/a'), 'mixed paste should remove cut source a')
    assert(fs.exists(tmp .. '/b'), 'mixed paste should leave copied source b')
    assert(fs.exists(tmp .. '/dest/a'), 'mixed paste should move cut file a')
    assert(fs.exists(tmp .. '/dest/b'), 'mixed paste should copy file b')
    assert_eq(marked_path_count(state), 0)

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Copying a directory recurses through the async copy, preserving nested files
-- and symlinks while leaving the source intact.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/tree', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/tree/nested', tonumber('755', 8)))
    write_file(tmp .. '/tree/top.txt', 'top')
    write_file(tmp .. '/tree/nested/leaf.txt', 'leaf')
    assert(vim.loop.fs_symlink('top.txt', tmp .. '/tree/link'))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('tree')
    api.toggle_copy()
    set_cursor_pos('dest')
    api.paste_under()
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert(fs.is_dir(tmp .. '/tree'), 'directory copy should leave the source directory')
    assert_eq(vim.fn.readfile(tmp .. '/dest/tree/top.txt')[1], 'top',
        'directory copy should copy top-level files')
    assert_eq(vim.fn.readfile(tmp .. '/dest/tree/nested/leaf.txt')[1], 'leaf',
        'directory copy should recurse into nested directories')
    assert_eq(vim.loop.fs_readlink(tmp .. '/dest/tree/link'), 'top.txt',
        'directory copy should recreate symlinks rather than follow them')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Marks are shared across dora windows so a path marked in one window can
    -- be pasted from another.
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')
    local root = fs.realpath(tmp)

    local source_win = vim.api.nvim_get_current_win()
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local source_state = store.get()
    set_cursor_pos('alpha.txt')
    api.toggle_copy()
    assert_eq(source_state.marked_paths[root .. '/alpha.txt'], 'copy',
        'copy should mark the file in the source window')

    vim.cmd('new')
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local dest_state = store.get()
    assert(dest_state ~= source_state, 'a second dora window should have its own state')
    assert_eq(dest_state.marked_paths[root .. '/alpha.txt'], 'copy',
        'marks should be shared with another dora window')

    set_cursor_pos('dest')
    api.paste_under()
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()
    assert(fs.exists(root .. '/dest/alpha.txt'),
        'pasting in another window should copy the file marked elsewhere')
    assert(fs.exists(root .. '/alpha.txt'), 'copy should leave the source file')
    assert_eq(marked_path_count(dest_state), 0, 'pasting should clear the shared marks')
    assert_eq(marked_path_count(source_state), 0,
        'pasting in one window should clear marks shown in the other')

    api.quit()
    vim.cmd('close!')
    vim.api.nvim_set_current_win(source_win)
    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    assert_eq(vim.fn.maparg('r', 'n', false, true).desc, 'Rename file')
    assert_eq(vim.fn.maparg('R', 'n', false, true).desc, 'Rename file with empty prompt')
    set_cursor_pos('alpha.txt')
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = state.rows[cursor[1]]

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.prompt, 'Rename')
        assert_eq(opts.initial_prompt, 'alpha.txt')
        assert_eq(opts.cwd, state.cwd)
        assert_eq(opts.width, 32)
        assert(opts.anchor, 'rename should anchor the prompt to the current row')
        assert_eq(opts.anchor.win, vim.api.nvim_get_current_win())
        assert_eq(opts.anchor.line, cursor[1])
        assert_eq(opts.anchor.col, row.name_start_col)
        assert(opts.anchor.superimpose, 'rename should superimpose the prompt onto the current row')
        assert(not pcall(opts.validate, 'nested/beta.txt'), 'rename prompt should reject relocation')
        cb('beta.txt', opts.validate('beta.txt'))
    end
    api.rename()
    prompt.input = old_input

    assert(not fs.exists(tmp .. '/alpha.txt'), 'rename should remove the old file')
    assert(fs.exists(tmp .. '/beta.txt'), 'rename should create the renamed file')
    assert_match(current_line(), 'beta%.txt$', 'rename should move cursor to the renamed file')

    local empty_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.prompt, 'Rename')
        assert_eq(opts.initial_prompt, '', 'empty rename should omit the current filename')
        cb('gamma.txt', opts.validate('gamma.txt'))
    end
    api.rename_empty()
    prompt.input = empty_input

    assert(not fs.exists(tmp .. '/beta.txt'), 'empty rename should remove the old file')
    assert(fs.exists(tmp .. '/gamma.txt'), 'empty rename should create the renamed file')
    assert_match(current_line(), 'gamma%.txt$', 'empty rename should move cursor to the renamed file')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end
