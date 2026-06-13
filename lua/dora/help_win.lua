local keymaps = require'dora.keymaps'
local util = require'dora.util'
local window = require'dora.window'

local api = vim.api

local M = {}

local SECTIONS = {
    {
        name = 'General',
        actions = {'help', 'quit'},
    },
    {
        name = 'Navigation',
        actions = {
            'up_dir', 'next_sibling', 'prev_sibling', 'last_sibling', 'first_sibling',
            'expand', 'expand_recursive', 'collapse', 'collapse_recursive', 'close_dir',
            'parent_dir', 'home_dir', 'set_bookmark', 'jump_bookmark',
        },
    },
    {
        name = 'Open',
        actions = {
            'open', 'open_split', 'open_vsplit', 'open_tab',
            'open_split_stay', 'open_vsplit_stay', 'open_tab_stay', 'open_external',
        },
    },
    {
        name = 'File Operations',
        actions = {
            'create', 'create_under', 'create_symlink', 'rename', 'rename_empty', 'trash', 'delete',
            'toggle_cut', 'toggle_copy', 'paste', 'paste_parent', 'clear_marks', 'shell_cmd',
        },
    },
    {
        name = 'View',
        actions = {'filter', 'clear_filter', 'info', 'toggle_hidden_files', 'reload'},
    },
    {
        name = 'Yank',
        actions = {
            'yank_file_path', 'yank_file_path_clipboard',
            'yank_dir_path', 'yank_dir_path_clipboard',
            'yank_filename', 'yank_filename_clipboard',
            'yank_name', 'yank_name_clipboard',
        },
    },
    {
        name = 'Sort',
        actions = {
            'sort_by_name', 'sort_by_name_desc',
            'sort_by_modified', 'sort_by_modified_desc',
            'sort_by_created', 'sort_by_created_desc',
            'sort_by_size', 'sort_by_size_desc',
            'sort_by_extension', 'sort_by_extension_desc',
        },
    },
}

---@class DoraHelpRow
---@field lhs? string
---@field desc? string
---@field section? string

---@param mappings? table<string, DoraKeymapSpec>
---@return table<string, DoraHelpRow[]>
local function keymap_sections(mappings)
    local sections = {}
    local action_sections = {}
    local action_order = {}
    for _, section in ipairs(SECTIONS) do
        sections[section.name] = {}
        for i, action in ipairs(section.actions) do
            action_sections[action] = section.name
            action_order[action] = i
        end
    end
    sections.Other = {}

    for lhs, rhs in pairs(mappings or {}) do
        local action, desc = keymaps.resolve(rhs)
        local section = type(action) == 'string' and action_sections[action] or nil
        local rows = sections[section or 'Other']
        rows[#rows+1] = {
            lhs = lhs,
            desc = desc or tostring(action),
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

    for _, section in ipairs(SECTIONS) do
        add_section(section.name)
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
                hl_group = 'DoraHelpSection',
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
