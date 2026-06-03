local M = {}

---@alias DoraFileType 'file'|'directory'|'link'
---@alias DoraOpenCommand 'edit'|'split'|'vsplit'|'tabedit'|string
---@alias DoraKeymapAction string|function
---@alias DoraKeymapSpec DoraKeymapAction|{[1]: DoraKeymapAction, desc?: string}
---@alias DoraIconConfig boolean|'nvim-web-devicons'|'mini.icons'
---@alias DoraSortOrder 'name'|'name_reverse'|'modified'|'modified_reverse'|'created'|'created_reverse'|'size'|'size_reverse'|'extension'|'extension_reverse'

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
---@field sync_local_cwd boolean

---@type DoraConfig
M.config = {
    -- Whether to show keymap hints for two-key normal mode mappings
    show_keymap_hints = true,
    -- Whether hidden files should be shown when dora opens
    show_hidden_files = true,
    -- Function used to determine what files should be hidden
    is_file_hidden = function(file) return vim.startswith(file.name, '.') end,
    -- Whether to show file icons. Set to true or 'nvim-web-devicons' to use
    -- nvim-web-devicons, or 'mini.icons' to use mini.icons.
    icons = false,
    -- Default file sorting order
    sort_order = 'name',
    -- Whether to sync the window's current directory with dora's current path
    sync_local_cwd = true,
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
        l = {"open",                            desc="Open"},
        ['<CR>'] = {"open",                     desc="Open"},
        ['<2-LeftMouse>'] = {"open",            desc="Open"},
        s = {"open_split",                      desc="Open in split"},
        v = {"open_vsplit",                     desc="Open in vertical split"},
        t = {"open_tab",                        desc="Open in tab"},
        ['<C-s>'] = {"open_split_keep",         desc="Open in split without closing Dora"},
        ['<C-v>'] = {"open_vsplit_keep",        desc="Open in vertical split without closing Dora"},
        ['<C-t>'] = {"open_tab_keep",           desc="Open in tab without closing Dora"},
        R = {"reload",                          desc="Reload listing"},
        i = {"info",                            desc="Show file info"},
        d = {"trash",                           desc="Move file to trash"},
        D = {"delete",                          desc="Delete file permanently"},
        a = {"create",                          desc="Add file"},
        r = {"rename",                          desc="Rename file"},
        m = {"set_bookmark",                    desc="Set bookmark"},
        ["'"] = {"jump_bookmark",               desc="Jump to bookmark"},
        x = {"cut",                             desc="Toggle cut mark"},
        c = {"copy",                            desc="Toggle copy mark"},
        p = {"paste",                           desc="Paste"},
        ['<Esc>'] = {"clear_marks",             desc="Clear paste marks"},
        gf = {"follow_symlink",                 desc="Follow symlink"},
        gh = {"home_dir",                       desc="Go to Home directory"},
        gx = {"open_external",                  desc="Open externally"},
        ['.'] = {"shell_cmd",                   desc="Shell command on file"},
        ['g.'] = {"toggle_hidden_files",        desc="Toggle hidden files"},
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
}

---@param dst table<string, any>
---@param src table<string, any>
local function merge_config(dst, src)
    for key, value in pairs(src) do
        if key == 'keymaps' and type(value) == 'table' and type(dst.keymaps) == 'table' then
            -- Don't merge keymaps since that can result in stale `desc` fields.
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
