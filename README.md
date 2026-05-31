# nvim-dirtree

Dirtree is a small directory viewer for Neovim 0.12+. It opens in the current
window, works well with normal buffer navigation, and stays out of the way when
you only need to browse, create, move, copy, delete, or inspect files.

It is closer to [vim-dirvish](https://github.com/justinmk/vim-dirvish) than to
a project drawer. Dirtree is meant to be opened when you need it, then closed or
replaced by the file you choose.

## Why Dirtree?

- **Normal buffers, not editable directory listings.** Dirtree does not make the
  directory buffer modifiable, which leaves more keys available for actions.
- **Quiet navigation history.** Dirtree buffers avoid populating the jumplist, so
  `<C-o>` usually takes you back through files rather than directory views.
- **Isolated instances.** Opening the same directory in two windows creates two
  independent Dirtree buffers. Navigation, marks, and expanded directories in one
  window do not affect the other.
- **Inline tree expansion.** You can stay in one directory while expanding
  selected subdirectories into a tree.

## Screenshot

<img width="888" height="767" alt="Screenshot 2026-05-08 at 1 13 52 PM" src="https://github.com/user-attachments/assets/5cc644cc-9c7f-4ac1-95e8-c15ed3c61cb7" />

## Usage

Open Dirtree with:

```vim
:Dirtree
:Dirtree path/to/dir
```

Or add a mapping:

```lua
vim.keymap.set('n', '-', '<Cmd>Dirtree<CR>')
```

## Configuration

Dirtree works without setup. To customize it, mutate `require'dirtree'.config` from
your Neovim config.

The default config is generated from `lua/dirtree.lua`:

<!-- dirtree-config:start -->
```lua
config = {
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
        ['.'] = {"<Cmd>lua require'dirtree.core'.toggle_hidden_files()<CR>", desc="Toggle hidden files"},
        gh = {"<Cmd>lua require'dirtree.core'.home_dir()<CR>",              desc="Home directory"},
        ['g?'] = {"<Cmd>lua require'dirtree.core'.help()<CR>",              desc="Show help"},
        [',n'] = {"<Cmd>lua require'dirtree.core'.sort_by('name')<CR>",      desc="Sort naturally by name"},
        [',N'] = {"<Cmd>lua require'dirtree.core'.sort_by('name_reverse')<CR>", desc="Sort naturally by name reversed"},
        [',m'] = {"<Cmd>lua require'dirtree.core'.sort_by('modified')<CR>",  desc="Sort by modified time"},
        [',M'] = {"<Cmd>lua require'dirtree.core'.sort_by('modified_reverse')<CR>", desc="Sort by modified time reversed"},
        [',c'] = {"<Cmd>lua require'dirtree.core'.sort_by('created')<CR>",   desc="Sort by creation time"},
        [',C'] = {"<Cmd>lua require'dirtree.core'.sort_by('created_reverse')<CR>", desc="Sort by creation time reversed"},
        [',s'] = {"<Cmd>lua require'dirtree.core'.sort_by('size')<CR>",      desc="Sort by file size"},
        [',S'] = {"<Cmd>lua require'dirtree.core'.sort_by('size_reverse')<CR>", desc="Sort by file size reversed"},
        [',e'] = {"<Cmd>lua require'dirtree.core'.sort_by('extension')<CR>", desc="Sort by extension"},
        [',E'] = {"<Cmd>lua require'dirtree.core'.sort_by('extension_reverse')<CR>", desc="Sort by extension reversed"},
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
    -- Function used to determine what files should be hidden
    hidden_filter = function(file) return vim.startswith(file.name, '.') end,
    -- Default file sorting order
    sort_order = 'name',
    -- Whether to sync the window's current directory with dirtree's current path
    sync_local_cwd = true,
}
```
<!-- dirtree-config:end -->

Example:

```lua
local dirtree = require'dirtree'

dirtree.config = vim.tbl_deep_extend('force', dirtree.config, {
    show_hidden = false,
    hidden_filter = function(file)
        return vim.startswith(file.name, '.') or file.name == 'node_modules'
    end,
    keymaps = {
        H = "<Cmd>lua require'dirtree.core'.help()<CR>",
        C = function() --[[...]] end,  -- keymaps can also be lua functions
    },
})
```

Keymaps may be strings, functions, or `{action, desc=...}` tables. Use the table
form when you want the mapping to appear nicely in `g?` help:

```lua
dirtree.config.keymaps.q = {"<Cmd>lua require'dirtree.core'.quit()<CR>", desc="Quit"}
```

Dirtree also shows a small hint window for two-character normal mode mappings.
For example, pressing `c` shows configured mappings like `cc`, `cd`, and `cf`.
Set `dirtree.config.keymap_hints = false` to disable these prefix hints.

Files are sorted naturally by name by default, with directories always grouped
before files. Use `,n`, `,m`, `,c`, `,s`, or `,e` to sort by name, modified
time, creation time, size, or extension. Use uppercase variants such as `,N`,
`,M`, `,C`, `,S`, and `,E` for the reversed order. Set
`dirtree.config.sort_order` to choose the initial order.

## Highlights

Customize Dirtree with these highlight groups:

```
DirtreeDirectory
DirtreeSymlink
DirtreeExecutable
DirtreeTree
DirtreeTreeActive
DirtreeVirtText
DirtreePromptBorder
DirtreePromptBorderValid
DirtreePromptBorderInvalid
DirtreeDeleteMore
DirtreeDeleteCursor
DirtreeMarkedText
DirtreeMarkedSign
DirtreeCutSign
DirtreeCopySign
DirtreeMarkedFile
DirtreeHelpHeader
DirtreeHelpKey
DirtreeHelpDesc
DirtreeKeymapHintArrow
DirtreeInfoLabel
DirtreeInfoValue
```

## Development

Regenerate the default configuration docs with:

```sh
sh scripts/docs.sh
```

Run the headless smoke test with:

```sh
sh scripts/smoke.sh
```

Benchmark Lua module load time with:

```sh
sh scripts/bench-require.sh
```

## Acknowledgements

Some minor bits of code were adapted from vim-dirvish and nvim-tree.

## Similar plugins

- [vim-vinegar](https://github.com/tpope/vim-vinegar)
- [vim-filebeagle](https://github.com/jeetsukumaran/vim-filebeagle)
- [vim-dirvish](https://github.com/justinmk/vim-dirvish)
- [lir.nvim](https://github.com/tamago324/lir.nvim)
