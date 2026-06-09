local util = require'dora.util'
local window = require'dora.window'

local api = vim.api

local M = {}

-- Needed because Lua tables don't preserve order.
local KEYMAP_ORDER = {
    'q', '-', 'h', 'l', '<CR>', '<2-LeftMouse>',
    's', 'v', 't', 'gx', 'J', 'K', '>', '<', 'gp',
    'o', 'O', 'u', 'U', 'f', 'F', 'R',
    '<Esc>', 'gh', 'g?', 'g.', '.', 'i',
    'd', 'D', 'a', 'A', 'r', 'm', "'", 'x', 'c', 'p', 'P', '.',
    'yy', 'yY', 'yd', 'yD', 'yf', 'yF', 'yb', 'yB',
    ',n', ',N', ',m', ',M', ',c', ',C', ',s', ',S', ',e', ',E',
}

---@class DoraHelpRow
---@field lhs? string
---@field desc? string
---@field section? string

---@param width integer
---@param height integer
---@return table
local function layout(width, height)
    return window.centered_layout({
        title = 'Help',
        width = width,
        height = height,
    })
end

---@param keymaps? table<string, DoraKeymapSpec>
---@param order? string[]
---@return DoraHelpRow[]
local function keymap_rows(keymaps, order)
    local rows = {}
    local handled = {}
    local function add(lhs, rhs)
        local action = type(rhs) == 'table' and rhs[1] or rhs
        local desc = type(rhs) == 'table' and rhs.desc or nil
        rows[#rows+1] = {lhs=lhs, desc=desc or tostring(action)}
    end
    for _, lhs in ipairs(order or {}) do
        if keymaps and keymaps[lhs] then
            add(lhs, keymaps[lhs])
            handled[lhs] = true
        end
    end
    local unordered = {}
    for lhs, rhs in pairs(keymaps or {}) do
        if not handled[lhs] then
            unordered[#unordered+1] = {lhs=lhs, rhs=rhs}
        end
    end
    table.sort(unordered, function(a, b) return a.lhs < b.lhs end)
    for _, entry in ipairs(unordered) do
        add(entry.lhs, entry.rhs)
    end
    return rows
end

---@param config DoraConfig
---@param bookmark_rows? DoraHelpRow[]
---@return DoraHelpRow[]
local function rows(config, bookmark_rows)
    local ret = {}
    if bookmark_rows and #bookmark_rows > 0 then
        ret[#ret+1] = {section='Bookmarks'}
        vim.list_extend(ret, bookmark_rows)
        ret[#ret+1] = {}
    end
    ret[#ret+1] = {section='Keymaps'}
    vim.list_extend(ret, keymap_rows(config.keymaps, KEYMAP_ORDER))
    return ret
end

---@param buf integer
---@param ns integer
---@param help_rows DoraHelpRow[]
local function render(buf, ns, help_rows)
    local key_width = 1
    for _, row in ipairs(help_rows) do
        if row.lhs then
            key_width = math.max(key_width, #row.lhs)
        end
    end

    local lines = {}
    for _, row in ipairs(help_rows) do
        if row.section then
            lines[#lines+1] = row.section
        elseif row.lhs then
            lines[#lines+1] = ('  %-' .. key_width .. 's  %s'):format(row.lhs, row.desc)
        else
            lines[#lines+1] = ''
        end
    end

    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, row in ipairs(help_rows) do
        local lnum = i - 1
        if row.section then
            api.nvim_buf_set_extmark(buf, ns, lnum, 0, {
                end_col = #row.section,
                hl_group = 'DoraInfoLabel',
            })
        elseif row.lhs then
            api.nvim_buf_set_extmark(buf, ns, lnum, 2, {
                end_col = 2 + key_width,
                hl_group = 'DoraInfoLabel',
            })
            api.nvim_buf_set_extmark(buf, ns, lnum, 2 + key_width + 2, {
                end_col = #lines[i],
                hl_group = 'DoraInfoValue',
            })
        end
    end
end

---@param config DoraConfig
---@param bookmark_rows? DoraHelpRow[]
function M.open(config, bookmark_rows)
    local help_rows = rows(config, bookmark_rows)
    if #help_rows == 0 then
        util.warn('No keymap descriptions configured')
        return
    end

    local key_width = 1
    local desc_width = 1
    for _, row in ipairs(help_rows) do
        if row.lhs then
            key_width = math.max(key_width, #row.lhs)
            desc_width = math.max(desc_width, #row.desc)
        end
    end

    local width = math.max(32, math.min(72, key_width + desc_width + 6))
    local height = #help_rows
    local origin_win = api.nvim_get_current_win()
    local buf = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace('dora/help_win.' .. buf)

    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = true
    render(buf, ns, help_rows)
    vim.bo[buf].modifiable = false

    local win = api.nvim_open_win(buf, true, layout(width, height))
    vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:DoraPromptBorder'
    vim.wo[win].cursorline = false

    local function close()
        window.close(buf, win)
        if api.nvim_win_is_valid(origin_win) then
            pcall(api.nvim_set_current_win, origin_win)
        end
    end
    for _, lhs in ipairs({'H', '?', 'q', '<Esc>', '<C-c>', '<CR>'}) do
        vim.keymap.set('n', lhs, close, {buffer=buf, silent=true, nowait=true})
    end
end

return M
