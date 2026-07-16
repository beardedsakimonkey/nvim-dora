-- Sort orders, mark rendering, yank actions, open externally, file info.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/11_sort_yank_info.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local dora = h.dora
local descriptions = h.actions.descriptions
local fs = h.fs
local keymaps = h.keymaps
local api = h.api
local store = h.store
local window = h.window
local assert_eq = h.assert_eq
local assert_match = h.assert_match
local touch = h.touch
local write_file = h.write_file
local marked_path_count = h.marked_path_count
local lines = h.lines
local set_cursor_line = h.set_cursor_line
local current_line = h.current_line
local find_line_index = h.find_line_index
local set_cursor_pos = h.set_cursor_pos
local assert_line_before = h.assert_line_before
local win_title = h.win_title

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir10', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir2', tonumber('755', 8)))
    write_file(tmp .. '/file10.txt', 'xxxxxxxxxx')
    write_file(tmp .. '/file2.txt', 'xxxxx')
    write_file(tmp .. '/alpha.md', 'xxx')
    write_file(tmp .. '/tiny.bin', 'x')
    write_file(tmp .. '/big.log', 'xxxxxxxxxxxxxxxxxxxx')
    assert(vim.loop.fs_utime(tmp .. '/tiny.bin', 50, 50))
    assert(vim.loop.fs_utime(tmp .. '/file10.txt', 100, 100))
    assert(vim.loop.fs_utime(tmp .. '/alpha.md', 150, 150))
    assert(vim.loop.fs_utime(tmp .. '/file2.txt', 200, 200))
    assert(vim.loop.fs_utime(tmp .. '/big.log', 250, 250))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    assert_eq(dora.config.sort_order, 'name')
    assert_line_before('^dir2/$', '^dir10/$', 'natural sort should order directory names naturally')
    assert_line_before('^dir10/$', '^alpha%.md$', 'directories should stay grouped before files')
    assert_line_before('^file2%.txt$', '^file10%.txt$', 'natural sort should order file names naturally')

    api.sort_by('name_desc')
    assert_eq(dora.config.sort_order, 'name_desc')
    assert_line_before('^dir10/$', '^dir2/$', 'reversed natural sort should reverse directory names')
    assert_line_before('^dir2/$', '^tiny%.bin$', 'reversed natural sort should keep directories before files')
    assert_line_before('^file10%.txt$', '^file2%.txt$', 'reversed natural sort should reverse file names')

    api.sort_by('size')
    assert_eq(dora.config.sort_order, 'size')
    assert_line_before('^dir10/$', '^tiny%.bin$', 'size sort should keep directories before files')
    assert_line_before('^tiny%.bin$', '^alpha%.md$', 'size sort should order files by size')
    assert_line_before('^file2%.txt$', '^file10%.txt$', 'size sort should order larger files later')

    api.sort_by('size_desc')
    assert_eq(dora.config.sort_order, 'size_desc')
    assert_line_before('^dir10/$', '^big%.log$', 'reversed size sort should keep directories before files')
    assert_line_before('^big%.log$', '^file10%.txt$', 'reversed size sort should order larger files first')
    assert_line_before('^file10%.txt$', '^file2%.txt$', 'reversed size sort should order smaller files later')

    api.sort_by('extension')
    assert_eq(dora.config.sort_order, 'extension')
    assert_line_before('^tiny%.bin$', '^big%.log$', 'extension sort should order by extension')
    assert_line_before('^big%.log$', '^alpha%.md$', 'extension sort should order by extension')
    assert_line_before('^alpha%.md$', '^file2%.txt$', 'extension sort should order by extension')

    api.sort_by('extension_desc')
    assert_eq(dora.config.sort_order, 'extension_desc')
    assert_line_before('^file2%.txt$', '^alpha%.md$', 'reversed extension sort should order by extension descending')
    assert_line_before('^alpha%.md$', '^big%.log$', 'reversed extension sort should order by extension descending')
    assert_line_before('^big%.log$', '^tiny%.bin$', 'reversed extension sort should order by extension descending')

    api.sort_by('modified')
    assert_eq(dora.config.sort_order, 'modified')
    assert_line_before('^tiny%.bin$', '^file10%.txt$', 'modified sort should order older files first')
    assert_line_before('^file2%.txt$', '^big%.log$', 'modified sort should order newer files later')

    api.sort_by('modified_desc')
    assert_eq(dora.config.sort_order, 'modified_desc')
    assert_line_before('^big%.log$', '^file2%.txt$', 'reversed modified sort should order newer files first')
    assert_line_before('^file10%.txt$', '^tiny%.bin$', 'reversed modified sort should order older files later')

    api.sort_by('created')
    assert_eq(dora.config.sort_order, 'created')
    api.sort_by('created_desc')
    assert_eq(dora.config.sort_order, 'created_desc')

    local prefix_map = vim.fn.maparg(',', 'n', false, true)
    vim.api.nvim_feedkeys('s', 't', false)
    prefix_map.callback()
    assert_eq(dora.config.sort_order, 'size', 'sort keymaps should work behind the comma prefix mapping')

    vim.api.nvim_feedkeys('S', 't', false)
    prefix_map.callback()
    assert_eq(dora.config.sort_order, 'size_desc', 'descending sort keymaps should dispatch renamed actions')

    api.quit()
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    assert_line_before('^big%.log$', '^tiny%.bin$',
        'new Dora windows should use the global sort order')
    api.sort_by('name')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/visible')
    touch(tmp .. '/.hidden')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    assert(vim.tbl_contains(lines(), 'visible'), 'visible files should render by default')
    assert(vim.tbl_contains(lines(), '.hidden'), 'dotfiles should render by default')

    api.toggle_hidden_files()
    assert(not vim.tbl_contains(lines(), '.hidden'), 'hidden files should be hidden after toggling visibility')

    api.quit()
    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    assert(not vim.tbl_contains(lines(), '.hidden'),
        'new Dora windows should use the global hidden-file visibility')

    api.toggle_hidden_files()
    assert(vim.tbl_contains(lines(), '.hidden'), 'toggling again should restore global hidden-file visibility')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/a')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    set_cursor_pos('a')
    api.toggle_cut()
    assert_eq(marked_path_count(state), 1)
    api.clear_cut()
    assert_eq(marked_path_count(state), 0, 'clear_cut should clear cut marks')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local old_unnamed = vim.fn.getreg('"')
    local old_unnamed_type = vim.fn.getregtype('"')
    local old_notify = vim.notify
    local notifications = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
        notifications[#notifications+1] = {msg = msg, level = level}
    end
    local had_clipboard, old_clipboard = pcall(vim.api.nvim_get_var, 'clipboard')
    vim.g.clipboard = {
        name = 'dora-smoke',
        copy = {
            ---@diagnostic disable-next-line: redefined-local
            ['+'] = function(lines) vim.g.dora_smoke_clipboard = table.concat(lines, '\n') end,
            ['*'] = function() end,
        },
        paste = {
            ['+'] = function() return {vim.split(vim.g.dora_smoke_clipboard or '', '\n'), 'v'} end,
            ['*'] = function() return {{''}, 'v'} end,
        },
    }
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    touch(tmp .. '/dir/archive.tar.gz')

    local augroup = vim.api.nvim_create_augroup('dora-smoke-yank', {})
    vim.api.nvim_create_autocmd('TextYankPost', {
        group = augroup,
        callback = function()
            vim.g.dora_smoke_yankpost_operator = vim.v.event.operator
            vim.g.dora_smoke_yankpost_regname = vim.v.event.regname
            vim.g.dora_smoke_yankpost_text = vim.v.event.regcontents[1]
            vim.hl.on_yank({timeout=1000})
        end,
    })

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_pos('dir')
    api.fold_out()
    set_cursor_line('archive%.tar%.gz$')
    local expected_path = fs.realpath(tmp) .. '/dir/archive.tar.gz'
    local expected_yank_text = current_line()

    local function yank_highlight_range()
        local yank_ns = assert(vim.api.nvim_get_namespaces()['nvim.hlyank'])
        local marks = vim.api.nvim_buf_get_extmarks(state.buf, yank_ns, 0, -1, {details=true})
        assert_eq(#marks, 1, 'visible yank should highlight one range')
        return marks[1][3], marks[1][4].end_col
    end

    local yank_filename_map = vim.fn.maparg('yf', 'n', false, true)
    assert_eq(yank_filename_map.desc, descriptions.yank_filename)
    assert_eq(type(yank_filename_map.callback), 'function')
    assert_eq(vim.fn.maparg('yn', 'n', false, true).desc, descriptions.yank_name_stem)
    assert_eq(vim.fn.maparg('yb', 'n'), '', 'yb should remain available for users')
    assert_eq(vim.fn.maparg('yB', 'n'), '', 'yB should remain available for users')
    local yank_cursor = vim.api.nvim_win_get_cursor(0)
    yank_filename_map.callback()
    assert_eq(vim.fn.getreg('"'), 'archive.tar.gz')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked filename: archive.tar.gz')
    assert_eq(vim.g.dora_smoke_yankpost_text, 'archive.tar.gz')
    assert_eq(vim.api.nvim_win_get_cursor(0)[1], yank_cursor[1])
    assert_eq(vim.api.nvim_win_get_cursor(0)[2], yank_cursor[2], 'filename yank should preserve the cursor')
    local row = state.rows[vim.api.nvim_win_get_cursor(0)[1]]
    local filename_col = row.name_end_col - #row.name
    local start_col, end_col = yank_highlight_range()
    assert_eq(start_col, filename_col, 'filename yank should highlight only the filename')
    assert_eq(end_col, filename_col + #'archive.tar.gz', 'filename yank should highlight the full filename')

    api.yank_full_path()
    assert_eq(vim.fn.getreg('"'), expected_path)
    assert_eq(notifications[#notifications].msg, 'dora: Yanked full path: ' .. expected_path)
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)
    assert_eq(vim.g.dora_smoke_yankpost_operator, 'y')
    assert_eq(vim.g.dora_smoke_yankpost_regname, '')
    assert_eq(vim.g.dora_smoke_yankpost_text, expected_yank_text)

    vim.g.dora_smoke_yankpost_operator = nil
    vim.g.dora_smoke_yankpost_regname = nil
    vim.g.dora_smoke_yankpost_text = nil
    api.yank_full_path_clipboard()
    assert_eq(vim.fn.getreg('+'), expected_path)
    assert_eq(notifications[#notifications].msg, 'dora: Yanked full path to clipboard: ' .. expected_path)
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)
    assert_eq(vim.g.dora_smoke_yankpost_operator, 'y')
    assert_eq(vim.g.dora_smoke_yankpost_regname, '+')
    assert_eq(vim.g.dora_smoke_yankpost_text, expected_yank_text)

    api.yank_dir_path()
    assert_eq(vim.fn.getreg('"'), fs.realpath(tmp) .. '/dir')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked parent directory: ' .. fs.realpath(tmp) .. '/dir')

    api.yank_dir_path_clipboard()
    assert_eq(vim.fn.getreg('+'), fs.realpath(tmp) .. '/dir')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked parent directory to clipboard: ' .. fs.realpath(tmp) .. '/dir')

    api.yank_filename()
    assert_eq(vim.fn.getreg('"'), 'archive.tar.gz')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked filename: archive.tar.gz')
    start_col, end_col = yank_highlight_range()
    assert_eq(start_col, filename_col)
    assert_eq(end_col, filename_col + #'archive.tar.gz')

    api.yank_filename_clipboard()
    assert_eq(vim.fn.getreg('+'), 'archive.tar.gz')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked filename to clipboard: archive.tar.gz')

    api.yank_name_stem()
    assert_eq(vim.fn.getreg('"'), 'archive.tar')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked name without extension: archive.tar')
    assert_eq(vim.g.dora_smoke_yankpost_text, 'archive.tar')
    start_col, end_col = yank_highlight_range()
    assert_eq(start_col, filename_col, 'name yank should start at the filename')
    assert_eq(end_col, filename_col + #'archive.tar', 'name yank should exclude the final extension')

    api.yank_name_stem_clipboard()
    assert_eq(vim.fn.getreg('+'), 'archive.tar')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked name without extension to clipboard: archive.tar')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
    vim.api.nvim_del_augroup_by_id(augroup)
    vim.fn.setreg('"', old_unnamed, old_unnamed_type)
    if had_clipboard then
        vim.g.clipboard = old_clipboard
    else
        pcall(vim.api.nvim_del_var, 'clipboard')
    end
    vim.notify = old_notify
    vim.g.dora_smoke_clipboard = nil
    vim.g.dora_smoke_yankpost_operator = nil
    vim.g.dora_smoke_yankpost_regname = nil
    vim.g.dora_smoke_yankpost_text = nil
end

do
    local old_notify = vim.notify
    local old_open = vim.ui.open
    local notifications = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
        notifications[#notifications+1] = {msg = msg, level = level}
    end

    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    touch(tmp .. '/dir/child')
    touch(tmp .. '/a')
    touch(tmp .. '/b')
    touch(tmp .. '/c')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local expected_path = fs.realpath(tmp) .. '/a'
    set_cursor_line('a$')
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.open = function(path)
        vim.g.dora_smoke_open_external_path = path
    end
    api.open_external()
    assert_eq(vim.g.dora_smoke_open_external_path, expected_path)
    assert_eq(notifications[#notifications].msg, 'dora: Opening a')
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.open = function()
        error('boom')
    end
    api.open_external()
    assert_match(notifications[#notifications].msg, '^dora: Could not open externally: ')
    assert_eq(notifications[#notifications].level, vim.log.levels.ERROR)

    local opened_paths = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.open = function(path)
        opened_paths[#opened_paths+1] = path
        if vim.endswith(path, '/b') then
            error('boom')
        end
    end
    set_cursor_line('^dir/$')
    api.fold_out()
    set_cursor_line('^dir/$')
    assert_eq(vim.fn.maparg('gx', 'x', false, true).desc, descriptions.open_external)
    vim.api.nvim_feedkeys('V4jgx', 'xt', false)
    assert_eq(#opened_paths, 5, 'visual gx should try to open every selected path')
    assert_eq(vim.api.nvim_get_mode().mode, 'n', 'visual gx should return to normal mode')
    assert_eq(opened_paths[1], fs.realpath(tmp) .. '/dir')
    assert_eq(opened_paths[2], fs.realpath(tmp) .. '/dir/child')
    assert_eq(opened_paths[3], fs.realpath(tmp) .. '/a')
    assert_eq(opened_paths[4], fs.realpath(tmp) .. '/b')
    assert_eq(opened_paths[5], fs.realpath(tmp) .. '/c')
    assert_match(notifications[#notifications - 1].msg, '^dora: Could not open b externally: ',
        'visual gx should report individual failures')
    assert_eq(notifications[#notifications].msg, 'dora: Opening c',
        'visual gx should continue after a failed open')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
    vim.notify = old_notify
    vim.ui.open = old_open
    vim.g.dora_smoke_open_external_path = nil
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    write_file(tmp .. '/alpha.txt', 'hello')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local origin_win = vim.api.nvim_get_current_win()
    local origin_line = vim.api.nvim_win_get_cursor(origin_win)[1]
    local origin_text = vim.api.nvim_get_current_line()
    local name_col = assert(origin_text:find('alpha.txt', 1, true)) - 1
    local anchor_pos = vim.fn.screenpos(origin_win, origin_line, name_col + 1)
    api.file_info()
    local info_win = vim.api.nvim_get_current_win()
    local info_buf = vim.api.nvim_get_current_buf()
    local info_cfg = vim.api.nvim_win_get_config(info_win)
    local info_lines = vim.api.nvim_buf_get_lines(info_buf, 0, -1, false)
    local info_text = table.concat(info_lines, '\n')

    assert(info_win ~= origin_win, 'info should open in a floating window')
    assert_eq(info_cfg.row, anchor_pos.row, 'info should open below the selected name')
    assert_eq(info_cfg.col, anchor_pos.col - 2, 'info content should align with the selected name')
    assert_match(vim.wo[info_win].winhighlight, 'FloatBorder:DoraPromptBorder')
    assert_match(win_title(info_win), 'Info')
    assert_match(info_text, 'Name%s+alpha%.txt')
    assert_match(info_text, 'Type%s+File')
    assert_match(info_text, 'Size%s+5 B')
    assert_match(info_text, 'Permissions%s+rw%-r%-%-r%-%-')
    assert_match(info_text, 'Modified%s+%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d')
    assert(info_text:find(tmp .. '/alpha.txt', 1, true), 'info should show the selected path')
    local stat = assert(vim.loop.fs_lstat(tmp .. '/alpha.txt'))
    assert(info_text:find(stat.uid .. ':' .. stat.gid, 1, true), 'info should retain numeric owner and group IDs')
    if vim.loop.os_uname().sysname == 'Darwin' or vim.loop.os_uname().sysname == 'Linux' then
        local passwd = assert(vim.loop.os_get_passwd())
        assert(info_text:find(passwd.username, 1, true), 'info should resolve the owner name')
    end
    assert(not find_line_index(info_lines, '^Executable%s+'), 'info should omit executable status')
    assert(not find_line_index(info_lines, '^Links%s+'), 'info should omit hard-link count')
    assert(not find_line_index(info_lines, '^Inode%s+'), 'info should omit inode')

    local marks = vim.api.nvim_buf_get_extmarks(info_buf, -1, 0, -1, {details=true})
    local has_label, has_value = false, false
    for _, mark in ipairs(marks) do
        local hl = mark[4].hl_group
        has_label = has_label or hl == 'DoraInfoLabel'
        has_value = has_value or hl == 'DoraInfoValue'
    end
    assert(has_label, 'info should highlight labels')
    assert(has_value, 'info should highlight values')

    vim.api.nvim_feedkeys('q', 'xt', false)
    assert_eq(vim.api.nvim_get_current_win(), origin_win, 'closing info should restore origin window')
    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/target.txt')
    assert(vim.loop.fs_symlink('target.txt', tmp .. '/link'))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_line('link$')
    api.file_info()
    local info_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

    assert_match(info_lines[3], '^Path%s+')
    assert_match(info_lines[4], '^Target%s+target%.txt$')
    assert_match(info_lines[5], '^Target type%s+File$')
    assert_match(info_lines[6], '^Size%s+')

    vim.api.nvim_feedkeys('q', 'xt', false)
    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end
