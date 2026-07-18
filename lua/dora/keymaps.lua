-- Installs dora's buffer-local keymaps, resolving each spec (a built-in
-- action name, a function, or a Vim RHS string) against the action registry,
-- and renders the which-key-style hint window for two-key prefixes.
local actions = require'dora.actions'
local window = require'dora.ui.window'

local api = vim.api
local uv = vim.uv

local M = {}

local HINT_DELAY = 200
local HINT_ARROW = '→'
local HINT_COLUMN_GAP = '    '
local HINT_KEY_ORDERS = {
    [','] = {n=1, m=2, c=3, s=4, e=5},
    g = {i=1, p=2, h=3, x=4, ['.']=5, ['?']=6},
    y = {y=1, d=2, f=3, n=4},
}

---@param rhs DoraKeymapSpec
---@return DoraKeymapAction action
---@return string? desc
function M.resolve(rhs)
    if type(rhs) == 'table' then
        assert(rhs[1], 'keymap table must include an action at index 1')
        local action = rhs[1]
        local desc = rhs.desc or (type(action) == 'string' and actions.descriptions[action] or nil)
        return action, desc
    end
    local desc = type(rhs) == 'string' and actions.descriptions[rhs] or nil
    return rhs, desc
end

---@param action DoraKeymapAction
---@return boolean
function M.has_visual_variant(action)
    return type(action) == 'string' and actions.visual_variants[action] ~= nil
end

---@return DoraKeymapContext
local function keymap_context()
    local state = require'dora.store'.get()
    local row = state.rows and state.rows[api.nvim_win_get_cursor(0)[1]] or nil
    local ctx = {cwd = state.cwd}
    if row and row.path then
        ctx.path = row.path
        ctx.type = row.type
    end
    return ctx
end

-- Dora needs a distinct buffer name for every live session. In a duplicate
-- session that name has an ID suffix, so expand % to the browsed directory for
-- the standard directory-changing commands instead of to the buffer name.
---@return string
local function commandline_percent()
    if vim.fn.getcmdline():match('^%s*[lt]?cd%s+$') then
        return vim.fn.fnameescape(require'dora.store'.get().cwd)
    end
    return '%'
end

-- Resolve a string action name to its dora/api.lua function, or nil when the
-- string is a plain Vim RHS rather than a built-in action name. api.lua is
-- required lazily: it requires this module at load time, so a top-level
-- require here would create a cycle.
---@param action DoraKeymapAction
---@return function?
local function api_action(action)
    if type(action) ~= 'string' then
        return nil
    end
    local fn = require'dora.api'[action]
    return type(fn) == 'function' and fn or nil
end

---@param action DoraKeymapAction
---@return function|string
local function map_keymap_action(action)
    if type(action) ~= 'string' then
        return function() action(keymap_context()) end
    end
    return api_action(action) or action
end

---@param action DoraKeymapAction
local function dispatch_keymap_action(action)
    if type(action) == 'function' then
        action(keymap_context())
        return
    end
    local fn = api_action(action)
    if fn then
        fn()
        return
    end
    api.nvim_feedkeys(api.nvim_replace_termcodes(action, true, true, true), 'nx', false)
end

---@param timeout integer
---@return string?
local function read_key(timeout)
    local started = uv.hrtime()
    while (uv.hrtime() - started) / 1000000 < timeout do
        local key = vim.fn.getcharstr(0)
        if key ~= '' then
            return key
        end
        vim.wait(10)
    end
    return nil
end

---@class DoraKeymapHintRow
---@field lhs string
---@field desc string
---@field key? string hint key used to derive the highlighted mnemonic word

-- Find the word in `desc` that motivates the hint key, e.g. "name" in
-- 'Sort by name' for ,n. Prefers the last word starting with the key (the
-- leading verb is usually shared by the whole hint group), then the first
-- word merely containing it (e.g. "externally" for gx).
---@param desc string
---@param key string?
---@return integer? start_pos
---@return integer? stop_pos inclusive
local function mnemonic_span(desc, key)
    if not key or not key:match('^%a$') then
        return nil
    end
    key = key:lower()
    local match_start, match_stop
    local contains_start, contains_stop
    local init = 1
    while true do
        local start_pos, stop_pos = desc:find('%a+', init)
        if not start_pos or not stop_pos then
            break
        end
        local word = desc:sub(start_pos, stop_pos):lower()
        if word ~= 'yank' then
            if word:sub(1, 1) == key then
                match_start, match_stop = start_pos, stop_pos
            elseif not contains_start and word:find(key, 1, true) then
                contains_start, contains_stop = start_pos, stop_pos
            end
        end
        init = stop_pos + 1
    end
    if match_start then
        return match_start, match_stop
    end
    return contains_start, contains_stop
end

---@param rows DoraKeymapHintRow[]
---@return integer key_width
---@return integer desc_width
local function hint_widths(rows)
    local key_width = 1
    local desc_width = 1
    for _, row in ipairs(rows) do
        key_width = math.max(key_width, vim.fn.strdisplaywidth(row.lhs))
        desc_width = math.max(desc_width, vim.fn.strdisplaywidth(row.desc))
    end
    return key_width, desc_width
end

---@param line string
---@param marks table[]
---@param lnum integer
---@param row DoraKeymapHintRow
---@param key_width integer
---@param desc_width integer
---@param pad_desc boolean
---@return string
local function append_hint_cell(line, marks, lnum, row, key_width, desc_width, pad_desc)
    local key = ('%-' .. key_width .. 's'):format(row.lhs)
    local desc = pad_desc and ('%-' .. desc_width .. 's'):format(row.desc) or row.desc
    local key_col = #line
    line = line .. key .. '  '
    local arrow_col = #line
    line = line .. HINT_ARROW .. '  '
    local desc_col = #line
    line = line .. desc

    marks[#marks+1] = {
        lnum = lnum,
        col = key_col,
        end_col = key_col + #key,
        hl_group = 'DoraInfoLabel',
    }
    marks[#marks+1] = {
        lnum = lnum,
        col = arrow_col,
        end_col = arrow_col + #HINT_ARROW,
        hl_group = 'DoraMutedText',
    }
    marks[#marks+1] = {
        lnum = lnum,
        col = desc_col,
        end_col = desc_col + #row.desc,
        hl_group = 'DoraInfoValue',
    }
    local mnemonic_start, mnemonic_stop = mnemonic_span(row.desc, row.key)
    if mnemonic_start then
        marks[#marks+1] = {
            lnum = lnum,
            col = desc_col + mnemonic_start - 1,
            end_col = desc_col + mnemonic_stop,
            hl_group = 'DoraKeymapHintMnemonic',
            priority = 200,
        }
    end
    return line
end

---@param prefix string
---@param rows DoraKeymapHintRow[]
---@return {lower: DoraKeymapHintRow, upper: DoraKeymapHintRow, key: string}[]?
local function case_pair_rows(prefix, rows)
    local prefix_len = #prefix
    local by_key = {}
    for _, row in ipairs(rows) do
        if row.lhs:sub(1, prefix_len) ~= prefix then
            return nil
        end
        local key = row.lhs:sub(prefix_len + 1)
        if #key ~= 1 or key:lower() == key:upper() then
            return nil
        end
        local lower_key = key:lower()
        by_key[lower_key] = by_key[lower_key] or {}
        if key == lower_key then
            by_key[lower_key].lower = row
        elseif key == key:upper() then
            by_key[lower_key].upper = row
        else
            return nil
        end
    end

    local pair_rows = {}
    for key, pair in pairs(by_key) do
        if not pair.lower or not pair.upper then
            return nil
        end
        pair_rows[#pair_rows+1] = {key=key, lower=pair.lower, upper=pair.upper}
    end
    if #pair_rows * 2 ~= #rows then
        return nil
    end

    table.sort(pair_rows, function(a, b)
        local key_order = HINT_KEY_ORDERS[prefix]
        if key_order then
            local a_order = key_order[a.key] or 100
            local b_order = key_order[b.key] or 100
            if a_order ~= b_order then
                return a_order < b_order
            end
        end
        return a.key < b.key
    end)
    return pair_rows
end

---@param rows DoraKeymapHintRow[]
---@return string[] lines
---@return table[] marks
local function single_column_hint_lines(rows)
    local key_width, desc_width = hint_widths(rows)
    local lines = {}
    local marks = {}
    for i, row in ipairs(rows) do
        lines[#lines+1] = append_hint_cell('  ', marks, i - 1, row, key_width, desc_width, false)
    end
    return lines, marks
end

---@param prefix string
---@param rows DoraKeymapHintRow[]
---@return string[]? lines
---@return table[]? marks
local function case_pair_hint_lines(prefix, rows)
    local pair_rows = case_pair_rows(prefix, rows)
    if not pair_rows then
        return nil, nil
    end

    local lower_rows = {}
    local upper_rows = {}
    for _, pair in ipairs(pair_rows) do
        lower_rows[#lower_rows+1] = pair.lower
        upper_rows[#upper_rows+1] = pair.upper
    end
    local lower_key_width, lower_desc_width = hint_widths(lower_rows)
    local upper_key_width, upper_desc_width = hint_widths(upper_rows)
    local lines = {}
    local marks = {}
    for i, pair in ipairs(pair_rows) do
        local line = append_hint_cell('  ', marks, i - 1, pair.lower, lower_key_width, lower_desc_width, true)
        line = line .. HINT_COLUMN_GAP
        line = append_hint_cell(line, marks, i - 1, pair.upper, upper_key_width, upper_desc_width, false)
        lines[#lines+1] = line
    end
    return lines, marks
end

---@param lines string[]
---@param max_width integer
---@return integer
local function hint_window_width(lines, max_width)
    local width = 1
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    return math.max(24, math.min(max_width, width))
end

---@param prefix string
---@param rows DoraKeymapHintRow[]
---@return integer buf
---@return integer win
function M.open_hint_window(prefix, rows)
    local origin_win = api.nvim_get_current_win()
    local lines, marks = case_pair_hint_lines(prefix, rows)
    local max_width = 96
    if not lines or not marks then
        lines, marks = single_column_hint_lines(rows)
        max_width = 72
    end
    local width = hint_window_width(lines, max_width)
    local height = math.max(1, #lines)
    local buf = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace('dora/keymaps.hints.' .. buf)

    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    for _, mark in ipairs(marks) do
        api.nvim_buf_set_extmark(buf, ns, mark.lnum, mark.col, {
            end_col = mark.end_col,
            hl_group = mark.hl_group,
            priority = mark.priority,
        })
    end
    vim.bo[buf].modifiable = false

    local win = api.nvim_open_win(buf, false, {
        relative = 'win',
        win = origin_win,
        anchor = 'SE',
        row = api.nvim_win_get_height(origin_win) - 1,
        col = api.nvim_win_get_width(origin_win) - 2,
        width = width,
        height = height,
        border = window.border(),
        style = 'minimal',
        noautocmd = true,
        focusable = false,
    })
    vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:DoraPromptBorder'
    vim.wo[win].cursorline = false
    return buf, win
end

---@param prefix string
---@param rows DoraKeymapHintRow[]
---@param has_direct? boolean prefix also has a standalone action, so keep
---  honoring 'timeoutlen' to let that action fire instead of waiting forever
---@return string?
function M.read_hint_key(prefix, rows, has_direct)
    local timeout = math.max(0, vim.o.timeoutlen)
    local delay = math.min(timeout, HINT_DELAY)
    local key = read_key(delay)
    if not key and delay < timeout then
        if #rows > 0 then
            local buf, win = M.open_hint_window(prefix, rows)
            vim.cmd.redraw()
            -- Once the hint window is up, leave it open until the user picks a
            -- key rather than dismissing it when 'timeoutlen' elapses. Prefixes
            -- that also have a standalone action keep timing out so it can fire.
            key = read_key(has_direct and (timeout - delay) or math.huge)
            window.close(buf, win)
        else
            key = read_key(timeout - delay)
        end
    end
    return key
end

---@param keymaps table<string, DoraKeymapSpec>
---@return table<string, {lhs: string, key: string, action: DoraKeymapAction, desc: string}[]>
local function keymap_hint_groups(keymaps)
    local groups = {}
    for lhs, rhs in pairs(keymaps) do
        if #lhs == 2 then
            local action, desc = M.resolve(rhs)
            local prefix = lhs:sub(1, 1)
            groups[prefix] = groups[prefix] or {}
            groups[prefix][#groups[prefix]+1] = {
                lhs = lhs,
                key = lhs:sub(2, 2),
                action = action,
                desc = desc or tostring(action),
            }
        end
    end
    for prefix, group in pairs(groups) do
        table.sort(group, function(a, b)
            local key_order = HINT_KEY_ORDERS[prefix]
            if key_order then
                local a_order = key_order[a.key] or 100
                local b_order = key_order[b.key] or 100
                if a_order ~= b_order then
                    return a_order < b_order
                end
            end
            return a.lhs < b.lhs
        end)
    end
    return groups
end

-- Replay keys the hint reader consumed but didn't handle. Feed with
-- remapping when a mapping exists for the sequence (e.g. a user's global
-- ]t) so it still fires; unmapped sequences must stay unmapped, or a
-- sequence starting with a hint prefix would re-trigger the prefix mapping
-- and loop forever.
---@param keys string
local function replay_keys(keys)
    local remap = not vim.tbl_isempty(vim.fn.maparg(keys, 'n', false, true))
    api.nvim_feedkeys(keys, remap and 'm' or 'n', false)
end

---@param prefix string
---@param group {lhs: string, key: string, action: DoraKeymapAction, desc: string}[]
---@param direct? {action: DoraKeymapAction, desc: string?}
local function show_keymap_hints(prefix, group, direct)
    local key = M.read_hint_key(prefix, vim.tbl_map(function(entry)
        return {lhs=entry.lhs, desc=entry.desc, key=entry.key}
    end, group), direct ~= nil)
    if key == '\27' then
        -- The hint window now persists past 'timeoutlen', so treat <Esc> as an
        -- explicit cancel instead of firing the direct action or feeding keys.
        return
    end
    for _, entry in ipairs(group) do
        if key == entry.key then
            dispatch_keymap_action(entry.action)
            return
        end
    end
    if direct then
        dispatch_keymap_action(direct.action)
        if key then
            replay_keys(key)
        end
        return
    end
    if not key then
        return
    end
    replay_keys(prefix .. key)
end

---@param lhs string
---@param groups table<string, {lhs: string, key: string, action: DoraKeymapAction, desc: string}[]>
---@return boolean
local function is_keymap_hint_prefix(lhs, groups)
    return #lhs == 1 and groups[lhs] ~= nil
end

---@param keymaps? table<string, DoraKeymapSpec>
---@return table<string, DoraKeymapSpec>
function M.derive_visual_keymaps(keymaps)
    local ret = {}
    for lhs, rhs in pairs(keymaps or {}) do
        local action, desc = M.resolve(rhs)
        local visual_action = type(action) == 'string' and actions.visual_variants[action] or nil
        if visual_action then
            ret[lhs] = desc and {visual_action, desc=desc} or visual_action
        end
    end
    return ret
end

---@param buf integer
---@param config DoraConfig
function M.setup(buf, config)
    vim.keymap.set('c', '%', commandline_percent, {
        buffer = buf,
        expr = true,
        replace_keycodes = false,
        silent = true,
    })
    local hint_groups = keymap_hint_groups(config.keymaps)
    for lhs, rhs in pairs(config.keymaps) do
        local action, desc = M.resolve(rhs)
        vim.keymap.set('n', lhs, map_keymap_action(action), {
            nowait = not is_keymap_hint_prefix(lhs, hint_groups),
            silent = true,
            buffer = buf,
            desc = desc,
        })
    end
    if config.show_keymap_hints then
        for prefix, group in pairs(hint_groups) do
            local direct
            if config.keymaps[prefix] then
                local action, desc = M.resolve(config.keymaps[prefix])
                direct = {action=action, desc=desc}
            end
            vim.keymap.set('n', prefix, function()
                show_keymap_hints(prefix, group, direct)
            end, {nowait=true, silent=true, buffer=buf, desc=direct and direct.desc or 'Show keymap hints'})
        end
    end
    for lhs, rhs in pairs(M.derive_visual_keymaps(config.keymaps)) do
        local action, desc = M.resolve(rhs)
        vim.keymap.set('x', lhs, map_keymap_action(action), {nowait=true, silent=true, buffer=buf, desc=desc})
    end
end

return M
