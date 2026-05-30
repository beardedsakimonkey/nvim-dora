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
        u = {"<Cmd>lua require'dirtree.core'.collapse()<CR>",               desc="Collapse"},
        U = {"<Cmd>lua require'dirtree.core'.collapse_reset()<CR>",         desc="Collapse and reset"},
        l = {"<Cmd>lua require'dirtree.core'.open()<CR>",                   desc="Open"},
        ['<CR>'] = {"<Cmd>lua require'dirtree.core'.open()<CR>",            desc="Open"},
        s = {"<Cmd>lua require'dirtree.core'.open('split')<CR>",            desc="Open in split"},
        v = {"<Cmd>lua require'dirtree.core'.open('vsplit')<CR>",           desc="Open in vertical split"},
        t = {"<Cmd>lua require'dirtree.core'.open('tabedit')<CR>",          desc="Open in tab"},
        gx = {"<Cmd>lua require'dirtree.core'.open_external()<CR>",         desc="Open externally"},
        R = {"<Cmd>lua require'dirtree.core'.reload()<CR>",                 desc="Reload"},
        i = {"<Cmd>lua require'dirtree.core'.info()<CR>",                   desc="Show info"},
        y = {"<Cmd>lua require'dirtree.core'.yank_path()<CR>",              desc="Yank path"},
        Y = {"<Cmd>lua require'dirtree.core'.yank_path('+')<CR>",           desc="Yank path to clipboard"},
        d = {"<Cmd>lua require'dirtree.core'.delete()<CR>",                 desc="Delete"},
        a = {"<Cmd>lua require'dirtree.core'.create()<CR>",                 desc="Create"},
        m = {"<Cmd>lua require'dirtree.core'.move()<CR>",                   desc="Move"},
        x = {"<Cmd>lua require'dirtree.core'.cut()<CR>",                    desc="Cut"},
        X = {"<Cmd>lua require'dirtree.core'.clear_paste_operation()<CR>",  desc="Clear cut/copy"},
        c = {"<Cmd>lua require'dirtree.core'.copy()<CR>",                   desc="Copy"},
        C = {"<Cmd>lua require'dirtree.core'.clear_paste_operation()<CR>",  desc="Clear cut/copy"},
        p = {"<Cmd>lua require'dirtree.core'.paste()<CR>",                  desc="Paste"},
        ['<Tab>'] = {"<Cmd>lua require'dirtree.core'.toggle_mark()<CR>",    desc="Toggle mark"},
        ['<S-Tab>'] = {"<Cmd>lua require'dirtree.core'.clear_marks()<CR>",  desc="Clear marks"},
        gh = {"<Cmd>lua require'dirtree.core'.toggle_hidden_files()<CR>",   desc="Toggle hidden files"},
        ['g?'] = {"<Cmd>lua require'dirtree.core'.help()<CR>",              desc="Show help"},
    },
    visual_keymaps = {
        J = {"<Cmd>lua require'dirtree.core'.next_sibling()<CR>", desc="Next sibling"},
        K = {"<Cmd>lua require'dirtree.core'.prev_sibling()<CR>", desc="Previous sibling"},
        ['<Tab>'] = {"<Cmd>lua require'dirtree.core'.toggle_mark_visual()<CR><Esc>", desc="Toggle marks"},
    },
    -- Whether hidden files should be shown when dirtree opens
    show_hidden = true,
    -- Function used to determine what files should be hidden behind `gh`
    hidden_filter = function(file) return vim.startswith(file.name, '.') end,
    -- Function used to sort files
    sort = function(files) table.sort(files, sort_by_name) end,
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
DirtreePromptCompletion
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
