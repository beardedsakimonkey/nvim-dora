local orig_notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, log_level, ...)
    if log_level == vim.log.levels.INFO then
        return
    end
    return orig_notify(msg, log_level, ...)
end

local function assert_eq(actual, expected, msg)
    assert(actual == expected, msg or ('expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual)))
end

local function assert_match(str, pattern, msg)
    assert(str:match(pattern), msg or (vim.inspect(str) .. ' does not match ' .. vim.inspect(pattern)))
end

local dora = require'dora'
local bookmarks = require'dora.bookmarks'
local fs = require'dora.fs'
local config = dora.config
local delete_win = require'dora.delete_win'
local keymaps = require'dora.keymaps'
local prompt = require'dora.prompt'
local api = require'dora.api'
local store = require'dora.store'
local window = require'dora.window'

for lhs, rhs in pairs(config.keymaps) do
    local _, desc = keymaps.resolve(rhs)
    assert(desc, ('default keymap %s should have a description'):format(lhs))
end

do
    local old_config = dora.config
    local old_keymaps = dora.config.keymaps
    local old_show_hidden_files = dora.config.show_hidden_files
    local old_tree_indent = dora.config.tree_indent
    local old_q = dora.config.keymaps.q
    local old_smoke_key = dora.config.keymaps.__dora_smoke_setup

    dora.setup({
        show_hidden_files = false,
        tree_indent = 2,
        keymaps = {
            q = {'quit'},
            __dora_smoke_setup = 'help',
        },
    })

    assert_eq(dora.config, old_config, 'setup should preserve the config table')
    assert_eq(dora.config.keymaps, old_keymaps, 'setup should preserve the keymaps table')
    assert_eq(config.show_hidden_files, false, 'setup should update config values in-place')
    assert_eq(config.tree_indent, 2, 'setup should update tree indentation')
    assert_eq(config.keymaps.__dora_smoke_setup, 'help', 'setup should merge new keymaps')
    assert_eq(config.keymaps.q.desc, nil, 'setup should replace keymap specs instead of merging desc')
    local _, q_desc = keymaps.resolve(config.keymaps.q)
    assert_eq(q_desc, 'Quit', 'table overrides without desc should inherit the action description')

    dora.config.show_hidden_files = old_show_hidden_files
    dora.config.tree_indent = old_tree_indent
    dora.config.keymaps.q = old_q
    dora.config.keymaps.__dora_smoke_setup = old_smoke_key
end

local cwd = assert(vim.loop.cwd())

assert_eq(vim.fn.synIDtrans(vim.fn.hlID('DoraPromptBorder')), vim.fn.synIDtrans(vim.fn.hlID('FloatBorder')), 'prompt border should default to FloatBorder')

local function touch(path)
    local fd = assert(vim.loop.fs_open(path, 'w', tonumber('644', 8)))
    assert(vim.loop.fs_close(fd))
end

local function write_file(path, contents)
    local fd = assert(vim.loop.fs_open(path, 'w', tonumber('644', 8)))
    assert(vim.loop.fs_write(fd, contents, 0))
    assert(vim.loop.fs_close(fd))
end

local function marked_path_count(state)
    local count = 0
    for _ in pairs(state.marked_paths) do
        count = count + 1
    end
    return count
end

-- Paste runs the copy asynchronously, so the editor stays responsive. Pump the
-- event loop until the in-flight paste finishes before asserting on its result.
local function wait_for_paste()
    assert(vim.wait(5000, function()
        return not store.get().paste_in_progress
    end), 'paste did not finish')
end

local function clear_persisted_view_state(win)
    pcall(vim.api.nvim_win_del_var, win or 0, 'dora_previous_directory')
end

local function lines()
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function buf_lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function set_cursor_line(pattern)
    for i, line in ipairs(lines()) do
        if line:match(pattern) then
            vim.api.nvim_win_set_cursor(0, {i, 0})
            return
        end
    end
    error('could not find line matching ' .. pattern)
end

local function current_line()
    return vim.api.nvim_get_current_line()
end

local function find_line_index(search_lines, pattern)
    for i, line in ipairs(search_lines) do
        if line:match(pattern) then
            return i
        end
    end
end

-- Mirrors api's set_cursor_pos: find the row by name rather than parsing
-- rendered lines
local function set_cursor_pos(name)
    for i, row in ipairs(store.get().rows or {}) do
        if row.name == name then
            vim.api.nvim_win_set_cursor(0, {i, 0})
            return
        end
    end
    error('could not find row ' .. name)
end

local function assert_line_before(pattern_a, pattern_b, msg)
    local search_lines = lines()
    local a = find_line_index(search_lines, pattern_a)
    local b = find_line_index(search_lines, pattern_b)
    assert(a and b and a < b, msg or (pattern_a .. ' should appear before ' .. pattern_b))
end

local function win_title(win)
    local title = vim.api.nvim_win_get_config(win).title
    if type(title) == 'string' then
        return title
    end
    if type(title) == 'table' then
        local chunks = {}
        for _, chunk in ipairs(title) do
            chunks[#chunks+1] = type(chunk) == 'table' and chunk[1] or tostring(chunk)
        end
        return table.concat(chunks)
    end
    return ''
end

local function has_highlight(state, hl_group)
    local marks = vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    for _, mark in ipairs(marks) do
        if mark[4].hl_group == hl_group then
            return true
        end
    end
    return false
end

local function has_high_priority_highlight(state, hl_group)
    local marks = vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    for _, mark in ipairs(marks) do
        if mark[4].hl_group == hl_group and mark[4].priority == 10000 then
            return true
        end
    end
    return false
end

local function has_priority_highlight(state, hl_group, priority)
    local marks = vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    for _, mark in ipairs(marks) do
        if mark[4].hl_group == hl_group and mark[4].priority == priority then
            return true
        end
    end
    return false
end

local function has_sign_highlight(state, hl_group)
    local marks = vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    for _, mark in ipairs(marks) do
        local details = mark[4]
        ---@cast details -nil  -- always present with {details = true}
        if details.sign_text and vim.startswith(details.sign_text, '▌') and details.sign_hl_group == hl_group then
            return true
        end
    end
    return false
end

local function cursor_tree_highlights(state)
    local ret = {}
    local marks = vim.api.nvim_buf_get_extmarks(state.buf, state.cursor_ns, 0, -1, {details = true})
    for _, mark in ipairs(marks) do
        if mark[4].hl_group == 'DoraTreeActive' then
            ret[#ret+1] = mark
        end
    end
    return ret
end

local function assert_cursor_tree_highlights(state, expected_count)
    vim.api.nvim_exec_autocmds('CursorMoved', {buffer = state.buf})
    local marks = cursor_tree_highlights(state)
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local row = state.rows[lnum]
    local expected_segments = {}
    local highlighted_segments = {}
    assert(row.parent_path, 'cursor row should have a parent path')
    assert_eq(#marks, expected_count, 'cursor should highlight the active sibling connectors')
    for i, tree_row in ipairs(state.rows) do
        for _, segment in ipairs(tree_row.tree_continuation_segments) do
            if segment.parent_path == row.parent_path then
                expected_segments[('%d:%d:%d'):format(i, segment.start_col, segment.end_col)] = true
            end
        end
        if tree_row.parent_path == row.parent_path and tree_row.tree_connector_start_col then
            expected_segments[('%d:%d:%d'):format(i, tree_row.tree_connector_start_col, tree_row.tree_prefix_len)] = true
        end
    end
    for _, mark in ipairs(marks) do
        local highlighted_lnum = mark[2] + 1
        local key = ('%d:%d:%d'):format(highlighted_lnum, mark[3], mark[4].end_col)
        assert(expected_segments[key], 'active tree highlight should match the cursor parent group')
        assert_eq(mark[4].priority, 10001)
        highlighted_segments[key] = true
    end
    for key in pairs(expected_segments) do
        assert(highlighted_segments[key], 'sibling tree segment should be highlighted')
    end
end

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
    local origin_pos = vim.fn.screenpos(origin_win, origin_cursor[1], origin_cursor[2] + 1)

    delete_win.delete(paths, function(confirmed)
        vim.g.dora_smoke_confirm_delete = confirmed
    end)
    local confirm_win = vim.api.nvim_get_current_win()
    local confirm_buf = vim.api.nvim_get_current_buf()
    local confirm_cfg = vim.api.nvim_win_get_config(confirm_win)
    local confirm_lines = vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)

    assert_match(vim.wo[confirm_win].winhighlight, 'FloatBorder:DoraPromptBorderInvalid')
    assert_eq(confirm_cfg.row, origin_pos.row, 'delete confirmation should anchor to the cursor by default')
    assert_eq(confirm_cfg.col, origin_pos.col - 1, 'delete confirmation should anchor to the cursor by default')
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

    delete_win.delete({tmp .. '/' .. rel_path}, function() end, {
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

    delete_win.delete({path}, function() end)
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

    delete_win.delete({path}, function() end, {
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
    local keep_line = find_line(' (keep)')
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

    delete_win.delete({tmp .. '/' .. rel_path}, function() end, {base = tmp})
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
    local bookmark_rows = bookmarks.help_rows(bookmarks.new())
    assert_eq(bookmark_rows[1].lhs, "''", "a fresh bookmark state should include the previous-directory shortcut")
    assert_eq(bookmark_rows[1].desc, 'Jump to previous directory')
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

    delete_win.delete({tmp .. '/icon.txt'}, function() end)
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
    delete_win.delete({dir}, function() end, {expanded = {[dir] = true}})
    local expanded_line = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)[1]
    assert_eq(expanded_line, '\238\151\190 subdir/', 'delete confirmation should preserve the expanded directory icon')
    vim.api.nvim_feedkeys('n', 'xt', false)

    -- Without expansion it falls back to the collapsed icon.
    delete_win.delete({dir}, function() end)
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
        if details.virt_text and details.virt_text_pos == 'inline' then
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

    delete_win.delete({tmp .. '/enter.txt'}, function(confirmed)
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
    delete_win.delete({tmp .. '/leave.txt'}, function(confirmed)
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

do
    local p = prompt.input({
        prompt = 'Smoke',
        cwd = cwd,
        validate = function(input)
            assert(input ~= 'bad')
            return input .. '-ok'
        end,
    }, function(input, result)
        vim.g.dora_smoke_input = input or 'nil'
        vim.g.dora_smoke_result = result or 'nil'
    end)
    ---@cast p DoraPrompt

    local cfg = vim.api.nvim_win_get_config(p.input_win)
    assert_eq(cfg.relative, 'editor')
    assert_eq(cfg.anchor, 'NW')
    assert_eq(cfg.border[1], '╭')
    assert_eq(type(vim.fn.maparg('<Esc>', 'i', false, true).callback), 'function',
        'prompt should close on insert-mode escape by default')
    assert_eq(type(vim.fn.maparg('<Esc>', 'n', false, true).callback), 'function')
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(p.input_buf, 'i')) do
        assert(map.lhs ~= '<Tab>', 'prompt should not map tab for completion')
    end

    p:set_input('bad', 3)
    p:validate()
    assert_eq(p.is_valid, false)

    p:set_input('abc', 3)
    p:confirm()
    assert_eq(vim.g.dora_smoke_input, 'abc')
    assert_eq(vim.g.dora_smoke_result, 'abc-ok')
end

do
    local origin_win = vim.api.nvim_get_current_win()
    local old_buf = vim.api.nvim_win_get_buf(origin_win)
    local old_number = vim.wo[origin_win].number
    local old_relativenumber = vim.wo[origin_win].relativenumber
    local old_signcolumn = vim.wo[origin_win].signcolumn
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.api.nvim_win_set_buf(origin_win, buf)
    vim.wo[origin_win].number = true
    vim.wo[origin_win].relativenumber = false
    vim.wo[origin_win].signcolumn = 'yes'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'root', '└── anchored.txt'})
    vim.api.nvim_win_set_cursor(origin_win, {2, 0})

    local name_col = #'└── '
    local pos = vim.fn.screenpos(origin_win, 2, name_col + 1)
    local p = prompt.input({
        prompt = 'Anchor',
        cwd = cwd,
        anchor = {win = origin_win, line = 2, col = name_col},
        validate = function(input)
            return input
        end,
    }, function() end)
    ---@cast p DoraPrompt

    local cfg = vim.api.nvim_win_get_config(p.input_win)
    assert_eq(cfg.relative, 'editor')
    assert_eq(cfg.row, pos.row)
    assert_eq(cfg.col, pos.col - 1)

    p:cancel()
    vim.wo[origin_win].number = old_number
    vim.wo[origin_win].relativenumber = old_relativenumber
    vim.wo[origin_win].signcolumn = old_signcolumn
    vim.api.nvim_win_set_buf(origin_win, old_buf)
    vim.api.nvim_buf_delete(buf, {force = true})
end

do
    local p = prompt.input({
        prompt = 'Escape typed input',
        cwd = cwd,
        validate = function(input)
            return input
        end,
    }, function(input)
        vim.g.dora_smoke_escape_typed = input == nil
    end)
    ---@cast p DoraPrompt

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('ix<Esc>', true, false, true), 'xt', false)
    assert(vim.wait(1000, function()
        return p.closed
    end), 'escape after typed input should close the prompt by default')
    assert_eq(vim.g.dora_smoke_escape_typed, true,
        'closing a prompt on escape should cancel it')
end

do
    local p = prompt.input({
        prompt = 'Escape key empty',
        cwd = cwd,
        validate = function(input)
            return input
        end,
    }, function(input)
        vim.g.dora_smoke_escape_key_empty = input == nil
    end)
    ---@cast p DoraPrompt

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('i<Esc>', true, false, true), 'xt', false)
    assert(vim.wait(1000, function()
        return p.closed
    end), 'escape with empty input should close the prompt by default')
    assert_eq(vim.g.dora_smoke_escape_key_empty, true)
end

do
    local original = config.prompt_insert_esc_closes
    config.prompt_insert_esc_closes = false
    local p = prompt.input({
        prompt = 'Escape leaves insert mode',
        cwd = cwd,
        validate = function(input)
            return input
        end,
    }, function() end)
    ---@cast p DoraPrompt

    assert(next(vim.fn.maparg('<Esc>', 'i', false, true)) == nil,
        'disabling prompt_insert_esc_closes should leave insert-mode escape unmapped')

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('ix<Esc>', true, false, true), 'xt', false)
    assert(vim.wait(1000, function()
        return p:get_input() == 'x' and vim.api.nvim_get_mode().mode == 'n'
    end), 'escape should leave insert mode when prompt_insert_esc_closes is false')
    assert(not p.closed,
        'escape should keep the prompt open when prompt_insert_esc_closes is false')
    p:cancel()
    config.prompt_insert_esc_closes = original
end

do
    local callback_count = 0
    local event_buf
    local group = vim.api.nvim_create_augroup('dora-smoke-prompt-filetype', {clear = true})
    vim.api.nvim_create_autocmd('FileType', {
        group = group,
        pattern = 'dora-prompt',
        callback = function(args)
            event_buf = args.buf
            vim.keymap.set('i', '<Esc>', '<Cmd>close<CR>', {buffer = args.buf})
        end,
    })
    local p = prompt.input({
        prompt = 'Prompt filetype',
        cwd = cwd,
        validate = function(input)
            return input
        end,
    }, function(input)
        callback_count = callback_count + 1
        assert_eq(input, nil, 'closing a prompt window should cancel the prompt')
    end)
    ---@cast p DoraPrompt

    assert_eq(event_buf, p.input_buf, 'prompt FileType autocmd should receive the prompt buffer')
    assert_eq(vim.bo[p.input_buf].filetype, 'dora-prompt', 'prompt buffers should use the dora-prompt filetype')
    assert_eq(vim.fn.maparg('<Esc>', 'i', false, true).rhs, '<Cmd>close<CR>',
        'prompt FileType autocmds should be able to set buffer mappings')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('i<Esc>', true, false, true), 'xt', false)
    assert(vim.wait(1000, function()
        return p.closed == true
    end), 'a FileType mapping should be able to close the prompt')
    assert_eq(callback_count, 1, 'closing the prompt should invoke the callback once')
    vim.api.nvim_del_augroup_by_id(group)
end

do
    local p = prompt.input({
        prompt = 'Cancel',
        cwd = cwd,
        validate = function(input)
            return input
        end,
    }, function(input)
        vim.g.dora_smoke_cancelled = input == nil
    end)
    ---@cast p DoraPrompt

    p:cancel()
    assert_eq(vim.g.dora_smoke_cancelled, true)
end

assert_match(fs.validate_create('x-new-file', cwd), 'x%-new%-file$')
assert_match(fs.validate_create('x-new-dir/', cwd), 'x%-new%-dir/$')
assert_match(fs.validate_create('x-new-parent/x-new-file', cwd), 'x%-new%-parent/x%-new%-file$')
assert(not pcall(fs.validate_create, '/tmp/x', cwd), 'create paths should stay relative')
assert_match(fs.validate_rename('renamed.txt', cwd .. '/old.txt'), 'renamed%.txt$')
assert(not pcall(fs.validate_rename, '', cwd .. '/old.txt'), 'empty rename filenames should be rejected')
assert(not pcall(fs.validate_rename, 'nested/renamed.txt', cwd .. '/old.txt'), 'rename should reject directory separators')
assert(not pcall(fs.validate_rename, 'old.txt', cwd .. '/old.txt'), 'rename should reject unchanged filenames')
assert_match(fs.resolve_copy_or_move_dest(cwd, '/tmp', cwd), '/tmp/[^/]+$')
assert_eq(fs.normalize_path('./foo/../bar', cwd), vim.fs.joinpath(cwd, 'bar'),
    'normalize_path should resolve relative dot components')
assert_eq(fs.parent_dir('/'), '/', 'parent_dir should not go above root')
assert_eq(fs.parent_dir('/tmp'), '/', 'parent_dir should keep root for top-level paths')
assert_eq(fs.get_parent_dir('/tmp'), '/', 'get_parent_dir should allow top-level paths')
assert_eq(fs.parent_dir('/tmp/foo/'), '/tmp', 'parent_dir should ignore a trailing separator')
assert_eq(fs.basename('/tmp/foo/'), 'foo', 'basename should ignore a trailing separator')
assert_eq(fs.strip_trailing_sep('/tmp/foo/'), '/tmp/foo', 'strip_trailing_sep should trim one or more trailing separators')

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))

    fs.create_file(tmp .. '/foo/bar.txt')
    assert(fs.exists(tmp .. '/foo/bar.txt'), 'create_file should create missing parent directories')
    assert(fs.is_dir(tmp .. '/foo'), 'create_file should create the parent directory')

    fs.create_dir(tmp .. '/alpha/beta/')
    assert(fs.is_dir(tmp .. '/alpha/beta'), 'create_dir should create missing parent directories')

    touch(tmp .. '/blocked')
    assert(not pcall(fs.validate_create, 'blocked/child.txt', tmp), 'create should reject paths below files')

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/target', tonumber('755', 8)))
    touch(tmp .. '/target/file.txt')
    assert(vim.loop.fs_symlink(tmp .. '/target', tmp .. '/link'))

    fs.delete(tmp .. '/link')
    assert(fs.is_dir(tmp .. '/target'), 'delete should not follow directory symlinks')
    assert(not fs.exists(tmp .. '/link'), 'delete should remove directory symlinks')

    fs.delete(tmp .. '/target')
    assert(not fs.exists(tmp .. '/target'), 'delete should recursively remove directories')
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
    local trash_dir
    if vim.loop.os_uname().sysname == 'Darwin' then
        trash_dir = tmp .. '/home/.Trash'
    else
        trash_dir = tmp .. '/data/Trash/files'
    end
    assert(vim.fn.mkdir(trash_dir, 'p') == 1)
    touch(tmp .. '/foo')
    touch(trash_dir .. '/foo')
    assert(vim.loop.fs_mkdir(trash_dir .. '/bar', tonumber('755', 8)))
    touch(tmp .. '/bar')

    fs.trash(tmp .. '/foo')
    fs.trash(tmp .. '/bar')
    assert(not fs.exists(tmp .. '/foo'), 'trash should remove source files')
    assert(not fs.exists(tmp .. '/bar'), 'trash should remove source files when destination name collides with a directory')
    assert(fs.exists(trash_dir .. '/foo'), 'trash should preserve existing trash entries')
    assert(fs.exists(trash_dir .. '/foo(1)'), 'trash should suffix colliding file names')
    assert(fs.exists(trash_dir .. '/bar'), 'trash should preserve existing trash directories')
    assert(fs.exists(trash_dir .. '/bar(1)'), 'trash should suffix colliding directory names')

    vim.env.HOME = old_home
    vim.env.XDG_DATA_HOME = old_data_home
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/nvim-dora', tonumber('755', 8)))
    touch(tmp .. '/nvim-dora/existing.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_line('nvim%-dora/$')
    api.expand()
    set_cursor_line('existing%.txt$')
    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.width, 32, 'create prompt should match the default delete window width')
        local path = opts.validate('foo/bar/a')
        cb('foo/bar/a', path)
    end
    api.add()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/foo/bar/a'), 'create should create a nested file path')
    assert(vim.tbl_contains(lines(), 'foo/'), 'create should render the new top-level parent')
    assert(vim.tbl_contains(lines(), '└── bar/'), 'create should expand the parents above the new file')
    assert(vim.tbl_contains(lines(), '    └── a'), 'create should reveal the created nested file')
    assert_match(current_line(), 'a$', 'create should move cursor to the created nested file')
    local row = store.get().rows[vim.api.nvim_win_get_cursor(0)[1]]
    assert_eq(row.path, fs.realpath(tmp) .. '/foo/bar/a')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/nvim-dora', tonumber('755', 8)))
    touch(tmp .. '/nvim-dora/existing.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_line('nvim%-dora/$')
    api.expand()
    set_cursor_line('existing%.txt$')
    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, 'nvim-dora/', 'create should prefill the hovered file parent path')
        local input = opts.initial_prompt .. 'foo/bar'
        cb(input, opts.validate(input))
    end
    api.add()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/nvim-dora/foo/bar'), 'create should create nested paths inside expanded directories')
    assert(vim.tbl_contains(lines(), '│   └── bar'), 'create should expand the parent under expanded directories')
    assert_match(current_line(), 'bar$', 'create should move cursor to the created nested file')
    local row = store.get().rows[vim.api.nvim_win_get_cursor(0)[1]]
    assert_eq(row.path, fs.realpath(tmp) .. '/nvim-dora/foo/bar')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

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
    api.expand()
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
    api.expand_recursive()
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
    api.expand()
    set_cursor_pos('beta')
    api.expand()

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
    assert(vim.loop.fs_mkdir(tmp .. '/root', tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    assert_eq(vim.fn.maparg('a', 'n', false, true).desc, 'Add file under directory')
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
    api.expand()
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
    api.expand()
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
    api.expand()
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
    -- api.expand()/api.collapse() directly; those read vim.v.count1 and would
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
    assert_eq(vim.fn.maparg('gp', 'n', false, true).desc, 'Go to parent directory')
    assert_eq(vim.fn.maparg('gp', 'x', false, true).desc, 'Go to parent directory')
    assert_eq(vim.fn.maparg('P', 'n', false, true).desc, 'Paste')
    set_cursor_pos('alpha')
    api.expand()
    set_cursor_pos('one')
    api.expand()

    set_cursor_line('file%.txt$')
    api.parent_dir()
    assert_match(current_line(), 'one/$', 'parent jump should move from a nested file to its parent directory')
    assert(state.expanded_dirs[root .. '/alpha/one'], 'parent jump should not collapse the parent directory')
    assert(find_line_index(lines(), 'file%.txt$'), 'parent jump should keep the parent directory children visible')

    api.parent_dir()
    assert_match(current_line(), 'alpha/$', 'parent jump should move from a nested directory to its parent directory')
    assert(state.expanded_dirs[root .. '/alpha'], 'parent jump should not collapse visited parent directories')

    set_cursor_pos('two')
    api.expand()
    set_cursor_line('deep%.txt$')
    vim.api.nvim_feedkeys('3gp', 'xt', false)
    assert_match(current_line(), 'alpha/$', 'counted parent jump should move up the requested number of parents')

    set_cursor_line('file%.txt$')
    vim.api.nvim_feedkeys('Vgp', 'xt', false)
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
    set_cursor_pos('alpha')
    api.expand()
    set_cursor_pos('one')
    api.expand()

    set_cursor_line('^alpha/$')
    api.close_dir()
    assert_match(current_line(), 'alpha/$', 'close should keep the cursor on the closed directory')
    assert(not state.expanded_dirs[root .. '/alpha'], 'close should collapse the hovered directory')
    assert(state.expanded_dirs[root .. '/alpha/one'], 'close should not touch expanded subdirectories')
    assert(not find_line_index(lines(), 'one/$'), 'close should hide the directory children')

    api.expand()
    assert(find_line_index(lines(), 'file%.txt$'), 're-expanding a closed directory should restore its expanded subtree')

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
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/file.lua')

    local old_icons = config.icons
    local old_devicons = package.loaded['nvim-web-devicons']
    config.icons = 'nvim-web-devicons'
    package.loaded['nvim-web-devicons'] = {
        get_icon = function(name, ext, opts)
            assert_eq(name, 'file.lua')
            assert_eq(ext, 'lua')
            assert_eq(opts.default, true)
            return '[lua]', 'DoraIcon'
        end,
    }

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    assert(vim.tbl_contains(lines(), '[lua] file.lua'), 'icons should render before filenames')
    assert_eq(state.rows[1].name_start_col, #'[lua] ', 'icon rows should keep name column after the icon')
    assert(has_high_priority_highlight(state, 'DoraIcon'), 'icons should use the provider highlight')

    api.quit()
    config.icons = old_icons
    package.loaded['nvim-web-devicons'] = old_devicons
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
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
    api.expand()
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
    touch(tmp .. '/trashed.txt')
    local old_trash = fs.trash
    ---@diagnostic disable-next-line: duplicate-set-field
    fs.trash = function(path)
        vim.g.dora_smoke_trashed_path = path
        assert_eq(vim.fn.delete(path), 0)
    end

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_pos('trashed.txt')
    api.trash()

    local confirm_win = vim.api.nvim_get_current_win()
    assert_match(win_title(confirm_win), 'Trash%?')
    vim.api.nvim_feedkeys('y', 'xt', false)

    assert_eq(vim.g.dora_smoke_trashed_path, state.cwd .. '/trashed.txt')
    assert(not fs.exists(tmp .. '/trashed.txt'), 'trash should remove the file from the listing source')

    api.quit()
    fs.trash = old_trash
    vim.g.dora_smoke_trashed_path = nil
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/deleted.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('deleted.txt')
    api.delete()

    local confirm_win = vim.api.nvim_get_current_win()
    assert_match(win_title(confirm_win), 'Delete%?')
    vim.api.nvim_feedkeys('y', 'xt', false)

    assert(not fs.exists(tmp .. '/deleted.txt'), 'delete should permanently remove the file')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')
    touch(tmp .. '/c')
    local trashed_paths = {}
    local old_trash = fs.trash
    ---@diagnostic disable-next-line: duplicate-set-field
    fs.trash = function(path)
        trashed_paths[#trashed_paths+1] = path
        assert_eq(vim.fn.delete(path), 0)
    end

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

    assert_eq(#trashed_paths, 2, 'visual trash should trash each selected file')
    assert_eq(trashed_paths[1], state.cwd .. '/a')
    assert_eq(trashed_paths[2], state.cwd .. '/b')
    assert(not fs.exists(tmp .. '/a'), 'visual trash should remove selected file a')
    assert(not fs.exists(tmp .. '/b'), 'visual trash should remove selected file b')
    assert(fs.exists(tmp .. '/c'), 'visual trash should leave unselected files')

    api.quit()
    fs.trash = old_trash
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

    -- Mark non-adjacent rows with a mix of cut and copy.
    set_cursor_line('bravo%.txt$')
    api.toggle_cut()
    set_cursor_line('delta%.txt$')
    api.toggle_copy()
    set_cursor_line('echo%.txt$')
    api.toggle_copy()
    assert_eq(marked_path_count(state), 3)

    set_cursor_line('alpha%.txt$')
    api.next_mark()
    assert_match(current_line(), 'bravo%.txt$', 'next mark should jump to the first paste mark below the cursor')
    api.next_mark()
    assert_match(current_line(), 'delta%.txt$', 'next mark should skip unmarked rows to the following mark')
    api.next_mark()
    assert_match(current_line(), 'echo%.txt$', 'next mark should jump to copy marks as well as cut marks')
    api.next_mark()
    assert_match(current_line(), 'echo%.txt$', 'next mark should stay put when no further mark exists')

    api.prev_mark()
    assert_match(current_line(), 'delta%.txt$', 'previous mark should jump to the closest mark above the cursor')

    set_cursor_line('alpha%.txt$')
    vim.api.nvim_feedkeys('2]m', 'xt', false)
    assert_match(current_line(), 'delta%.txt$', 'counted next mark should skip the requested number of marks')

    set_cursor_line('echo%.txt$')
    vim.api.nvim_feedkeys('2[m', 'xt', false)
    assert_match(current_line(), 'bravo%.txt$', 'counted previous mark should skip the requested number of marks')

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
    api.expand()
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
    api.expand()
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
    api.expand()
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
    local hint_str = 'k keep · o overwrite'
    assert_eq(confirm_lines[1], centered('1 conflict'),
        'a centered conflict count should head the confirmation')
    assert_eq(confirm_lines[2], centered(hint_str),
        'a centered both-keys hint should sit below the count')
    assert_eq(confirm_lines[3], string.rep('─', confirm_width),
        'a full-width divider should separate the header from the list')
    assert_eq(confirm_lines[4], 'alpha.txt → alpha(1).txt (keep)',
        'a conflict row should preview the kept-both name and tag its fate')
    assert_eq(confirm_lines[5], '↓', 'paste confirmation should show a down-arrow separator')
    assert_eq(confirm_lines[6], 'dest/', 'paste confirmation should show the target path relative to the root')
    assert_eq(confirm_cfg.row, cursor_pos.row,
        'paste confirmation should anchor below the cursorline')

    -- The count and each row's fate are colored; the hint spotlights both
    -- mnemonic keys, mutes the middot, and bolds the active mode's segment (keep,
    -- by default); the previewed name keeps its file-type color while the arrow
    -- reads in the normal color (not muted).
    local warn_pad, hint_pad = pad_for('1 conflict'), pad_for(hint_str)
    local key_k, key_o = hint_pad, hint_pad + #'k keep · '
    local middot_col = hint_pad + #'k keep '
    local warn, hint_keys, hint_middot, keep_bold, divider_muted, suffix_warn, arrow_muted, preview_name =
        false, 0, false, false, false, false, false, false
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
            and (col == key_o or col == key_k) then
            hint_keys = hint_keys + 1
        end
        if row == 1 and col == middot_col and details.hl_group == 'DoraMutedText' then
            hint_middot = true
        end
        if row == 1 and col == key_k and details.end_col == hint_pad + #'k keep'
            and details.hl_group == 'DoraBold' then
            keep_bold = true
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
    assert(hint_middot, 'the hint middot should be muted')
    assert(keep_bold, 'keep-both mode should bold the keep segment')
    assert(divider_muted, 'the header divider should be muted')
    assert(suffix_warn, 'each conflict row should tag its fate in the warning color')
    assert(not arrow_muted, 'the rename preview arrow should read in the normal color')
    assert(preview_name, 'the rename preview name should match the marked file color (copy)')

    -- `o` switches to overwrite mode in place: the border keeps warning, the
    -- rename preview collapses to the conflicting name (still tagged), the static
    -- hint is unchanged, and bold moves to the overwrite segment.
    vim.api.nvim_feedkeys('o', 'xt', false)
    assert_match(vim.wo[confirm_win].winhighlight, 'FloatBorder:DoraPromptBorderWarn',
        'overwrite mode should keep the warning border')
    local overwrite_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert_eq(overwrite_lines[1], centered('1 conflict'),
        'overwrite mode should keep the centered conflict count')
    assert_eq(overwrite_lines[2], centered(hint_str),
        'the both-keys hint should not change with the mode')
    assert_eq(overwrite_lines[4], 'alpha.txt (overwrite)',
        'overwrite mode should drop the preview and tag the row as overwritten')
    local overwrite_bold = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {details = true})) do
        local row, col, details = mark[2], mark[3], mark[4]
        ---@cast details -nil
        if row == 1 and col == key_o and details.end_col == hint_pad + #hint_str
            and details.hl_group == 'DoraBold' then
            overwrite_bold = true
        end
    end
    assert(overwrite_bold, 'overwrite mode should bold the overwrite segment')
    vim.api.nvim_feedkeys('k', 'xt', false)
    assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[4], 'alpha.txt → alpha(1).txt (keep)',
        'k should switch back to keep-both mode')

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
    -- A leading space keeps the error off the left border; RIGHT_PADDING balances
    -- the right, so the centered line carries one space on each side.
    local error_text = ' Cannot paste a directory into itself'
    local error_pad = math.max(0, math.floor((confirm_width - #error_text) / 2))
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
        '.luarc(1).json → .luarc(2).json (keep)',
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
        '.luarc(1).json → .luarc(3).json (keep)',
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
    assert_eq(confirm_lines[4], 'AGENTS(1).md → AGENTS(3).md (keep)',
        'the first conflict should preview the first free suffix')
    assert_eq(confirm_lines[5], 'AGENTS(2).md → AGENTS(4).md (keep)',
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

    assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[4], 'foo/ → foo(1)/ (keep)',
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
    api.expand()
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

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir/child', tonumber('755', 8)))
    touch(tmp .. '/dir/child/file.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_pos('dir')
    api.expand()
    set_cursor_line('child/$')
    api.expand()
    set_cursor_pos('dir')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, 'dir', 'rename should not append a slash for directories')
        cb('renamed', opts.validate('renamed'))
    end
    api.rename()
    prompt.input = old_input

    assert(not fs.exists(tmp .. '/dir'), 'rename should remove the old directory')
    assert(fs.exists(tmp .. '/renamed/child/file.txt'), 'rename should move the directory subtree')
    assert(state.expanded_dirs[state.cwd .. '/renamed'], 'rename should preserve expanded directory state')
    assert(state.expanded_dirs[state.cwd .. '/renamed/child'], 'rename should preserve expanded descendant state')
    assert(find_line_index(lines(), 'file%.txt$'), 'rename should render preserved expanded descendants')
    assert_match(current_line(), 'renamed/$', 'rename should move cursor to the renamed directory')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/targets', tonumber('755', 8)))
    touch(tmp .. '/targets/file.txt')
    local real_tmp = fs.realpath(tmp)
    assert(vim.loop.fs_symlink(real_tmp .. '/targets/file.txt', tmp .. '/absolute-link'))
    assert(vim.loop.fs_symlink('./targets/file.txt', tmp .. '/relative-link'))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local marks = vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    local has_absolute_link = false ---@type boolean?
    local has_relative_link = false ---@type boolean?
    for _, mark in ipairs(marks) do
        local details = mark[4]
        ---@cast details -nil  -- always present with {details = true}
        local virt_text = details.virt_text
        has_absolute_link = has_absolute_link
            or virt_text and virt_text[1] and virt_text[1][1] == '@ → targets/file.txt'
                and details.hl_mode == 'combine'
        has_relative_link = has_relative_link
            or virt_text and virt_text[1] and virt_text[1][1] == '@ → ./targets/file.txt'
    end
    assert(has_absolute_link, 'absolute symlink targets should render relative to the symlink')
    assert(has_relative_link, 'relative symlink targets should remain unchanged')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/target-dir', tonumber('755', 8)))
    touch(tmp .. '/target-dir/inside.txt')
    assert(vim.loop.fs_symlink(tmp .. '/target-dir', tmp .. '/dir-link'))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    assert_eq(vim.fn.maparg('gf', 'n'), '', 'gf should remain available for users')

    set_cursor_line('dir%-link$')
    api.open()
    assert_eq(state.cwd, fs.realpath(tmp .. '/target-dir'), 'open should navigate to symlinked directories')
    assert(vim.tbl_contains(lines(), 'inside.txt'), 'open should render symlinked directory contents')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/target.txt')
    assert(vim.loop.fs_symlink(tmp .. '/target.txt', tmp .. '/file-link'))
    local swap_dir = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(swap_dir, tonumber('755', 8)))
    local old_directory = vim.o.directory
    vim.o.directory = fs.realpath(swap_dir) .. '//'

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local dora_buf = vim.api.nvim_get_current_buf()
    set_cursor_line('file%-link$')
    api.open()
    assert_eq(vim.api.nvim_buf_get_name(0), fs.realpath(tmp .. '/target.txt'), 'open should edit symlinked files')
    assert_eq(vim.fn.bufexists(dora_buf), 0, 'opening a symlinked file should close Dora')

    vim.cmd('bdelete!')
    vim.o.directory = old_directory
    assert_eq(vim.fn.delete(swap_dir, 'rf'), 0)
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    touch(tmp .. '/dir/child.txt')
    touch(tmp .. '/a.txt')
    touch(tmp .. '/b.txt')
    local root = fs.realpath(tmp)

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local dora_buf = state.buf
    set_cursor_line('^dir/$')
    api.expand()
    set_cursor_line('^dir/$')
    for lhs, desc in pairs({
        l = 'Open',
        s = 'Open in split',
        v = 'Open in vertical split',
        t = 'Open in tab',
        ['<C-s>'] = 'Open in split (stay)',
        ['<C-v>'] = 'Open in vertical split (stay)',
        ['<C-t>'] = 'Open in tab (stay)',
    }) do
        assert_eq(vim.fn.maparg(lhs, 'x', false, true).desc, desc)
    end
    vim.api.nvim_feedkeys('V3jl', 'xt', false)

    assert_eq(vim.api.nvim_get_mode().mode, 'n', 'visual open should return to normal mode')
    assert_eq(vim.api.nvim_buf_get_name(0), root .. '/b.txt',
        'visual open should leave the last selected file current')
    assert(vim.fn.bufexists(root .. '/dir/child.txt') ~= 0,
        'visual open should load nested selected files')
    assert(vim.fn.bufexists(root .. '/a.txt') ~= 0,
        'visual open should load every selected file')
    assert_eq(vim.fn.bufexists(root .. '/dir'), 0,
        'visual open should ignore selected directories')
    assert_eq(vim.fn.bufexists(dora_buf), 0, 'visual open should close Dora')

    for _, path in ipairs({'dir/child.txt', 'a.txt', 'b.txt'}) do
        pcall(vim.cmd --[[@as function]], 'bdelete! ' .. vim.fn.fnameescape(root .. '/' .. path))
    end
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

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
    api.expand()
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
    api.collapse_recursive()
    assert_eq(reopened_state.expanded_dirs[root .. '/other'], nil)
    api.quit()

    vim.cmd('Dora ' .. vim.fn.fnameescape(root))
    assert_eq(store.get().expanded_dirs[root .. '/other'], nil,
        'collapsed directories should remain collapsed after reopening Dora')
    set_cursor_line('^other/$')
    api.expand()
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
    api.expand()
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

do
    local origin_win = vim.api.nvim_get_current_win()
    local buf, win = keymaps.open_hint_window('z', {
        {lhs='za', desc='Alpha'},
        {lhs='zx', desc='Xray'},
    })
    assert_eq(vim.api.nvim_get_current_win(), origin_win, 'keymap hints should not take focus')
    local cfg = vim.api.nvim_win_get_config(win)
    assert_eq(cfg.focusable, false, 'keymap hints should be non-focusable')
    assert_eq(cfg.relative, 'win', 'keymap hints should be relative to the current window')
    assert_eq(cfg.win, origin_win, 'keymap hints should anchor to the current window')
    assert_eq(cfg.anchor, 'SE', 'keymap hints should anchor to the bottom right')
    assert_eq(cfg.row, vim.api.nvim_win_get_height(origin_win) - 1, 'keymap hints should sit near the bottom')
    assert_eq(cfg.col, vim.api.nvim_win_get_width(origin_win) - 2, 'keymap hints should sit near the right edge')
    assert_eq(cfg.border[1], '╭', 'keymap hints should have a border')
    assert_match(vim.wo[win].winhighlight, 'FloatBorder:DoraPromptBorder')
    assert_eq(cfg.title, nil, 'keymap hints should not have a title')
    local hint_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local hint_text = table.concat(hint_lines, '\n')
    assert(hint_text:match('za%s+→%s+Alpha'), 'keymap hints should include the first custom mapping')
    assert(hint_text:match('zx%s+→%s+Xray'), 'keymap hints should include the second custom mapping')

    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {details=true})
    local has_key, has_arrow, has_desc = false, false, false
    for _, mark in ipairs(marks) do
        local hl = mark[4].hl_group
        has_key = has_key or hl == 'DoraInfoLabel'
        has_arrow = has_arrow or hl == 'DoraMutedText'
        has_desc = has_desc or hl == 'DoraInfoValue'
    end
    assert(has_key, 'keymap hints should highlight keys')
    assert(has_arrow, 'keymap hints should highlight arrows')
    assert(has_desc, 'keymap hints should highlight descriptions')
    window.close(buf, win)
end

do
    local buf, win = keymaps.open_hint_window(',', {
        {lhs=',n', key='n', desc='Sort by name'},
        {lhs=',s', key='s', desc='Sort by size'},
        {lhs=',x', key='x', desc='Open externally'},
        {lhs=',q', key='q', desc='Sort by name'},
        {lhs=',.', key='.', desc='Toggle hidden files'},
    })
    local hint_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local mnemonics = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {details=true})) do
        if mark[4].hl_group == 'DoraKeymapHintMnemonic' then
            local line = hint_lines[mark[2] + 1]
            mnemonics[#mnemonics+1] = line:sub(mark[3] + 1, mark[4].end_col)
        end
    end
    table.sort(mnemonics)
    assert_eq(#mnemonics, 3, 'hints without a matching word or an alphabetic key should not highlight a mnemonic')
    assert_eq(mnemonics[1], 'externally', 'mnemonics should fall back to a word containing the key')
    assert_eq(mnemonics[2], 'name', 'mnemonics should highlight the word starting with the key')
    assert_eq(mnemonics[3], 'size', 'mnemonics should prefer the last word starting with the key')
    window.close(buf, win)
end

do
    local buf, win = keymaps.open_hint_window('y', {
        {lhs='yF', desc='Yank filename to clipboard'},
        {lhs='yf', desc='Yank filename'},
        {lhs='yN', desc='Yank name without extension to clipboard'},
        {lhs='yn', desc='Yank name without extension'},
        {lhs='yY', desc='Yank full path to clipboard'},
        {lhs='yy', desc='Yank full path'},
        {lhs='yD', desc='Yank parent directory to clipboard'},
        {lhs='yd', desc='Yank parent directory'},
    })
    local hint_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert_match(hint_lines[1], '^  yf%s+→%s+Yank filename%s+yF%s+→%s+Yank filename to clipboard$')
    assert_match(hint_lines[2], '^  yy%s+→%s+Yank full path%s+yY%s+→%s+Yank full path to clipboard$')
    assert_match(hint_lines[3], '^  yd%s+→%s+Yank parent directory%s+yD%s+→%s+Yank parent directory to clipboard$')
    assert_match(hint_lines[4], '^  yn%s+→%s+Yank name without extension%s+yN%s+→%s+Yank name without extension to clipboard$')
    window.close(buf, win)
end

do
    local old_keymaps = config.keymaps
    local old_show_keymap_hints = config.show_keymap_hints
    local old_open = keymaps.open_hint_window
    local captured_prefix
    local captured_rows

    config.keymaps = {
        za = {"<Cmd>lua vim.g.dora_smoke_hint_keymap = 'za'<CR>", desc='Alpha'},
        zx = {function() vim.g.dora_smoke_hint_keymap = 'zx' end, desc='Xray'},
    }
    config.show_keymap_hints = true
    ---@diagnostic disable-next-line: duplicate-set-field
    keymaps.open_hint_window = function(prefix, rows)
        captured_prefix = prefix
        captured_rows = rows
        return old_open(prefix, rows)
    end
    vim.g.dora_smoke_hint_keymap = nil

    vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
    local prefix_map = vim.fn.maparg('z', 'n', false, true)
    assert_eq(prefix_map.desc, 'Show keymap hints')
    assert_eq(type(prefix_map.callback), 'function')
    assert_eq(vim.fn.maparg('za', 'n', false, true).desc, 'Alpha')
    assert_eq(vim.fn.maparg('zx', 'n', false, true).desc, 'Xray')
    vim.api.nvim_feedkeys('a', 't', false)
    prefix_map.callback()
    assert_eq(vim.g.dora_smoke_hint_keymap, 'za', 'keymap hints should dispatch legacy string actions')
    assert_eq(captured_prefix, nil, 'fast keymap sequences should not open the hint window')

    vim.g.dora_smoke_hint_keymap = nil
    vim.defer_fn(function()
        vim.api.nvim_feedkeys('x', 't', false)
    end, 250)
    prefix_map.callback()
    assert_eq(vim.g.dora_smoke_hint_keymap, 'zx', 'delayed keymap sequences should still dispatch')
    assert_eq(captured_prefix, 'z')
    assert_eq(#captured_rows, 2)
    assert_eq(captured_rows[1].lhs, 'za')
    assert_eq(captured_rows[1].desc, 'Alpha')
    assert_eq(captured_rows[2].lhs, 'zx')
    assert_eq(captured_rows[2].desc, 'Xray')
    api.quit()

    keymaps.open_hint_window = old_open
    config.keymaps = old_keymaps
    config.show_keymap_hints = old_show_keymap_hints
end

do
    local old_keymaps = config.keymaps
    local old_show_keymap_hints = config.show_keymap_hints
    local old_open = keymaps.open_hint_window
    local old_reload = api.reload

    config.keymaps = {
        za = 'reload',
    }
    config.show_keymap_hints = true
    local captured_rows
    ---@diagnostic disable-next-line: duplicate-set-field
    api.reload = function()
        vim.g.dora_smoke_named_keymap = 'reload'
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    keymaps.open_hint_window = function(prefix, rows)
        captured_rows = rows
        return old_open(prefix, rows)
    end
    vim.g.dora_smoke_named_keymap = nil

    vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
    local prefix_map = vim.fn.maparg('z', 'n', false, true)
    assert_eq(vim.fn.maparg('za', 'n', false, true).desc, 'Reload listing',
        'named actions should inherit mapping descriptions')
    vim.defer_fn(function()
        vim.api.nvim_feedkeys('a', 't', false)
    end, 250)
    prefix_map.callback()
    assert_eq(vim.g.dora_smoke_named_keymap, 'reload', 'keymap hints should dispatch named api actions')
    assert_eq(captured_rows[1].desc, 'Reload listing',
        'named actions should inherit keymap hint descriptions')
    api.quit()

    keymaps.open_hint_window = old_open
    api.reload = old_reload
    config.keymaps = old_keymaps
    config.show_keymap_hints = old_show_keymap_hints
end

do
    local old_keymaps = config.keymaps
    local old_show_keymap_hints = config.show_keymap_hints
    local old_reload = api.reload

    config.keymaps = {
        x = {'reload', desc='Custom reload'},
    }
    config.show_keymap_hints = false
    ---@diagnostic disable-next-line: duplicate-set-field
    api.reload = function()
        vim.g.dora_smoke_named_direct_keymap = 'reload'
    end
    vim.g.dora_smoke_named_direct_keymap = nil

    vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
    local map = vim.fn.maparg('x', 'n', false, true)
    assert_eq(map.desc, 'Custom reload', 'explicit descriptions should override action descriptions')
    assert_eq(type(map.callback), 'function')
    map.callback()
    assert_eq(vim.g.dora_smoke_named_direct_keymap, 'reload', 'direct keymaps should dispatch named api actions')
    api.quit()

    api.reload = old_reload
    config.keymaps = old_keymaps
    config.show_keymap_hints = old_show_keymap_hints
end

do
    local old_keymaps = config.keymaps
    local old_show_keymap_hints = config.show_keymap_hints

    config.keymaps = {
        za = {function() vim.g.dora_smoke_hint_keymap = 'za' end, desc='Alpha'},
        zx = {function() vim.g.dora_smoke_hint_keymap = 'zx' end, desc='Xray'},
    }
    config.show_keymap_hints = false

    vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
    assert_eq(vim.fn.maparg('z', 'n'), '', 'disabled keymap hints should not install prefix mappings')
    assert_eq(vim.fn.maparg('za', 'n', false, true).desc, 'Alpha')
    assert_eq(vim.fn.maparg('zx', 'n', false, true).desc, 'Xray')
    api.quit()

    config.keymaps = old_keymaps
    config.show_keymap_hints = old_show_keymap_hints
end

do
    local old_keymaps = config.keymaps
    local old_show_keymap_hints = config.show_keymap_hints

    config.keymaps = {
        x = {function() vim.g.dora_smoke_hint_keymap = 'x' end, desc='Plain X'},
        xy = {function() vim.g.dora_smoke_hint_keymap = 'xy' end, desc='X Y'},
    }
    config.show_keymap_hints = true

    vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
    assert_eq(vim.fn.maparg('x', 'n', false, true).desc, 'Plain X')
    assert_eq(vim.fn.maparg('xy', 'n', false, true).desc, 'X Y')
    api.quit()

    config.keymaps = old_keymaps
    config.show_keymap_hints = old_show_keymap_hints
end

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
    local state = store.get()
    assert_eq(state.sort_order, 'name')
    assert_line_before('^dir2/$', '^dir10/$', 'natural sort should order directory names naturally')
    assert_line_before('^dir10/$', '^alpha%.md$', 'directories should stay grouped before files')
    assert_line_before('^file2%.txt$', '^file10%.txt$', 'natural sort should order file names naturally')

    api.sort_by('name_desc')
    assert_eq(state.sort_order, 'name_desc')
    assert_line_before('^dir10/$', '^dir2/$', 'reversed natural sort should reverse directory names')
    assert_line_before('^dir2/$', '^tiny%.bin$', 'reversed natural sort should keep directories before files')
    assert_line_before('^file10%.txt$', '^file2%.txt$', 'reversed natural sort should reverse file names')

    api.sort_by('size')
    assert_eq(state.sort_order, 'size')
    assert_line_before('^dir10/$', '^tiny%.bin$', 'size sort should keep directories before files')
    assert_line_before('^tiny%.bin$', '^alpha%.md$', 'size sort should order files by size')
    assert_line_before('^file2%.txt$', '^file10%.txt$', 'size sort should order larger files later')

    api.sort_by('size_desc')
    assert_eq(state.sort_order, 'size_desc')
    assert_line_before('^dir10/$', '^big%.log$', 'reversed size sort should keep directories before files')
    assert_line_before('^big%.log$', '^file10%.txt$', 'reversed size sort should order larger files first')
    assert_line_before('^file10%.txt$', '^file2%.txt$', 'reversed size sort should order smaller files later')

    api.sort_by('extension')
    assert_eq(state.sort_order, 'extension')
    assert_line_before('^tiny%.bin$', '^big%.log$', 'extension sort should order by extension')
    assert_line_before('^big%.log$', '^alpha%.md$', 'extension sort should order by extension')
    assert_line_before('^alpha%.md$', '^file2%.txt$', 'extension sort should order by extension')

    api.sort_by('extension_desc')
    assert_eq(state.sort_order, 'extension_desc')
    assert_line_before('^file2%.txt$', '^alpha%.md$', 'reversed extension sort should order by extension descending')
    assert_line_before('^alpha%.md$', '^big%.log$', 'reversed extension sort should order by extension descending')
    assert_line_before('^big%.log$', '^tiny%.bin$', 'reversed extension sort should order by extension descending')

    api.sort_by('modified')
    assert_eq(state.sort_order, 'modified')
    assert_line_before('^tiny%.bin$', '^file10%.txt$', 'modified sort should order older files first')
    assert_line_before('^file2%.txt$', '^big%.log$', 'modified sort should order newer files later')

    api.sort_by('modified_desc')
    assert_eq(state.sort_order, 'modified_desc')
    assert_line_before('^big%.log$', '^file2%.txt$', 'reversed modified sort should order newer files first')
    assert_line_before('^file10%.txt$', '^tiny%.bin$', 'reversed modified sort should order older files later')

    api.sort_by('created')
    assert_eq(state.sort_order, 'created')
    api.sort_by('created_desc')
    assert_eq(state.sort_order, 'created_desc')

    local prefix_map = vim.fn.maparg(',', 'n', false, true)
    vim.api.nvim_feedkeys('s', 't', false)
    prefix_map.callback()
    assert_eq(state.sort_order, 'size', 'sort keymaps should work behind the comma prefix mapping')

    vim.api.nvim_feedkeys('S', 't', false)
    prefix_map.callback()
    assert_eq(state.sort_order, 'size_desc', 'descending sort keymaps should dispatch renamed actions')

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
    api.expand()
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
    assert_eq(yank_filename_map.desc, 'Yank filename')
    assert_eq(type(yank_filename_map.callback), 'function')
    assert_eq(vim.fn.maparg('yn', 'n', false, true).desc, 'Yank name without extension')
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

    api.yank_file_path()
    assert_eq(vim.fn.getreg('"'), expected_path)
    assert_eq(notifications[#notifications].msg, 'dora: Yanked file path: ' .. expected_path)
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)
    assert_eq(vim.g.dora_smoke_yankpost_operator, 'y')
    assert_eq(vim.g.dora_smoke_yankpost_regname, '')
    assert_eq(vim.g.dora_smoke_yankpost_text, expected_yank_text)

    vim.g.dora_smoke_yankpost_operator = nil
    vim.g.dora_smoke_yankpost_regname = nil
    vim.g.dora_smoke_yankpost_text = nil
    api.yank_file_path_clipboard()
    assert_eq(vim.fn.getreg('+'), expected_path)
    assert_eq(notifications[#notifications].msg, 'dora: Yanked file path to clipboard: ' .. expected_path)
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

    api.yank_name()
    assert_eq(vim.fn.getreg('"'), 'archive.tar')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked name without extension: archive.tar')
    assert_eq(vim.g.dora_smoke_yankpost_text, 'archive.tar')
    start_col, end_col = yank_highlight_range()
    assert_eq(start_col, filename_col, 'name yank should start at the filename')
    assert_eq(end_col, filename_col + #'archive.tar', 'name yank should exclude the final extension')

    api.yank_name_clipboard()
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
    api.expand()
    set_cursor_line('^dir/$')
    assert_eq(vim.fn.maparg('gx', 'x', false, true).desc, 'Open externally')
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
    assert_eq(info_cfg.col, anchor_pos.col - 1, 'info should align with the selected name')
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
    assert(find_line_index(help_lines, "^%s+''%s+%S+%s+Jump to previous directory$"),
        "help should always include the builtin previous-directory bookmark")
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
    local ok, err = pcall(vim.cmd, 'Dora')
    assert(ok, 'running :Dora from a dora://help buffer should not error: ' .. tostring(err))
    assert_eq(store.get().cwd, fs.normalize_sep(assert(vim.loop.cwd())),
        ':Dora from a non-filesystem buffer should open at the cwd')
    api.quit()
end

do
    local old_keymaps = config.keymaps
    config.keymaps = {
        n = "yank_file_path",
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
    api.expand()
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
    assert_eq(vim.fn.maparg('>', 'x', false, true).desc, 'Last sibling')
    assert_eq(type(vim.fn.maparg('>', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('<', 'x', false, true).desc, 'First sibling')
    assert_eq(type(vim.fn.maparg('<', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('d', 'x', false, true).desc, 'Move file to trash (Mac/Linux)')
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
    api.expand()
    set_cursor_line('nested/$')
    api.expand()

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

    api.last_sibling()
    assert_eq(current_line(), 'top.txt', 'last sibling should jump to the last root sibling')
    api.last_sibling()
    assert_eq(current_line(), 'top.txt', 'last sibling should stay on the last sibling')
    api.first_sibling()
    assert_eq(current_line(), 'alpha/', 'first sibling should jump to the first root sibling')
    api.first_sibling()
    assert_eq(current_line(), 'alpha/', 'first sibling should stay on the first sibling')

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
    api.first_sibling()
    assert_match(current_line(), 'nested/$', 'first sibling should jump to the first child sibling')
    api.last_sibling()
    assert_match(current_line(), 'file%.txt$', 'last sibling should jump to the last child sibling')

    set_cursor_line('deep%.txt$')
    api.prev_sibling()
    assert_match(current_line(), 'deep%.txt$', 'previous sibling should stay on an only child sibling')
    api.next_sibling()
    assert_match(current_line(), 'deep%.txt$', 'next sibling should stay on an only child sibling')
    api.first_sibling()
    assert_match(current_line(), 'deep%.txt$', 'first sibling should stay on an only child sibling')
    api.last_sibling()
    assert_match(current_line(), 'deep%.txt$', 'last sibling should stay on an only child sibling')

    set_cursor_pos('alpha')
    vim.api.nvim_feedkeys('2J', 'xt', false)
    assert_eq(current_line(), 'top.txt', 'counted next sibling should move the requested number of siblings')
    vim.api.nvim_feedkeys('2K', 'xt', false)
    assert_eq(current_line(), 'alpha/', 'counted previous sibling should move the requested number of siblings')
    -- Clear the pending count so it doesn't leak into later blocks that call
    -- api.expand()/api.collapse() directly; those read vim.v.count1 and would
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
    api.expand_recursive()
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
    api.collapse_recursive()
    assert(not state.expanded_dirs[root .. '/root'], 'recursive collapse should clear selected directory')
    assert(not state.expanded_dirs[root .. '/root/a'], 'recursive collapse should clear descendants')
    assert(not state.expanded_dirs[root .. '/root/a/b'], 'recursive collapse should clear nested descendants')
    assert(not state.expanded_dirs[root .. '/root/empty'], 'recursive collapse should clear empty descendants')
    assert(not vim.tbl_contains(lines(), '├ a/'), 'recursive collapse should hide children')

    api.expand()
    assert(vim.tbl_contains(lines(), '├ a/'), 'expand after recursive collapse should show one level')
    assert(not vim.tbl_contains(lines(), '│ └ b/'), 'expand after recursive collapse should not restore recursive state')

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
    api.expand()
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

    api.expand()
    assert(vim.tbl_contains(lines(), '│   └── file.txt'), 'second expand should expand another level')
    assert_cursor_tree_highlights(state, 3)

    set_cursor_line('file%.txt$')
    assert_cursor_tree_highlights(state, 1)
    assert(state.rows[vim.api.nvim_win_get_cursor(0)[1]].tree_connector_start_col > 0)
    api.toggle_copy()
    assert_eq(state.marked_paths[root .. '/alpha/one/file.txt'], 'copy', 'nested row should mark its real path')

    set_cursor_pos('alpha')
    api.collapse()
    assert(vim.tbl_contains(lines(), '├── one/'), 'collapse should keep the hovered directory open')
    assert(vim.tbl_contains(lines(), '└── two/'), 'collapse should keep shallow descendants visible')
    assert(not vim.tbl_contains(lines(), '│   └── file.txt'), 'collapse should hide the deepest visible level')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapse should leave the hovered directory expanded')
    assert(not state.expanded_dirs[root .. '/alpha/one'], 'collapse should fold deepest expanded descendants')

    api.expand()
    assert(vim.tbl_contains(lines(), '│   └── file.txt'), 're-expand should restore previous tree state')

    set_cursor_line('file%.txt$')
    api.collapse()
    assert(not vim.tbl_contains(lines(), '│   └── file.txt'), 'collapsing file should hide sibling rows below its parent directory')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapsing file should leave grandparent expanded')
    assert(not state.expanded_dirs[root .. '/alpha/one'], 'collapsing file should fold its parent directory')
    assert_match(current_line(), 'one/$', 'collapsing file should move cursor to its parent directory')

    api.collapse()
    assert(vim.tbl_contains(lines(), '├── one/'), 'collapsing a directory with no visible descendants should be a no-op')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapsing a directory with no visible descendants should leave ancestors expanded')
    assert_match(current_line(), 'one/$', 'collapsing a directory with no visible descendants should keep the cursor')

    set_cursor_pos('alpha')
    api.collapse()
    assert(vim.tbl_contains(lines(), '├── one/'), 'collapse should remove the deepest remaining descendant level first')
    assert(vim.tbl_contains(lines(), '└── two/'), 'collapse should keep shallow descendants visible')
    assert(not vim.tbl_contains(lines(), '    └── (empty)'), 'collapse should hide empty placeholders at the deepest level')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapse should leave the hovered directory expanded while descendants remain visible')
    assert(not state.expanded_dirs[root .. '/alpha/two'], 'collapse should fold deepest empty descendants')

    api.collapse()
    assert(not vim.tbl_contains(lines(), '├── one/'), 'collapsing one visible level should fold the hovered directory')
    assert(not state.expanded_dirs[root .. '/alpha'], 'collapsing one visible level should clear the hovered directory expansion')
    assert_match(current_line(), 'alpha/$', 'collapsing one visible level should keep cursor on the hovered directory')

    api.expand()
    api.expand()
    assert(vim.tbl_contains(lines(), '│   └── file.txt'), 'recursive state should be restorable after parent fallback collapse')

    set_cursor_line('one/$')
    api.collapse()
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
    api.expand()
    assert(vim.tbl_contains(lines(), '└── (empty)'), 'empty directories should render a placeholder')
    assert(has_highlight(state, 'DoraTree'), 'empty placeholder should be highlighted as tree text')

    set_cursor_pos('empty')
    api.collapse()
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
    local ok, msg = pcall(api.expand)
    fs.list = old_list
    assert(ok, msg)
    assert(vim.tbl_contains(lines(), '└── (not permitted)'), 'unreadable directories should render a placeholder')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

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
    assert_eq(vim.fn.maparg('f', 'n', false, true).desc, 'Filter visible files')
    assert_eq(vim.fn.maparg('F', 'n', false, true).desc, 'Clear filter')

    set_cursor_pos('alpha')
    api.expand()
    set_cursor_pos('gamma')
    api.expand()

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
    api.last_sibling()
    assert_eq(current_line(), 'root-MATCH.txt', 'filtered last-sibling navigation should reach the final result')
    api.first_sibling()
    assert_eq(current_line(), 'alpha/match.txt', 'filtered first-sibling navigation should reach the first result')

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
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))
    touch(tmp .. '/sub/seed.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('sub')
    api.expand()
    assert(find_line_index(lines(), 'seed%.txt$'), 'setup should show the expanded directory contents')

    -- The cached listing should refresh via the directory watcher when the
    -- directory changes behind dora's back.
    touch(tmp .. '/sub/external.txt')
    local found = vim.wait(2000, function()
        return find_line_index(lines(), 'external%.txt$') ~= nil
    end, 10)
    assert(found, 'external file changes should refresh the cached listing')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
local state = store.get()
assert_eq(state.cwd, fs.realpath(cwd))
assert(vim.api.nvim_buf_get_var(0, 'is_dora'), 'Dora buffer should be identified')
assert(#vim.api.nvim_buf_get_lines(0, 0, -1, false) > 0, 'Dora buffer should render entries')
api.quit()

print('dora: smoke ok\n')
