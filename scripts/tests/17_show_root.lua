-- The show_root option: rendering the browsed directory itself as the tree
-- root with its contents nested beneath it, and how actions treat that root
-- row. Part of the smoke suite (driven by scripts/smoke.lua). Run this file
-- on its own with DORA_TEST_FILE=scripts/tests/17_show_root.lua (see
-- scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local api = h.api
local config = h.config
local confirm_win = h.confirm_win
local fs = h.fs
local prompt = h.prompt
local store = h.store
local assert_eq = h.assert_eq
local touch = h.touch
local lines = h.lines
local current_line = h.current_line
local find_line_index = h.find_line_index
local marked_path_count = h.marked_path_count
local set_cursor_pos = h.set_cursor_pos
local wait_for_paste = h.wait_for_paste

local view = require'dora.view'

local function with_show_root(value, fn)
    local old = config.show_root
    config.show_root = value
    local ok, err = pcall(fn)
    config.show_root = old
    if not ok then
        error(err, 0)
    end
end

-- Rendering: the root row leads the buffer and the listing nests beneath it.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')
    touch(tmp .. '/beta.txt')
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))
    touch(tmp .. '/sub/nested.txt')

    with_show_root(true, function()
        vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
        local state = store.get()
        local root_name = vim.fs.basename(state.cwd)

        local rendered = lines()
        assert_eq(rendered[1], root_name .. '/', 'the root row should lead the buffer')
        assert(find_line_index(rendered, '^├── alpha%.txt$'), 'top-level files should nest under the root')
        assert(find_line_index(rendered, '^└── beta%.txt$'), 'the last top-level entry should use the corner connector')

        local root_row = state.rows[1]
        assert_eq(root_row.is_root, true, 'the first row should be marked as the root')
        assert_eq(root_row.path, state.cwd, 'the root row should carry the cwd path')
        assert_eq(root_row.type, 'directory')
        assert_eq(root_row.depth, 0)
        assert_eq(root_row.parent_path, nil, 'the root row should have no parent')
        assert_eq(root_row.name, root_name)
        assert_eq(root_row.directory_suffix_col, #root_name, 'the root row should embed the directory suffix')

        local alpha_row = state.rows[assert(find_line_index(rendered, '^├── alpha%.txt$'))]
        assert_eq(alpha_row.depth, 1, 'top-level entries should sit at depth 1 under the root')
        assert_eq(alpha_row.parent_path, state.cwd)

        -- Expanding a directory nests its children one level deeper.
        set_cursor_pos('sub')
        api.fold_out()
        rendered = lines()
        assert(find_line_index(rendered, '^│   └── nested%.txt$'),
            'expanded directory children should nest a level deeper than the root listing')
        api.fold_in_recursive()

        -- The filter view shows cwd-relative paths and no root row.
        state.filter_text = 'txt'
        view.render(state)
        rendered = lines()
        assert_eq(find_line_index(rendered, '^' .. vim.pesc(root_name) .. '/$'), nil,
            'the filter view should not include the root row')
        assert(find_line_index(rendered, '^alpha%.txt$'), 'the filter view should keep relative paths')
        for _, row in ipairs(state.rows) do
            assert(not row.is_root, 'filtered rows should never include the root')
        end
        state.filter_text = nil
        view.render(state)

        api.quit()
    end)

    -- Without show_root the listing renders at the top level, as before.
    with_show_root(false, function()
        vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
        local state = store.get()
        local rendered = lines()
        assert(find_line_index(rendered, '^alpha%.txt$'), 'show_root = false should keep the flat top-level listing')
        assert_eq(find_line_index(rendered, '^' .. vim.pesc(vim.fs.basename(state.cwd)) .. '/$'), nil,
            'show_root = false should render no root row')
        assert(not state.rows[1].is_root, 'show_root = false should mark no row as root')
        api.quit()
    end)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- An empty directory renders its placeholder beneath the root.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))

    with_show_root(true, function()
        vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
        local state = store.get()
        local rendered = lines()
        assert_eq(rendered[1], vim.fs.basename(state.cwd) .. '/')
        assert_eq(rendered[2], '└── (empty)', 'an empty root should show the placeholder as its child')
        assert_eq(#rendered, 2)
        api.quit()
    end)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- The root row uses the expanded directory icon when icons are enabled.
-- Only directories are listed: they take the built-in fallback icons, so the
-- test is independent of whatever icon provider earlier files left cached.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))

    local old_icons = config.icons
    config.icons = true
    with_show_root(true, function()
        vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
        local state = store.get()
        local root_row = state.rows[1]
        assert_eq(root_row.icon, '\238\151\190', 'the root row should use the expanded directory icon')
        assert_eq(root_row.icon_hl, 'DoraDirectory')
        assert_eq(root_row.name_start_col, #root_row.icon + 1, 'the root name should follow the icon')
        assert_eq(state.rows[2].icon, '\238\151\191', 'unexpanded children should keep the collapsed icon')
        api.quit()
    end)
    config.icons = old_icons

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Destructive and mark actions refuse the root row instead of acting on the
-- browsed directory itself.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/keep.txt')

    with_show_root(true, function()
        vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
        local state = store.get()
        vim.api.nvim_win_set_cursor(0, {1, 0})

        local notifications = {}
        local old_notify = vim.notify
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg) notifications[#notifications+1] = msg end

        local confirm_opened = false
        local old_show = confirm_win.show
        ---@diagnostic disable-next-line: duplicate-set-field
        confirm_win.show = function() confirm_opened = true end
        api.trash()
        api.delete()
        confirm_win.show = old_show
        assert(not confirm_opened, 'trash/delete on the root row should not open a confirmation')
        assert(fs.exists(tmp .. '/keep.txt'), 'the root directory should survive trash/delete on its row')

        api.toggle_cut()
        api.toggle_copy()
        assert_eq(marked_path_count(state), 0, 'cut/copy should not mark the root row')

        vim.notify = old_notify
        for i, action in ipairs({'trash', 'delete', 'cut', 'copy'}) do
            assert_eq(notifications[i], ('dora: Cannot %s the root directory'):format(action),
                action .. ' on the root row should warn instead of acting')
        end
        assert_eq(#notifications, 4, 'each refused root action should warn exactly once')

        api.quit()
    end)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Both add actions on the root row create directly in the cwd with an empty
-- initial prompt (add previously crashed resolving the root's parent).
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/existing.txt')

    with_show_root(true, function()
        vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
        local state = store.get()
        vim.api.nvim_win_set_cursor(0, {1, 0})

        local old_input = prompt.input
        ---@diagnostic disable-next-line: duplicate-set-field
        prompt.input = function(opts, cb)
            assert_eq(opts.initial_prompt, nil, 'add on the root row should start from an empty prompt')
            cb('added.txt', opts.validate('added.txt'))
        end
        api.add()
        assert(fs.exists(tmp .. '/added.txt'), 'add on the root row should create in the cwd')

        ---@diagnostic disable-next-line: duplicate-set-field
        prompt.input = function(opts, cb)
            assert_eq(opts.initial_prompt, nil, 'add_under on the root row should start from an empty prompt')
            cb('under.txt', opts.validate('under.txt'))
        end
        api.add_under()
        prompt.input = old_input
        assert(fs.exists(tmp .. '/under.txt'), 'add_under on the root row should create in the cwd')
        assert_eq(current_line(), '└── under.txt', 'the cursor should land on the created entry')
        assert_eq(state.cwd, vim.loop.fs_realpath(tmp), 'the session should still browse the same directory')

        api.quit()
    end)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Paste on the root row targets the cwd, like paste_under.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))
    touch(tmp .. '/sub/inner.txt')

    with_show_root(true, function()
        vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
        set_cursor_pos('sub')
        api.fold_out()
        set_cursor_pos('inner.txt')
        api.toggle_copy()
        vim.api.nvim_win_set_cursor(0, {1, 0})
        api.paste()
        vim.api.nvim_feedkeys('y', 'xt', false)
        wait_for_paste()
        assert(fs.exists(tmp .. '/inner.txt'), 'paste on the root row should paste into the cwd')
        assert_eq(current_line(), '└── inner.txt', 'the cursor should land on the pasted entry')
        api.fold_in_recursive()
        api.quit()
    end)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Folding at the root row: fold_out expands the first level, fold_in stops
-- above the root, and the root itself cannot be closed.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/sub', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/sub/deeper', tonumber('755', 8)))

    with_show_root(true, function()
        vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
        local state = store.get()
        vim.api.nvim_win_set_cursor(0, {1, 0})

        api.fold_out()
        assert(find_line_index(lines(), 'deeper/$'), 'fold_out on the root should expand the first level')
        assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1, 'the cursor should stay on the root row')

        api.fold_in()
        assert_eq(find_line_index(lines(), 'deeper/$'), nil, 'fold_in on the root should collapse the deepest level')

        local before = table.concat(lines(), '\n')
        api.fold_in()
        api.close_dir()
        assert_eq(table.concat(lines(), '\n'), before, 'fold_in/close_dir cannot collapse the root itself')

        state.expanded_dirs[state.cwd] = nil
        api.quit()
    end)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Visual selections sweep past the root row without acting on it.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/a.txt')
    touch(tmp .. '/b.txt')

    with_show_root(true, function()
        vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
        local state = store.get()
        vim.api.nvim_win_set_cursor(0, {1, 0})
        vim.api.nvim_feedkeys('Vj', 'xt', false)
        api.toggle_copy_visual()
        assert_eq(marked_path_count(state), 1, 'a visual mark over the root should only mark its children')
        assert_eq(state.marked_paths[state.cwd], nil, 'the root row should stay unmarked')
        assert_eq(state.marked_paths[state.cwd .. '/a.txt'], 'copy')
        api.clear_copy()
        api.quit()
    end)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Cursor motions around the root: parent_dir from a top-level entry lands on
-- the root, sibling motions stay put, and name matching skips the root row
-- when a child shares the cwd's basename.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/shadow', tonumber('755', 8)))
    touch(tmp .. '/shadow/shadow')

    with_show_root(true, function()
        vim.cmd('Dora ' .. vim.fn.fnameescape(tmp .. '/shadow'))
        local state = store.get()

        view.set_cursor_pos(state, 'shadow')
        assert_eq(vim.api.nvim_win_get_cursor(0)[1], 2,
            'name matching should skip the root row when a child shares its name')

        api.parent_dir()
        assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1, 'parent_dir from a top-level entry should land on the root')

        api.next_sibling()
        api.prev_sibling()
        assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1, 'sibling motions should stay on the root row')

        api.quit()
    end)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Renaming the root row renames the browsed directory and retargets the
-- session: cwd, buffer name, and expanded state all follow the new path.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/old', tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/old/sub', tonumber('755', 8)))
    touch(tmp .. '/old/sub/file.txt')

    with_show_root(true, function()
        vim.cmd('Dora ' .. vim.fn.fnameescape(tmp .. '/old'))
        local state = store.get()
        local parent = fs.get_parent_dir(state.cwd)
        set_cursor_pos('sub')
        api.fold_out()
        vim.api.nvim_win_set_cursor(0, {1, 0})

        local old_input = prompt.input
        ---@diagnostic disable-next-line: duplicate-set-field
        prompt.input = function(opts, cb)
            assert_eq(opts.initial_prompt, 'old', 'root rename should prefill the directory basename')
            assert_eq(opts.cwd, parent, 'root rename should resolve names against the parent directory')
            cb('new', opts.validate('new'))
        end
        api.rename()
        prompt.input = old_input

        assert(not fs.exists(tmp .. '/old'), 'root rename should move the browsed directory')
        assert(fs.exists(tmp .. '/new/sub/file.txt'), 'root rename should move the directory subtree')
        assert_eq(state.cwd, parent .. '/new', 'root rename should retarget the session cwd')
        assert_eq(vim.api.nvim_buf_get_name(state.buf), parent .. '/new',
            'root rename should rename the dora buffer after the new cwd')
        assert_eq(lines()[1], 'new/', 'root rename should re-render the root row under its new name')
        assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1, 'root rename should keep the cursor on the root row')
        assert_eq(state.expanded_dirs[parent .. '/new/sub'], true, 'root rename should carry expanded state over')
        assert(find_line_index(lines(), 'file%.txt$'), 'root rename should keep expanded children visible')

        api.fold_in_recursive()
        api.quit()
    end)

    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- The filesystem root has no parent to rename within.
do
    with_show_root(true, function()
        vim.cmd('Dora /')
        vim.api.nvim_win_set_cursor(0, {1, 0})
        local notification
        local old_notify = vim.notify
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg) notification = msg end
        local prompt_opened = false
        local old_input = prompt.input
        ---@diagnostic disable-next-line: duplicate-set-field
        prompt.input = function() prompt_opened = true end
        api.rename()
        prompt.input = old_input
        vim.notify = old_notify
        assert(not prompt_opened, 'rename on the filesystem root should not open a prompt')
        assert_eq(notification, 'dora: Cannot rename the filesystem root',
            'rename on the filesystem root should warn instead of prompting')
        api.quit()
    end)
end
