# nvim-dora

Dora is a directory explorer for Neovim 0.12+ focused on usability.
It is currently under development so expect breaking changes.

<!-- panvimdoc-ignore-start -->

## Screenshot

<img width="888" height="767" alt="Screenshot 2026-05-08 at 1 13 52 PM" src="https://github.com/user-attachments/assets/5cc644cc-9c7f-4ac1-95e8-c15ed3c61cb7" />

<!-- panvimdoc-ignore-end -->

## Motivation

Dora sits between project-drawer plugins such as
[nvim-tree](https://github.com/nvim-tree/nvim-tree.lua) and in-place directory
browsers such as netrw. Like netrw, it opens in the current window and gets out
of the way when a file is selected. Unlike many netrw-style plugins (e.g.
[vim-vinegar](https://github.com/tpope/vim-vinegar),
[oil.nvim](https://github.com/stevearc/oil.nvim), and
[vim-dirvish](https://github.com/justinmk/vim-dirvish)), it also provides a tree
view for exploring more than one directory at a time.

Dora aims to make filesystem navigation and common file operations efficient:

- The directory listing is non-modifiable, leaving more keys available for
  commands.
- Prompt border colors provide immediate validation feedback while creating
  or renaming files.
- Create and rename windows open below the cursor, keeping attention near the
  file being acted on.
- Files can be marked directly for cut or copy operations, then pasted at the
  destination.
- Expanded directories persist for the lifetime of the Neovim session, and
  the last directory and cursor position survive closing Dora. Reopen it and
  press `''` to return to where you left off.
- Built-in [which-key](https://github.com/folke/which-key.nvim)-style hints make prefixed keymaps discoverable.
- Navigation and file operations use convenient, mnemonic keymaps.

Dora has no required dependencies, about 4,000 lines of Lua, and a small
configuration surface. It also keeps startup overhead low: `require('dora')`
loads only the configuration module and measures well under 1 ms in the
included benchmark.

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

Dora also opens automatically when you edit a directory (e.g. `nvim .`).
To disable this, set:

```lua
vim.g.dora_disable_auto_open = true
```

## Configuration

Dora works without setup, but you can change the default config using `setup()`.
The arguments are deeply merged with the defaults, so you only need to specify
the options you want to add or change.

Here are the defaults:

<!-- dora-config:start -->
```lua
require('dora').setup {
    -- Whether to show keymap hints for two-key normal mode mappings
    show_keymap_hints = true,
    -- Whether hidden files should be shown when dora opens
    show_hidden_files = true,
    -- Function used to determine what files should be hidden
    is_file_hidden = function(file) return vim.startswith(file.name, '.') end,
    -- Whether to show file icons. Set to true or 'nvim-web-devicons' to use
    -- nvim-web-devicons, or 'mini.icons' to use mini.icons.
    icons = false,
    -- Default file sorting order ('name'|'name_desc'|'modified'|'modified_desc'|'created'|'created_desc'|'size'|'size_desc'|'extension'|'extension_desc')
    sort_order = 'name',
    -- Number of columns used for each level of tree indentation (minimum 2)
    tree_indent = 4,
    -- Whether to sync the window's current directory with dora's current path
    sync_local_cwd = false,
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
        ['<2-LeftMouse>'] = 'open',
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
        a = 'create',
        A = 'create_under',
        S = 'create_symlink',
        r = 'rename',
        R = 'rename_empty',
        d = 'trash',
        D = 'delete',
        x = 'toggle_cut',
        c = 'toggle_copy',
        p = 'paste',
        P = 'paste_parent',
        ['<Esc>'] = 'clear_marks',
        ['.'] = 'shell_cmd',

        -- View
        f = 'filter',
        F = 'clear_filter',
        i = 'info',
        ['g.'] = 'toggle_hidden_files',
        ['<C-r>'] = 'reload',

        -- Yank
        yy = 'yank_file_path',
        yY = 'yank_file_path_clipboard',
        yd = 'yank_dir_path',
        yD = 'yank_dir_path_clipboard',
        yn = 'yank_filename',
        yN = 'yank_filename_clipboard',
        yb = 'yank_basename',
        yB = 'yank_basename_clipboard',

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
```
<!-- dora-config:end -->

Example:

```lua
local dora = require('dora')

-- The config table is deeply merged with the defaults, so you only need to
-- specify the options you want to add/change.
dora.setup({
    keymaps = {
        d = 'delete',
        Y = 'yank_filename',
    },
    icons = true,
})

-- To remove a default keymap, set it to `nil`
dora.config.keymaps.l = nil
```

Keymaps may be core action names, Vim RHS strings, functions, or
`{action, desc=...}` tables. Built-in action names automatically use Dora's
description in mappings, prefix hints, and `g?` help, even when remapped:

```lua
dora.config.keymaps.x = "reload"
```

Use the table form to override the built-in wording or describe a custom
mapping:

```lua
dora.config.keymaps.q = {"quit", desc="Close Dora"}
```

Dora also shows a small hint window for two-character normal mode mappings.
For example, pressing `y` shows configured mappings like `yy`, `yd`, and `yf`.
Set `dora.config.show_keymap_hints = false` to disable these prefix hints.

Files are sorted naturally by name by default, with directories always grouped
before files. Use `,n`, `,m`, `,c`, `,s`, or `,e` to sort by name, modified
time, creation time, size, or extension. Use uppercase variants such as `,N`,
`,M`, `,C`, `,S`, and `,E` for the reversed order. Set
`dora.config.sort_order` to choose the initial order.

Dora float windows use rounded borders by default. On Neovim 0.12+, set
`vim.o.winborder` to customize the border style globally.

## Highlights

Customize Dora with these highlight groups:

<!-- dora-highlights:start -->
```vim
hi default link DoraFile                Normal
hi default link DoraDirectory           Directory
hi default link DoraSymlink             Constant
hi default link DoraExecutable          Function
hi default link DoraTree                NonText
hi default link DoraTreeActive          Directory
hi default link DoraVirtText            NonText
hi default link DoraIcon                Special
hi default link DoraCut                 DiagnosticError
hi default link DoraCopy                DiagnosticOk
hi default link DoraFilterMatch         Special
hi default link DoraFilterPath          Comment
hi default link DoraPromptBorder        FloatBorder
hi default link DoraPromptBorderValid   DoraPromptBorder
hi default link DoraPromptBorderInvalid DoraPromptBorder
hi default link DoraInfoLabel           Label
hi default link DoraInfoValue           Special
hi default link DoraHelpSection         Title
hi default link DoraDeleteMore          NonText
hi default link DoraKeymapHintArrow     NonText
hi default link DoraKeymapHintMnemonic  Underlined
```
<!-- dora-highlights:end -->

Unless overridden, `DoraPromptBorderValid` and `DoraPromptBorderInvalid` get
their foreground color replaced with that of `DiagnosticOk` and
`DiagnosticError` respectively, keeping the other `DoraPromptBorder`
attributes.

## Development

Regenerate the generated README sections and `doc/dora.txt` with:

```sh
sh scripts/docs.sh
```

This requires [panvimdoc](https://github.com/kdheepak/panvimdoc) and Pandoc
3.0+. Set `PANVIMDOC` to the path of `panvimdoc.sh`, or `PANVIMDOC_DIR` to a
panvimdoc checkout.

Check that both generated files are current with:

```sh
sh scripts/docs.sh --check
```

Run the headless smoke test with:

```sh
sh scripts/smoke.sh
```

Benchmark Lua module load time with:

```sh
sh scripts/bench-require.sh
```
