-- Input prompt behavior: validation border colors and escape/close handling.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/03_prompt.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local dora = h.dora
local config = h.config
local prompt = h.prompt
local api = h.api
local window = h.window
local cwd = h.cwd
local assert_eq = h.assert_eq

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
    assert_eq(cfg.col, pos.col - 2, 'prompt content should start at the anchor column')

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

do
    local ns = vim.api.nvim_create_namespace('dora/prompt')
    local p = prompt.input({
        prompt = 'Dynamic icon',
        cwd = cwd,
        icon = function(input)
            return vim.endswith(input, '/') and 'D' or 'F', 'DoraIcon'
        end,
        validate = function(input)
            return input
        end,
    }, function() end)
    ---@cast p DoraPrompt

    local function icon_virt_text()
        local marks = vim.api.nvim_buf_get_extmarks(p.input_buf, ns, 0, -1, {details = true})
        assert_eq(#marks, 1, 'the prompt should keep a single icon extmark')
        return marks[1][4].virt_text[1][1]
    end

    assert_eq(icon_virt_text(), 'F ', 'a function icon should render for the initial input')
    p:set_input('foo/', 4)
    p:update_icon()
    assert_eq(icon_virt_text(), 'D ', 'a function icon should re-resolve as the input changes')
    p:set_input('foo', 3)
    p:update_icon()
    assert_eq(icon_virt_text(), 'F ', 'removing the trailing slash should switch back to the file icon')
    p:cancel()
end
