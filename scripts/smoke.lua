local api = vim.api

local orig_notify = vim.notify
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
local core = require'dora.core'
local store = require'dora.store'
local util = require'dora.util'
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

local function clear_persisted_view_state(win)
    pcall(api.nvim_win_del_var, win or 0, 'dora_previous_directory')
    pcall(api.nvim_win_del_var, win or 0, 'dora_expanded_directories')
end

local function lines()
    return api.nvim_buf_get_lines(0, 0, -1, false)
end

local function buf_lines(buf)
    return api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function set_cursor_line(pattern)
    for i, line in ipairs(lines()) do
        if line:match(pattern) then
            api.nvim_win_set_cursor(0, {i, 0})
            return
        end
    end
    error('could not find line matching ' .. pattern)
end

local function current_line()
    return api.nvim_get_current_line()
end

local function find_line_index(search_lines, pattern)
    for i, line in ipairs(search_lines) do
        if line:match(pattern) then
            return i
        end
    end
end

local function assert_line_before(pattern_a, pattern_b, msg)
    local search_lines = lines()
    local a = find_line_index(search_lines, pattern_a)
    local b = find_line_index(search_lines, pattern_b)
    assert(a and b and a < b, msg or (pattern_a .. ' should appear before ' .. pattern_b))
end

local function win_title(win)
    local title = api.nvim_win_get_config(win).title
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

local function assert_centered_float(win, msg)
    local cfg = api.nvim_win_get_config(win)
    assert_eq(cfg.relative, 'editor', msg)
    assert_eq(cfg.row, math.max(0, math.floor((vim.o.lines - cfg.height - 2) / 2)), msg)
    assert_eq(cfg.col, math.floor((vim.o.columns - cfg.width) / 2), msg)
end

local function has_highlight(state, hl_group)
    local marks = api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    for _, mark in ipairs(marks) do
        if mark[4].hl_group == hl_group then
            return true
        end
    end
    return false
end

local function has_high_priority_highlight(state, hl_group)
    local marks = api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    for _, mark in ipairs(marks) do
        if mark[4].hl_group == hl_group and mark[4].priority == 10000 then
            return true
        end
    end
    return false
end

local function has_priority_highlight(state, hl_group, priority)
    local marks = api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    for _, mark in ipairs(marks) do
        if mark[4].hl_group == hl_group and mark[4].priority == priority then
            return true
        end
    end
    return false
end

local function has_sign_highlight(state, hl_group)
    local marks = api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    for _, mark in ipairs(marks) do
        local details = mark[4]
        if details.sign_text and vim.startswith(details.sign_text, '▌') and details.sign_hl_group == hl_group then
            return true
        end
    end
    return false
end

local function cursor_tree_highlights(state)
    local ret = {}
    local marks = api.nvim_buf_get_extmarks(state.buf, state.cursor_ns, 0, -1, {details = true})
    for _, mark in ipairs(marks) do
        if mark[4].hl_group == 'DoraTreeActive' then
            ret[#ret+1] = mark
        end
    end
    return ret
end

local function assert_cursor_tree_highlights(state, expected_count)
    api.nvim_exec_autocmds('CursorMoved', {buffer = state.buf})
    local marks = cursor_tree_highlights(state)
    local lnum = api.nvim_win_get_cursor(0)[1]
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
    local origin_win = api.nvim_get_current_win()
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
    local origin_cursor = api.nvim_win_get_cursor(origin_win)
    local origin_pos = vim.fn.screenpos(origin_win, origin_cursor[1], origin_cursor[2] + 1)

    delete_win.delete(paths, tmp, function(confirmed)
        vim.g.dora_smoke_confirm_delete = confirmed
    end)
    local confirm_win = api.nvim_get_current_win()
    local confirm_buf = api.nvim_get_current_buf()
    local confirm_cfg = api.nvim_win_get_config(confirm_win)
    local confirm_lines = api.nvim_buf_get_lines(confirm_buf, 0, -1, false)

    assert_match(vim.wo[confirm_win].winhighlight, 'FloatBorder:DoraPromptBorderInvalid')
    assert_eq(confirm_cfg.row, origin_pos.row, 'delete confirmation should anchor to the cursor by default')
    assert_eq(confirm_cfg.col, origin_pos.col - 1, 'delete confirmation should anchor to the cursor by default')
    assert_match(win_title(confirm_win), 'Delete 12 files%?')
    assert_eq(#confirm_lines, 11, 'delete confirmation should cap visible files')
    assert_eq(confirm_lines[1], ' foo.js')
    assert_eq(confirm_lines[2], ' dir/')
    assert_eq(confirm_lines[3], ' dir/bar.lua')
    assert_eq(confirm_lines[11], ' ... and 2 more')

    local marks = api.nvim_buf_get_extmarks(confirm_buf, -1, 0, -1, {details=true})
    local has_path, has_file, has_dir, has_dir_suffix, has_more = false, false, false, false, false
    for _, mark in ipairs(marks) do
        local row, col, details = mark[2], mark[3], mark[4]
        has_path = has_path
            or details.hl_group == 'DoraDeletePath'
        has_file = has_file
            or row == 0 and col == 1 and details.end_col == 7 and details.hl_group == 'DoraFile'
        has_dir = has_dir
            or row == 1 and col == 1 and details.end_col == 4 and details.hl_group == 'DoraDirectory'
        has_dir_suffix = has_dir_suffix
            or row == 1 and col == 4 and details.end_col == 5 and details.hl_group == 'DoraVirtText'
        has_more = has_more
            or row == 10 and details.hl_group == 'DoraDeleteMore'
    end
    assert(not has_path, 'delete confirmation should not dim the path portion')
    assert(has_file, 'delete confirmation should highlight file names by type')
    assert(has_dir, 'delete confirmation should highlight directory names by type')
    assert(not has_dir_suffix, 'delete confirmation should leave directory suffixes normal')
    assert(has_more, 'delete confirmation should highlight the overflow row')

    api.nvim_feedkeys('n', 'xt', false)
    assert_eq(vim.g.dora_smoke_confirm_delete, false)
    assert_eq(api.nvim_get_current_win(), origin_win)
    assert_eq(vim.o.guicursor, old_guicursor)
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local origin_buf = api.nvim_get_current_buf()
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    local long_dir = 'very-long-delete-confirmation-path-segment-with-extra-context'
    local long_file = 'file-with-a-long-name-that-should-stay-visible.txt'
    local rel_path = long_dir .. util.sep .. long_file
    assert_eq(vim.fn.mkdir(tmp .. util.sep .. long_dir, 'p'), 1)
    touch(tmp .. util.sep .. rel_path)

    local anchor_buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(anchor_buf)
    api.nvim_buf_set_lines(anchor_buf, 0, -1, false, {string.rep('x', vim.o.columns)})
    local anchor_win = api.nvim_get_current_win()
    local anchor_col = math.max(0, vim.o.columns - 12)
    local anchor_pos = vim.fn.screenpos(anchor_win, 1, anchor_col + 1)

    delete_win.delete({tmp .. util.sep .. rel_path}, tmp, function() end, {
        anchor = {win = anchor_win, line = 1, col = anchor_col},
    })
    local confirm_win = api.nvim_get_current_win()
    local confirm_buf = api.nvim_get_current_buf()
    local confirm_cfg = api.nvim_win_get_config(confirm_win)
    local confirm_lines = api.nvim_buf_get_lines(confirm_buf, 0, -1, false)
    local view = api.nvim_win_call(confirm_win, function()
        return vim.fn.winsaveview()
    end)
    local expected_width = math.min(96, math.max(20, vim.o.columns - 2))
    local expected_col = math.min(math.max(0, anchor_pos.col - 1), math.max(0, vim.o.columns - expected_width - 2))

    assert_eq(confirm_lines[1], ' ' .. rel_path)
    assert_eq(confirm_cfg.width, expected_width, 'delete confirmation should expand anchored windows for long paths')
    assert_eq(confirm_cfg.col, expected_col, 'delete confirmation should shift left to fit expanded windows')
    assert(confirm_cfg.col < anchor_pos.col - 1, 'delete confirmation should start left of the anchor when needed')
    assert_eq(view.leftcol, 0, 'delete confirmation should not rely on horizontal scroll')

    api.nvim_feedkeys('n', 'xt', false)
    api.nvim_set_current_buf(origin_buf)
    api.nvim_buf_delete(anchor_buf, {force = true})
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

    delete_win.delete({tmp .. '/icon.txt'}, tmp, function() end)
    local confirm_buf = api.nvim_get_current_buf()
    local confirm_lines = api.nvim_buf_get_lines(confirm_buf, 0, -1, false)
    assert_eq(confirm_lines[1], ' [del] icon.txt', 'delete confirmation should render file icons when enabled')

    local marks = api.nvim_buf_get_extmarks(confirm_buf, -1, 0, -1, {details=true})
    local has_icon, has_file = false, false
    for _, mark in ipairs(marks) do
        local row, col, details = mark[2], mark[3], mark[4]
        has_icon = has_icon
            or row == 0 and col == 1 and details.end_col == 6 and details.hl_group == 'DoraIcon'
        has_file = has_file
            or row == 0 and col == 7 and details.end_col == 15 and details.hl_group == 'DoraFile'
    end
    assert(has_icon, 'delete confirmation should highlight icons')
    assert(has_file, 'delete confirmation should keep highlighting filenames after icons')

    api.nvim_feedkeys('n', 'xt', false)
    config.icons = old_icons
    _G.MiniIcons = old_mini_icons
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/enter.txt')

    delete_win.delete({tmp .. '/enter.txt'}, tmp, function(confirmed)
        vim.g.dora_smoke_enter_confirm_delete = confirmed
    end)

    api.nvim_feedkeys('\r', 'xt', false)
    assert_eq(vim.g.dora_smoke_enter_confirm_delete, true)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local old_winborder = vim.o.winborder
    vim.o.winborder = ''
    assert_eq(window.border(), 'rounded', 'window borders should keep Dora rounded fallback without winborder')
    vim.o.winborder = 'single'
    local buf = api.nvim_create_buf(false, true)
    local win = api.nvim_open_win(buf, false, {
        relative = 'editor',
        row = 0,
        col = 0,
        width = 1,
        height = 1,
        border = window.border(),
    })
    assert_eq(api.nvim_win_get_config(win).border[1], '┌', 'window borders should defer to winborder when set')
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

    local cfg = api.nvim_win_get_config(p.input_win)
    assert_eq(cfg.relative, 'editor')
    assert_eq(cfg.anchor, 'NW')
    assert_eq(cfg.border[1], '╭')
    assert(next(vim.fn.maparg('<Esc>', 'i', false, true)) == nil,
        'prompt should use the default insert-mode escape behavior')
    assert_eq(type(vim.fn.maparg('<Esc>', 'n', false, true).callback), 'function')
    for _, map in ipairs(api.nvim_buf_get_keymap(p.input_buf, 'i')) do
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
    local origin_win = api.nvim_get_current_win()
    local old_buf = api.nvim_win_get_buf(origin_win)
    local old_number = vim.wo[origin_win].number
    local old_relativenumber = vim.wo[origin_win].relativenumber
    local old_signcolumn = vim.wo[origin_win].signcolumn
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    api.nvim_win_set_buf(origin_win, buf)
    vim.wo[origin_win].number = true
    vim.wo[origin_win].relativenumber = false
    vim.wo[origin_win].signcolumn = 'yes'
    api.nvim_buf_set_lines(buf, 0, -1, false, {'root', '└── anchored.txt'})
    api.nvim_win_set_cursor(origin_win, {2, 0})

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

    local cfg = api.nvim_win_get_config(p.input_win)
    assert_eq(cfg.relative, 'editor')
    assert_eq(cfg.row, pos.row)
    assert_eq(cfg.col, pos.col - 1)

    p:cancel()
    vim.wo[origin_win].number = old_number
    vim.wo[origin_win].relativenumber = old_relativenumber
    vim.wo[origin_win].signcolumn = old_signcolumn
    api.nvim_win_set_buf(origin_win, old_buf)
    api.nvim_buf_delete(buf, {force = true})
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

    api.nvim_feedkeys(api.nvim_replace_termcodes('ix<Esc>', true, false, true), 'xt', false)
    assert(vim.wait(1000, function()
        return p:get_input() == 'x' and vim.api.nvim_get_mode().mode == 'n'
    end), 'escape after typed input should leave insert mode')
    assert(not p.closed, 'escape after typed input should leave prompt open')
    p:cancel()
    assert_eq(vim.g.dora_smoke_escape_typed, true)
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

    api.nvim_feedkeys(api.nvim_replace_termcodes('i<Esc>', true, false, true), 'xt', false)
    assert(vim.wait(1000, function()
        return not p.closed and vim.api.nvim_get_mode().mode == 'n'
    end), 'escape with empty input should leave insert mode and keep the prompt open')
    p:cancel()
    assert_eq(vim.g.dora_smoke_escape_key_empty, true)
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
assert_eq(fs.parent_dir(util.sep), util.sep, 'parent_dir should not go above root')
assert_eq(fs.parent_dir(util.sep .. 'tmp'), util.sep, 'parent_dir should keep root for top-level paths')
assert_eq(fs.get_parent_dir(util.sep .. 'tmp'), util.sep, 'get_parent_dir should allow top-level paths')
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
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/home', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/home/.Trash', tonumber('755', 8)))
    touch(tmp .. '/foo')
    touch(tmp .. '/home/.Trash/foo')
    assert(vim.loop.fs_mkdir(tmp .. '/home/.Trash/bar', tonumber('755', 8)))
    touch(tmp .. '/bar')
    vim.env.HOME = tmp .. '/home'

    fs.trash(tmp .. '/foo')
    fs.trash(tmp .. '/bar')
    assert(not fs.exists(tmp .. '/foo'), 'trash should remove source files')
    assert(not fs.exists(tmp .. '/bar'), 'trash should remove source files when destination name collides with a directory')
    assert(fs.exists(tmp .. '/home/.Trash/foo'), 'trash should preserve existing trash entries')
    assert(fs.exists(tmp .. '/home/.Trash/foo 1'), 'trash should suffix colliding file names')
    assert(fs.exists(tmp .. '/home/.Trash/bar'), 'trash should preserve existing trash directories')
    assert(fs.exists(tmp .. '/home/.Trash/bar 1'), 'trash should suffix colliding directory names')

    vim.env.HOME = old_home
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/nvim-dora', tonumber('755', 8)))
    touch(tmp .. '/nvim-dora/existing.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_line('nvim%-dora/$')
    core.expand()
    set_cursor_line('existing%.txt$')
    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.width, 32, 'create prompt should match the default delete window width')
        local path = opts.validate('foo/bar/a')
        cb('foo/bar/a', path)
    end
    core.create()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/foo/bar/a'), 'create should create a nested file path')
    assert(vim.tbl_contains(lines(), 'foo/'), 'create should render the new top-level parent')
    assert(vim.tbl_contains(lines(), '└── bar/'), 'create should expand the selected created parent')
    assert(vim.tbl_contains(lines(), '    └── a'), 'create should recursively reveal the created nested file')
    assert_match(current_line(), 'foo/$', 'create should move cursor to the top-level created parent')
    local row = store.get().rows[api.nvim_win_get_cursor(0)[1]]
    assert_eq(row.path, fs.realpath(tmp) .. '/foo')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/nvim-dora', tonumber('755', 8)))
    touch(tmp .. '/nvim-dora/existing.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_line('nvim%-dora/$')
    core.expand()
    set_cursor_line('existing%.txt$')
    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, 'nvim-dora/', 'create should prefill the hovered file parent path')
        local input = opts.initial_prompt .. 'foo/bar'
        cb(input, opts.validate(input))
    end
    core.create()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/nvim-dora/foo/bar'), 'create should create nested paths inside expanded directories')
    assert(vim.tbl_contains(lines(), '│   └── bar'), 'create should expand the selected parent under expanded directories')
    assert_match(current_line(), 'foo/$', 'create should move cursor to the nearest visible created parent')
    local row = store.get().rows[api.nvim_win_get_cursor(0)[1]]
    assert_eq(row.path, fs.realpath(tmp) .. '/nvim-dora/foo')

    core.quit()
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
    core.create()
    prompt.input = old_input

    assert(fs.is_dir(tmp .. '/foo/bar'), 'create should create nested directory paths')
    assert(vim.tbl_contains(lines(), '└── bar/'), 'create should expand newly created directory parents')
    assert_match(current_line(), 'foo/$', 'create should keep cursor on the top-level created directory')

    core.quit()
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
    core.home_dir()
    assert_eq(state.cwd, fs.realpath(tmp .. '/home'), 'home directory should navigate to $HOME')
    assert(vim.tbl_contains(lines(), 'home-file.txt'), 'home directory should render $HOME contents')

    core.quit()
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
    util.set_cursor_pos('root')
    core.expand()
    set_cursor_line('child/$')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, 'root/', 'create should prefill the hovered directory parent path')
        local input = opts.initial_prompt .. 'file.txt'
        cb(input, opts.validate(input))
    end
    core.create()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/root/file.txt'), 'create should create beside the hovered directory')
    assert_match(current_line(), 'file%.txt$', 'cursor should move to the created sibling file')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/root', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/root/child', tonumber('755', 8)))
    touch(tmp .. '/root/child/existing.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('root')
    core.expand_recursive()
    set_cursor_line('existing%.txt$')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, 'root/child/', 'create should prefill the hovered file parent path')
        local input = opts.initial_prompt .. 'sibling.txt'
        cb(input, opts.validate(input))
    end
    core.create()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/root/child/sibling.txt'), 'create should create beside the hovered file')
    assert_match(current_line(), 'sibling%.txt$', 'cursor should move to the created sibling file')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    clear_persisted_view_state()
    vim.cmd('Dora ' .. vim.fn.fnameescape(util.sep))
    local state = store.get()
    local name = api.nvim_buf_get_name(state.buf)

    core.up_dir()
    assert_eq(state.cwd, util.sep, 'up directory should no-op at root')
    assert_eq(api.nvim_buf_get_name(state.buf), name, 'up directory should not rename the root buffer')
    assert_eq(state.bookmarks.previous_directory, nil, 'up directory at root should not update the previous-directory bookmark')

    core.quit()
end

do
    local parts = vim.tbl_filter(function(part) return part ~= '' end, vim.split(fs.realpath(cwd), util.sep, {plain=true}))
    assert(#parts >= 2, 'smoke cwd should have a top-level parent')
    local top_path = util.sep .. parts[1]

    vim.cmd('Dora ' .. vim.fn.fnameescape(top_path))
    local state = store.get()
    core.up_dir()

    assert_eq(state.cwd, util.sep, 'up directory should navigate from a top-level directory to root')
    assert(state.expanded_dirs[top_path], 'up directory should preserve the top-level previous cwd expansion')
    assert_match(current_line(), vim.pesc(parts[1]) .. '/$', 'up directory should move cursor to the previous top-level cwd row')
    assert(find_line_index(lines(), vim.pesc(parts[2]) .. '/$'), 'up directory should keep top-level previous cwd children visible at root')

    core.quit()
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/beta', tonumber('755', 8)))
    touch(tmp .. '/alpha/duplicate.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('alpha')
    core.expand()
    util.set_cursor_pos('beta')
    core.expand()

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, nil, 'create should not prefill a root-level directory path')
        local input = 'duplicate.txt'
        cb(input, opts.validate(input))
    end
    core.create()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/duplicate.txt'), 'create should create beside the root-level directory')
    assert_match(current_line(), 'duplicate%.txt$', 'cursor should move to the newly created duplicate file')
    local row = store.get().rows[api.nvim_win_get_cursor(0)[1]]
    assert_eq(row.path, store.get().cwd .. '/duplicate.txt')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/root', tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    assert_eq(vim.fn.maparg('A', 'n', false, true).desc, 'Add file under directory')
    util.set_cursor_pos('root')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, 'root/', 'create_under should prefill the hovered directory path')
        local input = opts.initial_prompt .. 'child.txt'
        cb(input, opts.validate(input))
    end
    core.create_under()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/root/child.txt'), 'create_under should create inside the hovered directory')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/anchor.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    util.set_cursor_pos('anchor%.txt')
    local cursor = api.nvim_win_get_cursor(0)
    local row = state.rows[cursor[1]]

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert(opts.anchor, 'create should anchor the prompt to the current row')
        assert_eq(opts.initial_prompt, nil, 'create should not prefill a root-level file path')
        assert_eq(opts.anchor.win, api.nvim_get_current_win())
        assert_eq(opts.anchor.line, cursor[1])
        assert_eq(opts.anchor.col, row.name_start_col)
        cb(nil)
    end
    core.create()
    prompt.input = old_input

    core.quit()
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

    util.set_cursor_pos('one')
    core.expand()
    assert(state.expanded_dirs[alpha .. '/one'], 'setup should expand a nested subtree')
    assert(find_line_index(lines(), 'file%.txt$'), 'setup should show the expanded nested file')

    core.up_dir()
    assert_eq(state.cwd, parent)
    assert(state.expanded_dirs[alpha], 'up directory should expand the previous cwd under its parent')
    assert(state.expanded_dirs[alpha .. '/one'], 'up directory should preserve nested subtree state')
    assert_match(current_line(), 'alpha/$', 'up directory should move cursor to the previous cwd row')
    assert(find_line_index(lines(), 'one/$'), 'up directory should keep previous cwd children visible')
    assert(find_line_index(lines(), 'file%.txt$'), 'up directory should keep nested expanded rows visible')

    core.quit()
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
    assert_eq(vim.fn.maparg('<BS>', 'n', false, true).desc, 'Go to and collapse parent directory')
    assert_eq(vim.fn.maparg('P', 'n', false, true).desc, 'Paste under parent directory')
    util.set_cursor_pos('alpha')
    core.expand()
    util.set_cursor_pos('one')
    core.expand()

    set_cursor_line('file%.txt$')
    core.parent_dir()
    assert_match(current_line(), 'one/$', 'parent jump should move from a nested file to its parent directory')
    assert(not state.expanded_dirs[tmp .. '/alpha/one'], 'parent jump should collapse the parent directory')
    assert(not find_line_index(lines(), 'file%.txt$'), 'parent jump should hide the parent directory children')

    core.parent_dir()
    assert_match(current_line(), 'alpha/$', 'parent jump should move from a nested directory to its parent directory')
    assert(not state.expanded_dirs[tmp .. '/alpha'], 'parent jump should collapse each visited parent directory')
    assert(not find_line_index(lines(), 'one/$'), 'parent jump should hide each visited parent directory children')

    core.parent_dir()
    assert_match(current_line(), 'alpha/$', 'parent jump should keep the cursor when the parent is not visible')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('b')
    local cursor = api.nvim_win_get_cursor(0)
    local row = store.get().rows[cursor[1]]

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert(opts.anchor, 'create should anchor at the current row')
        assert_eq(opts.anchor.win, api.nvim_get_current_win())
        assert_eq(opts.anchor.line, cursor[1])
        assert_eq(opts.anchor.col, row.name_start_col)
        cb(nil)
    end
    core.create()
    prompt.input = old_input

    core.quit()
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

    core.quit()
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

    core.quit()
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

    core.quit()
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

    core.quit()
    config.icons = old_icons
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/single.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('single%.txt')
    local origin_win = api.nvim_get_current_win()
    local cursor = api.nvim_win_get_cursor(origin_win)
    local row = store.get().rows[cursor[1]]
    local pos = vim.fn.screenpos(origin_win, cursor[1], row.name_start_col + 1)
    core.delete()

    local confirm_win = api.nvim_get_current_win()
    local confirm_buf = api.nvim_get_current_buf()
    local confirm_cfg = api.nvim_win_get_config(confirm_win)
    local confirm_lines = api.nvim_buf_get_lines(confirm_buf, 0, -1, false)
    assert_eq(confirm_cfg.row, pos.row)
    assert_eq(confirm_cfg.col, pos.col - 1)
    assert_match(win_title(confirm_win), 'Delete%?')
    assert_eq(confirm_lines[1], ' single.txt')

    api.nvim_feedkeys('n', 'xt', false)
    core.quit()
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
    local dora_win = api.nvim_get_current_win()
    local dora_buf = api.nvim_get_current_buf()
    assert_eq(vim.fn.maparg('<C-s>', 'n', false, true).desc, 'Open in split in place')
    assert_eq(vim.fn.maparg('<C-v>', 'n', false, true).desc, 'Open in vertical split in place')
    assert_eq(vim.fn.maparg('<C-t>', 'n', false, true).desc, 'Open in tab in place')

    set_cursor_line('split%.txt$')
    local existing_wins = api.nvim_tabpage_list_wins(0)
    core.open_split_keep()
    local split_win = vim.iter(api.nvim_tabpage_list_wins(0)):find(function(win)
        return not vim.tbl_contains(existing_wins, win)
    end)
    assert(split_win, '<C-s> should create a split')
    assert_eq(api.nvim_buf_get_name(api.nvim_win_get_buf(split_win)), real_tmp .. '/split.txt',
        '<C-s> should open the file in a split')
    assert(#vim.fn.win_findbuf(dora_buf) > 0, '<C-s> should keep the Dora buffer visible')
    assert_eq(api.nvim_get_current_win(), dora_win, '<C-s> should keep focus in Dora')
    api.nvim_win_close(split_win, true)

    set_cursor_line('vsplit%.txt$')
    existing_wins = api.nvim_tabpage_list_wins(0)
    core.open_vsplit_keep()
    local vsplit_win = vim.iter(api.nvim_tabpage_list_wins(0)):find(function(win)
        return not vim.tbl_contains(existing_wins, win)
    end)
    assert(vsplit_win, '<C-v> should create a vertical split')
    assert_eq(api.nvim_buf_get_name(api.nvim_win_get_buf(vsplit_win)), real_tmp .. '/vsplit.txt',
        '<C-v> should open the file in a vertical split')
    assert(#vim.fn.win_findbuf(dora_buf) > 0, '<C-v> should keep the Dora buffer visible')
    assert_eq(api.nvim_get_current_win(), dora_win, '<C-v> should keep focus in Dora')
    api.nvim_win_close(vsplit_win, true)

    set_cursor_line('tab%.txt$')
    local dora_tab = api.nvim_get_current_tabpage()
    local existing_tabs = api.nvim_list_tabpages()
    core.open_tab_keep()
    local file_tab = vim.iter(api.nvim_list_tabpages()):find(function(tab)
        return not vim.tbl_contains(existing_tabs, tab)
    end)
    assert(file_tab, '<C-t> should create a tab')
    local file_win = api.nvim_tabpage_get_win(file_tab)
    assert_eq(api.nvim_buf_get_name(api.nvim_win_get_buf(file_win)), real_tmp .. '/tab.txt',
        '<C-t> should open the file in a tab')
    assert(api.nvim_win_is_valid(dora_win), '<C-t> should keep the Dora window')
    assert_eq(api.nvim_win_get_buf(dora_win), dora_buf, '<C-t> should keep the Dora buffer in its original tab')
    assert_eq(api.nvim_get_current_tabpage(), dora_tab, '<C-t> should keep focus in the Dora tab')
    assert_eq(api.nvim_get_current_win(), dora_win, '<C-t> should keep focus in Dora')
    api.nvim_set_current_win(file_win)
    vim.cmd('tabclose')
    api.nvim_set_current_win(dora_win)

    core.quit()
    vim.o.directory = old_directory
    for _, path in ipairs({'split.txt', 'vsplit.txt', 'tab.txt'}) do
        pcall(vim.cmd, 'bdelete! ' .. vim.fn.fnameescape(real_tmp .. '/' .. path))
    end
    assert_eq(vim.fn.delete(swap_dir, 'rf'), 0)
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/trashed.txt')
    local old_trash = fs.trash
    fs.trash = function(path)
        vim.g.dora_smoke_trashed_path = path
        assert_eq(vim.fn.delete(path), 0)
    end

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    util.set_cursor_pos('trashed%.txt')
    core.trash()

    local confirm_win = api.nvim_get_current_win()
    assert_match(win_title(confirm_win), 'Trash%?')
    api.nvim_feedkeys('y', 'xt', false)

    assert_eq(vim.g.dora_smoke_trashed_path, state.cwd .. '/trashed.txt')
    assert(not fs.exists(tmp .. '/trashed.txt'), 'trash should remove the file from the listing source')

    core.quit()
    fs.trash = old_trash
    vim.g.dora_smoke_trashed_path = nil
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/deleted.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('deleted%.txt')
    core.delete()

    local confirm_win = api.nvim_get_current_win()
    assert_match(win_title(confirm_win), 'Delete%?')
    api.nvim_feedkeys('y', 'xt', false)

    assert(not fs.exists(tmp .. '/deleted.txt'), 'delete should permanently remove the file')

    core.quit()
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
    fs.trash = function(path)
        trashed_paths[#trashed_paths+1] = path
        assert_eq(vim.fn.delete(path), 0)
    end

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_line('a$')
    local origin_win = api.nvim_get_current_win()
    local target_line = find_line_index(lines(), 'b$')
    local target_row = state.rows[target_line]
    local pos = vim.fn.screenpos(origin_win, target_line, target_row.name_start_col + 1)
    api.nvim_feedkeys(api.nvim_replace_termcodes('Vjd', true, false, true), 'xt', false)

    local confirm_win = api.nvim_get_current_win()
    local confirm_cfg = api.nvim_win_get_config(confirm_win)
    assert_match(win_title(confirm_win), 'Trash 2 files%?')
    assert_eq(confirm_cfg.row, pos.row, 'visual trash confirmation should anchor to the visual cursor')
    assert_eq(confirm_cfg.col, pos.col - 1, 'visual trash confirmation should anchor to the visual cursor')
    api.nvim_feedkeys('y', 'xt', false)

    assert_eq(#trashed_paths, 2, 'visual trash should trash each selected file')
    assert_eq(trashed_paths[1], state.cwd .. '/a')
    assert_eq(trashed_paths[2], state.cwd .. '/b')
    assert(not fs.exists(tmp .. '/a'), 'visual trash should remove selected file a')
    assert(not fs.exists(tmp .. '/b'), 'visual trash should remove selected file b')
    assert(fs.exists(tmp .. '/c'), 'visual trash should leave unselected files')

    core.quit()
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
    local origin_win = api.nvim_get_current_win()
    local target_line = find_line_index(lines(), 'beta$')
    local target_row = state.rows[target_line]
    local pos = vim.fn.screenpos(origin_win, target_line, target_row.name_start_col + 1)
    api.nvim_feedkeys(api.nvim_replace_termcodes('VjD', true, false, true), 'xt', false)

    local confirm_win = api.nvim_get_current_win()
    local confirm_cfg = api.nvim_win_get_config(confirm_win)
    assert_match(win_title(confirm_win), 'Delete 2 files%?')
    assert_eq(confirm_cfg.row, pos.row, 'visual delete confirmation should anchor to the visual cursor')
    assert_eq(confirm_cfg.col, pos.col - 1, 'visual delete confirmation should anchor to the visual cursor')
    api.nvim_feedkeys('y', 'xt', false)

    assert(not fs.exists(tmp .. '/alpha'), 'visual delete should remove selected file alpha')
    assert(not fs.exists(tmp .. '/beta'), 'visual delete should remove selected file beta')
    assert(fs.exists(tmp .. '/gamma'), 'visual delete should leave unselected files')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local old_notify = vim.notify
    local notifications = {}
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
    core.toggle_copy()
    assert_eq(marked_path_count(state), 1)
    assert_eq(state.marked_paths[state.cwd .. '/alpha.txt'], 'copy', 'copy should mark the current file')
    assert(has_sign_highlight(state, 'DoraCopy'), 'copy should use a distinct sign highlight')
    assert(has_high_priority_highlight(state, 'DoraCopy'), 'copy should highlight filenames like the copy sign')

    core.toggle_copy()
    assert_eq(marked_path_count(state), 0, 'copy should toggle off an existing copy mark')

    core.toggle_cut()
    assert_eq(state.marked_paths[state.cwd .. '/alpha.txt'], 'cut', 'cut should replace a missing mark')
    assert(has_sign_highlight(state, 'DoraCut'), 'cut should use a distinct sign highlight')
    core.toggle_copy()
    assert_eq(state.marked_paths[state.cwd .. '/alpha.txt'], 'copy', 'copy should replace an existing cut mark')

    util.set_cursor_pos('dest')
    core.expand()
    core.paste()

    assert(fs.exists(tmp .. '/alpha.txt'), 'single-file copy should leave the source file')
    assert(fs.exists(tmp .. '/dest/alpha.txt'), 'paste should copy into the hovered directory')
    assert_eq(marked_path_count(state), 0)
    assert_match(current_line(), 'alpha%.txt$', 'paste should move cursor to the pasted file')
    assert_eq(notifications[#notifications].msg, 'dora: Pasted 1 item to ' .. state.cwd .. '/dest')
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)

    core.quit()
    vim.notify = old_notify
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local old_notify = vim.notify
    local notifications = {}
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
    core.toggle_copy()
    assert_eq(marked_path_count(state), 1)

    assert_eq(vim.fn.delete(tmp .. '/alpha.txt'), 0)
    reload_map.callback()
    assert_eq(marked_path_count(state), 0, 'reload should clear marks for files deleted externally')
    core.paste()
    assert_eq(notifications[#notifications].msg, 'dora: Nothing to paste')
    assert_eq(notifications[#notifications].level, vim.log.levels.ERROR)

    core.quit()
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
    core.toggle_copy()
    util.set_cursor_pos('dest')
    core.expand()
    set_cursor_line('alpha%.txt$')
    core.paste_parent()

    local confirm_win = api.nvim_get_current_win()
    assert_match(win_title(confirm_win), 'Overwrite%?')
    assert_eq(api.nvim_buf_get_lines(0, 0, -1, false)[1], ' dest/alpha.txt')
    api.nvim_feedkeys('n', 'xt', false)

    assert_eq(vim.fn.readfile(tmp .. '/dest/alpha.txt')[1], 'old',
        'declining overwrite should preserve the destination file')
    assert_eq(marked_path_count(state), 1,
        'declining overwrite should preserve paste marks')

    core.paste_parent()
    assert_match(win_title(api.nvim_get_current_win()), 'Overwrite%?')
    api.nvim_feedkeys('y', 'xt', false)

    assert_eq(vim.fn.readfile(tmp .. '/dest/alpha.txt')[1], 'new',
        'confirming overwrite should replace the destination file')
    assert(fs.exists(tmp .. '/alpha.txt'), 'copy overwrite should preserve the source file')
    assert_eq(marked_path_count(state), 0,
        'successful overwrite should clear paste marks')
    assert_match(current_line(), 'alpha%.txt$',
        'successful overwrite should keep the cursor on the pasted file')

    core.quit()
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
    core.toggle_cut()
    assert_eq(state.marked_paths[state.cwd .. '/a'], 'cut', 'cut should mark a file')
    set_cursor_line('c$')
    core.toggle_copy()
    assert_eq(state.marked_paths[state.cwd .. '/c'], 'copy', 'copy should mark another file independently')
    assert_eq(marked_path_count(state), 2)
    assert(has_sign_highlight(state, 'DoraCut'), 'cut marks should use the cut sign')
    assert(has_high_priority_highlight(state, 'DoraCut'), 'cut marks should highlight filenames like the cut sign')
    assert(has_sign_highlight(state, 'DoraCopy'), 'copy marks should use the copy sign')
    assert(has_high_priority_highlight(state, 'DoraCopy'), 'copy marks should highlight filenames like the copy sign')

    core.clear_marks()
    assert_eq(marked_path_count(state), 0, 'escape action should clear paste marks')

    set_cursor_line('b$')
    core.toggle_copy()
    assert_eq(state.marked_paths[state.cwd .. '/b'], 'copy', 'copy should set paste mark before escape')
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
    assert_eq(marked_path_count(state), 0, 'escape should clear paste marks')

    core.quit()
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

    util.set_cursor_pos('a')
    core.toggle_cut()
    util.set_cursor_pos('b')
    core.toggle_copy()
    assert_eq(marked_path_count(state), 2)

    util.set_cursor_pos('dest')
    core.expand()
    core.paste()

    assert(not fs.exists(tmp .. '/a'), 'mixed paste should remove cut source a')
    assert(fs.exists(tmp .. '/b'), 'mixed paste should leave copied source b')
    assert(fs.exists(tmp .. '/dest/a'), 'mixed paste should move cut file a')
    assert(fs.exists(tmp .. '/dest/b'), 'mixed paste should copy file b')
    assert_eq(marked_path_count(state), 0)

    core.quit()
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
    util.set_cursor_pos('alpha%.txt')
    local cursor = api.nvim_win_get_cursor(0)
    local row = state.rows[cursor[1]]

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.prompt, 'Rename to')
        assert_eq(opts.initial_prompt, 'alpha.txt')
        assert_eq(opts.cwd, state.cwd)
        assert_eq(opts.width, 32)
        assert(opts.anchor, 'rename should anchor the prompt to the current row')
        assert_eq(opts.anchor.win, api.nvim_get_current_win())
        assert_eq(opts.anchor.line, cursor[1])
        assert_eq(opts.anchor.col, row.name_start_col)
        assert(not pcall(opts.validate, 'nested/beta.txt'), 'rename prompt should reject relocation')
        cb('beta.txt', opts.validate('beta.txt'))
    end
    core.rename()
    prompt.input = old_input

    assert(not fs.exists(tmp .. '/alpha.txt'), 'rename should remove the old file')
    assert(fs.exists(tmp .. '/beta.txt'), 'rename should create the renamed file')
    assert_match(current_line(), 'beta%.txt$', 'rename should move cursor to the renamed file')

    local empty_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.prompt, 'Rename to')
        assert_eq(opts.initial_prompt, '', 'empty rename should omit the current filename')
        cb('gamma.txt', opts.validate('gamma.txt'))
    end
    core.rename_empty()
    prompt.input = empty_input

    assert(not fs.exists(tmp .. '/beta.txt'), 'empty rename should remove the old file')
    assert(fs.exists(tmp .. '/gamma.txt'), 'empty rename should create the renamed file')
    assert_match(current_line(), 'gamma%.txt$', 'empty rename should move cursor to the renamed file')

    core.quit()
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
    util.set_cursor_pos('dir')
    core.expand()
    set_cursor_line('child/$')
    core.expand()
    util.set_cursor_pos('dir')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.initial_prompt, 'dir', 'rename should not append a slash for directories')
        cb('renamed', opts.validate('renamed'))
    end
    core.rename()
    prompt.input = old_input

    assert(not fs.exists(tmp .. '/dir'), 'rename should remove the old directory')
    assert(fs.exists(tmp .. '/renamed/child/file.txt'), 'rename should move the directory subtree')
    assert(state.expanded_dirs[state.cwd .. '/renamed'], 'rename should preserve expanded directory state')
    assert(state.expanded_dirs[state.cwd .. '/renamed/child'], 'rename should preserve expanded descendant state')
    assert(find_line_index(lines(), 'file%.txt$'), 'rename should render preserved expanded descendants')
    assert_match(current_line(), 'renamed/$', 'rename should move cursor to the renamed directory')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    local home = assert(os.getenv'HOME')
    assert(vim.loop.fs_symlink(home, tmp .. '/home-link'))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local marks = api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    local has_home_link = false
    for _, mark in ipairs(marks) do
        local details = mark[4]
        local virt_text = details.virt_text
        has_home_link = has_home_link
            or virt_text and virt_text[1] and virt_text[1][1] == '@ → ~'
                and details.hl_mode == 'combine'
    end
    assert(has_home_link, 'symlink virtual text should abbreviate home directory and combine highlights')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/target-dir', tonumber('755', 8)))
    touch(tmp .. '/target-dir/inside.txt')
    touch(tmp .. '/regular.txt')
    assert(vim.loop.fs_symlink(tmp .. '/target-dir', tmp .. '/dir-link'))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    assert_eq(vim.fn.maparg('gf', 'n', false, true).desc, 'Follow symlink')

    set_cursor_line('regular%.txt$')
    local cwd = state.cwd
    core.follow_symlink()
    assert_eq(state.cwd, cwd, 'follow symlink should ignore regular files')
    assert_eq(api.nvim_get_current_buf(), state.buf, 'follow symlink should keep Dora focused for regular files')

    set_cursor_line('dir%-link$')
    core.follow_symlink()
    assert_eq(state.cwd, fs.realpath(tmp .. '/target-dir'), 'follow symlink should navigate to directory targets')
    assert(vim.tbl_contains(lines(), 'inside.txt'), 'follow symlink should render the target directory contents')

    core.quit()
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
    local dora_buf = api.nvim_get_current_buf()
    set_cursor_line('file%-link$')
    core.follow_symlink()
    assert_eq(api.nvim_buf_get_name(0), fs.realpath(tmp .. '/target.txt'), 'follow symlink should open file targets')
    assert_eq(vim.fn.bufexists(dora_buf), 0, 'following a file symlink should close Dora')

    vim.cmd('bdelete!')
    vim.o.directory = old_directory
    assert_eq(vim.fn.delete(swap_dir, 'rf'), 0)
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/project', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/other', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/other/nested', tonumber('755', 8)))

    local other_win = api.nvim_get_current_win()
    clear_persisted_view_state(other_win)
    vim.cmd('new')
    local bookmark_win = api.nvim_get_current_win()
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

    api.nvim_feedkeys('a', 't', false)
    set_map.callback()
    assert_eq(state.bookmarks.paths.a, root, 'ma should bookmark the current directory')

    set_cursor_line('^other/$')
    core.expand()
    assert(state.expanded_dirs[root .. '/other'], 'setup should expand a directory before quitting')

    set_cursor_line('^project/$')
    core.open()
    assert_eq(state.cwd, project)
    assert_eq(state.bookmarks.previous_directory, root, 'directory changes should update the builtin bookmark')

    api.nvim_feedkeys('b', 't', false)
    set_map.callback()
    assert_eq(state.bookmarks.paths.b, project, 'mb should bookmark the new current directory')

    local old_open = keymaps.open_hint_window
    local captured_prefix
    local captured_rows
    keymaps.open_hint_window = function(prefix, rows)
        captured_prefix = prefix
        captured_rows = rows
        return old_open(prefix, rows)
    end
    vim.defer_fn(function()
        api.nvim_feedkeys('a', 't', false)
    end, 250)
    jump_map.callback()
    assert_eq(state.cwd, root, "'a should jump to bookmark a")
    assert_eq(state.bookmarks.previous_directory, project, 'jumping to a bookmark should update the previous directory')
    assert_eq(captured_prefix, "'", 'delayed bookmark jumps should open mark hints')
    assert_eq(captured_rows[1].lhs, "''")
    assert_eq(captured_rows[2].lhs, "'a")
    assert_eq(captured_rows[3].lhs, "'b")

    captured_prefix = nil
    api.nvim_feedkeys("'", 't', false)
    jump_map.callback()
    assert_eq(state.cwd, project, "'' should jump to the previous directory")
    assert_eq(state.bookmarks.previous_directory, root, "'' should toggle the previous directory")
    assert_eq(captured_prefix, nil, "fast bookmark jumps should not open mark hints")
    keymaps.open_hint_window = old_open

    local old_notify = vim.notify
    local notification
    vim.notify = function(msg)
        notification = msg
    end
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 't', false)
    jump_map.callback()
    vim.notify = old_notify
    assert_eq(notification, nil, "escape should cancel a bookmark jump without notifying")

    core.help()
    local help_lines = api.nvim_buf_get_lines(0, 0, -1, false)
    local help_text = table.concat(help_lines, '\n')
    local navigation_line = find_line_index(help_lines, '^Navigation$')
    assert(navigation_line, 'help should include a navigation section')
    assert(not find_line_index(help_lines, '^Bookmarks$'), 'help should not include a bookmarks section')
    assert(navigation_line < find_line_index(help_lines, "^  m%s+Set bookmark$"),
        'help should show bookmark mappings under the navigation title')
    assert(find_line_index(help_lines, "^  '%s+Jump to bookmark$") < find_line_index(help_lines, "^  ''%s+Jump to previous directory$"),
        'help should show saved bookmark targets after bookmark mappings')
    assert(help_text:find("''", 1, true), "help should include the builtin previous-directory bookmark")
    assert(help_text:find("'a", 1, true), 'help should include bookmark a')
    assert(help_text:find("'b", 1, true), 'help should include bookmark b')
    assert(help_text:find(root, 1, true), 'help should include the bookmarked root directory')
    assert(help_text:find(project, 1, true), 'help should include the bookmarked project directory')

    api.nvim_feedkeys('q', 'xt', false)
    core.quit()

    vim.cmd('Dora ' .. vim.fn.fnameescape(project))
    local reopened_state = store.get()
    assert_eq(reopened_state.bookmarks.paths.a, root,
        'reopening Dora should preserve bookmark a')
    assert_eq(reopened_state.bookmarks.paths.b, project,
        'reopening Dora should preserve bookmark b')
    assert_eq(reopened_state.bookmarks.previous_directory, root,
        "reopening Dora in the same window should preserve the '' bookmark")
    api.nvim_feedkeys("'", 't', false)
    jump_map = vim.fn.maparg("'", 'n', false, true)
    jump_map.callback()
    assert_eq(reopened_state.cwd, root, "'' should jump to the previous view after reopening Dora")
    assert_eq(reopened_state.bookmarks.previous_directory, project,
        "'' should keep toggling after reopening Dora")
    assert(reopened_state.expanded_dirs[root .. '/other'],
        'reopening Dora in the same window should preserve expanded directories')
    assert(find_line_index(lines(), '^└── nested/$'),
        'restored expanded directories should be visible after returning to their parent')
    set_cursor_line('^other/$')
    core.collapse_recursive()
    assert_eq(reopened_state.expanded_dirs[root .. '/other'], nil)
    core.quit()

    vim.cmd('Dora ' .. vim.fn.fnameescape(root))
    assert_eq(store.get().expanded_dirs[root .. '/other'], nil,
        'collapsed directories should remain collapsed after reopening Dora')
    core.quit()

    api.nvim_set_current_win(other_win)
    vim.cmd('Dora ' .. vim.fn.fnameescape(project))
    local other_state = store.get()
    assert_eq(other_state.bookmarks.paths.a, root,
        'bookmark a should be shared with another window')
    assert_eq(other_state.bookmarks.paths.b, project,
        'bookmark b should be shared with another window')
    assert_eq(other_state.bookmarks.previous_directory, nil,
        "the '' bookmark should not be shared with another window")
    assert_eq(other_state.expanded_dirs[root .. '/other'], nil,
        'expanded directories should not be shared with another window')
    core.quit()

    api.nvim_set_current_win(bookmark_win)
    vim.cmd('close!')
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local origin_win = api.nvim_get_current_win()
    local buf, win = keymaps.open_hint_window('z', {
        {lhs='za', desc='Alpha'},
        {lhs='zx', desc='Xray'},
    })
    assert_eq(api.nvim_get_current_win(), origin_win, 'keymap hints should not take focus')
    local cfg = api.nvim_win_get_config(win)
    assert_eq(cfg.focusable, false, 'keymap hints should be non-focusable')
    assert_eq(cfg.relative, 'win', 'keymap hints should be relative to the current window')
    assert_eq(cfg.win, origin_win, 'keymap hints should anchor to the current window')
    assert_eq(cfg.anchor, 'SE', 'keymap hints should anchor to the bottom right')
    assert_eq(cfg.row, api.nvim_win_get_height(origin_win) - 1, 'keymap hints should sit near the bottom')
    assert_eq(cfg.col, api.nvim_win_get_width(origin_win) - 2, 'keymap hints should sit near the right edge')
    assert_eq(cfg.border[1], '╭', 'keymap hints should have a border')
    assert_match(vim.wo[win].winhighlight, 'FloatBorder:DoraPromptBorder')
    assert_eq(cfg.title, nil, 'keymap hints should not have a title')
    local hint_lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local hint_text = table.concat(hint_lines, '\n')
    assert(hint_text:match('za%s+→%s+Alpha'), 'keymap hints should include the first custom mapping')
    assert(hint_text:match('zx%s+→%s+Xray'), 'keymap hints should include the second custom mapping')

    local marks = api.nvim_buf_get_extmarks(buf, -1, 0, -1, {details=true})
    local has_key, has_arrow, has_desc = false, false, false
    for _, mark in ipairs(marks) do
        local hl = mark[4].hl_group
        has_key = has_key or hl == 'DoraInfoLabel'
        has_arrow = has_arrow or hl == 'DoraKeymapHintArrow'
        has_desc = has_desc or hl == 'DoraInfoValue'
    end
    assert(has_key, 'keymap hints should highlight keys')
    assert(has_arrow, 'keymap hints should highlight arrows')
    assert(has_desc, 'keymap hints should highlight descriptions')
    window.close(buf, win)
end

do
    local buf, win = keymaps.open_hint_window('y', {
        {lhs='yF', desc='Yank filename to clipboard'},
        {lhs='yf', desc='Yank filename'},
        {lhs='yB', desc='Yank basename to clipboard'},
        {lhs='yb', desc='Yank basename'},
        {lhs='yY', desc='Yank full path to clipboard'},
        {lhs='yy', desc='Yank full path'},
        {lhs='yD', desc='Yank directory path to clipboard'},
        {lhs='yd', desc='Yank directory path'},
    })
    local hint_lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    assert_match(hint_lines[1], '^  yy%s+→%s+Yank full path%s+yY%s+→%s+Yank full path to clipboard$')
    assert_match(hint_lines[2], '^  yd%s+→%s+Yank directory path%s+yD%s+→%s+Yank directory path to clipboard$')
    assert_match(hint_lines[3], '^  yf%s+→%s+Yank filename%s+yF%s+→%s+Yank filename to clipboard$')
    assert_match(hint_lines[4], '^  yb%s+→%s+Yank basename%s+yB%s+→%s+Yank basename to clipboard$')
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
    api.nvim_feedkeys('a', 't', false)
    prefix_map.callback()
    assert_eq(vim.g.dora_smoke_hint_keymap, 'za', 'keymap hints should dispatch legacy string actions')
    assert_eq(captured_prefix, nil, 'fast keymap sequences should not open the hint window')

    vim.g.dora_smoke_hint_keymap = nil
    vim.defer_fn(function()
        api.nvim_feedkeys('x', 't', false)
    end, 250)
    prefix_map.callback()
    assert_eq(vim.g.dora_smoke_hint_keymap, 'zx', 'delayed keymap sequences should still dispatch')
    assert_eq(captured_prefix, 'z')
    assert_eq(#captured_rows, 2)
    assert_eq(captured_rows[1].lhs, 'za')
    assert_eq(captured_rows[1].desc, 'Alpha')
    assert_eq(captured_rows[2].lhs, 'zx')
    assert_eq(captured_rows[2].desc, 'Xray')
    core.quit()

    keymaps.open_hint_window = old_open
    config.keymaps = old_keymaps
    config.show_keymap_hints = old_show_keymap_hints
end

do
    local old_keymaps = config.keymaps
    local old_show_keymap_hints = config.show_keymap_hints
    local old_open = keymaps.open_hint_window
    local captured_rows

    config.keymaps = {
        ['g?'] = {function() end, desc='Show help'},
        ['g.'] = {function() end, desc='Toggle hidden files'},
        gx = {function() end, desc='Open externally'},
        gh = {function() end, desc='Go to Home directory'},
        gf = {function() vim.g.dora_smoke_g_hint_keymap = 'gf' end, desc='Follow symlink'},
    }
    config.show_keymap_hints = true
    keymaps.open_hint_window = function(prefix, rows)
        captured_rows = rows
        return old_open(prefix, rows)
    end
    vim.g.dora_smoke_g_hint_keymap = nil

    vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
    local prefix_map = vim.fn.maparg('g', 'n', false, true)
    vim.defer_fn(function()
        api.nvim_feedkeys('f', 't', false)
    end, 250)
    prefix_map.callback()
    assert_eq(vim.g.dora_smoke_g_hint_keymap, 'gf', 'g keymap hints should dispatch selected mappings')
    assert_eq(captured_rows[1].lhs, 'gf')
    assert_eq(captured_rows[2].lhs, 'gh')
    assert_eq(captured_rows[3].lhs, 'gx')
    assert_eq(captured_rows[4].lhs, 'g.')
    assert_eq(captured_rows[5].lhs, 'g?')
    core.quit()

    keymaps.open_hint_window = old_open
    config.keymaps = old_keymaps
    config.show_keymap_hints = old_show_keymap_hints
end

do
    local old_keymaps = config.keymaps
    local old_show_keymap_hints = config.show_keymap_hints
    local old_open = keymaps.open_hint_window
    local old_reload = core.reload

    config.keymaps = {
        za = 'reload',
    }
    config.show_keymap_hints = true
    local captured_rows
    core.reload = function()
        vim.g.dora_smoke_named_keymap = 'reload'
    end
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
        api.nvim_feedkeys('a', 't', false)
    end, 250)
    prefix_map.callback()
    assert_eq(vim.g.dora_smoke_named_keymap, 'reload', 'keymap hints should dispatch named core actions')
    assert_eq(captured_rows[1].desc, 'Reload listing',
        'named actions should inherit keymap hint descriptions')
    core.quit()

    keymaps.open_hint_window = old_open
    core.reload = old_reload
    config.keymaps = old_keymaps
    config.show_keymap_hints = old_show_keymap_hints
end

do
    local old_keymaps = config.keymaps
    local old_show_keymap_hints = config.show_keymap_hints
    local old_reload = core.reload

    config.keymaps = {
        x = {'reload', desc='Custom reload'},
    }
    config.show_keymap_hints = false
    core.reload = function()
        vim.g.dora_smoke_named_direct_keymap = 'reload'
    end
    vim.g.dora_smoke_named_direct_keymap = nil

    vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
    local map = vim.fn.maparg('x', 'n', false, true)
    assert_eq(map.desc, 'Custom reload', 'explicit descriptions should override action descriptions')
    assert_eq(type(map.callback), 'function')
    map.callback()
    assert_eq(vim.g.dora_smoke_named_direct_keymap, 'reload', 'direct keymaps should dispatch named core actions')
    core.quit()

    core.reload = old_reload
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
    core.quit()

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
    core.quit()

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

    core.sort_by('name_desc')
    assert_eq(state.sort_order, 'name_desc')
    assert_line_before('^dir10/$', '^dir2/$', 'reversed natural sort should reverse directory names')
    assert_line_before('^dir2/$', '^tiny%.bin$', 'reversed natural sort should keep directories before files')
    assert_line_before('^file10%.txt$', '^file2%.txt$', 'reversed natural sort should reverse file names')

    core.sort_by('size')
    assert_eq(state.sort_order, 'size')
    assert_line_before('^dir10/$', '^tiny%.bin$', 'size sort should keep directories before files')
    assert_line_before('^tiny%.bin$', '^alpha%.md$', 'size sort should order files by size')
    assert_line_before('^file2%.txt$', '^file10%.txt$', 'size sort should order larger files later')

    core.sort_by('size_desc')
    assert_eq(state.sort_order, 'size_desc')
    assert_line_before('^dir10/$', '^big%.log$', 'reversed size sort should keep directories before files')
    assert_line_before('^big%.log$', '^file10%.txt$', 'reversed size sort should order larger files first')
    assert_line_before('^file10%.txt$', '^file2%.txt$', 'reversed size sort should order smaller files later')

    core.sort_by('extension')
    assert_eq(state.sort_order, 'extension')
    assert_line_before('^tiny%.bin$', '^big%.log$', 'extension sort should order by extension')
    assert_line_before('^big%.log$', '^alpha%.md$', 'extension sort should order by extension')
    assert_line_before('^alpha%.md$', '^file2%.txt$', 'extension sort should order by extension')

    core.sort_by('extension_desc')
    assert_eq(state.sort_order, 'extension_desc')
    assert_line_before('^file2%.txt$', '^alpha%.md$', 'reversed extension sort should order by extension descending')
    assert_line_before('^alpha%.md$', '^big%.log$', 'reversed extension sort should order by extension descending')
    assert_line_before('^big%.log$', '^tiny%.bin$', 'reversed extension sort should order by extension descending')

    core.sort_by('modified')
    assert_eq(state.sort_order, 'modified')
    assert_line_before('^tiny%.bin$', '^file10%.txt$', 'modified sort should order older files first')
    assert_line_before('^file2%.txt$', '^big%.log$', 'modified sort should order newer files later')

    core.sort_by('modified_desc')
    assert_eq(state.sort_order, 'modified_desc')
    assert_line_before('^big%.log$', '^file2%.txt$', 'reversed modified sort should order newer files first')
    assert_line_before('^file10%.txt$', '^tiny%.bin$', 'reversed modified sort should order older files later')

    core.sort_by('created')
    assert_eq(state.sort_order, 'created')
    core.sort_by('created_desc')
    assert_eq(state.sort_order, 'created_desc')

    local prefix_map = vim.fn.maparg(',', 'n', false, true)
    api.nvim_feedkeys('s', 't', false)
    prefix_map.callback()
    assert_eq(state.sort_order, 'size', 'sort keymaps should work behind the comma prefix mapping')

    api.nvim_feedkeys('S', 't', false)
    prefix_map.callback()
    assert_eq(state.sort_order, 'size_desc', 'descending sort keymaps should dispatch renamed actions')

    core.quit()
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

    core.toggle_hidden_files()
    assert(not vim.tbl_contains(lines(), '.hidden'), 'hidden files should be hidden after toggling visibility')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/a')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    util.set_cursor_pos('a')
    core.toggle_cut()
    assert_eq(marked_path_count(state), 1)
    core.clear_marks()
    assert_eq(marked_path_count(state), 0, 'clear_marks should clear paste marks')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local old_unnamed = vim.fn.getreg('"')
    local old_unnamed_type = vim.fn.getregtype('"')
    local old_notify = vim.notify
    local notifications = {}
    vim.notify = function(msg, level)
        notifications[#notifications+1] = {msg = msg, level = level}
    end
    local had_clipboard, old_clipboard = pcall(api.nvim_get_var, 'clipboard')
    vim.g.clipboard = {
        name = 'dora-smoke',
        copy = {
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

    local augroup = api.nvim_create_augroup('dora-smoke-yank', {})
    api.nvim_create_autocmd('TextYankPost', {
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
    util.set_cursor_pos('dir')
    core.expand()
    set_cursor_line('archive%.tar%.gz$')
    local expected_path = fs.realpath(tmp) .. '/dir/archive.tar.gz'
    local expected_yank_text = current_line()

    local function yank_highlight_range()
        local yank_ns = assert(api.nvim_get_namespaces()['nvim.hlyank'])
        local marks = api.nvim_buf_get_extmarks(state.buf, yank_ns, 0, -1, {details=true})
        assert_eq(#marks, 1, 'visible yank should highlight one range')
        return marks[1][3], marks[1][4].end_col
    end

    local yank_filename_map = vim.fn.maparg('Y', 'n', false, true)
    assert_eq(yank_filename_map.desc, 'Yank filename')
    assert_eq(type(yank_filename_map.callback), 'function')
    local yank_cursor = api.nvim_win_get_cursor(0)
    yank_filename_map.callback()
    assert_eq(vim.fn.getreg('"'), 'archive.tar.gz')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked filename: archive.tar.gz')
    assert_eq(vim.g.dora_smoke_yankpost_text, 'archive.tar.gz')
    assert_eq(api.nvim_win_get_cursor(0)[1], yank_cursor[1])
    assert_eq(api.nvim_win_get_cursor(0)[2], yank_cursor[2], 'filename yank should preserve the cursor')
    local row = state.rows[api.nvim_win_get_cursor(0)[1]]
    local filename_col = row.name_end_col - #row.name
    local start_col, end_col = yank_highlight_range()
    assert_eq(start_col, filename_col, 'filename yank should highlight only the filename')
    assert_eq(end_col, filename_col + #'archive.tar.gz', 'filename yank should highlight the full filename')

    core.yank_file_path()
    assert_eq(vim.fn.getreg('"'), expected_path)
    assert_eq(notifications[#notifications].msg, 'dora: Yanked file path: ' .. expected_path)
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)
    assert_eq(vim.g.dora_smoke_yankpost_operator, 'y')
    assert_eq(vim.g.dora_smoke_yankpost_regname, '')
    assert_eq(vim.g.dora_smoke_yankpost_text, expected_yank_text)

    vim.g.dora_smoke_yankpost_operator = nil
    vim.g.dora_smoke_yankpost_regname = nil
    vim.g.dora_smoke_yankpost_text = nil
    core.yank_file_path_clipboard()
    assert_eq(vim.fn.getreg('+'), expected_path)
    assert_eq(notifications[#notifications].msg, 'dora: Yanked file path to clipboard: ' .. expected_path)
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)
    assert_eq(vim.g.dora_smoke_yankpost_operator, 'y')
    assert_eq(vim.g.dora_smoke_yankpost_regname, '+')
    assert_eq(vim.g.dora_smoke_yankpost_text, expected_yank_text)

    core.yank_dir_path()
    assert_eq(vim.fn.getreg('"'), fs.realpath(tmp) .. '/dir')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked directory path: ' .. fs.realpath(tmp) .. '/dir')

    core.yank_dir_path_clipboard()
    assert_eq(vim.fn.getreg('+'), fs.realpath(tmp) .. '/dir')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked directory path to clipboard: ' .. fs.realpath(tmp) .. '/dir')

    core.yank_filename()
    assert_eq(vim.fn.getreg('"'), 'archive.tar.gz')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked filename: archive.tar.gz')
    start_col, end_col = yank_highlight_range()
    assert_eq(start_col, filename_col)
    assert_eq(end_col, filename_col + #'archive.tar.gz')

    core.yank_filename_clipboard()
    assert_eq(vim.fn.getreg('+'), 'archive.tar.gz')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked filename to clipboard: archive.tar.gz')

    core.yank_basename()
    assert_eq(vim.fn.getreg('"'), 'archive.tar')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked basename: archive.tar')
    assert_eq(vim.g.dora_smoke_yankpost_text, 'archive.tar')
    start_col, end_col = yank_highlight_range()
    assert_eq(start_col, filename_col, 'basename yank should start at the filename')
    assert_eq(end_col, filename_col + #'archive.tar', 'basename yank should exclude the final extension')

    core.yank_basename_clipboard()
    assert_eq(vim.fn.getreg('+'), 'archive.tar')
    assert_eq(notifications[#notifications].msg, 'dora: Yanked basename to clipboard: archive.tar')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
    api.nvim_del_augroup_by_id(augroup)
    vim.fn.setreg('"', old_unnamed, old_unnamed_type)
    if had_clipboard then
        vim.g.clipboard = old_clipboard
    else
        pcall(api.nvim_del_var, 'clipboard')
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
    vim.notify = function(msg, level)
        notifications[#notifications+1] = {msg = msg, level = level}
    end

    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/a')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local expected_path = fs.realpath(tmp) .. '/a'
    vim.ui.open = function(path)
        vim.g.dora_smoke_open_external_path = path
    end
    core.open_external()
    assert_eq(vim.g.dora_smoke_open_external_path, expected_path)
    assert_eq(notifications[#notifications].msg, 'dora: Opening a')
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)

    vim.ui.open = function()
        error('boom')
    end
    core.open_external()
    assert_match(notifications[#notifications].msg, '^dora: Could not open externally: ')
    assert_eq(notifications[#notifications].level, vim.log.levels.ERROR)

    core.quit()
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
    local origin_win = api.nvim_get_current_win()
    local origin_line = api.nvim_win_get_cursor(origin_win)[1]
    local origin_text = api.nvim_get_current_line()
    local name_col = assert(origin_text:find('alpha.txt', 1, true)) - 1
    local anchor_pos = vim.fn.screenpos(origin_win, origin_line, name_col + 1)
    core.info()
    local info_win = api.nvim_get_current_win()
    local info_buf = api.nvim_get_current_buf()
    local info_cfg = api.nvim_win_get_config(info_win)
    local info_lines = api.nvim_buf_get_lines(info_buf, 0, -1, false)
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

    local marks = api.nvim_buf_get_extmarks(info_buf, -1, 0, -1, {details=true})
    local has_label, has_value = false, false
    for _, mark in ipairs(marks) do
        local hl = mark[4].hl_group
        has_label = has_label or hl == 'DoraInfoLabel'
        has_value = has_value or hl == 'DoraInfoValue'
    end
    assert(has_label, 'info should highlight labels')
    assert(has_value, 'info should highlight values')

    api.nvim_feedkeys('q', 'xt', false)
    assert_eq(api.nvim_get_current_win(), origin_win, 'closing info should restore origin window')
    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
    local origin_win = api.nvim_get_current_win()
    core.help()
    local help_win = api.nvim_get_current_win()
    local help_buf = api.nvim_get_current_buf()
    assert(help_win ~= origin_win, 'help should open in a floating window')
    local help_lines = api.nvim_buf_get_lines(help_buf, 0, -1, false)
    local help_cfg = api.nvim_win_get_config(help_win)
    assert_eq(help_cfg.height, math.min(#help_lines, math.max(1, vim.o.lines - 4)))
    assert_eq(vim.wo[help_win].cursorline, false, 'help should disable cursorline')
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
    local mouse_line = find_line_index(help_lines, '^  <2%-LeftMouse>%s+Open$')
    local enter_line = find_line_index(help_lines, '^  <CR>%s+Open$')
    local open_line = find_line_index(help_lines, '^  l%s+Open$')
    assert(mouse_line < enter_line and enter_line < open_line,
        'help should sort mappings for the same action alphabetically')
    assert(find_line_index(help_lines, "^  ''%s+Jump to previous directory$"),
        "help should always include the builtin previous-directory bookmark")
    local general_line = find_line_index(help_lines, '^General$') - 1
    local quit_line = find_line_index(help_lines, '^  q%s+Quit$') - 1
    local section_highlight, key_highlight = false, false
    for _, mark in ipairs(api.nvim_buf_get_extmarks(help_buf, -1, 0, -1, {details=true})) do
        if mark[2] == general_line and mark[4].hl_group == 'DoraHelpSection' then
            section_highlight = true
        elseif mark[2] == quit_line and mark[4].hl_group == 'DoraInfoLabel' then
            key_highlight = true
        end
    end
    assert(section_highlight, 'help should use a dedicated highlight for section titles')
    assert(key_highlight, 'help should keep key labels visually distinct from section titles')

    api.nvim_feedkeys('q', 'xt', false)
    assert_eq(api.nvim_get_current_win(), origin_win, 'closing help should restore origin window')
    core.quit()
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
    core.help()
    local help_lines = api.nvim_buf_get_lines(0, 0, -1, false)
    local help_text = table.concat(help_lines, '\n')
    assert(help_text:match("x%s+<Cmd>lua vim%.g%.dora_smoke_legacy_keymap = 'normal'<CR>"), 'help should include legacy normal mappings')
    assert(find_line_index(help_lines, '^Yank$') < find_line_index(help_lines, '^  n%s+Yank full path$'),
        'help should categorize remapped built-in actions by action name')
    assert(find_line_index(help_lines, '^Other$'), 'help should group custom mappings under Other')
    assert(find_line_index(help_lines, "^  x%s+<Cmd>lua vim%.g%.dora_smoke_legacy_keymap = 'normal'<CR>$") < find_line_index(help_lines, '^  z%s+Normal Z$'),
        'help should sort custom mappings by key')
    api.nvim_feedkeys('q', 'xt', false)
    core.quit()

    config.keymaps = old_keymaps
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    assert_eq(vim.fn.maparg('J', 'x', false, true).desc, 'Last sibling')
    assert_eq(type(vim.fn.maparg('J', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('K', 'x', false, true).desc, 'First sibling')
    assert_eq(type(vim.fn.maparg('K', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('>', 'x', false, true).desc, 'Next sibling')
    assert_eq(type(vim.fn.maparg('>', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('<', 'x', false, true).desc, 'Previous sibling')
    assert_eq(type(vim.fn.maparg('<', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('d', 'x', false, true).desc, 'Move file to trash')
    assert_eq(type(vim.fn.maparg('d', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('D', 'x', false, true).desc, 'Delete file permanently')
    assert_eq(type(vim.fn.maparg('D', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('<Tab>', 'x'), '', 'visual Tab should not be mapped')

    core.quit()
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
    local state = store.get()

    util.set_cursor_pos('alpha')
    core.expand()
    set_cursor_line('nested/$')
    core.expand()

    util.set_cursor_pos('alpha')
    core.next_sibling()
    assert_eq(current_line(), 'beta/', 'next sibling should jump to the next root sibling')
    core.next_sibling()
    assert_eq(current_line(), 'top.txt', 'next sibling should include file siblings')
    core.next_sibling()
    assert_eq(current_line(), 'alpha/', 'next sibling should wrap from the last root sibling to the first')
    core.prev_sibling()
    assert_eq(current_line(), 'top.txt', 'previous sibling should wrap from the first root sibling to the last')
    core.prev_sibling()
    assert_eq(current_line(), 'beta/', 'previous sibling should jump to the previous sibling')
    core.prev_sibling()
    assert_eq(current_line(), 'alpha/', 'previous sibling should jump to the previous root sibling')

    core.last_sibling()
    assert_eq(current_line(), 'top.txt', 'last sibling should jump to the last root sibling')
    core.last_sibling()
    assert_eq(current_line(), 'top.txt', 'last sibling should stay on the last sibling')
    core.first_sibling()
    assert_eq(current_line(), 'alpha/', 'first sibling should jump to the first root sibling')
    core.first_sibling()
    assert_eq(current_line(), 'alpha/', 'first sibling should stay on the first sibling')

    set_cursor_line('nested/$')
    core.prev_sibling()
    assert_match(current_line(), 'file%.txt$', 'previous sibling should wrap from the first child sibling to the last')

    set_cursor_line('nested/$')
    core.next_sibling()
    assert_match(current_line(), 'file%.txt$', 'next sibling should jump to the next nested sibling')
    core.prev_sibling()
    assert_match(current_line(), 'nested/$', 'previous sibling should jump to the previous nested sibling')
    core.next_sibling()
    assert_match(current_line(), 'file%.txt$', 'next sibling should jump to the next nested sibling')
    core.next_sibling()
    assert_match(current_line(), 'nested/$', 'next sibling should wrap from the last child sibling to the first')
    core.prev_sibling()
    assert_match(current_line(), 'file%.txt$', 'previous sibling should wrap from the first child sibling to the last')
    core.first_sibling()
    assert_match(current_line(), 'nested/$', 'first sibling should jump to the first child sibling')
    core.last_sibling()
    assert_match(current_line(), 'file%.txt$', 'last sibling should jump to the last child sibling')

    set_cursor_line('deep%.txt$')
    core.prev_sibling()
    assert_match(current_line(), 'deep%.txt$', 'previous sibling should stay on an only child sibling')
    core.next_sibling()
    assert_match(current_line(), 'deep%.txt$', 'next sibling should stay on an only child sibling')
    core.first_sibling()
    assert_match(current_line(), 'deep%.txt$', 'first sibling should stay on an only child sibling')
    core.last_sibling()
    assert_match(current_line(), 'deep%.txt$', 'last sibling should stay on an only child sibling')

    core.quit()
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

    util.set_cursor_pos('root')
    core.expand_recursive()
    assert(vim.tbl_contains(lines(), '├ a/'), 'custom tree indentation should apply to child directories')
    assert(vim.tbl_contains(lines(), '│ └ b/'), 'custom tree indentation should apply to nested directories')
    assert(vim.tbl_contains(lines(), '│   └ file.txt'), 'custom tree indentation should apply to nested files')
    assert(vim.tbl_contains(lines(), '└ empty/'), 'custom tree indentation should apply to last children')
    assert(vim.tbl_contains(lines(), '  └ (empty)'), 'custom tree indentation should apply to empty placeholders')
    assert(state.expanded_dirs[root .. '/root'], 'recursive expand should expand selected directory')
    assert(state.expanded_dirs[root .. '/root/a'], 'recursive expand should expand descendants')
    assert(state.expanded_dirs[root .. '/root/a/b'], 'recursive expand should expand nested descendants')
    assert(state.expanded_dirs[root .. '/root/empty'], 'recursive expand should expand empty descendants')

    util.set_cursor_pos('root')
    core.collapse_recursive()
    assert(not state.expanded_dirs[root .. '/root'], 'recursive collapse should clear selected directory')
    assert(not state.expanded_dirs[root .. '/root/a'], 'recursive collapse should clear descendants')
    assert(not state.expanded_dirs[root .. '/root/a/b'], 'recursive collapse should clear nested descendants')
    assert(not state.expanded_dirs[root .. '/root/empty'], 'recursive collapse should clear empty descendants')
    assert(not vim.tbl_contains(lines(), '├ a/'), 'recursive collapse should hide children')

    core.expand()
    assert(vim.tbl_contains(lines(), '├ a/'), 'expand after recursive collapse should show one level')
    assert(not vim.tbl_contains(lines(), '│ └ b/'), 'expand after recursive collapse should not restore recursive state')

    core.quit()
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

    util.set_cursor_pos('alpha')
    core.expand()
    assert(vim.tbl_contains(lines(), '├── one/'), 'first expand should show alpha children')
    assert(vim.tbl_contains(lines(), '└── two/'), 'first expand should show all alpha children')
    assert(not vim.tbl_contains(lines(), '│   └── file.txt'), 'first expand should not expand grandchildren')
    assert(has_highlight(state, 'DoraDirectory'), 'directory rows should be highlighted')
    assert(has_priority_highlight(state, 'DoraFile', 100), 'file row highlights should not cover yank highlights')
    assert(has_high_priority_highlight(state, 'DoraTree'), 'tree prefixes should be highlighted')
    assert(has_high_priority_highlight(state, 'DoraVirtText'), 'directory suffixes should be highlighted')

    set_cursor_line('one/$')
    assert_cursor_tree_highlights(state, 2)
    assert_eq(state.rows[api.nvim_win_get_cursor(0)[1]].tree_connector_start_col, 0)

    core.expand()
    assert(vim.tbl_contains(lines(), '│   └── file.txt'), 'second expand should expand another level')
    assert_cursor_tree_highlights(state, 3)

    set_cursor_line('file%.txt$')
    assert_cursor_tree_highlights(state, 1)
    assert(state.rows[api.nvim_win_get_cursor(0)[1]].tree_connector_start_col > 0)
    core.toggle_copy()
    assert_eq(state.marked_paths[root .. '/alpha/one/file.txt'], 'copy', 'nested row should mark its real path')

    util.set_cursor_pos('alpha')
    core.collapse()
    assert(vim.tbl_contains(lines(), '├── one/'), 'collapse should keep the hovered directory open')
    assert(vim.tbl_contains(lines(), '└── two/'), 'collapse should keep shallow descendants visible')
    assert(not vim.tbl_contains(lines(), '│   └── file.txt'), 'collapse should hide the deepest visible level')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapse should leave the hovered directory expanded')
    assert(not state.expanded_dirs[root .. '/alpha/one'], 'collapse should fold deepest expanded descendants')

    core.expand()
    assert(vim.tbl_contains(lines(), '│   └── file.txt'), 're-expand should restore previous tree state')

    set_cursor_line('file%.txt$')
    core.collapse()
    assert(not vim.tbl_contains(lines(), '│   └── file.txt'), 'collapsing file should hide sibling rows below its parent directory')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapsing file should leave grandparent expanded')
    assert(not state.expanded_dirs[root .. '/alpha/one'], 'collapsing file should fold its parent directory')
    assert_match(current_line(), 'one/$', 'collapsing file should move cursor to its parent directory')

    core.collapse()
    assert(vim.tbl_contains(lines(), '├── one/'), 'collapsing a directory with no visible descendants should be a no-op')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapsing a directory with no visible descendants should leave ancestors expanded')
    assert_match(current_line(), 'one/$', 'collapsing a directory with no visible descendants should keep the cursor')

    util.set_cursor_pos('alpha')
    core.collapse()
    assert(vim.tbl_contains(lines(), '├── one/'), 'collapse should remove the deepest remaining descendant level first')
    assert(vim.tbl_contains(lines(), '└── two/'), 'collapse should keep shallow descendants visible')
    assert(not vim.tbl_contains(lines(), '    └── (empty)'), 'collapse should hide empty placeholders at the deepest level')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapse should leave the hovered directory expanded while descendants remain visible')
    assert(not state.expanded_dirs[root .. '/alpha/two'], 'collapse should fold deepest empty descendants')

    core.collapse()
    assert(not vim.tbl_contains(lines(), '├── one/'), 'collapsing one visible level should fold the hovered directory')
    assert(not state.expanded_dirs[root .. '/alpha'], 'collapsing one visible level should clear the hovered directory expansion')
    assert_match(current_line(), 'alpha/$', 'collapsing one visible level should keep cursor on the hovered directory')

    core.expand()
    core.expand()
    assert(vim.tbl_contains(lines(), '│   └── file.txt'), 'recursive state should be restorable after parent fallback collapse')

    set_cursor_line('one/$')
    core.collapse()
    assert(not vim.tbl_contains(lines(), '│   └── file.txt'), 'collapsing child should hide child contents')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapsing child should leave parent expanded')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/empty', tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    util.set_cursor_pos('empty')
    core.expand()
    assert(vim.tbl_contains(lines(), '└── (empty)'), 'empty directories should render a placeholder')
    assert(has_highlight(state, 'DoraTree'), 'empty placeholder should be highlighted as tree text')

    util.set_cursor_pos('empty')
    core.collapse()
    assert(not vim.tbl_contains(lines(), '└── (empty)'), 'collapsing empty directory should hide placeholder')

    core.quit()
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

    util.set_cursor_pos('unreadable')
    local ok, msg = pcall(core.expand)
    fs.list = old_list
    assert(ok, msg)
    assert(vim.tbl_contains(lines(), '└── (not permitted)'), 'unreadable directories should render a placeholder')

    core.quit()
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
    local origin_win = api.nvim_get_current_win()
    assert_eq(vim.fn.maparg('f', 'n', false, true).desc, 'Filter visible files')
    assert_eq(vim.fn.maparg('F', 'n', false, true).desc, 'Clear filter')

    util.set_cursor_pos('alpha')
    core.expand()
    util.set_cursor_pos('gamma')
    core.expand()

    api.nvim_win_set_cursor(origin_win, {#state.rows, 0})
    api.nvim_win_call(origin_win, function()
        vim.cmd'normal! zt'
    end)
    local scrolled_view = api.nvim_win_call(origin_win, function()
        return vim.fn.winsaveview()
    end)
    assert(scrolled_view.topline > 1, 'filter test should begin with Dora scrolled down')

    core.filter()
    local filter = assert(state.filter_window)
    local filter_cfg = api.nvim_win_get_config(filter.win)
    assert_eq(api.nvim_get_current_win(), filter.win, 'filter should receive focus while editing')
    assert_eq(filter_cfg.relative, 'win', 'filter should be positioned relative to the Dora window')
    assert_eq(filter_cfg.win, origin_win, 'filter should be attached to the Dora window')
    assert_eq(filter_cfg.anchor, 'NW', 'filter should be anchored from its top-left corner')
    assert_eq(filter_cfg.row, 0, 'filter should be aligned with the top of Dora')
    assert_eq(filter_cfg.col, 0, 'filter should be aligned with the left of Dora')
    assert_eq(filter_cfg.border, 'none', 'filter should be borderless')
    assert_eq(win_title(filter.win), '', 'filter should not have a title')
    local prefix_marks = api.nvim_buf_get_extmarks(filter.buf, filter.ns, 0, -1, {details = true})
    assert_eq(#prefix_marks, 1, 'filter should render one prefix')
    assert_eq(prefix_marks[1][4].virt_text[1][1], 'Filter›')
    assert_eq(prefix_marks[1][4].virt_text_pos, 'inline')
    assert_eq(prefix_marks[1][4].right_gravity, false)
    local spacer_marks = vim.tbl_filter(function(mark)
        return mark[4].virt_lines ~= nil
    end, api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true}))
    assert_eq(#spacer_marks, 1, 'filter should add one virtual spacer above the results')
    assert_eq(#spacer_marks[1][4].virt_lines, 1, 'filter spacer should be exactly one line')
    assert_eq(spacer_marks[1][4].virt_lines_above, true)

    filter:set_input('MATCH')
    local filtered_view = api.nvim_win_call(origin_win, function()
        return vim.fn.winsaveview()
    end)
    assert_eq(api.nvim_get_current_win(), filter.win, 'live filtering should keep focus in the filter window')
    assert_eq(api.nvim_win_get_cursor(origin_win)[1], 1, 'live filtering should move Dora to the first result')
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
    for _, mark in ipairs(api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})) do
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
    assert_eq(api.nvim_get_current_win(), origin_win, 'confirming should return focus to Dora')
    assert_eq(state.filter_text, 'MATCH')
    assert_eq(state.filter_preview, nil)
    assert_eq(state.filter_window, filter, 'confirming should retain the filter window')
    assert_eq(state.filter_editing, false)
    assert(window.valid_win(filter.win), 'confirming should keep the filter window visible')
    assert_eq(vim.bo[filter.buf].modifiable, false, 'confirming should lock the filter input')
    local remaining_spacers = vim.tbl_filter(function(mark)
        return mark[4].virt_lines ~= nil
    end, api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true}))
    assert_eq(#remaining_spacers, 1, 'confirming should retain the virtual spacer')
    local locked_view = api.nvim_win_call(origin_win, function()
        return vim.fn.winsaveview()
    end)
    assert_eq(locked_view.topline, 1, 'confirming should keep results at the top')
    assert_eq(locked_view.topfill, 1, 'confirming should keep the virtual spacer visible')
    assert_eq(current_line(), 'alpha/match.txt', 'confirming should select the first result')

    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
    local escaped_view = api.nvim_win_call(origin_win, function()
        return vim.fn.winsaveview()
    end)
    assert_eq(escaped_view.topfill, 1, 'escape should keep the virtual spacer visible')

    core.toggle_copy()
    assert_eq(state.marked_paths[fs.realpath(tmp) .. '/alpha/match.txt'], 'copy',
        'actions on filtered rows should use their real paths')
    core.next_sibling()
    assert_eq(current_line(), 'gamma/match.txt', 'filtered navigation should treat results as peers')
    core.last_sibling()
    assert_eq(current_line(), 'root-MATCH.txt', 'filtered last-sibling navigation should reach the final result')
    core.first_sibling()
    assert_eq(current_line(), 'alpha/match.txt', 'filtered first-sibling navigation should reach the first result')

    set_cursor_line('root%-MATCH%.txt$')
    core.filter()
    local reopened_filter = assert(state.filter_window)
    assert_eq(reopened_filter, filter, 'reopening should reuse the visible filter window')
    assert_eq(api.nvim_get_current_win(), reopened_filter.win, 'reopening should focus the filter window')
    assert_eq(reopened_filter:get_input(), 'MATCH', 'reopening should preload the committed filter')
    assert_eq(api.nvim_win_get_cursor(reopened_filter.win)[2], #'MATCH',
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
    local cancelled_view = api.nvim_win_call(origin_win, function()
        return vim.fn.winsaveview()
    end)
    assert_eq(cancelled_view.topline, 1, 'cancel should keep results at the top')
    assert_eq(cancelled_view.topfill, 1, 'cancel should keep the virtual spacer visible')

    core.filter()
    local dismissed_filter = assert(state.filter_window)
    dismissed_filter:set_input('other')
    api.nvim_win_close(dismissed_filter.win, true)
    assert(vim.wait(1000, function()
        return state.filter_window == nil
    end), 'externally closing the filter window should clear its handle')
    assert_eq(state.filter_text, 'MATCH', 'externally closing should preserve the committed filter')
    assert_eq(current_line(), 'root-MATCH.txt', 'externally closing should restore the previous result cursor')

    core.filter()
    local amended_filter = assert(state.filter_window)
    amended_filter:set_input('missing')
    assert_eq(#state.rows, 0, 'a filter with no matches should have no result rows')
    assert_eq(buf_lines(state.buf)[1], '', 'a filter with no matches should render a blank buffer')
    amended_filter:confirm()
    assert_eq(current_line(), '')
    assert(window.valid_win(amended_filter.win), 'confirming an amended filter should retain its window')
    core.clear_filter()
    assert_eq(state.filter_text, nil)
    assert_eq(state.filter_window, nil)
    assert(not window.valid_win(amended_filter.win), 'clearing should close the filter window')
    assert(vim.tbl_contains(lines(), 'alpha/'), 'clearing should restore the tree listing')

    core.filter()
    local cancelled_filter = assert(state.filter_window)
    cancelled_filter:set_input('other')
    cancelled_filter:cancel()
    assert_eq(state.filter_text, nil, 'cancelling a new filter should leave filtering disabled')
    assert_eq(state.filter_window, nil)
    assert(not window.valid_win(cancelled_filter.win), 'cancelling a new filter should close its window')

    core.filter()
    local empty_filter = assert(state.filter_window)
    empty_filter:set_input('match')
    empty_filter:set_input('')
    empty_filter:confirm()
    assert_eq(state.filter_text, nil, 'confirming an empty filter should clear filtering')
    assert_eq(state.filter_window, nil)
    assert(not window.valid_win(empty_filter.win), 'confirming an empty filter should hide its window')

    core.filter()
    local directory_filter = assert(state.filter_window)
    directory_filter:set_input('alpha')
    directory_filter:confirm()
    assert(window.valid_win(directory_filter.win), 'a committed directory filter should remain visible')
    assert_eq(current_line(), 'alpha/')
    core.open()
    assert_eq(state.cwd, fs.realpath(tmp .. '/alpha'), 'opening a filtered directory should navigate normally')
    assert_eq(state.filter_text, nil, 'directory navigation should clear the filter')
    assert_eq(state.filter_window, nil)
    assert(not window.valid_win(directory_filter.win), 'directory navigation should close the filter window')

    core.filter()
    local quit_filter = assert(state.filter_window)
    quit_filter:set_input('match')
    quit_filter:confirm()
    core.quit()
    assert(not window.valid_win(quit_filter.win), 'quitting Dora should close the filter window')
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
local state = store.get()
assert_eq(state.cwd, fs.realpath(cwd))
assert(api.nvim_buf_get_var(0, 'is_dora'), 'Dora buffer should be identified')
assert(#api.nvim_buf_get_lines(0, 0, -1, false) > 0, 'Dora buffer should render entries')
core.quit()

print('dora: smoke ok\n')
