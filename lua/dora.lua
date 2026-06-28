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
        ['g?'] = 'help', -- Show help
        q      = 'quit', -- Quit

        -- Navigation
        ['-']    = 'up_dir',             -- Up directory
        h        = 'up_dir',             -- Up directory
        J        = 'next_sibling',       -- Next sibling
        K        = 'prev_sibling',       -- Previous sibling
        ['>']    = 'last_sibling',       -- Last sibling
        ['<']    = 'first_sibling',      -- First sibling
        [']m']   = 'next_mark',          -- Next paste mark
        ['[m']   = 'prev_mark',          -- Previous paste mark
        o        = 'fold_out',           -- Fold out directory
        O        = 'fold_out_recursive', -- Fold out directory recursively
        i        = 'fold_in',            -- Fold in directory
        I        = 'fold_in_recursive',  -- Fold in directory recursively
        ['<BS>'] = 'close_dir',          -- Close directory
        gp       = 'parent_dir',         -- Go to parent directory
        gh       = 'home_dir',           -- Go to home directory
        m        = 'set_bookmark',       -- Set bookmark
        ["'"]    = 'jump_bookmark',      -- Jump to bookmark

        -- Open
        ['<CR>']  = 'open',             -- Open
        l         = 'open',             -- Open
        s         = 'open_split',       -- Open in split
        v         = 'open_vsplit',      -- Open in vertical split
        t         = 'open_tab',         -- Open in tab
        ['<C-s>'] = 'open_split_stay',  -- Open in split (stay)
        ['<C-v>'] = 'open_vsplit_stay', -- Open in vertical split (stay)
        ['<C-t>'] = 'open_tab_stay',    -- Open in tab (stay)
        gx        = 'open_external',    -- Open externally

        -- File operations
        a     = 'add_under',      -- Add file under directory
        A     = 'add',            -- Add file
        S     = 'create_symlink', -- Add symlink to file
        r     = 'rename',         -- Rename file
        R     = 'rename_empty',   -- Rename file with empty prompt
        d     = 'trash',          -- Move file to trash (Mac/Linux)
        D     = 'delete',         -- Delete file permanently
        u     = 'undo',           -- Restore the most recently trashed files
        x     = 'toggle_cut',     -- Toggle cut mark
        X     = 'clear_cut',      -- Clear all cut marks
        c     = 'toggle_copy',    -- Toggle copy mark
        C     = 'clear_copy',     -- Clear all copy marks
        p     = 'paste_under',    -- Paste under directory
        P     = 'paste',          -- Paste
        ['.'] = 'shell_cmd',      -- Shell command on file

        -- View
        f         = 'filter',              -- Filter visible files
        F         = 'clear_filter',        -- Clear filter
        gi        = 'file_info',           -- Show file info
        ['g.']    = 'toggle_hidden_files', -- Toggle hidden files
        ['<C-r>'] = 'reload',              -- Reload listing

        -- Yank
        yf = 'yank_filename',            -- Yank filename
        yF = 'yank_filename_clipboard',  -- Yank filename to clipboard
        yy = 'yank_file_path',           -- Yank full path
        yY = 'yank_file_path_clipboard', -- Yank full path to clipboard
        yd = 'yank_dir_path',            -- Yank parent directory
        yD = 'yank_dir_path_clipboard',  -- Yank parent directory to clipboard
        yn = 'yank_name',                -- Yank name without extension
        yN = 'yank_name_clipboard',      -- Yank name without extension to clipboard

        -- Sort
        [',n'] = 'sort_by_name',           -- Sort by name
        [',N'] = 'sort_by_name_desc',      -- Sort by name (descending)
        [',m'] = 'sort_by_modified',       -- Sort by modified time
        [',M'] = 'sort_by_modified_desc',  -- Sort by modified time (descending)
        [',c'] = 'sort_by_created',        -- Sort by creation time
        [',C'] = 'sort_by_created_desc',   -- Sort by creation time (descending)
        [',s'] = 'sort_by_size',           -- Sort by size
        [',S'] = 'sort_by_size_desc',      -- Sort by size (descending)
        [',e'] = 'sort_by_extension',      -- Sort by extension
        [',E'] = 'sort_by_extension_desc', -- Sort by extension (descending)
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
