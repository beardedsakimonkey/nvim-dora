# nvim-dora

Dora is a small directory viewer for Neovim 0.12+. It opens in the current
window, works well with normal buffer navigation, and stays out of the way when
you only need to browse, create, move, copy, delete, or inspect files.

It is closer to [vim-dirvish](https://github.com/justinmk/vim-dirvish) than to
a project drawer. Dora is meant to be opened when you need it, then closed or
replaced by the file you choose.

## Why Dora?

- **Normal buffers, not editable directory listings.** Dora does not make the
  directory buffer modifiable, which leaves more keys available for actions.
- **Quiet navigation history.** Dora buffers avoid populating the jumplist, so
  `<C-o>` usually takes you back through files rather than directory views.
- **Isolated instances.** Opening the same directory in two windows creates two
  independent Dora buffers. Navigation, paste marks, and expanded directories in one
  window do not affect the other.
- **Inline tree expansion.** You can stay in one directory while expanding
  selected subdirectories into a tree.

## Screenshot

<img width="888" height="767" alt="Screenshot 2026-05-08 at 1 13 52 PM" src="https://github.com/user-attachments/assets/5cc644cc-9c7f-4ac1-95e8-c15ed3c61cb7" />

## Usage

Open Dora with:

```vim
:Dora
:Dora path/to/dir
```

Or add a mapping:

```lua
vim.keymap.set('n', '-', '<Cmd>Dora<CR>')
```

## Configuration

Dora works without setup. To customize it, mutate `require'dora'.config` from
your Neovim config.

The default config is generated from `lua/dora.lua`:

<!-- dora-config:start -->
```lua
config = {
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
        s = {"open_split",                      desc="Open in split"},
        v = {"open_vsplit",                     desc="Open in vertical split"},
        t = {"open_tab",                        desc="Open in tab"},
        R = {"reload",                          desc="Reload listing"},
        i = {"info",                            desc="Show file info"},
        d = {"trash",                           desc="Move file to trash"},
        D = {"delete",                          desc="Delete file permanently"},
        a = {"create",                          desc="Add file"},
        r = {"rename",                          desc="Rename file"},
        m = {"move",                            desc="Move file"},
        x = {"cut",                             desc="Toggle cut mark"},
        c = {"copy",                            desc="Toggle copy mark"},
        p = {"paste",                           desc="Paste"},
        ['<Esc>'] = {"clear_marks",             desc="Clear paste marks"},
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
    -- Whether to show keymap hints for two-key normal mode mappings
    show_keymap_hints = true,
    -- Whether hidden files should be shown when dora opens
    show_hidden_files = true,
    -- Function used to determine what files should be hidden
    is_file_hidden = function(file) return vim.startswith(file.name, '.') end,
    -- Default file sorting order
    sort_order = 'name',
    -- Whether to sync the window's current directory with dora's current path
    sync_local_cwd = true,
}
```
<!-- dora-config:end -->

Example:

```lua
local dora = require'dora'

dora.config = vim.tbl_deep_extend('force', dora.config, {
    show_hidden_files = false,
    is_file_hidden = function(file)
        return vim.startswith(file.name, '.') or file.name == 'node_modules'
    end,
    keymaps = {
        H = "help",
        C = function() --[[...]] end,  -- keymaps can also be lua functions
    },
})
```

Keymaps may be core action names, Vim RHS strings, functions, or
`{action, desc=...}` tables. Use the table form when you want the mapping to
appear nicely in `g?` help:

```lua
dora.config.keymaps.q = {"quit", desc="Quit"}
```

Dora also shows a small hint window for two-character normal mode mappings.
For example, pressing `y` shows configured mappings like `yy`, `yd`, and `yf`.
Set `dora.config.show_keymap_hints = false` to disable these prefix hints.

Files are sorted naturally by name by default, with directories always grouped
before files. Use `,n`, `,m`, `,c`, `,s`, or `,e` to sort by name, modified
time, creation time, size, or extension. Use uppercase variants such as `,N`,
`,M`, `,C`, `,S`, and `,E` for the reversed order. Set
`dora.config.sort_order` to choose the initial order.

## Highlights

Customize Dora with these highlight groups:

```
DoraDirectory
DoraSymlink
DoraExecutable
DoraTree
DoraTreeActive
DoraVirtText
DoraPromptBorder
DoraPromptBorderValid
DoraPromptBorderInvalid
DoraDeleteMore
DoraDeleteCursor
DoraCut
DoraCopy
DoraInfoLabel
DoraInfoValue
DoraKeymapHintArrow
DoraInfoLabel
DoraInfoValue
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
