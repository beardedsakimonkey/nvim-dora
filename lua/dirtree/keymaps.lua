local window = require'dirtree.window'

local api = vim.api
local uv = vim.loop

local M = {}

local HINT_ARROW = '→'

local VISUAL_KEYMAP_ACTIONS = {
    next_sibling = 'next_sibling',
    prev_sibling = 'prev_sibling',
    toggle_selection = 'toggle_visual_selection',
}

---@param rhs DirtreeKeymapSpec
---@return DirtreeKeymapAction action
---@return string? desc
local function normalize_keymap(rhs)
    if type(rhs) == 'table' then
        assert(rhs[1], 'keymap table must include an action at index 1')
        return rhs[1], rhs.desc
    end
    return rhs, nil
end

---@param action DirtreeKeymapAction
---@return function|string
local function map_keymap_action(action)
    if type(action) ~= 'string' then
        return action
    end
    local core_action = require'dirtree.core'[action]
    if type(core_action) == 'function' then
        return core_action
    end
    return action
end

---@param action DirtreeKeymapAction
local function dispatch_keymap_action(action)
    if type(action) == 'function' then
        action()
        return
    end
    local core_action = require'dirtree.core'[action]
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

---@class DirtreeKeymapHintRow
---@field lhs string
---@field desc string

---@param prefix string
---@param rows DirtreeKeymapHintRow[]
---@return integer buf
---@return integer win
function M.open_hint_window(prefix, rows)
    local key_width = 1
    local desc_width = 1
    for _, row in ipairs(rows) do
        key_width = math.max(key_width, vim.fn.strdisplaywidth(row.lhs))
        desc_width = math.max(desc_width, vim.fn.strdisplaywidth(row.desc))
    end

    local width = math.max(24, math.min(72, key_width + desc_width + 7))
    local height = math.max(1, #rows)
    local origin_win = api.nvim_get_current_win()
    local buf = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace('dirtree/keymaps.hints.' .. buf)
    local lines = {}

    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = true
    for _, row in ipairs(rows) do
        lines[#lines+1] = ('  %-' .. key_width .. 's  ' .. HINT_ARROW .. '  %s'):format(row.lhs, row.desc)
    end
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    for i, _ in ipairs(rows) do
        local lnum = i - 1
        local arrow_col = 2 + key_width + 2
        local desc_col = arrow_col + #HINT_ARROW + 2
        api.nvim_buf_set_extmark(buf, ns, lnum, 2, {
            end_col = 2 + key_width,
            hl_group = 'DirtreeHelpKey',
        })
        api.nvim_buf_set_extmark(buf, ns, lnum, arrow_col, {
            end_col = arrow_col + #HINT_ARROW,
            hl_group = 'DirtreeKeymapHintArrow',
        })
        api.nvim_buf_set_extmark(buf, ns, lnum, desc_col, {
            end_col = #lines[i],
            hl_group = 'DirtreeHelpDesc',
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
        style = 'minimal',
        noautocmd = true,
        focusable = false,
    })
    vim.wo[win].winhighlight = 'NormalFloat:Normal'
    vim.wo[win].cursorline = false
    return buf, win
end

---@param keymaps table<string, DirtreeKeymapSpec>
---@return table<string, {lhs: string, key: string, action: DirtreeKeymapAction, desc: string}[]>
local function keymap_hint_groups(keymaps)
    local groups = {}
    for lhs, rhs in pairs(keymaps) do
        if #lhs == 2 then
            local action, desc = normalize_keymap(rhs)
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
    for _, group in pairs(groups) do
        table.sort(group, function(a, b) return a.lhs < b.lhs end)
    end
    return groups
end

---@param prefix string
---@param group {lhs: string, key: string, action: DirtreeKeymapAction, desc: string}[]
---@param direct? {action: DirtreeKeymapAction, desc: string?}
local function show_keymap_hints(prefix, group, direct)
    local buf, win = M.open_hint_window(prefix, vim.tbl_map(function(entry)
        return {lhs=entry.lhs, desc=entry.desc}
    end, group))
    vim.cmd.redraw()
    local key = read_key(vim.o.timeoutlen)
    window.close(buf, win)
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
---@param groups table<string, {lhs: string, key: string, action: DirtreeKeymapAction, desc: string}[]>
---@return boolean
local function is_keymap_hint_prefix(lhs, groups)
    return #lhs == 1 and groups[lhs] ~= nil
end

---@param keymaps? table<string, DirtreeKeymapSpec>
---@return table<string, DirtreeKeymapSpec>
function M.derive_visual_keymaps(keymaps)
    local ret = {}
    for lhs, rhs in pairs(keymaps or {}) do
        local action, desc = normalize_keymap(rhs)
        local visual_action = type(action) == 'string' and VISUAL_KEYMAP_ACTIONS[action] or nil
        if visual_action then
            ret[lhs] = desc and {visual_action, desc=desc} or visual_action
        end
    end
    return ret
end

---@param buf integer
---@param config DirtreeConfig
function M.setup(buf, config)
    local hint_groups = keymap_hint_groups(config.keymaps)
    for lhs, rhs in pairs(config.keymaps) do
        local action, desc = normalize_keymap(rhs)
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
                local action, desc = normalize_keymap(config.keymaps[prefix])
                direct = {action=action, desc=desc}
            end
            vim.keymap.set('n', prefix, function()
                show_keymap_hints(prefix, group, direct)
            end, {nowait=true, silent=true, buffer=buf, desc=direct and direct.desc or 'Show keymap hints'})
        end
    end
    for lhs, rhs in pairs(M.derive_visual_keymaps(config.keymaps)) do
        local action, desc = normalize_keymap(rhs)
        vim.keymap.set('x', lhs, map_keymap_action(action), {nowait=true, silent=true, buffer=buf, desc=desc})
    end
end

return M
