-- The `g?` help split: lists the configured mappings grouped into the
-- sections defined by the action registry, plus saved bookmarks.
local actions = require'dora.actions'
local keymaps = require'dora.keymaps'
local util = require'dora.util'
local window = require'dora.window'

local api = vim.api

local M = {}

---@class DoraHelpRow
---@field lhs? string
---@field desc? string
---@field section? string
---@field visual? boolean whether the mapping also works on a visual selection

---@param mappings? table<string, DoraKeymapSpec>
---@return table<string, DoraHelpRow[]>
local function keymap_sections(mappings)
    local sections = {}
    for _, name in ipairs(actions.SECTIONS) do
        sections[name] = {}
    end
    local action_sections = {}
    local action_order = {}
    local section_counts = {}
    for _, meta in ipairs(actions.ACTIONS) do
        action_sections[meta.name] = meta.section
        section_counts[meta.section] = (section_counts[meta.section] or 0) + 1
        action_order[meta.name] = section_counts[meta.section]
    end
    sections.Other = {}

    for lhs, rhs in pairs(mappings or {}) do
        local action, desc = keymaps.resolve(rhs)
        local section = type(action) == 'string' and action_sections[action] or nil
        local rows = sections[section or 'Other']
        rows[#rows+1] = {
            lhs = lhs,
            desc = desc or tostring(action),
            visual = keymaps.has_visual_variant(action),
            order = action_order[action],
        }
    end

    for _, rows in pairs(sections) do
        table.sort(rows, function(a, b)
            if a.order ~= b.order then
                if a.order == nil then return false end
                if b.order == nil then return true end
                return a.order < b.order
            end
            return a.lhs < b.lhs
        end)
        for _, row in ipairs(rows) do
            row.order = nil
        end
    end
    return sections
end

---@param config DoraConfig
---@param bookmark_rows? DoraHelpRow[]
---@return DoraHelpRow[]
local function rows(config, bookmark_rows)
    local ret = {}
    local sections = keymap_sections(config.keymaps)
    if bookmark_rows then
        vim.list_extend(sections.Navigation, bookmark_rows)
    end

    local function add_section(name)
        local section_rows = sections[name]
        if #section_rows == 0 then
            return
        end
        if #ret > 0 then
            ret[#ret+1] = {}
        end
        ret[#ret+1] = {section=name}
        vim.list_extend(ret, section_rows)
    end

    for _, name in ipairs(actions.SECTIONS) do
        add_section(name)
    end
    add_section('Other')
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
    local marks = {}
    for i, row in ipairs(help_rows) do
        local lnum = i - 1
        if row.section then
            lines[i] = row.section
            marks[#marks+1] = {lnum=lnum, col=0, end_col=#row.section, hl='DoraHelpSection'}
        elseif row.lhs then
            -- Keymap column
            local line = '  '
            local key = ('%-' .. key_width .. 's'):format(row.lhs)
            local key_col = #line
            line = line .. key
            marks[#marks+1] = {lnum=lnum, col=key_col, end_col=key_col + #key, hl='DoraInfoLabel'}
            -- Mode column
            line = line .. '  '
            local mode = row.visual and 'nv' or 'n'
            local mode_col = #line
            line = line .. ('%-2s'):format(mode)
            marks[#marks+1] = {lnum=lnum, col=mode_col, end_col=mode_col + #mode, hl='DoraMutedText'}
            -- Description column
            line = line .. '  '
            local desc_col = #line
            line = line .. row.desc
            marks[#marks+1] = {lnum=lnum, col=desc_col, end_col=#line, hl='DoraInfoValue'}
            lines[i] = line
        else
            lines[i] = ''
        end
    end

    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, mark in ipairs(marks) do
        api.nvim_buf_set_extmark(buf, ns, mark.lnum, mark.col, {
            end_col = mark.end_col,
            hl_group = mark.hl,
        })
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

    local origin_win = api.nvim_get_current_win()
    local buf = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace('dora/help_win.' .. buf)

    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = true
    render(buf, ns, help_rows)
    vim.bo[buf].modifiable = false

    -- The URI form keeps vim from resolving the name as a path
    local name = 'dora://help'
    local i = 0
    while vim.fn.bufexists(name) ~= 0 do
        i = i + 1
        name = 'dora://help [' .. i .. ']'
    end
    api.nvim_buf_set_name(buf, name)

    -- A split rather than a float, so dora stays usable while help is open
    local win = api.nvim_open_win(buf, true, {
        split = 'right',
        win = origin_win,
    })
    vim.wo[win].cursorline = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'

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
