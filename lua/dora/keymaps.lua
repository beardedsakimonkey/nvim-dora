local window = require'dora.window'

local api = vim.api
local uv = vim.loop

local M = {}

local HINT_DELAY = 200
local HINT_ARROW = '→'
local HINT_COLUMN_GAP = '    '
local HINT_KEY_ORDERS = {
    [','] = {n=1, m=2, c=3, s=4, e=5},
    g = {p=1, h=2, f=3, x=4, ['.']=5, ['?']=6},
    y = {y=1, d=2, n=3, b=4},
}

local ACTION_DESCRIPTIONS = {
    quit = 'Quit',
    up_dir = 'Up directory',
    next_sibling = 'Next sibling',
    prev_sibling = 'Previous sibling',
    last_sibling = 'Last sibling',
    first_sibling = 'First sibling',
    parent_dir = 'Go to parent directory',
    expand = 'Expand directory',
    expand_recursive = 'Expand directory recursively',
    collapse = 'Collapse directory',
    collapse_recursive = 'Collapse directory recursively',
    close_dir = 'Close directory',
    filter = 'Filter visible files',
    clear_filter = 'Clear filter',
    reload = 'Reload listing',
    open = 'Open',
    open_split = 'Open in split',
    open_vsplit = 'Open in vertical split',
    open_tab = 'Open in tab',
    open_split_keep = 'Open in split in place',
    open_vsplit_keep = 'Open in vertical split in place',
    open_tab_keep = 'Open in tab in place',
    info = 'Show file info',
    trash = 'Move file to trash',
    delete = 'Delete file permanently',
    create = 'Add file',
    create_under = 'Add file under directory',
    create_symlink = 'Add symlink to file',
    rename = 'Rename file',
    rename_empty = 'Rename file with empty prompt',
    set_bookmark = 'Set bookmark',
    jump_bookmark = 'Jump to bookmark',
    toggle_cut = 'Toggle cut mark',
    toggle_copy = 'Toggle copy mark',
    paste = 'Paste',
    paste_parent = 'Paste under parent directory',
    clear_marks = 'Clear cut/copy marks',
    follow_symlink = 'Follow symlink',
    home_dir = 'Go to home directory',
    open_external = 'Open externally',
    shell_cmd = 'Shell command on file',
    toggle_hidden_files = 'Toggle hidden files',
    help = 'Show help',
    yank_filename = 'Yank file name',
    yank_file_path = 'Yank full path',
    yank_file_path_clipboard = 'Yank full path to clipboard',
    yank_dir_path = 'Yank directory path',
    yank_dir_path_clipboard = 'Yank directory path to clipboard',
    yank_filename_clipboard = 'Yank file name to clipboard',
    yank_basename = 'Yank basename',
    yank_basename_clipboard = 'Yank basename to clipboard',
    sort_by_name = 'Sort by name',
    sort_by_name_desc = 'Sort by name (descending)',
    sort_by_modified = 'Sort by modified time',
    sort_by_modified_desc = 'Sort by modified time (descending)',
    sort_by_created = 'Sort by creation time',
    sort_by_created_desc = 'Sort by creation time (descending)',
    sort_by_size = 'Sort by size',
    sort_by_size_desc = 'Sort by size (descending)',
    sort_by_extension = 'Sort by extension',
    sort_by_extension_desc = 'Sort by extension (descending)',
}

-- Mnemonic words for hints where the right word can't be derived from the
-- hint key, e.g. the doubled key in yy → 'Yank full path', or non-letter
-- keys like g? and g.
local ACTION_MNEMONICS = {
    help = 'help',
    toggle_hidden_files = 'hidden',
    yank_file_path = 'full',
    yank_file_path_clipboard = 'full',
}

local VISUAL_KEYMAP_ACTIONS = {
    collapse = 'collapse_visual',
    collapse_recursive = 'collapse_recursive_visual',
    delete = 'delete_visual',
    expand = 'expand_visual',
    expand_recursive = 'expand_recursive_visual',
    first_sibling = 'first_sibling',
    last_sibling = 'last_sibling',
    next_sibling = 'next_sibling',
    prev_sibling = 'prev_sibling',
    toggle_copy = 'toggle_copy_visual',
    toggle_cut = 'toggle_cut_visual',
    trash = 'trash_visual',
}

---@param rhs DoraKeymapSpec
---@return DoraKeymapAction action
---@return string? desc
function M.resolve(rhs)
    if type(rhs) == 'table' then
        assert(rhs[1], 'keymap table must include an action at index 1')
        local action = rhs[1]
        local desc = rhs.desc or (type(action) == 'string' and ACTION_DESCRIPTIONS[action] or nil)
        return action, desc
    end
    local desc = type(rhs) == 'string' and ACTION_DESCRIPTIONS[rhs] or nil
    return rhs, desc
end

---@param action DoraKeymapAction
---@return function|string
local function map_keymap_action(action)
    if type(action) ~= 'string' then
        return action
    end
    local core_action = require'dora.core'[action]
    if type(core_action) == 'function' then
        return core_action
    end
    return action
end

---@param action DoraKeymapAction
local function dispatch_keymap_action(action)
    if type(action) == 'function' then
        action()
        return
    end
    local core_action = require'dora.core'[action]
    if type(core_action) == 'function' then
        core_action()
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
---@field mnemonic? string explicit mnemonic word overriding the derivation

-- Find the word in `desc` that motivates the hint key, e.g. "name" in
-- 'Sort by name' for ,n. Prefers the last word starting with the key (the
-- leading verb is usually shared by the whole hint group), then the first
-- word merely containing it (e.g. "externally" for gx). An explicit
-- `mnemonic` word takes precedence over the derivation.
---@param desc string
---@param key string?
---@param mnemonic string?
---@return integer? start_pos
---@return integer? stop_pos inclusive
local function mnemonic_span(desc, key, mnemonic)
    if mnemonic then
        return desc:lower():find('%f[%a]' .. mnemonic:lower() .. '%f[%A]')
    end
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
        if word:sub(1, 1) == key then
            match_start, match_stop = start_pos, stop_pos
        elseif not contains_start and word:find(key, 1, true) then
            contains_start, contains_stop = start_pos, stop_pos
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
        hl_group = 'DoraKeymapHintArrow',
    }
    marks[#marks+1] = {
        lnum = lnum,
        col = desc_col,
        end_col = desc_col + #row.desc,
        hl_group = 'DoraInfoValue',
    }
    local mnemonic_start, mnemonic_stop = mnemonic_span(row.desc, row.key, row.mnemonic)
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
---@return string?
function M.read_hint_key(prefix, rows)
    local timeout = math.max(0, vim.o.timeoutlen)
    local delay = math.min(timeout, HINT_DELAY)
    local key = read_key(delay)
    if not key and delay < timeout then
        local buf, win
        if #rows > 0 then
            buf, win = M.open_hint_window(prefix, rows)
            vim.cmd.redraw()
        end
        key = read_key(timeout - delay)
        if buf and win then
            window.close(buf, win)
        end
    end
    return key
end

---@param keymaps table<string, DoraKeymapSpec>
---@return table<string, {lhs: string, key: string, action: DoraKeymapAction, desc: string, mnemonic?: string}[]>
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
                mnemonic = type(action) == 'string' and ACTION_MNEMONICS[action] or nil,
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

---@param prefix string
---@param group {lhs: string, key: string, action: DoraKeymapAction, desc: string}[]
---@param direct? {action: DoraKeymapAction, desc: string?}
local function show_keymap_hints(prefix, group, direct)
    local key = M.read_hint_key(prefix, vim.tbl_map(function(entry)
        return {lhs=entry.lhs, desc=entry.desc, key=entry.key, mnemonic=entry.mnemonic}
    end, group))
    for _, entry in ipairs(group) do
        if key == entry.key then
            dispatch_keymap_action(entry.action)
            return
        end
    end
    if direct then
        dispatch_keymap_action(direct.action)
        if key then
            api.nvim_feedkeys(key, 'n', false)
        end
        return
    end
    if not key then
        return
    end
    api.nvim_feedkeys(prefix .. key, 'n', false)
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
        local visual_action = type(action) == 'string' and VISUAL_KEYMAP_ACTIONS[action] or nil
        if visual_action then
            ret[lhs] = desc and {visual_action, desc=desc} or visual_action
        end
    end
    return ret
end

---@param buf integer
---@param config DoraConfig
function M.setup(buf, config)
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
