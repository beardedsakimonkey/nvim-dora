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
local prompt = require'dirtree.prompt'
local core = require'dirtree.core'
local store = require'dirtree.store'
local util = require'dirtree.util'

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

local function mark_count(state)
    local count = 0
    for _ in pairs(state.marks) do
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
    local marked_segments = {}
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
        local marked_lnum = mark[2] + 1
        local key = ('%d:%d:%d'):format(marked_lnum, mark[3], mark[4].end_col)
        assert(expected_segments[key], 'active tree highlight should match the cursor parent group')
        assert_eq(mark[4].priority, 10001)
        marked_segments[key] = true
    end
    for key in pairs(expected_segments) do
        assert(marked_segments[key], 'sibling tree segment should be highlighted')
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
    assert(not p.list_win, 'prompt should not create a completion window')
    assert_eq(type(vim.fn.maparg('<Esc>', 'i', false, true).callback), 'function')
    assert_eq(vim.fn.maparg('<Esc>', 'i', false, true).expr, 1)
    assert_eq(type(vim.fn.maparg('<Esc>', 'n', false, true).callback), 'function')

    p:set_input('bad', 3)
    p:redraw()
    assert_eq(p.is_valid, false)

    p:set_input('u', 1)
    p:redraw()
    assert(p.completion)
    assert_eq(p.completion.word, 'UNLICENSE')
    assert_eq(p.completion.suffix, 'NLICENSE')
    p:accept_completion()
    assert_eq(p:get_input(), 'UNLICENSE')

    p:set_input('lua/d', 5)
    p:redraw()
    assert(p.completion)
    assert_eq(p.completion.word, 'lua/dirtree/')
    assert_eq(p.completion.suffix, 'irtree/')
    p:accept_completion()
    assert_eq(p:get_input(), 'lua/dirtree/')

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
    touch(tmp .. '/a')
    touch(tmp .. '/b')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('a')
    core.toggle_mark()
    util.set_cursor_pos('b')
    core.toggle_mark()
    local cursor = api.nvim_win_get_cursor(0)
    local row = store.get().rows[cursor[1]]

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert(opts.anchor, 'create should anchor the prompt to the current row with multiple marks')
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

    local old_show_hidden = config.show_hidden
    config.show_hidden = false

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    config.show_hidden = old_show_hidden
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
    core.toggle_mark()
    util.set_cursor_pos('dir')
    core.expand()
    set_cursor_line('nested%.js$')
    core.toggle_mark()
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
    assert(not fs.exists(tmp .. '/dir/nested.js'), 'confirmed delete should remove nested marked file')
    assert_eq(mark_count(state), 0)

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
    core.toggle_mark()
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
    assert_eq(mark_count(state), 1)
    assert_eq(state.paste_operation, 'copy', 'copy should set the paste operation')
    assert(has_sign_highlight(state, 'DirtreeCopySign'), 'copy should use a distinct sign highlight')

    util.set_cursor_pos('dest')
    core.expand()
    set_cursor_line('%(empty%)$')
    core.paste()

    assert(fs.exists(tmp .. '/alpha.txt'), 'single-file copy should leave the source file')
    assert(fs.exists(tmp .. '/dest/alpha.txt'), 'paste should copy into the hovered parent directory')
    assert_eq(mark_count(state), 0)
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

    set_cursor_line('a$')
    core.toggle_mark()
    set_cursor_line('b$')
    core.toggle_mark()
    core.cut()
    assert(state.marks[state.cwd .. '/a'], 'cut should keep marked rows marked')
    assert(state.marks[state.cwd .. '/b'], 'cut should keep marked rows marked')
    assert_eq(state.paste_operation, 'cut', 'cut should set a global paste operation')
    assert(has_sign_highlight(state, 'DirtreeCutSign'), 'cut should use the cut sign')

    set_cursor_line('c$')
    core.toggle_mark()
    assert(state.marks[state.cwd .. '/c'], 'tab should still add marks while cut is active')
    assert_eq(state.paste_operation, 'cut', 'tab should preserve the global cut state')
    assert(has_sign_highlight(state, 'DirtreeCutSign'), 'new marks should use the active cut sign')

    core.clear_paste_operation()
    assert(not state.paste_operation, 'clearing paste operation should keep plain marks')
    assert_eq(mark_count(state), 3)
    assert(has_sign_highlight(state, 'DirtreeMarkedSign'), 'clearing paste operation should use plain mark signs')

    core.copy()
    assert_eq(state.paste_operation, 'copy', 'copy should replace the global paste operation')
    assert(has_sign_highlight(state, 'DirtreeCopySign'), 'copy should use the copy sign')

    set_cursor_line('b$')
    core.toggle_mark()
    assert(not state.marks[state.cwd .. '/b'], 'tab should remove the toggled mark')
    assert_eq(state.paste_operation, 'copy', 'tab should preserve copy while other marks remain')

    set_cursor_line('a$')
    core.toggle_mark()
    set_cursor_line('c$')
    core.toggle_mark()
    assert_eq(mark_count(state), 0)
    assert_eq(state.paste_operation, 'copy', 'removing the last mark should preserve paste operation')

    set_cursor_line('b$')
    core.toggle_mark()
    assert_eq(state.paste_operation, 'copy', 'remarking should keep the preserved paste operation')
    assert(has_sign_highlight(state, 'DirtreeCopySign'), 'remarked files should use the preserved copy sign')

    core.clear_marks()
    assert_eq(mark_count(state), 0)
    assert_eq(state.paste_operation, 'copy', 'clearing marks should preserve paste operation')

    core.clear_paste_operation()
    assert(not state.paste_operation, 'clearing paste operation should reset plain mark mode')

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
    core.toggle_mark()
    util.set_cursor_pos('b')
    core.toggle_mark()
    assert_eq(mark_count(state), 2)
    assert(state.marks[state.cwd .. '/a'], 'a should be marked')
    assert(state.marks[state.cwd .. '/b'], 'b should be marked')
    local marks = api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, {details = true})
    local has_sign, has_file_hl = false, false
    for _, mark in ipairs(marks) do
        local details = mark[4]
        has_sign = has_sign
            or details.sign_text and vim.startswith(details.sign_text, '▌') and details.sign_hl_group == 'DirtreeMarkedSign'
        has_file_hl = has_file_hl or details.hl_group == 'DirtreeMarkedFile'
    end
    assert(has_sign, 'marked rows should render a sign marker')
    assert(has_file_hl, 'marked rows should highlight filenames')
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
    assert_eq(mark_count(state), 0)
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
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/a')
    touch(tmp .. '/b')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    util.set_cursor_pos('a')
    core.toggle_mark()
    util.set_cursor_pos('b')
    core.toggle_mark()
    util.set_cursor_pos('dest')

    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        assert(not opts.anchor, 'bulk move should keep the prompt centered')
        assert_eq(opts.width, nil, 'bulk move should keep the standard prompt width')
        cb(nil)
    end
    core.move()
    prompt.input = old_input

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
    vim.cmd('Dirtree ' .. vim.fn.fnameescape(cwd))
    assert_eq(vim.fn.maparg('q', 'n', false, true).desc, 'Quit')
    assert_eq(vim.fn.maparg('i', 'n', false, true).desc, 'Show info')
    assert_eq(vim.fn.maparg('y', 'n', false, true).desc, 'Yank path')
    assert_eq(vim.fn.maparg('Y', 'n', false, true).desc, 'Yank path to clipboard')
    assert_eq(vim.fn.maparg('g?', 'n', false, true).desc, 'Show help')
    assert_eq(vim.fn.maparg('x', 'n', false, true).desc, 'Cut')
    assert_eq(vim.fn.maparg('X', 'n', false, true).desc, 'Clear cut/copy')
    assert_eq(vim.fn.maparg('c', 'n', false, true).desc, 'Copy')
    assert_eq(vim.fn.maparg('C', 'n', false, true).desc, 'Clear cut/copy')
    assert_eq(vim.fn.maparg('p', 'n', false, true).desc, 'Paste')
    assert_eq(vim.fn.maparg('<S-Tab>', 'n', false, true).desc, 'Clear marks')
    assert_eq(vim.fn.maparg('<Tab>', 'x', false, true).desc, 'Toggle marks')
    core.quit()
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
    touch(tmp .. '/a')
    touch(tmp .. '/b')

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    util.set_cursor_pos('a')
    core.toggle_mark()
    util.set_cursor_pos('b')
    core.toggle_mark()
    assert_eq(mark_count(state), 2)

    core.clear_marks()
    assert_eq(mark_count(state), 0)

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
    touch(tmp .. '/a')

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
    local expected_path = fs.realpath(tmp) .. '/a'
    core.yank_path()
    assert_eq(vim.fn.getreg('"'), expected_path)
    assert_eq(notifications[#notifications].msg, '[dirtree] Yanked path')
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)
    assert_eq(vim.g.dirtree_smoke_yankpost_operator, 'y')
    assert_eq(vim.g.dirtree_smoke_yankpost_regname, '')
    assert_eq(vim.g.dirtree_smoke_yankpost_text, 'a')

    vim.g.dirtree_smoke_yankpost_operator = nil
    vim.g.dirtree_smoke_yankpost_regname = nil
    vim.g.dirtree_smoke_yankpost_text = nil
    core.yank_path('+')
    assert_eq(vim.fn.getreg('+'), expected_path)
    assert_eq(notifications[#notifications].msg, '[dirtree] Yanked path to clipboard')
    assert_eq(notifications[#notifications].level, vim.log.levels.INFO)
    assert_eq(vim.g.dirtree_smoke_yankpost_operator, 'y')
    assert_eq(vim.g.dirtree_smoke_yankpost_regname, '+')
    assert_eq(vim.g.dirtree_smoke_yankpost_text, 'a')

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
    assert(vim.tbl_contains(help_lines, 'Normal'), 'help should show normal mappings')
    assert(vim.tbl_contains(help_lines, 'Visual'), 'help should show visual mappings')
    assert(table.concat(help_lines, '\n'):match('g%?%s+Show help'), 'help should include described mappings')
    assert(table.concat(help_lines, '\n'):match('i%s+Show info'), 'help should include the info mapping')
    assert(table.concat(help_lines, '\n'):match('y%s+Yank path'), 'help should include the yank path mapping')
    assert(table.concat(help_lines, '\n'):match('Y%s+Yank path to clipboard'), 'help should include the clipboard yank mapping')
    assert(table.concat(help_lines, '\n'):match('<S%-Tab>%s+Clear marks'), 'help should include the clear marks mapping')
    assert(find_line_index(help_lines, '^  q%s+Quit$') < find_line_index(help_lines, '^  h%s+Up directory$'),
        'help should follow configured normal keymap order')
    assert(find_line_index(help_lines, '^  h%s+Up directory$') < find_line_index(help_lines, '^  %-%s+Up directory$'),
        'help should preserve ordered punctuation keymaps')

    local marks = api.nvim_buf_get_extmarks(help_buf, -1, 0, -1, {details=true})
    local has_header, has_key, has_desc = false, false, false
    for _, mark in ipairs(marks) do
        local hl = mark[4].hl_group
        has_header = has_header or hl == 'DirtreeHelpHeader'
        has_key = has_key or hl == 'DirtreeHelpKey'
        has_desc = has_desc or hl == 'DirtreeHelpDesc'
    end
    assert(has_header, 'help should highlight section headers')
    assert(has_key, 'help should highlight keys')
    assert(has_desc, 'help should highlight descriptions')

    api.nvim_feedkeys('q', 'xt', false)
    assert_eq(api.nvim_get_current_win(), origin_win, 'closing help should restore origin window')
    core.quit()
end

do
    local old_keymaps = config.keymaps
    local old_visual_keymaps = config.visual_keymaps
    config.keymaps = {
        x = "<Cmd>lua vim.g.dirtree_smoke_legacy_keymap = 'normal'<CR>",
        z = {"<Cmd>lua vim.g.dirtree_smoke_legacy_keymap = 'normal-z'<CR>", desc="Normal Z"},
    }
    config.visual_keymaps = {
        y = "<Cmd>lua vim.g.dirtree_smoke_legacy_keymap = 'visual'<CR>",
    }

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(cwd))
    assert_eq(vim.fn.maparg('x', 'n', false, true).rhs, "<Cmd>lua vim.g.dirtree_smoke_legacy_keymap = 'normal'<CR>")
    assert_eq(vim.fn.maparg('y', 'x', false, true).rhs, "<Cmd>lua vim.g.dirtree_smoke_legacy_keymap = 'visual'<CR>")
    core.help()
    local help_lines = api.nvim_buf_get_lines(0, 0, -1, false)
    local help_text = table.concat(help_lines, '\n')
    assert(help_text:match("x%s+<Cmd>lua vim%.g%.dirtree_smoke_legacy_keymap = 'normal'<CR>"), 'help should include legacy normal mappings')
    assert(help_text:match("y%s+<Cmd>lua vim%.g%.dirtree_smoke_legacy_keymap = 'visual'<CR>"), 'help should include legacy visual mappings')
    assert(find_line_index(help_lines, "^  x%s+<Cmd>lua vim%.g%.dirtree_smoke_legacy_keymap = 'normal'<CR>$") < find_line_index(help_lines, '^  z%s+Normal Z$'),
        'help should sort unordered custom mappings after local order')
    api.nvim_feedkeys('q', 'xt', false)
    core.quit()

    config.keymaps = old_keymaps
    config.visual_keymaps = old_visual_keymaps
end

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    assert_eq(vim.fn.maparg('J', 'x', false, true).rhs, "<Cmd>lua require'dirtree.core'.next_sibling()<CR>")
    assert_eq(vim.fn.maparg('K', 'x', false, true).rhs, "<Cmd>lua require'dirtree.core'.prev_sibling()<CR>")

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

    vim.cmd('Dirtree ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    util.set_cursor_pos('alpha')
    core.expand()
    set_cursor_line('nested/$')
    core.expand()

    util.set_cursor_pos('alpha')
    core.next_sibling()
    assert_eq(current_line(), 'beta/', 'J should jump to the next root sibling')
    core.next_sibling()
    assert_eq(current_line(), 'top.txt', 'J should include file siblings')
    core.next_sibling()
    assert_eq(current_line(), 'top.txt', 'J should stay on the last sibling')
    core.prev_sibling()
    assert_eq(current_line(), 'beta/', 'K should jump to the previous sibling')
    core.prev_sibling()
    assert_eq(current_line(), 'alpha/', 'K should jump to the previous root sibling')
    core.prev_sibling()
    assert_eq(current_line(), 'alpha/', 'K should stay on the first sibling')

    set_cursor_line('nested/$')
    core.prev_sibling()
    assert_match(current_line(), 'nested/$', 'K should stay on the first child sibling')

    set_cursor_line('nested/$')
    core.next_sibling()
    assert_match(current_line(), 'file%.txt$', 'J should jump to the next nested sibling')
    core.prev_sibling()
    assert_match(current_line(), 'nested/$', 'K should jump to the previous nested sibling')
    core.next_sibling()
    assert_match(current_line(), 'file%.txt$', 'J should jump to the next nested sibling')
    core.next_sibling()
    assert_match(current_line(), 'file%.txt$', 'J should stay on the last child sibling')

    set_cursor_line('deep%.txt$')
    core.prev_sibling()
    assert_match(current_line(), 'deep%.txt$', 'K should stay on an only child sibling')
    core.next_sibling()
    assert_match(current_line(), 'deep%.txt$', 'J should stay on an only child sibling')

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
    core.collapse_reset()
    assert(not state.expanded_dirs[root .. '/root'], 'reset collapse should clear selected directory')
    assert(not state.expanded_dirs[root .. '/root/a'], 'reset collapse should clear descendants')
    assert(not state.expanded_dirs[root .. '/root/a/b'], 'reset collapse should clear nested descendants')
    assert(not state.expanded_dirs[root .. '/root/empty'], 'reset collapse should clear empty descendants')
    assert(not vim.tbl_contains(lines(), '├── a/'), 'reset collapse should hide children')

    core.expand()
    assert(vim.tbl_contains(lines(), '├── a/'), 'expand after reset should show one level')
    assert(not vim.tbl_contains(lines(), '│   └── b/'), 'expand after reset should not restore recursive state')

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
    core.toggle_mark_visual()
    assert_eq(mark_count(state), 2)
    assert(state.marks[state.cwd .. '/a'], 'visual toggle should mark first selected row')
    assert(state.marks[state.cwd .. '/b'], 'visual toggle should mark second selected row')
    assert(not state.marks[state.cwd .. '/c'], 'visual toggle should not mark unselected rows')

    vim.fn.setpos("'<", {0, 2, 1, 0})
    vim.fn.setpos("'>", {0, 1, 1, 0})
    core.toggle_mark_visual()
    assert_eq(mark_count(state), 0, 'visual toggle should handle reversed ranges')

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
    assert_eq(mark_count(state), 1)
    assert(not state.marks[state.cwd .. '/a'], 'live visual toggle should not use stale visual marks')
    assert(state.marks[state.cwd .. '/b'], 'live visual toggle should mark the selected cursor line')

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
    core.toggle_mark()
    assert(state.marks[root .. '/alpha/one/file.txt'], 'nested row should mark its real path')

    util.set_cursor_pos('alpha')
    core.collapse()
    assert(not vim.tbl_contains(lines(), '├── one/'), 'collapse should hide children')
    assert(state.expanded_dirs[root .. '/alpha/one'], 'collapse should remember descendant state')

    core.expand()
    assert(vim.tbl_contains(lines(), '│   └── file.txt'), 're-expand should restore previous tree state')

    set_cursor_line('file%.txt$')
    core.collapse()
    assert(not vim.tbl_contains(lines(), '│   └── file.txt'), 'collapsing file should hide sibling rows below its parent directory')
    assert(state.expanded_dirs[root .. '/alpha'], 'collapsing file should leave grandparent expanded')
    assert(not state.expanded_dirs[root .. '/alpha/one'], 'collapsing file should fold its parent directory')
    assert_match(current_line(), 'one/$', 'collapsing file should move cursor to its parent directory')

    core.collapse()
    assert(not vim.tbl_contains(lines(), '├── one/'), 'collapsing an already collapsed directory should fold its parent')
    assert(not state.expanded_dirs[root .. '/alpha'], 'collapsing an already collapsed directory should clear parent expansion')
    assert_match(current_line(), 'alpha/$', 'collapsing child directory should move cursor to its parent directory')

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
    core.toggle_mark()
    assert_eq(mark_count(state), 0, 'empty placeholder should not be markable')

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
assert(api.nvim_buf_get_var(0, 'is_dirtree'), 'Dirtree buffer should be marked')
assert(#api.nvim_buf_get_lines(0, 0, -1, false) > 0, 'Dirtree buffer should render entries')
core.quit()

print('[dirtree] smoke ok')
