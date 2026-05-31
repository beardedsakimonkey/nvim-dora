local M = {}

local function sort_by_name(a, b)
    if (a.type == 'directory') == (b.type == 'directory') then
        return a.name < b.name
    else
        return a.type == 'directory'
    end
end

---@alias DirtreeFileType 'file'|'directory'|'link'
---@alias DirtreeOpenCommand 'edit'|'split'|'vsplit'|'tabedit'|string
---@alias DirtreeKeymapAction string|function
---@alias DirtreeKeymapSpec DirtreeKeymapAction|{[1]: DirtreeKeymapAction, desc?: string}

---@class DirtreeFile
---@field name string
---@field type DirtreeFileType

---@class DirtreeConfig
---@field keymaps table<string, DirtreeKeymapSpec>
---@field visual_keymaps table<string, DirtreeKeymapSpec>
---@field keymap_hints boolean
---@field show_hidden boolean
---@field hidden_filter fun(file: DirtreeFile, files: DirtreeFile[], dir: string): boolean
---@field sort? fun(files: DirtreeFile[])
---@field sync_local_cwd boolean

---@type DirtreeConfig
M.config = {
    keymaps = {
        q = {"<Cmd>lua require'dirtree.core'.quit()<CR>",                   desc="Quit"},
        h = {"<Cmd>lua require'dirtree.core'.up_dir()<CR>",                 desc="Up directory"},
        ['-'] = {"<Cmd>lua require'dirtree.core'.up_dir()<CR>",             desc="Up directory"},
        J = {"<Cmd>lua require'dirtree.core'.next_sibling()<CR>",           desc="Next sibling"},
        K = {"<Cmd>lua require'dirtree.core'.prev_sibling()<CR>",           desc="Previous sibling"},
        o = {"<Cmd>lua require'dirtree.core'.expand()<CR>",                 desc="Expand"},
        O = {"<Cmd>lua require'dirtree.core'.expand_recursive()<CR>",       desc="Expand recursively"},
        u = {"<Cmd>lua require'dirtree.core'.collapse()<CR>",               desc="Collapse descendants"},
        U = {"<Cmd>lua require'dirtree.core'.collapse_reset()<CR>",         desc="Collapse and reset"},
        l = {"<Cmd>lua require'dirtree.core'.open()<CR>",                   desc="Open"},
        ['<CR>'] = {"<Cmd>lua require'dirtree.core'.open()<CR>",            desc="Open"},
        s = {"<Cmd>lua require'dirtree.core'.open('split')<CR>",            desc="Open in split"},
        v = {"<Cmd>lua require'dirtree.core'.open('vsplit')<CR>",           desc="Open in vertical split"},
        t = {"<Cmd>lua require'dirtree.core'.open('tabedit')<CR>",          desc="Open in tab"},
        gx = {"<Cmd>lua require'dirtree.core'.open_external()<CR>",         desc="Open externally"},
        R = {"<Cmd>lua require'dirtree.core'.reload()<CR>",                 desc="Reload"},
        i = {"<Cmd>lua require'dirtree.core'.info()<CR>",                   desc="Show info"},
        gy = {"<Cmd>lua require'dirtree.core'.yank_path()<CR>",             desc="Yank path"},
        gY = {"<Cmd>lua require'dirtree.core'.yank_path('+')<CR>",          desc="Yank path to clipboard"},
        cc = {"<Cmd>lua require'dirtree.core'.copy_file_path()<CR>",        desc="Copy file path"},
        cd = {"<Cmd>lua require'dirtree.core'.copy_dir_path()<CR>",         desc="Copy directory path"},
        cf = {"<Cmd>lua require'dirtree.core'.copy_filename()<CR>",         desc="Copy filename"},
        cn = {"<Cmd>lua require'dirtree.core'.copy_filename_stem()<CR>",    desc="Copy filename without extension"},
        d = {"<Cmd>lua require'dirtree.core'.delete()<CR>",                 desc="Delete"},
        a = {"<Cmd>lua require'dirtree.core'.create()<CR>",                 desc="Create"},
        r = {"<Cmd>lua require'dirtree.core'.rename()<CR>",                 desc="Rename"},
        m = {"<Cmd>lua require'dirtree.core'.move()<CR>",                   desc="Move"},
        x = {"<Cmd>lua require'dirtree.core'.cut()<CR>",                    desc="Cut"},
        X = {"<Cmd>lua require'dirtree.core'.clear_paste_operation()<CR>",  desc="Clear cut/copy"},
        y = {"<Cmd>lua require'dirtree.core'.copy()<CR>",                   desc="Copy"},
        Y = {"<Cmd>lua require'dirtree.core'.clear_paste_operation()<CR>",  desc="Clear cut/copy"},
        p = {"<Cmd>lua require'dirtree.core'.paste()<CR>",                  desc="Paste"},
        ['<Tab>'] = {"<Cmd>lua require'dirtree.core'.toggle_mark()<CR>",    desc="Toggle mark"},
        ['<Esc>'] = {"<Cmd>lua require'dirtree.core'.clear_marks()<CR>",    desc="Clear marks"},
        ['<C-a>'] = {"<Cmd>lua require'dirtree.core'.select_all()<CR>",      desc="Select all"},
        ['<C-r>'] = {"<Cmd>lua require'dirtree.core'.invert_selection()<CR>", desc="Invert selection"},
        gh = {"<Cmd>lua require'dirtree.core'.toggle_hidden_files()<CR>",   desc="Toggle hidden files"},
        ['g?'] = {"<Cmd>lua require'dirtree.core'.help()<CR>",              desc="Show help"},
    },
    visual_keymaps = {
        J = {"<Cmd>lua require'dirtree.core'.next_sibling()<CR>", desc="Next sibling"},
        K = {"<Cmd>lua require'dirtree.core'.prev_sibling()<CR>", desc="Previous sibling"},
        ['<Tab>'] = {"<Cmd>lua require'dirtree.core'.toggle_mark_visual()<CR><Esc>", desc="Toggle marks"},
    },
    -- Whether to show keymap hints for two-key normal mode mappings
    keymap_hints = true,
    -- Whether hidden files should be shown when dirtree opens
    show_hidden = true,
    -- Function used to determine what files should be hidden behind `gh`
    hidden_filter = function(file) return vim.startswith(file.name, '.') end,
    -- Function used to sort files
    sort = function(files) table.sort(files, sort_by_name) end,
    -- Whether to sync the window's current directory with dirtree's current path
    sync_local_cwd = true,
}

---@param dir? string
---@param from_au? boolean
function M.dirtree(dir, from_au)
    require'dirtree.core'.dirtree(dir, from_au)
end

return M
