local M = {}

---@alias DirtreeFileType 'file'|'directory'|'link'
---@alias DirtreeOpenCommand 'edit'|'split'|'vsplit'|'tabedit'|string
---@alias DirtreeKeymapAction string|function
---@alias DirtreeKeymapSpec DirtreeKeymapAction|{[1]: DirtreeKeymapAction, desc?: string}
---@alias DirtreeSortOrder 'name'|'name_reverse'|'modified'|'modified_reverse'|'created'|'created_reverse'|'size'|'size_reverse'|'extension'|'extension_reverse'

---@class DirtreeFile
---@field name string
---@field type DirtreeFileType
---@field size? integer
---@field mtime? table
---@field birthtime? table

---@class DirtreeConfig
---@field keymaps table<string, DirtreeKeymapSpec>
---@field visual_keymaps table<string, DirtreeKeymapSpec>
---@field keymap_hints boolean
---@field show_hidden boolean
---@field hidden_filter fun(file: DirtreeFile, files: DirtreeFile[], dir: string): boolean
---@field sort_order DirtreeSortOrder
---@field sync_local_cwd boolean

---@type DirtreeConfig
M.config = {
    keymaps = {
        q = {"quit", desc="Quit"},
        h = {"up_dir", desc="Up directory"},
        ['-'] = {"up_dir", desc="Up directory"},
        J = {"next_sibling", desc="Next sibling"},
        K = {"prev_sibling", desc="Previous sibling"},
        o = {"expand", desc="Expand directory"},
        O = {"expand_recursive", desc="Expand directory recursively"},
        u = {"collapse", desc="Collapse directory"},
        U = {"collapse_recursive", desc="Collapse directory recursively"},
        l = {"open", desc="Open"},
        ['<CR>'] = {"open", desc="Open"},
        s = {"open_split", desc="Open in split"},
        v = {"open_vsplit", desc="Open in vertical split"},
        t = {"open_tab", desc="Open in tab"},
        gx = {"open_external", desc="Open externally"},
        R = {"reload", desc="Reload listing"},
        i = {"info", desc="Show info"},
        cc = {"copy_file_path", desc="Copy file path"},
        cC = {"copy_file_path_clipboard", desc="Copy file path to clipboard"},
        cd = {"copy_dir_path", desc="Copy directory path"},
        cD = {"copy_dir_path_clipboard", desc="Copy directory path to clipboard"},
        cf = {"copy_filename", desc="Copy filename"},
        cF = {"copy_filename_clipboard", desc="Copy filename to clipboard"},
        cn = {"copy_basename", desc="Copy basename"},
        cN = {"copy_basename_clipboard", desc="Copy basename to clipboard"},
        d = {"delete", desc="Delete file"},
        a = {"create", desc="Create file"},
        r = {"rename", desc="Rename file"},
        m = {"move", desc="Move file"},
        x = {"cut", desc="Cut"},
        X = {"clear_paste_operation", desc="Clear cut/copy"},
        y = {"copy", desc="Copy"},
        Y = {"clear_paste_operation", desc="Clear cut/copy"},
        p = {"paste", desc="Paste"},
        ['<Tab>'] = {"toggle_selection", desc="Toggle selection"},
        ['<Esc>'] = {"clear_selection", desc="Clear selection"},
        ['<C-a>'] = {"select_all", desc="Select all"},
        ['<C-r>'] = {"invert_selection", desc="Invert selection"},
        ['.'] = {"toggle_hidden_files", desc="Toggle hidden files"},
        gh = {"home_dir", desc="Go to Home directory"},
        ['g?'] = {"help", desc="Show help"},
        [',n'] = {"sort_by_name", desc="Sort naturally by name"},
        [',N'] = {"sort_by_name_reverse", desc="Sort naturally by name reversed"},
        [',m'] = {"sort_by_modified", desc="Sort by modified time"},
        [',M'] = {"sort_by_modified_reverse", desc="Sort by modified time reversed"},
        [',c'] = {"sort_by_created", desc="Sort by creation time"},
        [',C'] = {"sort_by_created_reverse", desc="Sort by creation time reversed"},
        [',s'] = {"sort_by_size", desc="Sort by file size"},
        [',S'] = {"sort_by_size_reverse", desc="Sort by file size reversed"},
        [',e'] = {"sort_by_extension", desc="Sort by extension"},
        [',E'] = {"sort_by_extension_reverse", desc="Sort by extension reversed"},
    },
    visual_keymaps = {
        J = {"next_sibling", desc="Next sibling"},
        K = {"prev_sibling", desc="Previous sibling"},
        ['<Tab>'] = {"toggle_visual_selection", desc="Toggle selection"},
    },
    -- Whether to show keymap hints for two-key normal mode mappings
    keymap_hints = true,
    -- Whether hidden files should be shown when dirtree opens
    show_hidden = true,
    -- Function used to determine what files should be hidden
    hidden_filter = function(file) return vim.startswith(file.name, '.') end,
    -- Default file sorting order
    sort_order = 'name',
    -- Whether to sync the window's current directory with dirtree's current path
    sync_local_cwd = true,
}

---@param dir? string
---@param from_au? boolean
function M.dirtree(dir, from_au)
    require'dirtree.core'.dirtree(dir, from_au)
end

return M
