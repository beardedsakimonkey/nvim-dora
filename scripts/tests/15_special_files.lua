-- Special file type rendering: the ls -F virt text markers and highlights
-- for fifos and sockets, device highlights, and the provider-independent
-- fallback icons. Part of the smoke suite (driven by scripts/smoke.lua). Run
-- this file on its own with DORA_TEST_FILE=scripts/tests/15_special_files.lua
-- (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local api = h.api
local store = h.store
local assert_eq = h.assert_eq
local touch = h.touch
local lines = h.lines
local find_line_index = h.find_line_index
local has_priority_highlight = h.has_priority_highlight

local icons = require'dora.icons'

do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/regular.txt')
    vim.fn.system({'mkfifo', tmp .. '/my-fifo'})
    assert_eq(vim.v.shell_error, 0, 'mkfifo should succeed')
    -- Closing the handle unlinks the socket file, so keep it open until the
    -- assertions below are done.
    local sock = vim.loop.new_pipe(false)
    assert(sock:bind(tmp .. '/my-socket'))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local state = store.get()

    local rendered = lines()
    local fifo_line = assert(find_line_index(rendered, '^my%-fifo$'), 'fifo should render')
    local socket_line = assert(find_line_index(rendered, '^my%-socket$'), 'socket should render')
    local regular_line = assert(find_line_index(rendered, '^regular%.txt$'), 'regular file should render')

    local function overlay_marker(lnum)
        local marks = vim.api.nvim_buf_get_extmarks(state.buf, state.ns, {lnum - 1, 0}, {lnum - 1, -1}, {details = true})
        for _, mark in ipairs(marks) do
            local details = mark[4]
            ---@cast details -nil  -- always present with {details = true}
            if details.virt_text and details.virt_text_pos == 'overlay' then
                return details.virt_text[1][1], details.hl_mode
            end
        end
    end

    local fifo_marker, fifo_hl_mode = overlay_marker(fifo_line)
    assert_eq(fifo_marker, '|', 'fifos should render the ls -F pipe marker')
    assert_eq(fifo_hl_mode, 'combine')
    assert_eq(overlay_marker(socket_line), '=', 'sockets should render the ls -F socket marker')
    assert_eq(overlay_marker(regular_line), nil, 'regular files should render no type marker')

    assert(has_priority_highlight(state, 'DoraFifo', 100), 'fifo lines should use the DoraFifo highlight')
    assert(has_priority_highlight(state, 'DoraSocket', 100), 'socket lines should use the DoraSocket highlight')

    api.quit()
    sock:close()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

do
    -- Special types take the built-in fallback icons under both providers,
    -- bypassing name/extension matching (a fifo named log.txt is not a text
    -- file, and a char device like /dev/null is not a generic file).
    for _, provider in ipairs({true, 'mini.icons'}) do
        for file_type, special in pairs(icons.special_types) do
            local icon, hl = icons.get(provider, {name = 'log.txt', type = file_type, size = 0}, '/dev/log.txt')
            assert_eq(icon, special.icon, 'provider should fall back for ' .. file_type)
            assert_eq(hl, special.hl, 'fallback should use the ' .. file_type .. ' highlight')
        end
    end
end
