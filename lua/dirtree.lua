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
---@field show_keymap_hints boolean
---@field show_hidden_files boolean
---@field is_file_hidden fun(file: DirtreeFile, files: DirtreeFile[], dir: string): boolean
---@field sort_order DirtreeSortOrder
---@field sync_local_cwd boolean

---@type DirtreeConfig
M.config = {
    keymaps = {
        q = {"quit",                            desc="Quit"},
        h = {"up_dir",                          desc="Up directory"},
        ['-'] = {"up_dir",                      desc="Up directory"},
        J = {"last_sibling",                    desc="Last sibling"},
        K = {"first_sibling",                   desc="First sibling"},
        ['>'] = {"next_sibling",                desc="Next sibling"},
        ['<'] = {"prev_sibling",                desc="Previous sibling"},
        P = {"parent_dir",                      desc="Parent directory"},
        o = {"expand",                          desc="Expand directory"},
        O = {"expand_recursive",                desc="Expand directory recursively"},
        u = {"collapse",                        desc="Collapse directory"},
        U = {"collapse_recursive",              desc="Collapse directory recursively"},
        l = {"expand_or_open",                  desc="Expand directory or open file"},
        ['<CR>'] = {"open",                     desc="Open"},
        s = {"open_split",                      desc="Open in split"},
        v = {"open_vsplit",                     desc="Open in vertical split"},
        t = {"open_tab",                        desc="Open in tab"},
        R = {"reload",                          desc="Reload listing"},
        i = {"info",                            desc="Show file info"},
        d = {"delete",                          desc="Delete file"},
        a = {"create",                          desc="Add file"},
        r = {"rename",                          desc="Rename file"},
        m = {"move",                            desc="Move file"},
        x = {"cut",                             desc="Toggle cut mark"},
        c = {"copy",                            desc="Toggle copy mark"},
        p = {"paste",                           desc="Paste"},
        ['<Esc>'] = {"clear_selection",         desc="Clear paste marks"},
        ['.'] = {"toggle_hidden_files",         desc="Toggle hidden files"},
        gh = {"home_dir",                       desc="Go to Home directory"},
        gx = {"open_external",                  desc="Open externally"},
        ['g?'] = {"help",                       desc="Show help"},
        yy = {"yank_file_path",                 desc="Yank file path"},
        yY = {"yank_file_path_clipboard",       desc="Yank file path to clipboard"},
        yd = {"yank_dir_path",                  desc="Yank directory path"},
        yD = {"yank_dir_path_clipboard",        desc="Yank directory path to clipboard"},
        yf = {"yank_filename",                  desc="Yank filename"},
        yF = {"yank_filename_clipboard",        desc="Yank filename to clipboard"},
        yb = {"yank_basename",                  desc="Yank basename"},
        yB = {"yank_basename_clipboard",        desc="Yank basename to clipboard"},
        [',n'] = {"sort_by_name",               desc="Sort by name"},
        [',N'] = {"sort_by_name_reverse",       desc="Sort by name (reversed)"},
        [',m'] = {"sort_by_modified",           desc="Sort by modified time"},
        [',M'] = {"sort_by_modified_reverse",   desc="Sort by modified time (reversed)"},
        [',c'] = {"sort_by_created",            desc="Sort by creation time"},
        [',C'] = {"sort_by_created_reverse",    desc="Sort by creation time (reversed)"},
        [',s'] = {"sort_by_size",               desc="Sort by size"},
        [',S'] = {"sort_by_size_reverse",       desc="Sort by size (reversed)"},
        [',e'] = {"sort_by_extension",          desc="Sort by extension"},
        [',E'] = {"sort_by_extension_reverse",  desc="Sort by extension (reversed)"},
    },
    -- Whether to show keymap hints for two-key normal mode mappings
    show_keymap_hints = true,
    -- Whether hidden files should be shown when dirtree opens
    show_hidden_files = true,
    -- Function used to determine what files should be hidden
    is_file_hidden = function(file) return vim.startswith(file.name, '.') end,
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
