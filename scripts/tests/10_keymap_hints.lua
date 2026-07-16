-- Keymap hints: prefix hint windows, mapping descriptions, disabled hints.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/10_keymap_hints.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local config = h.config
local keymaps = h.keymaps
local api = h.api
local window = h.window
local cwd = h.cwd
local assert_eq = h.assert_eq
local assert_match = h.assert_match

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
        {lhs=',x', key='x', desc='Open in external program'},
        {lhs=',q', key='q', desc='Sort by name'},
        {lhs=',.', key='.', desc='Toggle hidden files visible'},
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
    assert_eq(mnemonics[1], 'external', 'mnemonics should fall back to a word containing the key')
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
    assert_match(hint_lines[1], '^  yy%s+→%s+Yank full path%s+yY%s+→%s+Yank full path to clipboard$')
    assert_match(hint_lines[2], '^  yd%s+→%s+Yank parent directory%s+yD%s+→%s+Yank parent directory to clipboard$')
    assert_match(hint_lines[3], '^  yf%s+→%s+Yank filename%s+yF%s+→%s+Yank filename to clipboard$')
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
    assert_eq(vim.fn.maparg('za', 'n', false, true).desc, 'Reload tree view',
        'named actions should inherit mapping descriptions')
    vim.defer_fn(function()
        vim.api.nvim_feedkeys('a', 't', false)
    end, 250)
    prefix_map.callback()
    assert_eq(vim.g.dora_smoke_named_keymap, 'reload', 'keymap hints should dispatch named api actions')
    assert_eq(captured_rows[1].desc, 'Reload tree view',
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
        zx = {function() vim.g.dora_smoke_hint_keymap = 'zx' end, desc='Xray'},
    }
    config.show_keymap_hints = true
    vim.keymap.set('n', 'zt', function() vim.g.dora_smoke_global_keymap = 'zt' end, {desc='Global zt'})
    vim.g.dora_smoke_global_keymap = nil
    vim.g.dora_smoke_hint_keymap = nil

    vim.cmd('Dora ' .. vim.fn.fnameescape(cwd))
    local prefix_map = vim.fn.maparg('z', 'n', false, true)
    vim.api.nvim_feedkeys('t', 't', false)
    prefix_map.callback()
    vim.api.nvim_feedkeys('', 'x', false)
    assert_eq(vim.g.dora_smoke_global_keymap, 'zt',
        "keys that don't match a hint should fall through to the user's own mappings")
    assert_eq(vim.g.dora_smoke_hint_keymap, nil, 'falling through should not dispatch a hint action')

    vim.api.nvim_feedkeys('q', 't', false)
    prefix_map.callback()
    vim.api.nvim_feedkeys('', 'x', false)
    assert_eq(vim.g.dora_smoke_global_keymap, 'zt',
        'unmapped sequences should replay without remapping (and must not re-trigger the prefix)')
    assert_eq(vim.g.dora_smoke_hint_keymap, nil, 'unmapped sequences should not dispatch a hint action')
    api.quit()

    vim.keymap.del('n', 'zt')
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
