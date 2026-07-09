-- Auto-open on directory edit, session reuse, splits, preview window, end-to-end :Dora.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/14_windows.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local dora = h.dora
local fs = h.fs
local api = h.api
local store = h.store
local window = h.window
local cwd = h.cwd
local assert_eq = h.assert_eq
local write_file = h.write_file
local clear_persisted_view_state = h.clear_persisted_view_state
local lines = h.lines
local buf_lines = h.buf_lines
local set_cursor_pos = h.set_cursor_pos

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    local old_home = vim.env.HOME
    vim.env.HOME = tmp

    vim.cmd('vsplit ~')
    local state = store.get()
    assert(vim.api.nvim_buf_get_var(0, 'is_dora'), 'editing ~ should open Dora')
    assert_eq(state.cwd, fs.realpath(tmp), 'editing ~ should open Dora at the home directory')

    api.quit()
    vim.cmd('close!')
    vim.env.HOME = old_home
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local buf = vim.api.nvim_get_current_buf()
    local buf_count = #vim.api.nvim_list_bufs()

    vim.cmd('edit ' .. vim.fn.fnameescape(tmp .. '/sub'))
    assert_eq(vim.api.nvim_get_current_buf(), buf, 'editing a directory from dora should reuse the session buffer')
    assert_eq(store.get(), state, 'editing a directory from dora should reuse the session state')
    assert_eq(state.cwd, fs.realpath(tmp .. '/sub'), 'editing a directory from dora should navigate the session')
    assert_eq(#vim.api.nvim_list_bufs(), buf_count, 'editing a directory from dora should not leak buffers')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    assert_eq(vim.api.nvim_get_current_buf(), buf, ':Dora inside dora should reuse the session buffer')
    assert_eq(state.cwd, fs.realpath(tmp), ':Dora inside dora should navigate the session')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local left_win = vim.api.nvim_get_current_win()
    local left_buf = vim.api.nvim_get_current_buf()
    local left_state = store.get()

    vim.cmd('vsplit ' .. vim.fn.fnameescape(tmp .. '/sub'))
    local right_win = vim.api.nvim_get_current_win()
    local right_buf = vim.api.nvim_get_current_buf()
    local right_state = store.get()

    assert(right_win ~= left_win, 'vsplit should create a second window')
    assert(right_buf ~= left_buf, 'vsplit directory from dora should create a separate Dora buffer')
    assert(right_state ~= left_state, 'vsplit directory from dora should create a separate Dora session')
    assert_eq(vim.api.nvim_win_get_buf(left_win), left_buf, 'vsplit directory from dora should leave the original window unchanged')
    assert_eq(vim.api.nvim_win_get_buf(right_win), right_buf, 'vsplit directory from dora should use the new buffer in the split')
    assert_eq(left_state.cwd, fs.realpath(tmp), 'vsplit directory from dora should not retarget the original session')
    assert_eq(right_state.cwd, fs.realpath(tmp .. '/sub'), 'vsplit directory from dora should browse the requested directory')

    api.quit()
    vim.api.nvim_win_close(right_win, true)
    vim.api.nvim_set_current_win(left_win)
    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local original_cwd = vim.fn.getcwd(-1, -1)
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    local target = fs.realpath(tmp)

    local function cmdline(cmd)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(':' .. cmd .. '<CR>', true, false, true), 'xt', false)
    end

    vim.cmd.tabnew()
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd.vnew()
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local right_win = vim.api.nvim_get_current_win()
    local duplicate_buf = vim.api.nvim_get_current_buf()

    assert(vim.api.nvim_buf_get_name(duplicate_buf) ~= target,
        'a simultaneous Dora session should receive a distinct buffer name')

    cmdline("let g:dora_smoke_cmdline_percent = expand('%')")
    assert_eq(vim.g.dora_smoke_cmdline_percent, vim.api.nvim_buf_get_name(duplicate_buf),
        '% should retain its normal meaning outside directory-changing commands')
    vim.g.dora_smoke_cmdline_percent = nil

    cmdline('tcd %')
    assert_eq(vim.fn.getcwd(), target, ':tcd % should use the browsed directory')
    assert_eq(vim.fn.getcwd(-1, -1), original_cwd, ':tcd % should not change the global working directory')
    vim.cmd.vnew()
    assert_eq(vim.fn.getcwd(), target, ':tcd % should apply to a new window in the tab')
    vim.cmd.close()
    vim.cmd('tcd ' .. vim.fn.fnameescape(original_cwd))

    cmdline('lcd %')
    assert_eq(vim.fn.getcwd(), target, ':lcd % should use the browsed directory')
    assert_eq(vim.fn.getcwd(-1, -1), original_cwd, ':lcd % should not change the global working directory')

    cmdline('cd %')
    assert_eq(vim.fn.getcwd(-1, -1), target, ':cd % should use the browsed directory')
    vim.cmd('cd ' .. vim.fn.fnameescape(original_cwd))

    api.quit()
    vim.api.nvim_win_close(right_win, true)
    vim.api.nvim_set_current_win(left_win)
    api.quit()
    vim.cmd.tabclose()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Preview: opens a split without stealing focus, reads only enough of huge
    -- files to fill a window, follows the cursor, and loads the real buffer
    -- when focused.
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    tmp = fs.realpath(tmp)
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    write_file(tmp .. '/small.txt', 'alpha\nbeta\n')
    write_file(tmp .. '/bin.dat', 'binary\0data')
    local big_line_count = vim.o.lines + 500
    local big_lines = {}
    for i = 1, big_line_count do
        big_lines[i] = 'line ' .. i
    end
    write_file(tmp .. '/big.txt', table.concat(big_lines, '\n') .. '\n')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local dora_state = store.get()
    local dora_win = vim.api.nvim_get_current_win()
    set_cursor_pos('small.txt')
    api.toggle_preview()
    local preview = assert(dora_state.preview, 'toggle_preview should open a preview')
    assert(vim.api.nvim_win_is_valid(preview.win), 'preview window should be open')
    assert_eq(vim.api.nvim_get_current_win(), dora_win, 'preview should not steal focus')
    assert_eq(preview.path, tmp .. '/small.txt')
    assert_eq(table.concat(buf_lines(vim.api.nvim_win_get_buf(preview.win)), '\n'), 'alpha\nbeta')

    set_cursor_pos('big.txt')
    vim.api.nvim_exec_autocmds('CursorMoved', {buffer = dora_state.buf})
    local shown = buf_lines(vim.api.nvim_win_get_buf(preview.win))
    assert_eq(preview.path, tmp .. '/big.txt', 'preview should follow the cursor')
    assert_eq(shown[1], 'line 1')
    assert_eq(#shown, vim.o.lines, 'preview should read only enough lines to fill a window')

    set_cursor_pos('dir')
    vim.api.nvim_exec_autocmds('CursorMoved', {buffer = dora_state.buf})
    assert_eq(buf_lines(vim.api.nvim_win_get_buf(preview.win))[1], '(directory)',
        'directories should show a placeholder instead of content')

    set_cursor_pos('bin.dat')
    vim.api.nvim_exec_autocmds('CursorMoved', {buffer = dora_state.buf})
    assert_eq(buf_lines(vim.api.nvim_win_get_buf(preview.win))[1], '(binary)',
        'binary files should show a placeholder instead of content')

    set_cursor_pos('big.txt')
    vim.api.nvim_exec_autocmds('CursorMoved', {buffer = dora_state.buf})
    vim.api.nvim_set_current_win(preview.win)
    assert(preview.full, 'focusing the preview should load the full buffer')
    local full_buf = vim.api.nvim_win_get_buf(preview.win)
    assert_eq(vim.api.nvim_buf_get_name(full_buf), tmp .. '/big.txt')
    assert_eq(vim.api.nvim_buf_line_count(full_buf), big_line_count,
        'focusing the preview should load the whole file')

    vim.api.nvim_set_current_win(dora_win)
    set_cursor_pos('small.txt')
    vim.api.nvim_exec_autocmds('CursorMoved', {buffer = dora_state.buf})
    assert_eq(preview.path, tmp .. '/small.txt')
    assert(not preview.full, 'moving to another file should return to a partial preview')

    api.toggle_preview()
    assert_eq(dora_state.preview, nil, 'toggle should close an open preview')
    assert(not vim.api.nvim_win_is_valid(preview.win), 'toggle should close the preview window')
    api.toggle_preview()
    vim.api.nvim_win_close(assert(dora_state.preview).win, true)
    assert_eq(dora_state.preview, nil, 'closing the preview window by hand should clear the state')

    api.toggle_preview()
    local preview_win_id = assert(dora_state.preview).win
    api.quit()
    assert(not vim.api.nvim_win_is_valid(preview_win_id), 'quitting dora should close the preview')
    clear_persisted_view_state()
    pcall(vim.api.nvim_buf_delete, full_buf, {force = true})
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
local state = store.get()
assert_eq(state.cwd, fs.realpath(cwd))
assert(vim.api.nvim_buf_get_var(0, 'is_dora'), 'Dora buffer should be identified')
assert(#vim.api.nvim_buf_get_lines(0, 0, -1, false) > 0, 'Dora buffer should render entries')
api.quit()
