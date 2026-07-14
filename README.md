<img width="717" height="284" alt="dora logo" src="https://github.com/user-attachments/assets/fa1dab28-13da-475d-9b41-473d76abd6a3" />

# nvim-dora

Dora is a directory explorer for Neovim 0.12+ focused on usability. It was born
from a desire for a modern netrw-style plugin with a tree view. It includes:

- 🪾 A tree view that can be expanded or collapsed one level at a time (or
  all the way) for quick exploration.
- 🩻 "Transparent" floating windows positioned over selected files (at the
  ["locus of attention"](https://raskincenter.org/jef/humane-interface/)).
- ✅ Window border colors that provide validation feedback while typing.
- ⚠️ A paste confirmation window that detects conflicts and enables conflict
  resolution.
- ↩️ An undoable "trash" operation for Mac/Linux.
- 🔖 A "last directory" bookmark that persists across Dora sessions.
- 💡 Built-in [which-key](https://github.com/folke/which-key.nvim)-style hints to
  make two-letter keymaps more discoverable.

Dora does *not* include:

- ❌ SSH support
- ❌ Git integration

## Requirements

- Neovim 0.12+
- (Optional) [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons)
  or [mini.icons](https://github.com/nvim-mini/mini.icons) with a [Nerd
  Font](https://www.nerdfonts.com/)

Dora supports macOS, Linux, and Windows. Trash and undo-trash are unavailable
on Windows; permanent deletion remains available.

<!-- panvimdoc-ignore-start -->

## Contents

1. [Installation](#installation)
2. [Usage](#usage)
3. [Configuration](#configuration)
4. [Core workflow](#core-workflow)
5. [Features and behavior](#features-and-behavior)
6. [Development](#development)

## Demos

<img width="637" height="570" alt="Dora screenshot" src="https://github.com/user-attachments/assets/d265a765-3e4f-49fb-9b63-678978bb1030" />

<!-- panvimdoc-ignore-end -->

## Installation

```lua
vim.pack.add({ 'https://github.com/beardedsakimonkey/nvim-dora' })
```

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

    -- Whether <Esc> in insert mode closes prompts.
    prompt_insert_esc_closes = true,

    -- Whether to show the current browsed directory as the tree root.
    show_root = false,

    -- Whether to show keymap hints for two-key normal mode mappings
    show_keymap_hints = true,

    -- Whether hidden files should be shown by default
    show_hidden_files = true,

    -- Function used to determine what files should be hidden. It receives the
    -- current file, all files in its directory, and the absolute directory path.
    is_hidden_file = function(file) return vim.startswith(file.name, '.') end,

    -- Which side of the window the preview opens on ('left'|'right'|'above'|'below')
    preview_split = 'right',

    -- Default file sorting order ('name'|'name_desc'|'modified'|'modified_desc'|'created'|'created_desc'|'size'|'size_desc'|'extension'|'extension_desc')
    sort_order = 'name',

    -- Number of columns used for each level of tree indentation (minimum 2)
    tree_indent = 4,

    -- Timeout in milliseconds for LSP willRenameFiles requests.
    -- Set to 0 to disable LSP rename/move integration.
    lsp_timeout = 1000,

    -- Key mappings
    keymaps = {
        -- General
        ['g?'] = 'help', -- Show help
        q      = 'quit', -- Quit

        -- Navigation
        ['-']     = 'up_dir',             -- Up directory
        h         = 'up_dir',             -- Up directory
        J         = 'next_sibling',       -- Next sibling
        K         = 'prev_sibling',       -- Previous sibling
        ['>']     = 'last_sibling',       -- Last sibling
        ['<']     = 'first_sibling',      -- First sibling
        ['<C-p>'] = 'parent_dir',         -- Parent directory
        o         = 'fold_out',           -- Fold out directory
        O         = 'fold_out_recursive', -- Fold out directory recursively
        i         = 'fold_in',            -- Fold in directory
        I         = 'fold_in_recursive',  -- Fold in directory recursively
        ['<BS>']  = 'close_dir',          -- Close directory
        gp        = 'toggle_preview',     -- Toggle preview
        gh        = 'home_dir',           -- Go to home directory
        m         = 'set_bookmark',       -- Set bookmark
        ["'"]     = 'jump_bookmark',      -- Jump to bookmark
        [']m']    = 'next_paste_mark',    -- Next paste mark
        ['[m']    = 'prev_paste_mark',    -- Previous paste mark

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
        a     = 'add',            -- Add file
        A     = 'add_under',      -- Add file under directory
        S     = 'create_symlink', -- Add symlink to file
        r     = 'rename',         -- Rename file
        R     = 'rename_empty',   -- Rename file with empty prompt
        d     = 'trash',          -- Move file to trash (Mac/Linux)
        D     = 'delete',         -- Delete file permanently
        u     = 'undo_trash',     -- Restore the most recently trashed files
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
```
<!-- dora-config:end -->

Setting `icons = true` is equivalent to selecting `"nvim-web-devicons"`.
Selecting `"mini.icons"` expects `MiniIcons.setup()` to have run. If the
selected provider is unavailable, Dora falls back to built-in Nerd Font
glyphs.

The `is_hidden_file` callback receives three arguments:

- `file`: the current entry, with `name`, `type`, `size`, `mtime`, and
  `birthtime` fields where available
- `files`: all entries in the directory
- `dir`: the absolute path of that directory

> [!NOTE]
> Visual mode mappings are installed automatically for built-in actions that
> support them, including cursor movements, expanding/collapsing directories,
> opening, marking, and deleting files.

Example setup:

```lua
local dora = require('dora')

-- `dora.setup` merges options into the default config.
dora.setup({
    icons = true,
    keymaps = {
        ['<2-LeftMouse>'] = 'open',
        Y = 'yank_file_path',
    },
})

-- `dora.config` is mutable. To remove a keymap, set it to `nil`
dora.config.keymaps.D = nil
```

Keymaps may be action names, Vim RHS strings, Lua functions, or `{action,
desc=...}` tables. Built-in action names automatically use Dora's description in
mappings, prefix hints, and `g?` help, even when remapped.

Function keymaps are called with a context table describing where the mapping
was triggered:

- `cwd` (string): directory dora is currently browsing
- `path` (string?): absolute path of the entry under the cursor
- `type` (string?): `"file"`, `"directory"`, or `"link"`

`path` and `type` are omitted on rows without a file, such as the placeholder
shown for empty directories.

## Core workflow

- Use `l` or `<CR>` to open an entry, and `h` or `-` to go up a directory.
- Use `o` and `i` to expand and collapse the tree one level at a time; uppercase
  `O` and `I` operate recursively.
- Use `a` or `A` to create, `r` to rename, and `d` to move entries to the trash.
- Use `x` or `c` to mark entries for cutting or copying, then `p` or `P` to paste.
- Use `f` to filter the visible tree, `gp` to preview, and `g?` to see every
  configured mapping.

Visual mode works with actions that accept multiple entries, including opening,
expanding or collapsing, marking, trashing, and deleting.

## Features and behavior

### Creating files and directories

The "add" prompt creates a directory when its input ends in `/`; otherwise it
creates a file. Nested paths are accepted and missing parent directories are
created automatically.

The typed path is relative to the selected entry: `a` creates beside it, and
`A` creates beneath the selected directory (or beside the selected file).
`A` prefills the directory's name, so the prompt continues its row in place.

### Changing the working directory

To change Neovim's current working directory to the directory being browsed,
run this from a dora buffer:

```vim
:cd %
```

To map this action, use a function keymap and the current Dora context:

```lua
require('dora').setup {
    keymaps = {
        ['gc'] = {
            function(ctx)
                vim.api.nvim_set_current_dir(ctx.cwd)
            end,
            desc = 'Change working directory',
        },
    },
}
```

Dora expands `%` to the browsed directory for interactive `:cd`, `:lcd`, and
`:tcd` commands. Each Dora instance has a separate buffer, and simultaneous
instances browsing the same directory receive unique buffer names. Configured
string mappings are non-recursive, so a mapping such as
`gc = '<Cmd>cd %<CR>'` bypasses Dora's special expansion and may use that unique
buffer name instead. The function mapping above avoids that ambiguity.

### Keymap hints

Dora also shows a small hint window for two-character normal mode mappings.
For example, pressing `y` shows configured mappings like `yy`, `yd`, and `yf`.
Set `dora.config.show_keymap_hints = false` to disable these prefix hints.

### Preview window

Press `gp` to toggle a preview split, which follows the entry under the cursor.
File previews initially use a lightweight scratch buffer and read only enough of
the file to fill the window. This avoids fully loading large files and does not
run filetype plugins or attach LSP clients while browsing. Move focus into the
preview to replace the scratch buffer with the real, fully loaded file buffer,
which can then be scrolled or edited normally.

Directories are previewed as a snapshot of their entries using Dora's current
sorting and hidden-file settings. Set `dora.config.preview_split` to `left`,
`right`, `above`, or `below` to choose where the preview opens.

### Sort order

Files are sorted naturally by name by default, with directories always grouped
before files. Use `,n`, `,m`, `,c`, `,s`, or `,e` to sort by name, modified
time, creation time, size, or extension. Use uppercase variants such as `,N`,
`,M`, `,C`, `,S`, and `,E` for the reversed order. Set
`dora.config.sort_order` to choose the default order.

### Borders

Dora float windows use rounded borders by default. On Neovim 0.12+, set
`vim.o.winborder` to customize the border style globally.

### Prompts and confirmations

Text prompts (rename, create, symlink, and so on) are confirmed with `<CR>` in
insert or normal mode. Cancel them with `<C-c>` in either mode, or with `<Esc>`
or `q` in normal mode. By default, `<Esc>` also cancels from insert mode; set
`prompt_insert_esc_closes = false` to make it leave insert mode instead. Prompt
buffers use the `dora-prompt` filetype, so you can customize them with a
`FileType` autocmd.

Confirmation windows accept with `y`, `Y`, or `<CR>`, and cancel with `n`, `N`,
`q`, `<Esc>`, or `<C-c>`. They can also be toggled closed by pressing the action
key again: for example, `p` or `P` closes a paste confirmation, while `d` or
`D` closes a trash or delete confirmation. Toggling a confirmation closed
cancels the operation.

### Filtering

Press `f` to filter the files currently visible in the tree. Filters use
case-insensitive Vim regexes, so patterns such as `lua$` work as expected. Press
`<C-i>` in the filter prompt to invert the filter, `<CR>` to keep the filter
(even while navigating), or `<Esc>` to cancel. Press `F` to clear the current
filter.

### Bookmarks

Press `m` followed by any one-character key to bookmark the current directory,
then press `'` followed by that key to return to it. Bookmarks are shared by all
Dora windows during the current Neovim session.

Use `''` to jump back to the previous directory; repeat it to toggle between the
two most recent directories. This previous-directory bookmark is window-local
and persists when Dora is closed and reopened in that window.

### LSP rename integration

File and directory renames and moves are LSP-aware. Before changing the
filesystem, Dora sends `workspace/willRenameFiles` to active language servers
which support it and applies any returned workspace edits. After filesystem
work completes, it sends `workspace/didRenameFiles` for the successful
operations.

`lsp_timeout` controls how long Dora waits for each synchronous
`willRenameFiles` response and defaults to 1000 milliseconds. Set it to `0` to
disable native LSP integration.

### Highlights

Customize Dora with these highlight groups:

<!-- dora-highlights:start -->
```vim
hi default link DoraFile                Normal
hi default link DoraDirectory           Directory
hi default link DoraSymlink             Constant
hi default link DoraExecutable          Function
hi default link DoraFifo                Type
hi default link DoraSocket              PreProc
hi default link DoraDevice              Type
hi default link DoraTree                NonText
hi default link DoraTreeActive          Directory
hi default link DoraVirtText            NonText
hi default link DoraIcon                Special
hi default link DoraCut                 DiagnosticError
hi default link DoraCopy                DiagnosticOk
hi default link DoraWarn                DiagnosticWarn
hi default link DoraError               DiagnosticError
hi default link DoraFilterMatch         Special
hi default link DoraFilterPath          Comment
hi default link DoraPromptBorder        FloatBorder
hi default link DoraPromptBorderValid   DoraPromptBorder
hi default link DoraPromptBorderInvalid DoraPromptBorder
hi default link DoraPromptBorderWarn    DoraPromptBorder
hi default link DoraInfoLabel           Label
hi default link DoraInfoValue           Special
hi default link DoraHelpSection         Title
hi default link DoraMutedText           NonText
hi default link DoraKeymapHintMnemonic  Underlined
```
<!-- dora-highlights:end -->

Unless overridden, `DoraPromptBorderValid`, `DoraPromptBorderInvalid`, and
`DoraPromptBorderWarn` get their foreground color replaced with that of
`DiagnosticOk`, `DiagnosticError`, and `DiagnosticWarn` respectively, keeping
the other `DoraPromptBorder` attributes.

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
