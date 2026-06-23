local M = {}

---@alias DoraFileType 'file'|'directory'|'link'
---@alias DoraOpenCommand 'edit'|'split'|'vsplit'|'tabedit'|string

---@class DoraKeymapContext
---@field cwd string Directory dora is currently browsing
---@field path? string Absolute path of the entry under the cursor
---@field type? DoraFileType Type of the entry under the cursor

---@alias DoraKeymapAction string|fun(ctx: DoraKeymapContext)
---@alias DoraKeymapSpec DoraKeymapAction|{[1]: DoraKeymapAction, desc?: string}
---@alias DoraIconConfig boolean|'nvim-web-devicons'|'mini.icons'
---@alias DoraSortOrder 'name'|'name_desc'|'modified'|'modified_desc'|'created'|'created_desc'|'size'|'size_desc'|'extension'|'extension_desc'

---@class DoraFile
---@field name string
---@field type DoraFileType
---@field size? integer
---@field mtime? table
---@field birthtime? table

---@class DoraConfig
---@field keymaps table<string, DoraKeymapSpec>
---@field show_keymap_hints boolean
---@field show_hidden_files boolean
---@field is_file_hidden fun(file: DoraFile, files: DoraFile[], dir: string): boolean
---@field icons DoraIconConfig
---@field sort_order DoraSortOrder
---@field tree_indent integer
---@field prompt_insert_esc_closes boolean

---@type DoraConfig
M.config = {
    -- Whether to show file icons. Set to true or 'nvim-web-devicons' to use
    -- nvim-web-devicons, or 'mini.icons' to use mini.icons.
    icons = false,
    -- Number of columns used for each level of tree indentation (minimum 2)
    tree_indent = 4,
    -- Whether to show keymap hints for two-key normal mode mappings
    show_keymap_hints = true,
    -- Whether hidden files should be shown by default
    show_hidden_files = true,
    -- Function used to determine what files should be hidden
    is_file_hidden = function(file) return vim.startswith(file.name, '.') end,
    -- Default file sorting order ('name'|'name_desc'|'modified'|'modified_desc'|'created'|'created_desc'|'size'|'size_desc'|'extension'|'extension_desc')
    sort_order = 'name',
    -- Whether <Esc> in insert mode closes prompts.
    prompt_insert_esc_closes = true,
    -- Key mappings
    keymaps = {
        -- General
        ['g?'] = 'help',
        q = 'quit',

        -- Navigation
        ['-'] = 'up_dir',
        h = 'up_dir',
        J = 'next_sibling',
        K = 'prev_sibling',
        ['>'] = 'last_sibling',
        ['<'] = 'first_sibling',
        o = 'expand',
        O = 'expand_recursive',
        u = 'collapse',
        U = 'collapse_recursive',
        ['<BS>'] = 'close_dir',
        gp = 'parent_dir',
        gh = 'home_dir',
        m = 'set_bookmark',
        ["'"] = 'jump_bookmark',

        -- Open
        ['<CR>'] = 'open',
        l = 'open',
        s = 'open_split',
        v = 'open_vsplit',
        t = 'open_tab',
        ['<C-s>'] = 'open_split_stay',
        ['<C-v>'] = 'open_vsplit_stay',
        ['<C-t>'] = 'open_tab_stay',
        gx = 'open_external',

        -- File operations
        a = 'add_under',
        A = 'add',
        S = 'create_symlink',
        r = 'rename',
        R = 'rename_empty',
        d = 'trash',
        D = 'delete',
        x = 'toggle_cut',
        c = 'toggle_copy',
        p = 'paste_under',
        P = 'paste',
        ['<Esc>'] = 'clear_marks',
        ['.'] = 'shell_cmd',

        -- View
        f = 'filter',
        F = 'clear_filter',
        i = 'file_info',
        ['g.'] = 'toggle_hidden_files',
        ['<C-r>'] = 'reload',

        -- Yank
        yf = 'yank_filename',
        yF = 'yank_filename_clipboard',
        yy = 'yank_file_path',
        yY = 'yank_file_path_clipboard',
        yd = 'yank_dir_path',
        yD = 'yank_dir_path_clipboard',
        yn = 'yank_name',
        yN = 'yank_name_clipboard',

        -- Sort
        [',n'] = 'sort_by_name',
        [',N'] = 'sort_by_name_desc',
        [',m'] = 'sort_by_modified',
        [',M'] = 'sort_by_modified_desc',
        [',c'] = 'sort_by_created',
        [',C'] = 'sort_by_created_desc',
        [',s'] = 'sort_by_size',
        [',S'] = 'sort_by_size_desc',
        [',e'] = 'sort_by_extension',
        [',E'] = 'sort_by_extension_desc',
    },
}

---@param dst table<string, any>
---@param src table<string, any>
local function merge_config(dst, src)
    for key, value in pairs(src) do
        if key == 'keymaps' and type(value) == 'table' and type(dst.keymaps) == 'table' then
            -- Replace individual keymap specs instead of deep-merging table fields.
            for lhs, rhs in pairs(value) do
                dst.keymaps[lhs] = rhs
            end
        elseif type(value) == 'table' and type(dst[key]) == 'table' then
            merge_config(dst[key], value)
        else
            dst[key] = value
        end
    end
end

---@param opts table
function M.setup(opts)
    assert(type(opts) == 'table', 'dora.setup() expects a table')
    merge_config(M.config, opts)
end

return M
