-- Confirmation window rendering: titles, truncation and alignment, icons, borders.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/02_confirm_win.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local fs = h.fs
local config = h.config
local confirm_win = h.confirm_win
local prompt = h.prompt
local api = h.api
local store = h.store
local window = h.window
local cwd = h.cwd
local assert_eq = h.assert_eq
local assert_match = h.assert_match
local touch = h.touch
local set_cursor_pos = h.set_cursor_pos
local win_title = h.win_title

do
    local origin_win = vim.api.nvim_get_current_win()
    local old_guicursor = vim.o.guicursor
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    touch(tmp .. '/foo.js')
    touch(tmp .. '/dir/bar.lua')
    local paths = {tmp .. '/foo.js', tmp .. '/dir', tmp .. '/dir/bar.lua'}
    for i = 4, 12 do
        paths[#paths+1] = tmp .. '/dir/file-' .. i .. '.txt'
    end
    local origin_cursor = vim.api.nvim_win_get_cursor(origin_win)
    -- No anchor: the confirmation superimposes flush left of the text, so measure
    -- column 0 of the cursor line, not the cursor cell.
    local origin_pos = vim.fn.screenpos(origin_win, origin_cursor[1], 1)

    confirm_win.show(paths, function(confirmed)
        vim.g.dora_smoke_confirm_delete = confirmed
    end)
    local confirm_win = vim.api.nvim_get_current_win()
    local confirm_buf = vim.api.nvim_get_current_buf()
    local confirm_lines = vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)

    assert_match(vim.wo[confirm_win].winhighlight, 'FloatBorder:DoraPromptBorderInvalid')
    local content_pos = vim.fn.screenpos(confirm_win, 1, 1)
    assert_eq(content_pos.row, origin_pos.row, 'delete confirmation should sit on the cursor line by default')
    assert_eq(content_pos.col, origin_pos.col, 'delete confirmation should align left of the text by default')
    assert_match(win_title(confirm_win), 'Delete 12 files%?')
    assert_eq(#confirm_lines, 11, 'delete confirmation should cap visible files')
    assert_eq(confirm_lines[1], 'foo.js')
    assert_eq(confirm_lines[2], 'dir/')
    assert_eq(confirm_lines[3], 'bar.lua')
    assert_eq(confirm_lines[11], '... and 2 more')

    local marks = vim.api.nvim_buf_get_extmarks(confirm_buf, -1, 0, -1, {details=true})
    local has_path, has_file, has_dir, has_dir_suffix, has_more = false, false, false, false, false
    for _, mark in ipairs(marks) do
        local row, col, details = mark[2], mark[3], mark[4]
        ---@cast details -nil  -- always present with {details = true}
        has_path = has_path
            or details.hl_group == 'DoraDeletePath'
        has_file = has_file
            or row == 0 and col == 0 and details.end_col == 6 and details.hl_group == 'DoraFile'
        has_dir = has_dir
            or row == 1 and col == 0 and details.end_col == 3 and details.hl_group == 'DoraDirectory'
        has_dir_suffix = has_dir_suffix
            or row == 1 and col == 3 and details.end_col == 4 and details.hl_group == 'DoraVirtText'
        has_more = has_more
            or row == 10 and details.hl_group == 'DoraMutedText'
    end
    assert(not has_path, 'delete confirmation should not dim the path portion')
    assert(has_file, 'delete confirmation should highlight file names by type')
    assert(has_dir, 'delete confirmation should highlight directory names by type')
    assert(has_dir_suffix, 'delete confirmation should highlight directory suffixes with DoraVirtText')
    assert(has_more, 'delete confirmation should highlight the overflow row')

    vim.api.nvim_feedkeys('n', 'xt', false)
    assert_eq(vim.g.dora_smoke_confirm_delete, false)
    assert_eq(vim.api.nvim_get_current_win(), origin_win)
    assert_eq(vim.o.guicursor, old_guicursor)
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Entries carry the tree view's ls -F type markers: '*' for executables,
    -- '|' for fifos, '@' for symlinks (without the tree's arrow-and-target),
    -- alongside the existing directory '/'.
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/run.sh')
    assert(vim.loop.fs_chmod(tmp .. '/run.sh', tonumber('755', 8)))
    vim.fn.system({'mkfifo', tmp .. '/my-fifo'})
    assert_eq(vim.v.shell_error, 0, 'mkfifo should succeed')
    assert(vim.loop.fs_symlink(tmp .. '/run.sh', tmp .. '/my-link'))
    touch(tmp .. '/plain.txt')

    confirm_win.show({tmp .. '/run.sh', tmp .. '/my-fifo', tmp .. '/my-link', tmp .. '/plain.txt'}, function() end)
    local confirm_buf = vim.api.nvim_get_current_buf()
    local confirm_lines = vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)
    assert_eq(confirm_lines[1], 'run.sh*', 'executables should carry the ls -F star marker')
    assert_eq(confirm_lines[2], 'my-fifo|', 'fifos should carry the ls -F pipe marker')
    assert_eq(confirm_lines[3], 'my-link@', 'symlinks should carry the ls -F at marker')
    assert_eq(confirm_lines[4], 'plain.txt', 'regular files should carry no type marker')

    local marks = vim.api.nvim_buf_get_extmarks(confirm_buf, -1, 0, -1, {details=true})
    local has_exec, has_fifo, has_exec_marker, has_fifo_marker = false, false, false, false
    for _, mark in ipairs(marks) do
        local row, col, details = mark[2], mark[3], mark[4]
        ---@cast details -nil  -- always present with {details = true}
        has_exec = has_exec
            or row == 0 and col == 0 and details.end_col == 6 and details.hl_group == 'DoraExecutable'
        has_exec_marker = has_exec_marker
            or row == 0 and col == 6 and details.end_col == 7 and details.hl_group == 'DoraVirtText'
        has_fifo = has_fifo
            or row == 1 and col == 0 and details.end_col == 7 and details.hl_group == 'DoraFifo'
        has_fifo_marker = has_fifo_marker
            or row == 1 and col == 7 and details.end_col == 8 and details.hl_group == 'DoraVirtText'
    end
    assert(has_exec, 'confirmation should color executable names with DoraExecutable')
    assert(has_exec_marker, 'confirmation should highlight the star marker with DoraVirtText')
    assert(has_fifo, 'confirmation should color fifo names with DoraFifo')
    assert(has_fifo_marker, 'confirmation should highlight the pipe marker with DoraVirtText')

    vim.api.nvim_feedkeys('n', 'xt', false)
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local origin_buf = vim.api.nvim_get_current_buf()
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    local long_dir = 'very-long-delete-confirmation-path-segment-with-extra-context'
    local long_file = 'file-with-a-long-name-that-should-stay-visible.txt'
    local rel_path = long_dir .. '/' .. long_file
    assert_eq(vim.fn.mkdir(tmp .. '/' .. long_dir, 'p'), 1)
    touch(tmp .. '/' .. rel_path)

    local anchor_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(anchor_buf)
    vim.api.nvim_buf_set_lines(anchor_buf, 0, -1, false, {string.rep('x', vim.o.columns)})
    local anchor_win = vim.api.nvim_get_current_win()
    local anchor_col = math.max(0, vim.o.columns - 12)
    local anchor_pos = vim.fn.screenpos(anchor_win, 1, anchor_col + 1)

    confirm_win.show({tmp .. '/' .. rel_path}, function() end, {
        anchor = {win = anchor_win, line = 1, col = anchor_col},
    })
    local confirm_win = vim.api.nvim_get_current_win()
    local confirm_buf = vim.api.nvim_get_current_buf()
    local confirm_cfg = vim.api.nvim_win_get_config(confirm_win)
    local confirm_lines = vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)
    local view = vim.api.nvim_win_call(confirm_win, function()
        return vim.fn.winsaveview()
    end)
    local expected_width = math.max(32, math.min(vim.o.columns - 4, vim.fn.strdisplaywidth(long_file) + 1))
    local expected_col = math.min(anchor_pos.col - 2, math.max(0, vim.o.columns - expected_width - 2))

    assert_eq(confirm_lines[1], long_file)
    assert_eq(confirm_cfg.width, expected_width, 'delete confirmation should expand anchored windows for long names')
    assert_eq(confirm_cfg.col, expected_col, 'delete confirmation should shift left to fit expanded windows')
    assert(confirm_cfg.col < anchor_pos.col - 1, 'delete confirmation should start left of the anchor when needed')
    assert_eq(view.leftcol, 0, 'delete confirmation should not rely on horizontal scroll')

    vim.api.nvim_feedkeys('n', 'xt', false)
    vim.api.nvim_set_current_buf(origin_buf)
    vim.api.nvim_buf_delete(anchor_buf, {force = true})
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- A name longer than the old fixed cap stays fully visible when the viewport
    -- is wide enough: the window grows to fit it rather than eliding.
    local origin_buf = vim.api.nvim_get_current_buf()
    local saved_columns = vim.o.columns
    vim.o.columns = 200
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    local long_file = string.rep('a', 100) .. '.txt'
    assert(vim.fn.strdisplaywidth(long_file) > 96, 'name should exceed the old fixed cap')
    local path = tmp .. '/' .. long_file
    touch(path)

    confirm_win.show({path}, function() end)
    local confirm_win = vim.api.nvim_get_current_win()
    local confirm_buf = vim.api.nvim_get_current_buf()
    local confirm_cfg = vim.api.nvim_win_get_config(confirm_win)
    local confirm_lines = vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)

    assert_eq(confirm_lines[1], long_file)
    assert(not confirm_lines[1]:find('…', 1, true), 'a name that fits the viewport should not be elided')
    assert_eq(confirm_cfg.width, vim.fn.strdisplaywidth(long_file) + 1,
        'delete confirmation should grow past the old cap to fit a long name')

    vim.api.nvim_feedkeys('n', 'xt', false)
    vim.api.nvim_set_current_buf(origin_buf)
    vim.o.columns = saved_columns
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- A paste conflict whose name is too long for the window elides the name(s)
    -- so no row spills past the edge, in either keep-both or overwrite mode.
    local origin_win = vim.api.nvim_get_current_win()
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    local long_name = 'a-really-quite-long-file-name-that-will-never-fit-the-confirmation-window-at-all.txt'
    local path = tmp .. '/' .. long_name
    touch(path)
    local rename = 'a-really-quite-long-file-name-that-will-never-fit-the-confirmation-window-at-all (1).txt'

    confirm_win.show({path}, function() end, {
        action = 'Paste',
        base = tmp,
        dest = tmp,
        allow_overwrite = true,
        renames = {[path] = rename},
        operations = {[path] = 'copy'},
    })
    local confirm_win = vim.api.nvim_get_current_win()
    local confirm_buf = vim.api.nvim_get_current_buf()
    local width = vim.api.nvim_win_get_config(confirm_win).width

    local function fits(label)
        for _, line in ipairs(vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)) do
            assert(vim.fn.strdisplaywidth(line) <= width,
                ('%s row should fit the %d-col window: %q'):format(label, width, line))
        end
    end
    local function find_line(needle)
        for _, line in ipairs(vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)) do
            if line:find(needle, 1, true) then
                return line
            end
        end
    end

    assert(width <= vim.o.columns - 4, 'paste confirmation should not exceed the viewport')
    local keep_line = find_line(' (rename)')
    assert(keep_line, 'keep-both paste should preview the renamed file')
    assert(keep_line:find('→', 1, true), 'keep-both preview should keep the rename arrow')
    assert(keep_line:find('…', 1, true), 'a too-long keep-both row should be elided')
    fits('keep-both')

    -- Overwrite mode drops the preview but keeps the longer suffix; it must fit too.
    vim.api.nvim_feedkeys('o', 'xt', false)
    assert(find_line(' (overwrite)'), 'overwrite mode should tag the conflict row')
    assert(find_line('…'), 'a too-long overwrite row should be elided')
    fits('overwrite')

    vim.api.nvim_feedkeys('n', 'xt', false)
    assert_eq(vim.api.nvim_get_current_win(), origin_win)
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- A nested mark shows a relative path; when it overflows, the directory
    -- prefix is elided first so the basename (with its extension) stays readable.
    local origin_win = vim.api.nvim_get_current_win()
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    local long_dir = 'a-deeply-nested-directory-whose-name-is-much-too-long-to-fit-the-window'
    local long_file = 'and-then-a-file-with-an-equally-unreasonable-name-inside-it.txt'
    local rel_path = long_dir .. '/' .. long_file
    assert_eq(vim.fn.mkdir(tmp .. '/' .. long_dir, 'p'), 1)
    touch(tmp .. '/' .. rel_path)

    confirm_win.show({tmp .. '/' .. rel_path}, function() end, {base = tmp})
    local confirm_win = vim.api.nvim_get_current_win()
    local confirm_buf = vim.api.nvim_get_current_buf()
    local width = vim.api.nvim_win_get_config(confirm_win).width
    local line = vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)[1]

    assert(vim.fn.strdisplaywidth(line) <= width,
        ('nested row should fit the %d-col window: %q'):format(width, line))
    assert(line:find('…', 1, true), 'an overflowing relative path should be elided')
    assert(not line:find(long_dir, 1, true), 'the long directory prefix should not survive in full')
    assert(line:find(long_file, 1, true), 'the basename should stay whole when the prefix can absorb the cut')

    vim.api.nvim_feedkeys('n', 'xt', false)
    assert_eq(vim.api.nvim_get_current_win(), origin_win)
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/icon.txt')

    local old_icons = config.icons
    local old_mini_icons = _G.MiniIcons
    config.icons = 'mini.icons'
    _G.MiniIcons = {
        get = function(category, path)
            assert_eq(category, 'file')
            assert_eq(path, tmp .. '/icon.txt')
            return '[del]', 'DoraIcon'
        end,
    }

    confirm_win.show({tmp .. '/icon.txt'}, function() end)
    local confirm_buf = vim.api.nvim_get_current_buf()
    local confirm_lines = vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)
    assert_eq(confirm_lines[1], '[del] icon.txt', 'delete confirmation should render file icons when enabled')

    local marks = vim.api.nvim_buf_get_extmarks(confirm_buf, -1, 0, -1, {details=true})
    local has_icon, has_file = false, false
    for _, mark in ipairs(marks) do
        local row, col, details = mark[2], mark[3], mark[4]
        ---@cast details -nil  -- always present with {details = true}
        has_icon = has_icon
            or row == 0 and col == 0 and details.end_col == 5 and details.hl_group == 'DoraIcon'
        has_file = has_file
            or row == 0 and col == 6 and details.end_col == 14 and details.hl_group == 'DoraFile'
    end
    assert(has_icon, 'delete confirmation should highlight icons')
    assert(has_file, 'delete confirmation should keep highlighting filenames after icons')

    vim.api.nvim_feedkeys('n', 'xt', false)
    config.icons = old_icons
    _G.MiniIcons = old_mini_icons
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    local dir = tmp .. '/subdir'
    assert(vim.loop.fs_mkdir(dir, tonumber('755', 8)))

    local old_icons = config.icons
    config.icons = true

    -- A directory left expanded in the tree keeps its open-folder icon.
    confirm_win.show({dir}, function() end, {expanded = {[dir] = true}})
    local expanded_line = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)[1]
    assert_eq(expanded_line, '\238\151\190 subdir/', 'delete confirmation should preserve the expanded directory icon')
    vim.api.nvim_feedkeys('n', 'xt', false)

    -- Without expansion it falls back to the collapsed icon.
    confirm_win.show({dir}, function() end)
    local collapsed_line = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)[1]
    assert_eq(collapsed_line, '\238\151\191 subdir/', 'delete confirmation should use the collapsed icon for unexpanded directories')
    vim.api.nvim_feedkeys('n', 'xt', false)

    config.icons = old_icons
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/icon.txt')

    local old_icons = config.icons
    local old_mini_icons = _G.MiniIcons
    config.icons = 'mini.icons'
    _G.MiniIcons = {
        get = function() return '▸', 'DoraIcon' end,
    }

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('icon.txt')
    local origin_win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(origin_win)
    local row = store.get().rows[cursor[1]]
    assert_eq(row.name_start_col, #'▸ ', 'icon rows should offset the name column')
    local name_pos = vim.fn.screenpos(origin_win, cursor[1], row.name_start_col + 1)
    api.delete()

    local confirm_win = vim.api.nvim_get_current_win()
    local confirm_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert_eq(confirm_lines[1], '▸ icon.txt')
    local first_item_pos = vim.fn.screenpos(confirm_win, 1, #'▸ ' + 1)
    assert_eq(first_item_pos.row, name_pos.row, 'icon delete confirmation should superimpose onto the deleted row')
    assert_eq(first_item_pos.col, name_pos.col, 'icon delete confirmation should align the filename with the deleted row')

    vim.api.nvim_feedkeys('n', 'xt', false)
    api.quit()
    config.icons = old_icons
    _G.MiniIcons = old_mini_icons
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/icon.txt')

    local old_icons = config.icons
    local old_mini_icons = _G.MiniIcons
    config.icons = 'mini.icons'
    _G.MiniIcons = {
        get = function() return '▸', 'DoraIcon' end,
    }

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('icon.txt')
    local origin_win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(origin_win)
    local row = store.get().rows[cursor[1]]
    local icon_pos = vim.fn.screenpos(origin_win, cursor[1], row.icon_start_col + 1)
    local name_pos = vim.fn.screenpos(origin_win, cursor[1], row.name_start_col + 1)

    api.rename()
    local prompt_win = vim.api.nvim_get_current_win()
    local prompt_buf = vim.api.nvim_get_current_buf()
    assert_eq(vim.api.nvim_buf_get_lines(prompt_buf, 0, 1, false)[1], 'icon.txt',
        'rename prompt should keep the icon out of the editable text')
    local virt_icon
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(prompt_buf, -1, 0, -1, {details = true})) do
        local details = mark[4]
        if details and details.virt_text and details.virt_text_pos == 'inline' then
            virt_icon = details.virt_text[1][1]
        end
    end
    assert_eq(virt_icon, '▸ ', 'rename prompt should render the icon as virtual text')
    -- screenpos on the first byte reports its inline virt text start, so the
    -- icon alignment pins the first cell and the second byte pins the text
    local input_pos = vim.fn.screenpos(prompt_win, 1, 1)
    assert_eq(input_pos.row, icon_pos.row, 'icon rename prompt should superimpose onto the renamed row')
    assert_eq(input_pos.col, icon_pos.col, 'icon rename prompt icon should align with the row icon')
    local second_pos = vim.fn.screenpos(prompt_win, 1, 2)
    assert_eq(second_pos.col, name_pos.col + 1, 'icon rename prompt text should align with the filename')

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-c>', true, false, true), 'xt', false)
    api.quit()
    config.icons = old_icons
    _G.MiniIcons = old_mini_icons
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- The rename prompt icon re-resolves from the typed name under the
    -- entry's fixed type: directories need no trailing slash, and an expanded
    -- directory keeps its open icon.
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/a.txt')
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))

    local old_icons = config.icons
    local old_mini_icons = _G.MiniIcons
    config.icons = 'mini.icons'
    _G.MiniIcons = {
        get = function(category, path)
            return '[' .. category .. ':' .. path .. ']',
                category == 'directory' and 'DoraDirectory' or 'DoraIcon'
        end,
    }

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local old_input = prompt.input
    set_cursor_pos('a.txt')
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(type(opts.icon), 'function', 'rename prompt should pass a live icon when icons are enabled')
        local icon, hl = opts.icon('b.lua')
        assert_eq(icon, '[file:b.lua]', 'rename prompt icon should track the typed name')
        assert_eq(hl, 'DoraIcon')
        cb(nil)
    end
    api.rename()

    set_cursor_pos('sub')
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        local icon, hl = opts.icon('renamed')
        assert_eq(icon, '[directory:renamed]',
            'renaming a directory should resolve the typed name as a directory without a trailing slash')
        assert_eq(hl, 'DoraDirectory')
        cb(nil)
    end
    api.rename()

    -- Directories resolve through the built-in fallback under the devicons
    -- setting, so the expanded flag picks the open or closed glyph. Flip the
    -- provider only around the prompt itself: rendering file rows under
    -- `true` would poison the icon module's provider cache for later tests.
    api.fold_out()
    set_cursor_pos('sub')
    local sub_row = store.get().rows[vim.api.nvim_win_get_cursor(0)[1]]
    assert_eq(sub_row.name, 'sub')
    local icons = require'dora.icons'
    local expanded_icon = icons.get(true, {name = 'sub', type = 'directory'}, sub_row.path, true)
    local collapsed_icon = icons.get(true, {name = 'sub', type = 'directory'}, sub_row.path, false)
    assert(expanded_icon ~= collapsed_icon, 'the expanded directory icon should differ from the collapsed one')
    config.icons = true
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        local icon = opts.icon('renamed')
        assert_eq(icon, expanded_icon, 'renaming an expanded directory should keep the open-folder icon')
        cb(nil)
    end
    api.rename()

    config.icons = false
    set_cursor_pos('a.txt')
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.icon, nil, 'disabled icons should leave the rename prompt icon unset')
        cb(nil)
    end
    api.rename()

    prompt.input = old_input
    config.icons = old_icons
    _G.MiniIcons = old_mini_icons
    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Rename prompt border: a file→file overwrite warns, a clean name is valid,
    -- and an existing directory target is invalid.
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/source.txt')
    touch(tmp .. '/existing.txt')
    assert(vim.loop.fs_mkdir(tmp .. '/subdir', tonumber('755', 8)))
    local src = tmp .. '/source.txt'

    local p = prompt.input({
        cwd = tmp,
        initial_prompt = 'source.txt',
        validate = function(input) return fs.validate_rename(input, src) end,
        warn = function(_, dest)
            return fs.exists(dest) and not fs.same_file(src, dest)
        end,
    }, function() end)
    assert(p)

    p:set_input('existing.txt', #'existing.txt')
    p:validate()
    assert_match(vim.wo[p.input_win].winhighlight, 'FloatBorder:DoraPromptBorderWarn',
        'renaming over an existing file should warn')

    p:set_input('unique.txt', #'unique.txt')
    p:validate()
    assert_match(vim.wo[p.input_win].winhighlight, 'FloatBorder:DoraPromptBorderValid',
        'renaming to a free name should be valid')

    p:set_input('subdir', #'subdir')
    p:validate()
    assert_match(vim.wo[p.input_win].winhighlight, 'FloatBorder:DoraPromptBorderInvalid',
        'renaming over an existing directory should be invalid')

    p:cancel()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/enter.txt')

    confirm_win.show({tmp .. '/enter.txt'}, function(confirmed)
        vim.g.dora_smoke_enter_confirm_delete = confirmed
    end)

    vim.api.nvim_feedkeys('\r', 'xt', false)
    assert_eq(vim.g.dora_smoke_enter_confirm_delete, true)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local origin_win = vim.api.nvim_get_current_win()
    local old_guicursor = vim.o.guicursor
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/leave.txt')

    vim.g.dora_smoke_leave_confirm_delete = nil
    confirm_win.show({tmp .. '/leave.txt'}, function(confirmed)
        vim.g.dora_smoke_leave_confirm_delete = confirmed
    end)
    local confirm_win = vim.api.nvim_get_current_win()
    assert(confirm_win ~= origin_win, 'delete confirmation should take focus')

    vim.api.nvim_set_current_win(origin_win)
    assert_eq(vim.g.dora_smoke_leave_confirm_delete, false,
        'leaving the delete confirmation should cancel it')
    assert(not vim.api.nvim_win_is_valid(confirm_win),
        'leaving the delete confirmation should close the window')
    assert_eq(vim.o.guicursor, old_guicursor,
        'leaving the delete confirmation should restore guicursor')
    assert_eq(vim.api.nvim_get_current_win(), origin_win)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local old_winborder = vim.o.winborder
    vim.o.winborder = ''
    assert_eq(window.border(), 'rounded', 'window borders should keep Dora rounded fallback without winborder')
    vim.o.winborder = 'single'
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        row = 0,
        col = 0,
        width = 1,
        height = 1,
        border = window.border(),
    })
    assert_eq(vim.api.nvim_win_get_config(win).border[1], '┌', 'window borders should defer to winborder when set')
    window.close(buf, win)
    vim.o.winborder = 'none'
    assert_eq(window.border(), nil, 'window borders should respect no-border winborder')
    vim.o.winborder = old_winborder
end
