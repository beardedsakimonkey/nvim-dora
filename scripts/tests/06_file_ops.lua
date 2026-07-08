-- File operations: rename, opening in splits, trash and delete (incl. visual selections), undo trash.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/06_file_ops.lua (see scripts/smoke.sh).
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
local lines = h.lines
local set_cursor_line = h.set_cursor_line
local current_line = h.current_line
local find_line_index = h.find_line_index
local set_cursor_pos = h.set_cursor_pos
local win_title = h.win_title
local wait_for_remove = h.wait_for_remove

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    write_file(tmp .. '/source.txt', 'new')
    write_file(tmp .. '/dest.txt', 'old')
    assert(vim.loop.fs_mkdir(tmp .. '/dest-dir', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/source-dir', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/other-dir', tonumber('755', 8)))

    assert_eq(fs.validate_rename('dest.txt', tmp .. '/source.txt'), tmp .. '/dest.txt',
        'file rename should allow an existing file destination')
    assert(not pcall(fs.validate_rename, 'dest-dir', tmp .. '/source.txt'),
        'file rename should reject an existing directory destination')
    assert(not pcall(fs.validate_rename, 'dest.txt', tmp .. '/source-dir'),
        'directory rename should reject an existing file destination')
    assert(not pcall(fs.validate_rename, 'other-dir', tmp .. '/source-dir'),
        'directory rename should reject an existing directory destination')
    assert(not pcall(fs.rename, tmp .. '/source.txt', tmp .. '/dest-dir'),
        'file rename execution should reject an existing directory destination')
    assert(not pcall(fs.rename, tmp .. '/source-dir', tmp .. '/dest.txt'),
        'directory rename execution should reject an existing file destination')
    assert(not pcall(fs.rename, tmp .. '/source-dir', tmp .. '/other-dir'),
        'directory rename execution should reject an existing directory destination')

    -- Case-only renames (README -> readme) must work even though the source and
    -- destination resolve to the same entry on case-insensitive filesystems.
    write_file(tmp .. '/Case.txt', 'x')
    assert(vim.loop.fs_mkdir(tmp .. '/CaseDir', tonumber('755', 8)))
    assert_eq(fs.validate_rename('case.txt', tmp .. '/Case.txt'), tmp .. '/case.txt',
        'rename should allow changing only the case of a filename')
    assert_eq(fs.validate_rename('casedir', tmp .. '/CaseDir'), tmp .. '/casedir',
        'rename should allow changing only the case of a directory name')
    assert(pcall(fs.rename, tmp .. '/Case.txt', tmp .. '/case.txt'),
        'rename execution should change only the case of a filename')
    assert(fs.exists(tmp .. '/case.txt'), 'case-only file rename should land on the new casing')
    assert(pcall(fs.rename, tmp .. '/CaseDir', tmp .. '/casedir'),
        'rename execution should change only the case of a directory name')
    assert(fs.exists(tmp .. '/casedir'), 'case-only directory rename should land on the new casing')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_line('source%.txt$')
    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        cb('dest.txt', opts.validate('dest.txt'))
    end

    api.rename()
    assert_match(win_title(vim.api.nvim_get_current_win()), 'Overwrite%?')
    assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1], 'dest.txt')
    vim.api.nvim_feedkeys('n', 'xt', false)
    assert_eq(vim.fn.readfile(tmp .. '/source.txt')[1], 'new',
        'declining rename overwrite should preserve the source file')
    assert_eq(vim.fn.readfile(tmp .. '/dest.txt')[1], 'old',
        'declining rename overwrite should preserve the destination file')
    assert_eq(vim.api.nvim_get_current_buf(), state.buf,
        'declining rename overwrite should restore Dora')

    api.rename()
    assert_match(win_title(vim.api.nvim_get_current_win()), 'Overwrite%?')
    vim.api.nvim_feedkeys('y', 'xt', false)
    prompt.input = old_input

    assert(not fs.exists(tmp .. '/source.txt'),
        'confirming rename overwrite should remove the source file')
    assert_eq(vim.fn.readfile(tmp .. '/dest.txt')[1], 'new',
        'confirming rename overwrite should replace the destination file')
    assert_match(current_line(), 'dest%.txt$',
        'confirming rename overwrite should move the cursor to the destination')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/nested', tonumber('755', 8)))
    touch(tmp .. '/nested/inner.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('nested')
    api.fold_out()
    set_cursor_pos('inner.txt')
    local origin_win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(origin_win)
    local row = store.get().rows[cursor[1]]
    local name_pos = vim.fn.screenpos(origin_win, cursor[1], row.name_start_col + 1)

    api.rename()
    local prompt_win = vim.api.nvim_get_current_win()
    assert(prompt_win ~= origin_win, 'rename should open a prompt window')
    assert_eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], 'inner.txt')
    local input_pos = vim.fn.screenpos(prompt_win, 1, 1)
    assert_eq(input_pos.row, name_pos.row, 'rename prompt should superimpose onto the renamed row')
    assert_eq(input_pos.col, name_pos.col, 'rename prompt text should align with the filename')

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-c>', true, false, true), 'xt', false)
    assert_eq(vim.api.nvim_get_current_win(), origin_win, 'cancelling rename should restore the origin window')
    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/split.txt')
    touch(tmp .. '/vsplit.txt')
    touch(tmp .. '/tab.txt')
    local real_tmp = fs.realpath(tmp)
    local swap_dir = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(swap_dir, tonumber('755', 8)))
    local old_directory = vim.o.directory
    vim.o.directory = fs.realpath(swap_dir) .. '//'

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local dora_win = vim.api.nvim_get_current_win()
    local dora_buf = vim.api.nvim_get_current_buf()
    assert_eq(vim.fn.maparg('<C-s>', 'n', false, true).desc, 'Open in split (stay)')
    assert_eq(vim.fn.maparg('<C-v>', 'n', false, true).desc, 'Open in vertical split (stay)')
    assert_eq(vim.fn.maparg('<C-t>', 'n', false, true).desc, 'Open in tab (stay)')

    set_cursor_line('split%.txt$')
    local existing_wins = vim.api.nvim_tabpage_list_wins(0)
    api.open_split_stay()
    local split_win = vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(function(win)
        return not vim.tbl_contains(existing_wins, win)
    end)
    assert(split_win, '<C-s> should create a split')
    assert_eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(split_win)), real_tmp .. '/split.txt',
        '<C-s> should open the file in a split')
    assert(#vim.fn.win_findbuf(dora_buf) > 0, '<C-s> should keep the Dora buffer visible')
    assert_eq(vim.api.nvim_get_current_win(), dora_win, '<C-s> should keep focus in Dora')
    vim.api.nvim_win_close(split_win, true)

    set_cursor_line('vsplit%.txt$')
    existing_wins = vim.api.nvim_tabpage_list_wins(0)
    api.open_vsplit_stay()
    local vsplit_win = vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(function(win)
        return not vim.tbl_contains(existing_wins, win)
    end)
    assert(vsplit_win, '<C-v> should create a vertical split')
    assert_eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vsplit_win)), real_tmp .. '/vsplit.txt',
        '<C-v> should open the file in a vertical split')
    assert(#vim.fn.win_findbuf(dora_buf) > 0, '<C-v> should keep the Dora buffer visible')
    assert_eq(vim.api.nvim_get_current_win(), dora_win, '<C-v> should keep focus in Dora')
    vim.api.nvim_win_close(vsplit_win, true)

    set_cursor_line('tab%.txt$')
    local dora_tab = vim.api.nvim_get_current_tabpage()
    local existing_tabs = vim.api.nvim_list_tabpages()
    api.open_tab_stay()
    local file_tab = vim.iter(vim.api.nvim_list_tabpages()):find(function(tab)
        return not vim.tbl_contains(existing_tabs, tab)
    end)
    assert(file_tab, '<C-t> should create a tab')
    local file_win = vim.api.nvim_tabpage_get_win(file_tab)
    assert_eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(file_win)), real_tmp .. '/tab.txt',
        '<C-t> should open the file in a tab')
    assert(vim.api.nvim_win_is_valid(dora_win), '<C-t> should keep the Dora window')
    assert_eq(vim.api.nvim_win_get_buf(dora_win), dora_buf, '<C-t> should keep the Dora buffer in its original tab')
    assert_eq(vim.api.nvim_get_current_tabpage(), dora_tab, '<C-t> should keep focus in the Dora tab')
    assert_eq(vim.api.nvim_get_current_win(), dora_win, '<C-t> should keep focus in Dora')
    vim.api.nvim_set_current_win(file_win)
    vim.cmd('tabclose')
    vim.api.nvim_set_current_win(dora_win)

    api.quit()
    vim.o.directory = old_directory
    for _, path in ipairs({'split.txt', 'vsplit.txt', 'tab.txt'}) do
        pcall(vim.cmd --[[@as function]], 'bdelete! ' .. vim.fn.fnameescape(real_tmp .. '/' .. path))
    end
    assert_eq(vim.fn.delete(swap_dir, 'rf'), 0)
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))
    touch(tmp .. '/sub/inner.txt')
    touch(tmp .. '/file.txt')
    local real_tmp = fs.realpath(tmp)

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local dora_win = vim.api.nvim_get_current_win()
    local dora_buf = vim.api.nvim_get_current_buf()

    -- Visual edit-open still skips directories: a directory-only selection
    -- opens nothing.
    set_cursor_pos('sub')
    vim.api.nvim_feedkeys('V', 'xt', false)
    api.open_visual()
    assert_eq(vim.api.nvim_get_current_buf(), dora_buf, 'visual edit-open should skip directories')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)

    -- Visual split-open includes directories: the directory opens as a new
    -- dora session in its own split, alongside the selected file.
    set_cursor_pos('sub')
    local existing_wins = vim.api.nvim_tabpage_list_wins(0)
    vim.api.nvim_feedkeys('Vj', 'xt', false)
    api.open_vsplit_stay_visual()
    assert_eq(vim.api.nvim_get_mode().mode, 'n', 'visual open should leave visual mode')
    assert_eq(vim.api.nvim_get_current_win(), dora_win, 'stay-open should keep focus in Dora')
    local new_wins = vim.iter(vim.api.nvim_tabpage_list_wins(0)):filter(function(win)
        return not vim.tbl_contains(existing_wins, win)
    end):totable()
    assert_eq(#new_wins, 2, 'visual vsplit-open should open one window per selected row')
    local dir_win, file_win
    for _, win in ipairs(new_wins) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.b[buf].is_dora then
            dir_win = win
        elseif vim.api.nvim_buf_get_name(buf) == real_tmp .. '/file.txt' then
            file_win = win
        end
    end
    assert(dir_win, 'visual vsplit-open should open the directory in a Dora split')
    assert_eq(store.get(vim.api.nvim_win_get_buf(dir_win)).cwd, real_tmp .. '/sub',
        'the directory split should browse the selected directory')
    assert(file_win, 'visual vsplit-open should open the file in a split')

    vim.api.nvim_set_current_win(dir_win)
    api.quit()
    vim.api.nvim_win_close(file_win, true)
    vim.api.nvim_set_current_win(dora_win)

    -- Non-stay split-open also includes directories, and ends the
    -- originating session like any non-stay open.
    set_cursor_pos('sub')
    vim.api.nvim_feedkeys('V', 'xt', false)
    api.open_split_visual()
    assert(vim.b.is_dora, 'non-stay visual open of a directory should land in its dora session')
    assert_eq(store.get().cwd, real_tmp .. '/sub',
        'the non-stay split should browse the selected directory')
    assert(not vim.api.nvim_buf_is_valid(dora_buf),
        'non-stay visual open should clean up the originating session')
    api.quit()
    vim.cmd('only')
    pcall(vim.cmd --[[@as function]], 'bdelete! ' .. vim.fn.fnameescape(real_tmp .. '/file.txt'))
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Trash moves files into the real trash, so point HOME/XDG at a temp trash
    -- for the duration of the test.
    local old_home = vim.env.HOME
    local old_data_home = vim.env.XDG_DATA_HOME
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/home', tonumber('755', 8)))
    vim.env.HOME = tmp .. '/home'
    vim.env.XDG_DATA_HOME = tmp .. '/data'
    local trash_dir = vim.loop.os_uname().sysname == 'Darwin'
        and tmp .. '/home/.Trash'
        or tmp .. '/data/Trash/files'
    touch(tmp .. '/trashed.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('trashed.txt')
    api.trash()

    local confirm_win = vim.api.nvim_get_current_win()
    assert_match(win_title(confirm_win), 'Trash%?')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_remove()

    assert(not fs.exists(tmp .. '/trashed.txt'), 'trash should remove the file from the listing source')
    assert(fs.exists(trash_dir .. '/trashed.txt'), 'trash should move the file into the trash directory')

    -- Drain the shared undo history so later undo tests start from a clean slate.
    api.undo_trash()
    vim.api.nvim_feedkeys('y', 'xt', false)
    assert(fs.exists(tmp .. '/trashed.txt'), 'undo should restore the trashed file')

    api.quit()
    vim.env.HOME = old_home
    vim.env.XDG_DATA_HOME = old_data_home
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/deleted.txt')
    local root = fs.realpath(tmp)

    vim.cmd('edit ' .. vim.fn.fnameescape(tmp .. '/deleted.txt'))
    assert(vim.fn.bufexists(root .. '/deleted.txt') ~= 0, 'test should load the file buffer before deleting')
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('deleted.txt')
    api.delete()

    local confirm_win = vim.api.nvim_get_current_win()
    assert_match(win_title(confirm_win), 'Delete%?')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_remove()

    assert(not fs.exists(tmp .. '/deleted.txt'), 'delete should permanently remove the file')
    assert_eq(vim.fn.bufexists(root .. '/deleted.txt'), 0, 'delete should close the removed file buffer')

    api.quit()
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
    local trash_dir = vim.loop.os_uname().sysname == 'Darwin'
        and tmp .. '/home/.Trash'
        or tmp .. '/data/Trash/files'
    write_file(tmp .. '/trashed.txt', 'payload')
    local root = fs.realpath(tmp)

    vim.cmd('edit ' .. vim.fn.fnameescape(tmp .. '/trashed.txt'))
    assert(vim.fn.bufexists(root .. '/trashed.txt') ~= 0, 'test should load the file buffer before trashing')
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('trashed.txt')
    api.trash()
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_remove()

    assert(not fs.exists(tmp .. '/trashed.txt'), 'trash should remove the file from its original location')
    assert(fs.exists(trash_dir .. '/trashed.txt'), 'trash should move the file into the trash')
    assert_eq(vim.fn.bufexists(root .. '/trashed.txt'), 0, 'trash should close the removed file buffer')
    assert_eq(vim.fn.bufexists(trash_dir .. '/trashed.txt'), 0, 'trash should not leave a buffer renamed into the trash')

    api.undo_trash()
    vim.api.nvim_feedkeys('y', 'xt', false)
    assert(fs.exists(tmp .. '/trashed.txt'), 'undo should restore the trashed file after buffer cleanup')
    assert_eq(vim.fn.bufexists(root .. '/trashed.txt'), 0, 'undo trash should not recreate the removed file buffer')

    api.quit()
    vim.env.HOME = old_home
    vim.env.XDG_DATA_HOME = old_data_home
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
    local trash_dir = vim.loop.os_uname().sysname == 'Darwin'
        and tmp .. '/home/.Trash'
        or tmp .. '/data/Trash/files'
    touch(tmp .. '/a')
    touch(tmp .. '/b')
    touch(tmp .. '/c')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_line('a$')
    local origin_win = vim.api.nvim_get_current_win()
    local target_line = find_line_index(lines(), 'a$')
    local target_row = state.rows[target_line]
    local pos = vim.fn.screenpos(origin_win, target_line, target_row.name_start_col + 1)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('Vjd', true, false, true), 'xt', false)

    local confirm_win = vim.api.nvim_get_current_win()
    assert_match(win_title(confirm_win), 'Trash 2 files%?')
    local first_item_pos = vim.fn.screenpos(confirm_win, 1, 1)
    assert_eq(first_item_pos.row, pos.row, 'visual trash confirmation should superimpose onto the first selected row')
    assert_eq(first_item_pos.col, pos.col, 'visual trash confirmation should superimpose onto the first selected row')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_remove()

    assert(not fs.exists(tmp .. '/a'), 'visual trash should remove selected file a')
    assert(not fs.exists(tmp .. '/b'), 'visual trash should remove selected file b')
    assert(fs.exists(tmp .. '/c'), 'visual trash should leave unselected files')
    assert(fs.exists(trash_dir .. '/a'), 'visual trash should move selected file a into the trash')
    assert(fs.exists(trash_dir .. '/b'), 'visual trash should move selected file b into the trash')

    -- Drain the shared undo history so later undo tests start from a clean slate.
    api.undo_trash()
    vim.api.nvim_feedkeys('y', 'xt', false)
    assert(fs.exists(tmp .. '/a'), 'undo should restore the whole visual batch')
    assert(fs.exists(tmp .. '/b'), 'undo should restore the whole visual batch')

    api.quit()
    vim.env.HOME = old_home
    vim.env.XDG_DATA_HOME = old_data_home
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Undo restores files out of the real trash, so point HOME/XDG at a temp
    -- trash for the duration of the test.
    local old_home = vim.env.HOME
    local old_data_home = vim.env.XDG_DATA_HOME
    local old_notify = vim.notify
    local notifications = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
        notifications[#notifications+1] = {msg = msg, level = level}
    end

    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/home', tonumber('755', 8)))
    vim.env.HOME = tmp .. '/home'
    vim.env.XDG_DATA_HOME = tmp .. '/data'

    write_file(tmp .. '/undo.txt', 'payload')
    touch(tmp .. '/keep.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('undo.txt')
    api.trash()
    assert_match(win_title(vim.api.nvim_get_current_win()), 'Trash%?')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_remove()
    assert(not fs.exists(tmp .. '/undo.txt'), 'trash should remove the file before undo')

    -- Undo lists the files it will restore and only restores once confirmed; its
    -- confirmation superimposes flush left of the text on the cursor line.
    local tree_win = vim.api.nvim_get_current_win()
    local tree_cursor = vim.api.nvim_win_get_cursor(tree_win)
    local line_start_pos = vim.fn.screenpos(tree_win, tree_cursor[1], 1)
    api.undo_trash()
    local undo_win = vim.api.nvim_get_current_win()
    local undo_buf = vim.api.nvim_get_current_buf()
    local undo_lines = vim.api.nvim_buf_get_lines(undo_buf, 0, -1, false)
    assert_match(win_title(undo_win), 'Undo trash%?')
    assert_match(vim.wo[undo_win].winhighlight, 'FloatBorder:DoraPromptBorder$')
    assert_eq(undo_lines[1], 'undo.txt', 'undo confirmation should list the file being restored')
    local content_pos = vim.fn.screenpos(undo_win, 1, 1)
    assert_eq(content_pos.row, line_start_pos.row,
        'undo confirmation content should sit on the cursor line, not below it')
    assert_eq(content_pos.col, line_start_pos.col,
        'undo confirmation content should align just right of the line number')
    assert(not fs.exists(tmp .. '/undo.txt'), 'undo should not restore until confirmed')
    vim.api.nvim_feedkeys('y', 'xt', false)
    assert(fs.exists(tmp .. '/undo.txt'), 'undo should restore the trashed file once confirmed')
    local fd = assert(vim.loop.fs_open(tmp .. '/undo.txt', 'r', tonumber('644', 8)))
    local contents = vim.loop.fs_read(fd, 32, 0)
    assert(vim.loop.fs_close(fd))
    assert_eq(contents, 'payload', 'undo should restore the original contents')
    assert_match(current_line(), 'undo%.txt$', 'undo should move the cursor to the restored file')
    assert_eq(notifications[#notifications].msg, 'dora: Restored 1 item')
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)

    -- The history is now empty, so undoing again reports nothing to restore.
    api.undo_trash()
    assert_eq(notifications[#notifications].msg, 'dora: No trash to undo')
    assert_eq(notifications[#notifications].level, vim.log.levels.ERROR)

    -- Cancelling the confirmation restores nothing and leaves the batch on the
    -- history, so a later undo can still bring it back.
    set_cursor_pos('undo.txt')
    api.trash()
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_remove()
    assert(not fs.exists(tmp .. '/undo.txt'), 'trash should remove the file before the cancelled undo')
    api.undo_trash()
    vim.api.nvim_feedkeys('n', 'xt', false)
    assert(not fs.exists(tmp .. '/undo.txt'), 'cancelling undo should not restore the file')

    -- When the original name has been taken again, undo restores to a free
    -- sibling rather than clobbering the new file.
    write_file(tmp .. '/undo.txt', 'newer')
    api.undo_trash()
    vim.api.nvim_feedkeys('y', 'xt', false)
    assert(fs.exists(tmp .. '/undo.txt'), 'undo should leave the file that took the original name')
    assert(fs.exists(tmp .. '/undo(1).txt'), 'undo should restore to a non-clobbering name when the original is taken')

    api.quit()
    vim.notify = old_notify
    vim.env.HOME = old_home
    vim.env.XDG_DATA_HOME = old_data_home
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- A visual trash records one batch, so a single undo brings every file back.
    local old_home = vim.env.HOME
    local old_data_home = vim.env.XDG_DATA_HOME
    local old_notify = vim.notify
    local notifications = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
        notifications[#notifications+1] = {msg = msg, level = level}
    end

    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/home', tonumber('755', 8)))
    vim.env.HOME = tmp .. '/home'
    vim.env.XDG_DATA_HOME = tmp .. '/data'
    touch(tmp .. '/a')
    touch(tmp .. '/b')
    touch(tmp .. '/c')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_line('a$')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('Vjd', true, false, true), 'xt', false)
    assert_match(win_title(vim.api.nvim_get_current_win()), 'Trash 2 files%?')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_remove()
    assert(not fs.exists(tmp .. '/a'), 'visual trash should remove a')
    assert(not fs.exists(tmp .. '/b'), 'visual trash should remove b')

    -- The confirmation titles the whole batch and lists every file it restores.
    api.undo_trash()
    local undo_win = vim.api.nvim_get_current_win()
    local undo_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    assert_match(win_title(undo_win), 'Undo trash%? %(2 files%)')
    assert_eq(undo_lines[1], 'a', 'undo confirmation should list the first file in the batch')
    assert_eq(undo_lines[2], 'b', 'undo confirmation should list the whole batch')
    vim.api.nvim_feedkeys('y', 'xt', false)
    assert(fs.exists(tmp .. '/a'), 'undo should restore the first file in the batch')
    assert(fs.exists(tmp .. '/b'), 'undo should restore the whole trashed batch')
    assert(fs.exists(tmp .. '/c'), 'undo should leave files that were never trashed')
    assert_eq(notifications[#notifications].msg, 'dora: Restored 2 items')
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)

    api.quit()
    vim.notify = old_notify
    vim.env.HOME = old_home
    vim.env.XDG_DATA_HOME = old_data_home
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- A restored directory is previewed at its original (now empty) location, so
    -- its trailing '/' comes from the trashed copy's type, not the empty target.
    local old_home = vim.env.HOME
    local old_data_home = vim.env.XDG_DATA_HOME

    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/home', tonumber('755', 8)))
    vim.env.HOME = tmp .. '/home'
    vim.env.XDG_DATA_HOME = tmp .. '/data'
    assert(vim.loop.fs_mkdir(tmp .. '/mydir', tonumber('755', 8)))
    touch(tmp .. '/mydir/inner')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('mydir')
    api.trash()
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_remove()
    assert(not fs.exists(tmp .. '/mydir'), 'trash should remove the directory before undo')

    api.undo_trash()
    local undo_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    assert_eq(undo_lines[1], 'mydir/', 'undo confirmation should mark a restored directory with a trailing slash')
    vim.api.nvim_feedkeys('y', 'xt', false)
    assert(fs.exists(tmp .. '/mydir/inner'), 'undo should restore the directory and its contents')

    api.quit()
    vim.env.HOME = old_home
    vim.env.XDG_DATA_HOME = old_data_home
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/alpha')
    touch(tmp .. '/beta')
    touch(tmp .. '/gamma')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_line('alpha$')
    local origin_win = vim.api.nvim_get_current_win()
    local target_line = find_line_index(lines(), 'alpha$')
    local target_row = state.rows[target_line]
    local pos = vim.fn.screenpos(origin_win, target_line, target_row.name_start_col + 1)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('VjD', true, false, true), 'xt', false)

    local confirm_win = vim.api.nvim_get_current_win()
    assert_match(win_title(confirm_win), 'Delete 2 files%?')
    local first_item_pos = vim.fn.screenpos(confirm_win, 1, 1)
    assert_eq(first_item_pos.row, pos.row, 'visual delete confirmation should superimpose onto the first selected row')
    assert_eq(first_item_pos.col, pos.col, 'visual delete confirmation should superimpose onto the first selected row')
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_remove()

    assert(not fs.exists(tmp .. '/alpha'), 'visual delete should remove selected file alpha')
    assert(not fs.exists(tmp .. '/beta'), 'visual delete should remove selected file beta')
    assert(fs.exists(tmp .. '/gamma'), 'visual delete should leave unselected files')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    -- More files than the cap that truncates the cursor-anchored list.
    local count = 15
    for i = 1, count do
        touch(tmp .. ('/f%02d'):format(i))
    end

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_line('f01$')
    local origin_win = vim.api.nvim_get_current_win()
    local target_line = find_line_index(lines(), 'f01$')
    local target_row = state.rows[target_line]
    local pos = vim.fn.screenpos(origin_win, target_line, target_row.name_start_col + 1)
    -- Select every file and delete. The confirmation superimposes over the
    -- selected rows, so it lists them all instead of overflowing.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('V' .. (count - 1) .. 'jD', true, false, true), 'xt', false)

    local confirm_win = vim.api.nvim_get_current_win()
    local confirm_buf = vim.api.nvim_get_current_buf()
    assert_match(win_title(confirm_win), 'Delete ' .. count .. ' files%?')
    local first_item_pos = vim.fn.screenpos(confirm_win, 1, 1)
    assert_eq(first_item_pos.row, pos.row, 'superimposed visual delete confirmation should align with the first selected row')
    local confirm_lines = vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)
    assert_eq(#confirm_lines, count, 'superimposed visual delete should list every selected file without truncating')
    for _, line in ipairs(confirm_lines) do
        assert(not line:match('and %d+ more'), 'superimposed visual delete should not show an overflow line')
    end
    assert_eq(confirm_lines[1], 'f01')
    assert_eq(confirm_lines[count], 'f' .. count)

    vim.api.nvim_feedkeys('n', 'xt', false)
    assert(fs.exists(tmp .. '/f01'), 'declining the confirmation should keep files')
    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- A selection spanning the whole viewport cannot fit one aligned line per
    -- row plus the float's border, so it overflows rather than silently hiding
    -- the rows the window can't show.
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    for i = 1, 60 do
        touch(tmp .. ('/f%02d'):format(i))
    end

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local origin_win = vim.api.nvim_get_current_win()
    local info = vim.fn.getwininfo(origin_win)[1]
    vim.api.nvim_win_set_cursor(origin_win, {info.topline, 0})
    local visible = info.botline - info.topline + 1
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('V' .. (visible - 1) .. 'jD', true, false, true), 'xt', false)

    local confirm_win = vim.api.nvim_get_current_win()
    local confirm_buf = vim.api.nvim_get_current_buf()
    assert_match(win_title(confirm_win), 'Delete ' .. visible .. ' files%?')
    local confirm_lines = vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)
    -- The window must be tall enough to show every rendered line; otherwise the
    -- bottom rows would be hidden with no indication.
    assert(vim.api.nvim_win_get_height(confirm_win) >= #confirm_lines,
        'viewport-filling delete should not hide rows the buffer contains')
    assert(vim.fn.screenpos(confirm_win, #confirm_lines, 1).row ~= 0,
        'the last confirmation line should be on screen')
    assert(confirm_lines[#confirm_lines]:match('^%.%.%. and %d+ more$'),
        'viewport-filling delete should overflow into a "... and N more" line')

    vim.api.nvim_feedkeys('n', 'xt', false)
    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end
