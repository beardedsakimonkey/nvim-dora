local api = vim.api

local function assert_eq(actual, expected, msg)
    assert(actual == expected, msg or ('expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual)))
end

local function assert_match(str, pattern, msg)
    assert(str:match(pattern), msg or (vim.inspect(str) .. ' does not match ' .. vim.inspect(pattern)))
end

local fs = require'dirtree.fs'
local config = require'dirtree'.config
local delete_win = require'dirtree.delete_win'
local keymaps = require'dirtree.keymaps'
local prompt = require'dirtree.prompt'
local core = require'dirtree.core'
local store = require'dirtree.store'
local util = require'dirtree.util'
local window = require'dirtree.window'

local cwd = assert(vim.loop.cwd())

local function touch(path)
    local fd = assert(vim.loop.fs_open(path, 'w', tonumber('644', 8)))
    assert(vim.loop.fs_close(fd))
end

local function write_file(path, contents)
    local fd = assert(vim.loop.fs_open(path, 'w', tonumber('644', 8)))
    assert(vim.loop.fs_write(fd, contents, 0))
    assert(vim.loop.fs_close(fd))
end

local function read_file(path)
    local fd = assert(vim.loop.fs_open(path, 'r', tonumber('644', 8)))
    local stat = assert(vim.loop.fs_fstat(fd))
    local contents = assert(vim.loop.fs_read(fd, stat.size, 0))
    assert(vim.loop.fs_close(fd))
    return contents
end

local function selection_count(state)
    local count = 0
    for _ in pairs(state.selection) do
        count = count + 1
    end
    return count
end

local function lines()
    return api.nvim_buf_get_lines(0, 0, -1, false)
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
        if mark[4].hl_group == 'DirtreeTreeActive' then
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

    delete_win.delete(paths, tmp, function(confirmed)
        vim.g.dirtree_smoke_confirm_delete = confirmed
    end)
    local confirm_win = api.nvim_get_current_win()
    local confirm_buf = api.nvim_get_current_buf()
    local confirm_cfg = api.nvim_win_get_config(confirm_win)
    local confirm_lines = api.nvim_buf_get_lines(confirm_buf, 0, -1, false)

    assert_eq(confirm_cfg.border[1][2], 'DirtreePromptBorderInvalid')
    assert_match(vim.wo[confirm_win].winhighlight, 'Cursor:DirtreeDeleteCursor')
    assert_eq(vim.o.guicursor, 'a:block-DirtreeDeleteCursor')
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
            or details.hl_group == 'DirtreeDeletePath'
        has_file = has_file
            or row == 0 and col == 1 and details.end_col == 7 and details.hl_group == 'DirtreeFile'
        has_dir = has_dir
            or row == 1 and col == 1 and details.end_col == 4 and details.hl_group == 'DirtreeDirectory'
        has_dir_suffix = has_dir_suffix
            or row == 1 and col == 4 and details.end_col == 5 and details.hl_group == 'DirtreeVirtText'
        has_more = has_more
            or row == 10 and details.hl_group == 'DirtreeDeleteMore'
    end
    assert(not has_path, 'delete confirmation should not dim the path portion')
    assert(has_file, 'delete confirmation should highlight file names by type')
    assert(has_dir, 'delete confirmation should highlight directory names by type')
    assert(not has_dir_suffix, 'delete confirmation should leave directory suffixes normal')
    assert(has_more, 'delete confirmation should highlight the overflow row')

    api.nvim_feedkeys('n', 'xt', false)
    assert_eq(vim.g.dirtree_smoke_confirm_delete, false)
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
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/enter.txt')

    delete_win.delete({tmp .. '/enter.txt'}, tmp, function(confirmed)
        vim.g.dirtree_smoke_enter_confirm_delete = confirmed
    end)

    api.nvim_feedkeys('\r', 'xt', false)
    assert_eq(vim.g.dirtree_smoke_enter_confirm_delete, true)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
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
        vim.g.dirtree_smoke_input = input or 'nil'
        vim.g.dirtree_smoke_result = result or 'nil'
    end)
    ---@cast p DirtreePrompt

    local cfg = api.nvim_win_get_config(p.input_win)
    assert_eq(cfg.relative, 'editor')
    assert_eq(cfg.anchor, 'NW')
    assert_eq(cfg.border[1][1], '╭')
    assert_eq(type(vim.fn.maparg('<Esc>', 'i', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('<Esc>', 'i', false, true).expr, 1)
    assert_eq(type(vim.fn.maparg('<Esc>', 'n', false, true).callback), 'function')
    for _, map in ipairs(api.nvim_buf_get_keymap(p.input_buf, 'i')) do
        assert(map.lhs ~= '<Tab>', 'prompt should not map tab for completion')
    end

    p:set_input('bad', 3)
    p:redraw()
    assert_eq(p.is_valid, false)

    p:set_input('abc', 3)
    p:confirm()
    assert_eq(vim.g.dirtree_smoke_input, 'abc')
    assert_eq(vim.g.dirtree_smoke_result, 'abc-ok')
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
    ---@cast p DirtreePrompt

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
        prompt = 'Escape non-empty',
        cwd = cwd,
        validate = function(input)
            return input
        end,
    }, function(input)
        vim.g.dirtree_smoke_escape_non_empty = input == nil
    end)
    ---@cast p DirtreePrompt

    p:set_input('abc', 3)
    p:escape_insert()
    assert(not p.closed, 'escape with input should leave prompt open')
    p:cancel()
    assert_eq(vim.g.dirtree_smoke_escape_non_empty, true)
end

do
    local p = prompt.input({
        prompt = 'Escape empty',
        cwd = cwd,
        validate = function(input)
            return input
        end,
    }, function(input)
        vim.g.dirtree_smoke_escape_empty = input == nil
    end)
    ---@cast p DirtreePrompt

    p:set_input('', 0)
    p:escape_insert()
    assert(p.closed, 'escape with empty input should close prompt')
    assert_eq(vim.g.dirtree_smoke_escape_empty, true)
end

do
    local p = prompt.input({
        prompt = 'Escape typed input',
        cwd = cwd,
        validate = function(input)
            return input
        end,
    }, function(input)
        vim.g.dirtree_smoke_escape_typed = input == nil
    end)
    ---@cast p DirtreePrompt

    api.nvim_feedkeys(api.nvim_replace_termcodes('ix<Esc>', true, false, true), 'xt', false)
    assert(vim.wait(1000, function()
        return p:get_input() == 'x' and vim.api.nvim_get_mode().mode == 'n'
    end), 'escape after typed input should leave insert mode')
    assert(not p.closed, 'escape after typed input should leave prompt open')
    p:cancel()
    assert_eq(vim.g.dirtree_smoke_escape_typed, true)
end

do
    local p = prompt.input({
        prompt = 'Escape key empty',
        cwd = cwd,
        validate = function(input)
            return input
        end,
    }, function(input)
        vim.g.dirtree_smoke_escape_key_empty = input == nil
    end)
    ---@cast p DirtreePrompt

    api.nvim_feedkeys(api.nvim_replace_termcodes('i<Esc>', true, false, true), 'xt', false)
    assert(vim.wait(1000, function()
        return p.closed and vim.api.nvim_get_mode().mode == 'n'
    end), 'escape with empty input should close prompt via keypress')
    assert_eq(vim.g.dirtree_smoke_escape_key_empty, true)
end

do
    local p = prompt.input({
        prompt = 'Cancel',
        cwd = cwd,
        validate = function(input)
            return input
        end,
    }, function(input)
        vim.g.dirtree_smoke_cancelled = input == nil
    end)
    ---@cast p DirtreePrompt

    p:cancel()
    assert_eq(vim.g.dirtree_smoke_cancelled, true)
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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.width, 32, 'create prompt should match the default delete window width')
        local path = opts.validate('foo/bar.txt')
        cb('foo/bar.txt', path)
    end
    core.create()
    prompt.input = old_input

    assert(fs.exists(tmp .. '/foo/bar.txt'), 'create should create a nested file path')
    assert(vim.tbl_contains(lines(), 'foo/'), 'create should render the new top-level parent')

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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('root')
    core.expand()
    set_cursor_line('child/$')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.default, 'root/', 'create should prefill the hovered directory parent path')
        local input = opts.default .. 'file.txt'
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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('root')
    core.expand_recursive()
    set_cursor_line('existing%.txt$')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.default, 'root/child/', 'create should prefill the hovered file parent path')
        local input = opts.default .. 'sibling.txt'
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
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/alpha', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/beta', tonumber('755', 8)))
    touch(tmp .. '/alpha/duplicate.txt')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('alpha')
    core.expand()
    util.set_cursor_pos('beta')
    core.expand()

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.default, nil, 'create should not prefill a root-level directory path')
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
    touch(tmp .. '/anchor.txt')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    util.set_cursor_pos('anchor%.txt')
    local cursor = api.nvim_win_get_cursor(0)
    local row = state.rows[cursor[1]]

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert(opts.anchor, 'create should anchor the prompt to the current row')
        assert_eq(opts.default, nil, 'create should not prefill a root-level file path')
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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp .. '/alpha'))
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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    assert_eq(vim.fn.maparg('P', 'n', false, true).desc, 'Parent directory')
    util.set_cursor_pos('alpha')
    core.expand()
    util.set_cursor_pos('one')
    core.expand()

    set_cursor_line('file%.txt$')
    core.parent_dir()
    assert_match(current_line(), 'one/$', 'parent jump should move from a nested file to its parent directory')

    core.parent_dir()
    assert_match(current_line(), 'alpha/$', 'parent jump should move from a nested directory to its parent directory')

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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('a')
    core.toggle_selection()
    util.set_cursor_pos('b')
    core.toggle_selection()
    local cursor = api.nvim_win_get_cursor(0)
    local row = store.get().rows[cursor[1]]

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert(opts.anchor, 'create should anchor even with multiple selections')
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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    config.show_hidden_files = old_show_hidden_files
    assert(not vim.tbl_contains(lines(), '.hidden'), 'hidden files should be hidden when configured')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/dir/nested.js')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    util.set_cursor_pos('a')
    core.toggle_selection()
    util.set_cursor_pos('dir')
    core.expand()
    set_cursor_line('nested%.js$')
    core.toggle_selection()
    core.delete()

    local confirm_win = api.nvim_get_current_win()
    local confirm_buf = api.nvim_get_current_buf()
    local confirm_lines = api.nvim_buf_get_lines(confirm_buf, 0, -1, false)
    local confirm_cfg = api.nvim_win_get_config(confirm_win)
    assert_eq(confirm_cfg.row, math.max(0, math.floor((vim.o.lines - #confirm_lines - 2) / 2)))
    assert_match(win_title(confirm_win), 'Delete 2 files%?')
    assert_eq(confirm_lines[1], ' a')
    assert_eq(confirm_lines[2], ' dir/nested.js')

    api.nvim_feedkeys('y', 'xt', false)
    assert(not api.nvim_win_is_valid(confirm_win), 'confirming delete should close the confirmation window')
    assert(not fs.exists(tmp .. '/a'), 'confirmed delete should remove top-level file')
    assert(not fs.exists(tmp .. '/dir/nested.js'), 'confirmed delete should remove nested selected file')
    assert_eq(selection_count(state), 0)

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/single.txt')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
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
    touch(tmp .. '/single.txt')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('single%.txt')
    core.toggle_selection()
    core.delete()

    local confirm_win = api.nvim_get_current_win()
    local confirm_buf = api.nvim_get_current_buf()
    local confirm_cfg = api.nvim_win_get_config(confirm_win)
    local confirm_lines = api.nvim_buf_get_lines(confirm_buf, 0, -1, false)
    assert_eq(confirm_cfg.row, math.max(0, math.floor((vim.o.lines - #confirm_lines - 2) / 2)))
    assert_eq(confirm_cfg.col, math.floor((vim.o.columns - confirm_cfg.width) / 2))
    assert_match(win_title(confirm_win), 'Delete%?')
    assert_eq(confirm_lines[1], ' single.txt')

    api.nvim_feedkeys('n', 'xt', false)
    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    set_cursor_line('alpha%.txt$')
    core.copy()
    assert_eq(selection_count(state), 1)
    assert_eq(state.paste_operation, 'copy', 'copy should set the paste operation')
    assert(has_sign_highlight(state, 'DirtreeCopySign'), 'copy should use a distinct sign highlight')

    util.set_cursor_pos('dest')
    core.expand()
    set_cursor_line('%(empty%)$')
    core.paste()

    assert(fs.exists(tmp .. '/alpha.txt'), 'single-file copy should leave the source file')
    assert(fs.exists(tmp .. '/dest/alpha.txt'), 'paste should copy into the hovered parent directory')
    assert_eq(selection_count(state), 0)
    assert(not state.paste_operation, 'paste should clear the staged copy')
    assert_match(current_line(), 'alpha%.txt$', 'paste should move cursor to the pasted file')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')
    touch(tmp .. '/c')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local old_notify = vim.notify
    local notifications = {}
    vim.notify = function(msg, level)
        notifications[#notifications+1] = {msg = msg, level = level}
    end
    local function assert_paste_mode_warning()
        assert(notifications[#notifications], 'duplicate paste mode should notify')
        assert_eq(notifications[#notifications].msg, '[dirtree] Paste mode is already active')
        notifications = {}
    end

    set_cursor_line('a$')
    core.toggle_selection()
    assert_match(current_line(), 'b$', 'tab should move cursor down after selecting')
    set_cursor_line('b$')
    core.toggle_selection()
    assert_match(current_line(), 'c$', 'tab should move cursor down after selecting another row')
    core.cut()
    assert(state.selection[state.cwd .. '/a'], 'cut should keep selected rows selected')
    assert(state.selection[state.cwd .. '/b'], 'cut should keep selected rows selected')
    assert_eq(state.paste_operation, 'cut', 'cut should set a global paste operation')
    assert(has_sign_highlight(state, 'DirtreeCutSign'), 'cut should use the cut sign')
    assert(has_high_priority_highlight(state, 'DirtreeCutSign'), 'cut should highlight filenames like the cut sign')
    core.cut()
    assert_paste_mode_warning()
    assert_eq(selection_count(state), 2, 'duplicate cut should preserve selection')
    assert_eq(state.paste_operation, 'cut', 'duplicate cut should preserve paste operation')

    set_cursor_line('c$')
    core.toggle_selection()
    assert(state.selection[state.cwd .. '/c'], 'tab should still add selections while cut is active')
    assert_match(current_line(), 'c$', 'tab should stay put on the last row')
    assert_eq(state.paste_operation, 'cut', 'tab should preserve the global cut state')
    assert(has_sign_highlight(state, 'DirtreeCutSign'), 'new selections should use the active cut sign')
    assert(has_high_priority_highlight(state, 'DirtreeCutSign'), 'new selections should highlight filenames like the cut sign')

    core.clear_paste_operation()
    assert(not state.paste_operation, 'clearing paste operation should keep plain selections')
    assert_eq(selection_count(state), 3)
    assert(has_sign_highlight(state, 'DirtreeSelectionSign'), 'clearing paste operation should use plain selection signs')
    assert(has_high_priority_highlight(state, 'DirtreeSelectionFile'), 'clearing paste operation should use plain filename highlights')

    core.copy()
    assert_eq(state.paste_operation, 'copy', 'copy should replace the global paste operation')
    assert(has_sign_highlight(state, 'DirtreeCopySign'), 'copy should use the copy sign')
    assert(has_high_priority_highlight(state, 'DirtreeCopySign'), 'copy should highlight filenames like the copy sign')
    core.copy()
    assert_paste_mode_warning()
    assert_eq(selection_count(state), 3, 'duplicate copy should preserve selection')
    assert_eq(state.paste_operation, 'copy', 'duplicate copy should preserve paste operation')

    set_cursor_line('b$')
    core.toggle_selection()
    assert(not state.selection[state.cwd .. '/b'], 'tab should remove the toggled selection')
    assert_match(current_line(), 'c$', 'tab should move cursor down after unselecting')
    assert_eq(state.paste_operation, 'copy', 'tab should preserve copy while other selections remain')

    set_cursor_line('a$')
    core.toggle_selection()
    set_cursor_line('c$')
    core.toggle_selection()
    assert_eq(selection_count(state), 0)
    assert_eq(state.paste_operation, 'copy', 'removing the last selection should preserve paste operation')

    set_cursor_line('b$')
    core.toggle_selection()
    assert_eq(state.paste_operation, 'copy', 'reselecting should keep the preserved paste operation')
    assert(has_sign_highlight(state, 'DirtreeCopySign'), 'reselected files should use the preserved copy sign')
    assert(has_high_priority_highlight(state, 'DirtreeCopySign'), 'reselected files should highlight filenames like the copy sign')

    core.clear_selection()
    assert_eq(selection_count(state), 0)
    assert(not state.paste_operation, 'clearing selection should clear the paste operation')

    core.clear_paste_operation()
    assert(not state.paste_operation, 'clearing paste operation should reset plain selection mode')

    set_cursor_line('b$')
    core.copy()
    assert_eq(state.paste_operation, 'copy', 'copy should set paste operation before escape')
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
    assert_eq(selection_count(state), 0, 'escape should clear selections')
    assert(not state.paste_operation, 'escape should clear the paste operation')

    vim.notify = old_notify
    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    util.set_cursor_pos('a')
    core.toggle_selection()
    util.set_cursor_pos('b')
    core.toggle_selection()
    assert_eq(selection_count(state), 2)
    assert(state.selection[state.cwd .. '/a'], 'a should be selected')
    assert(state.selection[state.cwd .. '/b'], 'b should be selected')
    local marks = api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    local has_sign, has_file_hl = false, false
    for _, mark in ipairs(marks) do
        local details = mark[4]
        has_sign = has_sign
            or details.sign_text and vim.startswith(details.sign_text, '▌') and details.sign_hl_group == 'DirtreeSelectionSign'
        has_file_hl = has_file_hl or details.hl_group == 'DirtreeSelectionFile'
    end
    assert(has_sign, 'selected rows should render a sign marker')
    assert(has_file_hl, 'selected rows should highlight filenames')
    core.cut()
    assert_eq(state.paste_operation, 'cut', 'cut should set the paste operation')
    assert(has_sign_highlight(state, 'DirtreeCutSign'), 'cut should use a distinct sign highlight')

    util.set_cursor_pos('dest')
    core.expand()
    set_cursor_line('%(empty%)$')
    core.paste()

    assert(not fs.exists(tmp .. '/a'), 'bulk cut paste should remove source a')
    assert(not fs.exists(tmp .. '/b'), 'bulk cut paste should remove source b')
    assert(fs.exists(tmp .. '/dest/a'), 'bulk cut paste should move a')
    assert(fs.exists(tmp .. '/dest/b'), 'bulk cut paste should move b')
    assert_eq(selection_count(state), 0)
    assert(not state.paste_operation, 'paste should clear the staged cut')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    util.set_cursor_pos('alpha%.txt')
    local cursor = api.nvim_win_get_cursor(0)
    local row = state.rows[cursor[1]]

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert(opts.anchor, 'single-file move should anchor the prompt to the current row')
        assert_eq(opts.width, 32, 'single-file move prompt should match the default delete window width')
        assert_eq(opts.anchor.win, api.nvim_get_current_win())
        assert_eq(opts.anchor.line, cursor[1])
        assert_eq(opts.anchor.col, row.name_start_col)
        local dest = opts.validate('beta.txt')
        cb('beta.txt', dest)
    end
    core.move()
    prompt.input = old_input

    assert(not fs.exists(tmp .. '/alpha.txt'), 'single-file move should rename the source file')
    assert(fs.exists(tmp .. '/beta.txt'), 'single-file move should create the destination file')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    util.set_cursor_pos('alpha%.txt')
    local cursor = api.nvim_win_get_cursor(0)
    local row = state.rows[cursor[1]]

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.prompt, 'Rename to')
        assert_eq(opts.default, 'alpha.txt')
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

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir/child', tonumber('755', 8)))
    touch(tmp .. '/dir/child/file.txt')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    util.set_cursor_pos('dir')
    core.expand()
    set_cursor_line('child/$')
    core.expand()
    util.set_cursor_pos('dir')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert_eq(opts.default, 'dir', 'rename should not append a slash for directories')
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
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    util.set_cursor_pos('a')
    core.toggle_selection()
    util.set_cursor_pos('b')
    core.toggle_selection()
    core.rename()

    assert_eq(vim.bo.buftype, 'acwrite', 'bulk rename should open an acwrite buffer')
    assert_eq(vim.bo.filetype, 'dirtree-bulk-rename')
    assert_eq(table.concat(lines(), '\n'), 'a\nb')
    api.nvim_buf_set_lines(0, 0, -1, false, {'dest/a-renamed', 'b-renamed'})
    vim.cmd'write'

    assert(fs.exists(tmp .. '/dest/a-renamed'), 'bulk rename should move files into existing directories')
    assert(fs.exists(tmp .. '/b-renamed'), 'bulk rename should rename files')
    assert(not fs.exists(tmp .. '/a'), 'bulk rename should remove old source paths')
    assert(not fs.exists(tmp .. '/b'), 'bulk rename should remove old source paths')
    assert_eq(selection_count(state), 0, 'successful bulk rename should clear selection')
    assert_match(current_line(), 'a%-renamed$', 'bulk rename should move cursor to the first changed destination')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    write_file(tmp .. '/a', 'from-a')
    write_file(tmp .. '/b', 'from-b')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    util.set_cursor_pos('a')
    core.toggle_selection()
    util.set_cursor_pos('b')
    core.toggle_selection()
    core.rename()
    api.nvim_buf_set_lines(0, 0, -1, false, {'b', 'a'})
    vim.cmd'write'

    assert_eq(read_file(tmp .. '/a'), 'from-b', 'bulk rename should support swaps')
    assert_eq(read_file(tmp .. '/b'), 'from-a', 'bulk rename should support swaps')
    assert_eq(selection_count(state), 0)

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir/child', tonumber('755', 8)))
    touch(tmp .. '/dir/child/file.txt')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    util.set_cursor_pos('dir')
    core.expand()
    set_cursor_line('child/$')
    core.expand()
    util.set_cursor_pos('dir')
    core.toggle_selection()
    core.rename()
    api.nvim_buf_set_lines(0, 0, -1, false, {'renamed'})
    vim.cmd'write'

    assert(fs.exists(tmp .. '/renamed/child/file.txt'), 'bulk rename should move directory subtrees')
    assert(state.expanded_dirs[state.cwd .. '/renamed'], 'bulk rename should preserve expanded renamed directories')
    assert(state.expanded_dirs[state.cwd .. '/renamed/child'], 'bulk rename should preserve expanded descendants')
    assert(find_line_index(lines(), 'file%.txt$'), 'bulk rename should render preserved expanded descendants')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/a')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    util.set_cursor_pos('a')
    core.toggle_selection()
    core.rename()
    vim.cmd'write'

    assert(fs.exists(tmp .. '/a'), 'unchanged bulk rename save should keep the source')
    assert_eq(selection_count(state), 1, 'unchanged bulk rename save should keep selection')
    assert_eq(api.nvim_get_current_buf(), state.buf, 'unchanged bulk rename save should return to the tree')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local old_notify = vim.notify
    local notifications = {}
    vim.notify = function(msg, level)
        notifications[#notifications+1] = {msg = msg, level = level}
    end

    local function expect_invalid(setup, new_lines, pattern)
        notifications = {}
        local tmp = vim.fn.tempname()
        assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
        local cleanup = setup(tmp)
        vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
        local state = store.get()
        cleanup.select(state)
        local tree_win = api.nvim_get_current_win()
        core.rename()
        local bulk_win = api.nvim_get_current_win()
        local bulk_buf = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(bulk_buf, 0, -1, false, new_lines)
        vim.cmd'write'
        assert_eq(api.nvim_get_current_buf(), bulk_buf, 'invalid bulk rename should keep the buffer open')
        assert(notifications[#notifications], 'invalid bulk rename should notify')
        assert_match(notifications[#notifications].msg, pattern)
        cleanup.assert_unchanged(tmp, state)
        api.nvim_win_close(bulk_win, true)
        api.nvim_set_current_win(tree_win)
        core.quit()
        assert_eq(vim.fn.delete(tmp, 'rf'), 0)
    end

    local function select_files(...)
        local names = {...}
        return function()
            for _, name in ipairs(names) do
                util.set_cursor_pos(name)
                core.toggle_selection()
            end
        end
    end

    expect_invalid(function(tmp)
        touch(tmp .. '/a')
        touch(tmp .. '/b')
        return {
            select = select_files('a', 'b'),
            assert_unchanged = function()
                assert(fs.exists(tmp .. '/a') and fs.exists(tmp .. '/b'))
            end,
        }
    end, {'x', 'x'}, 'Duplicate destination')

    expect_invalid(function(tmp)
        touch(tmp .. '/a')
        return {
            select = select_files('a'),
            assert_unchanged = function()
                assert(fs.exists(tmp .. '/a'))
            end,
        }
    end, {'a', 'b'}, 'Expected 1 lines')

    expect_invalid(function(tmp)
        touch(tmp .. '/a')
        return {
            select = select_files('a'),
            assert_unchanged = function()
                assert(fs.exists(tmp .. '/a'))
            end,
        }
    end, {''}, 'Line cannot be empty')

    expect_invalid(function(tmp)
        touch(tmp .. '/a')
        return {
            select = select_files('a'),
            assert_unchanged = function()
                assert(fs.exists(tmp .. '/a'))
            end,
        }
    end, {'/tmp/a'}, 'must be relative')

    expect_invalid(function(tmp)
        touch(tmp .. '/a')
        return {
            select = select_files('a'),
            assert_unchanged = function()
                assert(fs.exists(tmp .. '/a'))
            end,
        }
    end, {'../a'}, 'cannot contain %. or %.%.')

    expect_invalid(function(tmp)
        touch(tmp .. '/a')
        return {
            select = select_files('a'),
            assert_unchanged = function()
                assert(fs.exists(tmp .. '/a'))
            end,
        }
    end, {'missing/a'}, 'does not exist')

    expect_invalid(function(tmp)
        touch(tmp .. '/a')
        touch(tmp .. '/b')
        return {
            select = select_files('a'),
            assert_unchanged = function()
                assert(fs.exists(tmp .. '/a') and fs.exists(tmp .. '/b'))
            end,
        }
    end, {'b'}, 'already exists')

    expect_invalid(function(tmp)
        assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
        touch(tmp .. '/dir/child.txt')
        return {
            select = function()
                util.set_cursor_pos('dir')
                core.expand()
                util.set_cursor_pos('dir')
                core.toggle_selection()
                set_cursor_line('child%.txt$')
                core.toggle_selection()
            end,
            assert_unchanged = function()
                assert(fs.exists(tmp .. '/dir/child.txt'))
            end,
        }
    end, {'dir', 'dir/child.txt'}, 'and its descendant')

    expect_invalid(function(tmp)
        assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
        assert(vim.loop.fs_mkdir(tmp .. '/dir/child', tonumber('755', 8)))
        return {
            select = select_files('dir'),
            assert_unchanged = function()
                assert(fs.exists(tmp .. '/dir/child'))
            end,
        }
    end, {'dir/child/renamed'}, 'into itself')

    vim.notify = old_notify
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('a')
    core.toggle_selection()
    util.set_cursor_pos('b')
    core.toggle_selection()
    util.set_cursor_pos('dest')

    core.move()
    assert_eq(vim.bo.buftype, 'acwrite', 'bulk move should open the bulk rename buffer')
    assert_eq(table.concat(lines(), '\n'), 'a\nb')
    api.nvim_buf_set_lines(0, 0, -1, false, {'dest/a', 'dest/b'})
    vim.cmd'write'

    assert(fs.exists(tmp .. '/dest/a'), 'bulk move should move selected files through the bulk rename buffer')
    assert(fs.exists(tmp .. '/dest/b'), 'bulk move should move selected files through the bulk rename buffer')
    assert(not fs.exists(tmp .. '/a'))
    assert(not fs.exists(tmp .. '/b'))

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    local home = assert(os.getenv'HOME')
    assert(vim.loop.fs_symlink(home, tmp .. '/home-link'))

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
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
    assert_eq(cfg.border[1][1], '╭', 'keymap hints should have a border')
    assert_eq(cfg.border[1][2], 'DirtreePromptBorder', 'keymap hint border should use the prompt border highlight')
    assert_eq(cfg.title, nil, 'keymap hints should not have a title')
    local hint_lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local hint_text = table.concat(hint_lines, '\n')
    assert(hint_text:match('za%s+→%s+Alpha'), 'keymap hints should include the first custom mapping')
    assert(hint_text:match('zx%s+→%s+Xray'), 'keymap hints should include the second custom mapping')

    local marks = api.nvim_buf_get_extmarks(buf, -1, 0, -1, {details=true})
    local has_key, has_arrow, has_desc = false, false, false
    for _, mark in ipairs(marks) do
        local hl = mark[4].hl_group
        has_key = has_key or hl == 'DirtreeHelpKey'
        has_arrow = has_arrow or hl == 'DirtreeKeymapHintArrow'
        has_desc = has_desc or hl == 'DirtreeHelpDesc'
    end
    assert(has_key, 'keymap hints should highlight keys')
    assert(has_arrow, 'keymap hints should highlight arrows')
    assert(has_desc, 'keymap hints should highlight descriptions')
    window.close(buf, win)
end

do
    local buf, win = keymaps.open_hint_window(',', {
        {lhs=',C', desc='Sort by creation time reversed'},
        {lhs=',E', desc='Sort by extension reversed'},
        {lhs=',M', desc='Sort by modified time reversed'},
        {lhs=',N', desc='Sort naturally by name reversed'},
        {lhs=',S', desc='Sort by size reversed'},
        {lhs=',c', desc='Sort by creation time'},
        {lhs=',e', desc='Sort by extension'},
        {lhs=',m', desc='Sort by modified time'},
        {lhs=',n', desc='Sort naturally by name'},
        {lhs=',s', desc='Sort by size'},
    })
    local hint_lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    assert_eq(#hint_lines, 5, 'sort keymap hints should render paired lower/upper variants on one row')
    assert(hint_lines[1]:match(',n%s+→%s+Sort naturally by name%s+,N%s+→%s+Sort naturally by name reversed'),
        'sort keymap hints should pair name sort variants with lowercase on the left')
    assert(hint_lines[2]:match(',m%s+→%s+Sort by modified time%s+,M%s+→%s+Sort by modified time reversed'),
        'sort keymap hints should pair modified sort variants with lowercase on the left')
    assert(hint_lines[3]:match(',c%s+→%s+Sort by creation time%s+,C%s+→%s+Sort by creation time reversed'),
        'sort keymap hints should pair creation sort variants with lowercase on the left')
    assert(hint_lines[4]:match(',s%s+→%s+Sort by size%s+,S%s+→%s+Sort by size reversed'),
        'sort keymap hints should pair size sort variants with lowercase on the left')
    assert(hint_lines[5]:match(',e%s+→%s+Sort by extension%s+,E%s+→%s+Sort by extension reversed'),
        'sort keymap hints should pair extension sort variants with lowercase on the left')
    window.close(buf, win)
end

do
    local old_keymaps = config.keymaps
    local old_show_keymap_hints = config.show_keymap_hints
    local old_open = keymaps.open_hint_window
    local captured_prefix
    local captured_rows

    config.keymaps = {
        za = {"<Cmd>lua vim.g.dirtree_smoke_hint_keymap = 'za'<CR>", desc='Alpha'},
        zx = {function() vim.g.dirtree_smoke_hint_keymap = 'zx' end, desc='Xray'},
    }
    config.show_keymap_hints = true
    keymaps.open_hint_window = function(prefix, rows)
        captured_prefix = prefix
        captured_rows = rows
        return old_open(prefix, rows)
    end
    vim.g.dirtree_smoke_hint_keymap = nil

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(cwd))
    local prefix_map = vim.fn.maparg('z', 'n', false, true)
    assert_eq(prefix_map.desc, 'Show keymap hints')
    assert_eq(type(prefix_map.callback), 'function')
    assert_eq(vim.fn.maparg('za', 'n', false, true).desc, 'Alpha')
    assert_eq(vim.fn.maparg('zx', 'n', false, true).desc, 'Xray')
    api.nvim_feedkeys('a', 't', false)
    prefix_map.callback()
    assert_eq(vim.g.dirtree_smoke_hint_keymap, 'za', 'keymap hints should dispatch legacy string actions')
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
    local old_reload = core.reload

    config.keymaps = {
        za = {'reload', desc='Reload'},
    }
    config.show_keymap_hints = true
    core.reload = function()
        vim.g.dirtree_smoke_named_keymap = 'reload'
    end
    keymaps.open_hint_window = function(prefix, rows)
        return old_open(prefix, rows)
    end
    vim.g.dirtree_smoke_named_keymap = nil

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(cwd))
    local prefix_map = vim.fn.maparg('z', 'n', false, true)
    api.nvim_feedkeys('a', 't', false)
    prefix_map.callback()
    assert_eq(vim.g.dirtree_smoke_named_keymap, 'reload', 'keymap hints should dispatch named core actions')
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
        x = {'reload', desc='Reload'},
    }
    config.show_keymap_hints = false
    core.reload = function()
        vim.g.dirtree_smoke_named_direct_keymap = 'reload'
    end
    vim.g.dirtree_smoke_named_direct_keymap = nil

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(cwd))
    local map = vim.fn.maparg('x', 'n', false, true)
    assert_eq(map.desc, 'Reload')
    assert_eq(type(map.callback), 'function')
    map.callback()
    assert_eq(vim.g.dirtree_smoke_named_direct_keymap, 'reload', 'direct keymaps should dispatch named core actions')
    core.quit()

    core.reload = old_reload
    config.keymaps = old_keymaps
    config.show_keymap_hints = old_show_keymap_hints
end

do
    local old_keymaps = config.keymaps
    local old_show_keymap_hints = config.show_keymap_hints

    config.keymaps = {
        za = {function() vim.g.dirtree_smoke_hint_keymap = 'za' end, desc='Alpha'},
        zx = {function() vim.g.dirtree_smoke_hint_keymap = 'zx' end, desc='Xray'},
    }
    config.show_keymap_hints = false

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(cwd))
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
        x = {function() vim.g.dirtree_smoke_hint_keymap = 'x' end, desc='Plain X'},
        xy = {function() vim.g.dirtree_smoke_hint_keymap = 'xy' end, desc='X Y'},
    }
    config.show_keymap_hints = true

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(cwd))
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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    assert_eq(state.sort_order, 'name')
    assert_line_before('^dir2/$', '^dir10/$', 'natural sort should order directory names naturally')
    assert_line_before('^dir10/$', '^alpha%.md$', 'directories should stay grouped before files')
    assert_line_before('^file2%.txt$', '^file10%.txt$', 'natural sort should order file names naturally')

    core.sort_by('name_reverse')
    assert_eq(state.sort_order, 'name_reverse')
    assert_line_before('^dir10/$', '^dir2/$', 'reversed natural sort should reverse directory names')
    assert_line_before('^dir2/$', '^tiny%.bin$', 'reversed natural sort should keep directories before files')
    assert_line_before('^file10%.txt$', '^file2%.txt$', 'reversed natural sort should reverse file names')

    core.sort_by('size')
    assert_eq(state.sort_order, 'size')
    assert_line_before('^dir10/$', '^tiny%.bin$', 'size sort should keep directories before files')
    assert_line_before('^tiny%.bin$', '^alpha%.md$', 'size sort should order files by size')
    assert_line_before('^file2%.txt$', '^file10%.txt$', 'size sort should order larger files later')

    core.sort_by('size_reverse')
    assert_eq(state.sort_order, 'size_reverse')
    assert_line_before('^dir10/$', '^big%.log$', 'reversed size sort should keep directories before files')
    assert_line_before('^big%.log$', '^file10%.txt$', 'reversed size sort should order larger files first')
    assert_line_before('^file10%.txt$', '^file2%.txt$', 'reversed size sort should order smaller files later')

    core.sort_by('extension')
    assert_eq(state.sort_order, 'extension')
    assert_line_before('^tiny%.bin$', '^big%.log$', 'extension sort should order by extension')
    assert_line_before('^big%.log$', '^alpha%.md$', 'extension sort should order by extension')
    assert_line_before('^alpha%.md$', '^file2%.txt$', 'extension sort should order by extension')

    core.sort_by('extension_reverse')
    assert_eq(state.sort_order, 'extension_reverse')
    assert_line_before('^file2%.txt$', '^alpha%.md$', 'reversed extension sort should order by extension descending')
    assert_line_before('^alpha%.md$', '^big%.log$', 'reversed extension sort should order by extension descending')
    assert_line_before('^big%.log$', '^tiny%.bin$', 'reversed extension sort should order by extension descending')

    core.sort_by('modified')
    assert_eq(state.sort_order, 'modified')
    assert_line_before('^tiny%.bin$', '^file10%.txt$', 'modified sort should order older files first')
    assert_line_before('^file2%.txt$', '^big%.log$', 'modified sort should order newer files later')

    core.sort_by('modified_reverse')
    assert_eq(state.sort_order, 'modified_reverse')
    assert_line_before('^big%.log$', '^file2%.txt$', 'reversed modified sort should order newer files first')
    assert_line_before('^file10%.txt$', '^tiny%.bin$', 'reversed modified sort should order older files later')

    core.sort_by('created')
    assert_eq(state.sort_order, 'created')
    core.sort_by('created_reverse')
    assert_eq(state.sort_order, 'created_reverse')

    local prefix_map = vim.fn.maparg(',', 'n', false, true)
    api.nvim_feedkeys('s', 't', false)
    prefix_map.callback()
    assert_eq(state.sort_order, 'size', 'sort keymaps should work behind the comma prefix mapping')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/visible')
    touch(tmp .. '/.hidden')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
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
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')
    touch(tmp .. '/dir/nested')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    util.set_cursor_pos('a')
    core.toggle_selection()
    util.set_cursor_pos('b')
    core.toggle_selection()
    assert_eq(selection_count(state), 2)

    core.clear_selection()
    assert_eq(selection_count(state), 0)

    util.set_cursor_pos('dir')
    core.expand()
    core.select_all()
    assert_eq(selection_count(state), 4)
    assert(state.selection[state.cwd .. '/a'], 'select all should select visible files')
    assert(state.selection[state.cwd .. '/b'], 'select all should select visible files')
    assert(state.selection[state.cwd .. '/dir'], 'select all should select visible directories')
    assert(state.selection[state.cwd .. '/dir/nested'], 'select all should select expanded child rows')
    core.clear_selection()
    assert_eq(selection_count(state), 0)

    state.selection[state.cwd .. '/a'] = true
    core.invert_selection()
    assert_eq(selection_count(state), 3)
    assert(not state.selection[state.cwd .. '/a'], 'invert selection should clear selected visible rows')
    assert(state.selection[state.cwd .. '/b'], 'invert selection should select unselected visible rows')
    assert(state.selection[state.cwd .. '/dir'], 'invert selection should select unselected visible directories')
    assert(state.selection[state.cwd .. '/dir/nested'], 'invert selection should select unselected expanded child rows')
    core.clear_selection()
    assert_eq(selection_count(state), 0)

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
        name = 'dirtree-smoke',
        copy = {
            ['+'] = function(lines) vim.g.dirtree_smoke_clipboard = table.concat(lines, '\n') end,
            ['*'] = function() end,
        },
        paste = {
            ['+'] = function() return {vim.split(vim.g.dirtree_smoke_clipboard or '', '\n'), 'v'} end,
            ['*'] = function() return {{''}, 'v'} end,
        },
    }
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    touch(tmp .. '/dir/archive.tar.gz')

    local augroup = api.nvim_create_augroup('dirtree-smoke-yank', {})
    api.nvim_create_autocmd('TextYankPost', {
        group = augroup,
        callback = function()
            vim.g.dirtree_smoke_yankpost_operator = vim.v.event.operator
            vim.g.dirtree_smoke_yankpost_regname = vim.v.event.regname
            vim.g.dirtree_smoke_yankpost_text = vim.v.event.regcontents[1]
        end,
    })

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('dir')
    core.expand()
    set_cursor_line('archive%.tar%.gz$')
    local expected_path = fs.realpath(tmp) .. '/dir/archive.tar.gz'
    local expected_yank_text = current_line()

    core.yank_file_path()
    assert_eq(vim.fn.getreg('"'), expected_path)
    assert_eq(notifications[#notifications].msg, '[dirtree] Yanked file path')
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)
    assert_eq(vim.g.dirtree_smoke_yankpost_operator, 'y')
    assert_eq(vim.g.dirtree_smoke_yankpost_regname, '')
    assert_eq(vim.g.dirtree_smoke_yankpost_text, expected_yank_text)

    vim.g.dirtree_smoke_yankpost_operator = nil
    vim.g.dirtree_smoke_yankpost_regname = nil
    vim.g.dirtree_smoke_yankpost_text = nil
    core.yank_file_path_clipboard()
    assert_eq(vim.fn.getreg('+'), expected_path)
    assert_eq(notifications[#notifications].msg, '[dirtree] Yanked file path to clipboard')
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)
    assert_eq(vim.g.dirtree_smoke_yankpost_operator, 'y')
    assert_eq(vim.g.dirtree_smoke_yankpost_regname, '+')
    assert_eq(vim.g.dirtree_smoke_yankpost_text, expected_yank_text)

    core.yank_dir_path()
    assert_eq(vim.fn.getreg('"'), fs.realpath(tmp) .. '/dir')
    assert_eq(notifications[#notifications].msg, '[dirtree] Yanked directory path')

    core.yank_dir_path_clipboard()
    assert_eq(vim.fn.getreg('+'), fs.realpath(tmp) .. '/dir')
    assert_eq(notifications[#notifications].msg, '[dirtree] Yanked directory path to clipboard')

    core.yank_filename()
    assert_eq(vim.fn.getreg('"'), 'archive.tar.gz')
    assert_eq(notifications[#notifications].msg, '[dirtree] Yanked filename')

    core.yank_filename_clipboard()
    assert_eq(vim.fn.getreg('+'), 'archive.tar.gz')
    assert_eq(notifications[#notifications].msg, '[dirtree] Yanked filename to clipboard')

    core.yank_basename()
    assert_eq(vim.fn.getreg('"'), 'archive.tar')
    assert_eq(notifications[#notifications].msg, '[dirtree] Yanked basename')

    core.yank_basename_clipboard()
    assert_eq(vim.fn.getreg('+'), 'archive.tar')
    assert_eq(notifications[#notifications].msg, '[dirtree] Yanked basename to clipboard')

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
    vim.g.dirtree_smoke_clipboard = nil
    vim.g.dirtree_smoke_yankpost_operator = nil
    vim.g.dirtree_smoke_yankpost_regname = nil
    vim.g.dirtree_smoke_yankpost_text = nil
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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local expected_path = fs.realpath(tmp) .. '/a'
    vim.ui.open = function(path)
        vim.g.dirtree_smoke_open_external_path = path
    end
    core.open_external()
    assert_eq(vim.g.dirtree_smoke_open_external_path, expected_path)
    assert_eq(notifications[#notifications].msg, '[dirtree] Opening a')
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)

    vim.ui.open = function()
        error('boom')
    end
    core.open_external()
    assert_match(notifications[#notifications].msg, '^%[dirtree%] Could not open externally: ')
    assert_eq(notifications[#notifications].level, vim.log.levels.ERROR)

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
    vim.notify = old_notify
    vim.ui.open = old_open
    vim.g.dirtree_smoke_open_external_path = nil
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    write_file(tmp .. '/alpha.txt', 'hello')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local origin_win = api.nvim_get_current_win()
    core.info()
    local info_win = api.nvim_get_current_win()
    local info_buf = api.nvim_get_current_buf()
    local info_cfg = api.nvim_win_get_config(info_win)
    local info_lines = api.nvim_buf_get_lines(info_buf, 0, -1, false)
    local info_text = table.concat(info_lines, '\n')

    assert(info_win ~= origin_win, 'info should open in a floating window')
    assert_eq(info_cfg.border[1][2], 'DirtreePromptBorder')
    assert_match(win_title(info_win), 'Info')
    assert_match(info_text, 'Name%s+alpha%.txt')
    assert_match(info_text, 'Type%s+File')
    assert_match(info_text, 'Size%s+5 B')
    assert_match(info_text, 'Permissions%s+rw%-r%-%-r%-%-')
    assert(info_text:find(tmp .. '/alpha.txt', 1, true), 'info should show the selected path')

    local marks = api.nvim_buf_get_extmarks(info_buf, -1, 0, -1, {details=true})
    local has_label, has_value = false, false
    for _, mark in ipairs(marks) do
        local hl = mark[4].hl_group
        has_label = has_label or hl == 'DirtreeInfoLabel'
        has_value = has_value or hl == 'DirtreeInfoValue'
    end
    assert(has_label, 'info should highlight labels')
    assert(has_value, 'info should highlight values')

    api.nvim_feedkeys('q', 'xt', false)
    assert_eq(api.nvim_get_current_win(), origin_win, 'closing info should restore origin window')
    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    vim.cmd('Dirtree ' .. vim.fn.fnameescape(cwd))
    local origin_win = api.nvim_get_current_win()
    core.help()
    local help_win = api.nvim_get_current_win()
    local help_buf = api.nvim_get_current_buf()
    assert(help_win ~= origin_win, 'help should open in a floating window')
    local help_lines = api.nvim_buf_get_lines(help_buf, 0, -1, false)
    local help_cfg = api.nvim_win_get_config(help_win)
    assert_eq(help_cfg.height, math.min(#help_lines, math.max(1, vim.o.lines - 4)))
    assert_eq(vim.wo[help_win].cursorline, false, 'help should disable cursorline')
    assert(not find_line_index(help_lines, '^Normal$'), 'help should omit the normal section title')
    assert(not find_line_index(help_lines, '^Visual$'), 'help should omit the visual section')

    api.nvim_feedkeys('q', 'xt', false)
    assert_eq(api.nvim_get_current_win(), origin_win, 'closing help should restore origin window')
    core.quit()
end

do
    local old_keymaps = config.keymaps
    config.keymaps = {
        x = "<Cmd>lua vim.g.dirtree_smoke_legacy_keymap = 'normal'<CR>",
        z = {"<Cmd>lua vim.g.dirtree_smoke_legacy_keymap = 'normal-z'<CR>", desc="Normal Z"},
    }

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(cwd))
    assert_eq(vim.fn.maparg('x', 'n', false, true).rhs, "<Cmd>lua vim.g.dirtree_smoke_legacy_keymap = 'normal'<CR>")
    core.help()
    local help_lines = api.nvim_buf_get_lines(0, 0, -1, false)
    local help_text = table.concat(help_lines, '\n')
    assert(help_text:match("x%s+<Cmd>lua vim%.g%.dirtree_smoke_legacy_keymap = 'normal'<CR>"), 'help should include legacy normal mappings')
    assert(not find_line_index(help_lines, '^Normal$'), 'help should omit the normal section title')
    assert(not find_line_index(help_lines, '^Visual$'), 'help should omit the visual section')
    assert(find_line_index(help_lines, "^  x%s+<Cmd>lua vim%.g%.dirtree_smoke_legacy_keymap = 'normal'<CR>$") < find_line_index(help_lines, '^  z%s+Normal Z$'),
        'help should sort unordered custom mappings after local order')
    api.nvim_feedkeys('q', 'xt', false)
    core.quit()

    config.keymaps = old_keymaps
end

do
    local tmp = vim.fn.tempname()
    local old_toggle_visual_selection = core.toggle_visual_selection
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    core.toggle_visual_selection = function()
        vim.g.dirtree_smoke_visual_keymap = 'tab'
    end
    vim.g.dirtree_smoke_visual_keymap = nil

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    assert_eq(vim.fn.maparg('J', 'x', false, true).desc, 'Last sibling')
    assert_eq(type(vim.fn.maparg('J', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('K', 'x', false, true).desc, 'First sibling')
    assert_eq(type(vim.fn.maparg('K', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('>', 'x', false, true).desc, 'Next sibling')
    assert_eq(type(vim.fn.maparg('>', 'x', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('<', 'x', false, true).desc, 'Previous sibling')
    assert_eq(type(vim.fn.maparg('<', 'x', false, true).callback), 'function')
    local tab_map = vim.fn.maparg('<Tab>', 'x', false, true)
    assert_eq(tab_map.desc, 'Toggle selection')
    assert_eq(type(tab_map.callback), 'function')
    tab_map.callback()
    assert_eq(vim.g.dirtree_smoke_visual_keymap, 'tab', 'visual Tab should dispatch the visual selection action')

    core.quit()
    core.toggle_visual_selection = old_toggle_visual_selection
    vim.g.dirtree_smoke_visual_keymap = nil
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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
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
    assert_eq(current_line(), 'top.txt', 'next sibling should stay on the last sibling')
    core.prev_sibling()
    assert_eq(current_line(), 'beta/', 'previous sibling should jump to the previous sibling')
    core.prev_sibling()
    assert_eq(current_line(), 'alpha/', 'previous sibling should jump to the previous root sibling')
    core.prev_sibling()
    assert_eq(current_line(), 'alpha/', 'previous sibling should stay on the first sibling')

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
    assert_match(current_line(), 'nested/$', 'previous sibling should stay on the first child sibling')

    set_cursor_line('nested/$')
    core.next_sibling()
    assert_match(current_line(), 'file%.txt$', 'next sibling should jump to the next nested sibling')
    core.prev_sibling()
    assert_match(current_line(), 'nested/$', 'previous sibling should jump to the previous nested sibling')
    core.next_sibling()
    assert_match(current_line(), 'file%.txt$', 'next sibling should jump to the next nested sibling')
    core.next_sibling()
    assert_match(current_line(), 'file%.txt$', 'next sibling should stay on the last child sibling')
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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local root = state.cwd

    util.set_cursor_pos('root')
    core.expand_recursive()
    assert(vim.tbl_contains(lines(), '├── a/'), 'recursive expand should show child directories')
    assert(vim.tbl_contains(lines(), '│   └── b/'), 'recursive expand should show nested directories')
    assert(vim.tbl_contains(lines(), '│       └── file.txt'), 'recursive expand should show nested files')
    assert(vim.tbl_contains(lines(), '└── empty/'), 'recursive expand should show empty child directories')
    assert(vim.tbl_contains(lines(), '    └── (empty)'), 'recursive expand should show empty placeholders')
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
    assert(not vim.tbl_contains(lines(), '├── a/'), 'recursive collapse should hide children')

    core.expand()
    assert(vim.tbl_contains(lines(), '├── a/'), 'expand after recursive collapse should show one level')
    assert(not vim.tbl_contains(lines(), '│   └── b/'), 'expand after recursive collapse should not restore recursive state')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')
    touch(tmp .. '/c')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    vim.fn.setpos("'<", {0, 1, 1, 0})
    vim.fn.setpos("'>", {0, 2, 1, 0})
    core.toggle_visual_selection()
    assert_eq(selection_count(state), 2)
    assert(state.selection[state.cwd .. '/a'], 'visual toggle should select first selected row')
    assert(state.selection[state.cwd .. '/b'], 'visual toggle should select second selected row')
    assert(not state.selection[state.cwd .. '/c'], 'visual toggle should not select unselected rows')

    vim.fn.setpos("'<", {0, 2, 1, 0})
    vim.fn.setpos("'>", {0, 1, 1, 0})
    core.toggle_visual_selection()
    assert_eq(selection_count(state), 0, 'visual toggle should handle reversed ranges')

    core.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    vim.fn.setpos("'<", {0, 1, 1, 0})
    vim.fn.setpos("'>", {0, 1, 1, 0})
    api.nvim_win_set_cursor(0, {2, 0})
    api.nvim_feedkeys(api.nvim_replace_termcodes('V<Tab>', true, false, true), 'xt', false)
    assert_eq(selection_count(state), 1)
    assert(not state.selection[state.cwd .. '/a'], 'live visual toggle should not use stale visual selection')
    assert(state.selection[state.cwd .. '/b'], 'live visual toggle should select the selected cursor line')

    core.quit()
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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()
    local root = state.cwd

    util.set_cursor_pos('alpha')
    core.expand()
    assert(vim.tbl_contains(lines(), '├── one/'), 'first expand should show alpha children')
    assert(vim.tbl_contains(lines(), '└── two/'), 'first expand should show all alpha children')
    assert(not vim.tbl_contains(lines(), '│   └── file.txt'), 'first expand should not expand grandchildren')
    assert(has_highlight(state, 'DirtreeDirectory'), 'directory rows should be highlighted')
    assert(has_priority_highlight(state, 'DirtreeFile', 100), 'file row highlights should not cover yank highlights')
    assert(has_high_priority_highlight(state, 'DirtreeTree'), 'tree prefixes should be highlighted')
    assert(has_high_priority_highlight(state, 'DirtreeVirtText'), 'directory suffixes should be highlighted')

    set_cursor_line('one/$')
    assert_cursor_tree_highlights(state, 2)
    assert_eq(state.rows[api.nvim_win_get_cursor(0)[1]].tree_connector_start_col, 0)

    core.expand()
    assert(vim.tbl_contains(lines(), '│   └── file.txt'), 'second expand should expand another level')
    assert_cursor_tree_highlights(state, 3)

    set_cursor_line('file%.txt$')
    assert_cursor_tree_highlights(state, 1)
    assert(state.rows[api.nvim_win_get_cursor(0)[1]].tree_connector_start_col > 0)
    core.toggle_selection()
    assert(state.selection[root .. '/alpha/one/file.txt'], 'nested row should select its real path')

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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    util.set_cursor_pos('empty')
    core.expand()
    assert(vim.tbl_contains(lines(), '└── (empty)'), 'empty directories should render a placeholder')
    assert(has_highlight(state, 'DirtreeTree'), 'empty placeholder should be highlighted as tree text')

    set_cursor_line('%(empty%)$')
    core.toggle_selection()
    assert_eq(selection_count(state), 0, 'empty placeholder should not be selectable')

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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
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

vim.cmd('Dirtree ' .. vim.fn.fnameescape(cwd))
local state = store.get()
assert_eq(state.cwd, fs.realpath(cwd))
assert(api.nvim_buf_get_var(0, 'is_dirtree'), 'Dirtree buffer should be identified')
assert(#api.nvim_buf_get_lines(0, 0, -1, false) > 0, 'Dirtree buffer should render entries')
core.quit()

print('[dirtree] smoke ok\n')
