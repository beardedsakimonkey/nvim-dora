# nvim-dora

Dora is a directory explorer for Neovim 0.12+ focused on usability.
It is currently under development so expect breaking changes.

<!-- panvimdoc-ignore-start -->

<img width="637" height="570" alt="Dora screenshot" src="https://github.com/user-attachments/assets/d265a765-3e4f-49fb-9b63-678978bb1030" />

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
- Dora remembers the selected entry in each visited directory and restores the
  cursor to it when navigating back.
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
        ['g;'] = 'prev_change',
        ['g,'] = 'next_change',

        -- View
        f = 'filter',
        F = 'clear_filter',
        i = 'info',
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
```
<!-- dora-config:end -->

> [!NOTE]
> Visual mode mappings are installed automatically for built-in actions that
> support them, including cursor movements, expanding/collapsing directories,
> opening, marking, and deleting files.

Example setup:

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

-- `dora.config` is mutable and affects existing dora buffers.
-- To remove a default keymap, set it to `nil`
dora.config.keymaps.D = nil
-- To remove all keymaps, set keymaps to `{}`
dora.config.keymaps = {}
```

Keymaps may be core action names, Vim RHS strings, functions, or
`{action, desc=...}` tables. Built-in action names automatically use Dora's
description in mappings, prefix hints, and `g?` help, even when remapped.

Use the table form to override the built-in wording or describe a custom
mapping:

```lua
dora.config.keymaps.q = {"quit", desc="Close Dora"}
```

Function keymaps are called with a context table describing where the mapping
was triggered:

- `cwd` (string): directory dora is currently browsing
- `path` (string?): absolute path of the entry under the cursor
- `type` (string?): `"file"`, `"directory"`, or `"link"`

`path` and `type` are omitted on rows without a file, such as the placeholder
shown for empty directories. For example, to change the window's local working
directory to the browsed directory:

```lua
dora.setup({
    keymaps = {
        gl = {
            ---@param ctx {cwd: string, path: string?, type: "file"|"directory"|"link"?}
            function(ctx)
                vim.cmd.lcd(ctx.cwd)
            end,
            desc = ":lcd to browsed directory",
        },
    },
})
```

Dora also shows a small hint window for two-character normal mode mappings.
For example, pressing `y` shows configured mappings like `yy`, `yd`, and `yf`.
Set `dora.config.show_keymap_hints = false` to disable these prefix hints.

Files are sorted naturally by name by default, with directories always grouped
before files. Use `,n`, `,m`, `,c`, `,s`, or `,e` to sort by name, modified
time, creation time, size, or extension. Use uppercase variants such as `,N`,
`,M`, `,C`, `,S`, and `,E` for the reversed order. Set
`dora.config.sort_order` to choose the initial order.

Dora prompt buffers use the `dora-prompt` filetype. Use a `FileType` autocmd
to customize them. For example, to make `<Esc>` close a prompt directly from
insert mode:

```lua
vim.api.nvim_create_autocmd("FileType", {
    pattern = "dora-prompt",
    callback = function(args)
        vim.keymap.set("i", "<Esc>", "<Cmd>close<CR>", {buffer = args.buf})
    end,
})
```

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
hi default link DoraMutedText           NonText
hi default link DoraOverwrite           DiagnosticWarn
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
