-- Shared helpers for the smoke suite (scripts/tests/*.lua). Each test file
-- loads this with dofile and pulls what it needs from the returned table.
-- Loading is idempotent: the table is built once per Neovim instance and
-- cached, so the suite driver and standalone single-file runs both work.
if _G.__dora_smoke_helpers then
    return _G.__dora_smoke_helpers
end

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
local actions = require'dora.actions'
local history = require'dora.history'
local fs = require'dora.fs'
local config = dora.config
local confirm_win = require'dora.ui.confirm'
local keymaps = require'dora.keymaps'
local prompt = require'dora.ui.prompt'
local api = require'dora.api'
local store = require'dora.store'
local window = require'dora.ui.window'

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

-- Trash/delete are asynchronous like paste; pump the event loop until the
-- in-flight removal finishes before asserting on its result.
local function wait_for_remove()
    assert(vim.wait(5000, function()
        return not store.get().remove_in_progress
    end), 'remove did not finish')
end

local function clear_persisted_view_state(win)
    history.clear(win or vim.api.nvim_get_current_win())
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

local H = {
    assert_eq = assert_eq,
    assert_match = assert_match,
    dora = dora,
    actions = actions,
    history = history,
    fs = fs,
    config = config,
    confirm_win = confirm_win,
    keymaps = keymaps,
    prompt = prompt,
    api = api,
    store = store,
    window = window,
    cwd = cwd,
    touch = touch,
    write_file = write_file,
    marked_path_count = marked_path_count,
    wait_for_paste = wait_for_paste,
    wait_for_remove = wait_for_remove,
    clear_persisted_view_state = clear_persisted_view_state,
    lines = lines,
    buf_lines = buf_lines,
    set_cursor_line = set_cursor_line,
    current_line = current_line,
    find_line_index = find_line_index,
    set_cursor_pos = set_cursor_pos,
    assert_line_before = assert_line_before,
    win_title = win_title,
    has_highlight = has_highlight,
    has_high_priority_highlight = has_high_priority_highlight,
    has_priority_highlight = has_priority_highlight,
    has_sign_highlight = has_sign_highlight,
    cursor_tree_highlights = cursor_tree_highlights,
    assert_cursor_tree_highlights = assert_cursor_tree_highlights,
}
_G.__dora_smoke_helpers = H
return H
