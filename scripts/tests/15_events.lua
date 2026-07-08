-- User autocmd events (DoraAction*) fired for filesystem actions, so
-- integrations like Snacks.rename can forward renames/moves to the LSP.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/15_events.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local fs = h.fs
local prompt = h.prompt
local api = h.api
local store = h.store
local assert_eq = h.assert_eq
local touch = h.touch
local set_cursor_pos = h.set_cursor_pos
local wait_for_paste = h.wait_for_paste
local wait_for_remove = h.wait_for_remove

-- Capture every DoraAction* User autocmd for the duration of the suite. The
-- events table is cleared in place at each block so the callbacks keep seeing
-- the same upvalue.
local events = {}
local function reset_events()
    for i = #events, 1, -1 do
        events[i] = nil
    end
end
local function find_event(pattern)
    for _, event in ipairs(events) do
        if event.pattern == pattern then
            return event
        end
    end
end
local group = vim.api.nvim_create_augroup('dora_events_test', {clear = true})
for _, kind in ipairs({'Rename', 'Move', 'Copy', 'Create', 'Delete'}) do
    vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'DoraAction' .. kind,
        callback = function(ev)
            events[#events+1] = {pattern = ev.match, data = ev.data}
        end,
    })
end

-- Rename emits DoraActionRename with the old and new absolute paths.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/alpha.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local root = store.get().cwd
    set_cursor_pos('alpha.txt')
    reset_events()
    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        cb('beta.txt', opts.validate('beta.txt'))
    end
    api.rename()
    prompt.input = old_input

    assert_eq(#events, 1, 'rename should emit exactly one event')
    assert_eq(events[1].pattern, 'DoraActionRename')
    assert_eq(events[1].data.action, 'rename')
    assert_eq(events[1].data.from, root .. '/alpha.txt')
    assert_eq(events[1].data.to, root .. '/beta.txt')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Creating a file or directory emits DoraActionCreate with only `to`, and the
-- directory path is reported without a trailing slash.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local root = store.get().cwd
    local old_input = prompt.input

    reset_events()
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        cb('made.txt', opts.validate('made.txt'))
    end
    api.add()
    assert_eq(#events, 1, 'creating a file should emit one event')
    assert_eq(events[1].pattern, 'DoraActionCreate')
    assert_eq(events[1].data.to, root .. '/made.txt')
    assert_eq(events[1].data.from, nil, 'create should carry no `from`')

    reset_events()
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        cb('newdir/', opts.validate('newdir/'))
    end
    api.add()
    prompt.input = old_input
    assert_eq(#events, 1, 'creating a directory should emit one event')
    assert_eq(events[1].data.to, root .. '/newdir',
        'a created directory should be reported without a trailing slash')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Creating a symlink emits DoraActionCreate for the new link path.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/target.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local root = store.get().cwd
    set_cursor_pos('target.txt')
    reset_events()
    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb)
        cb('mylink', opts.validate('mylink'))
    end
    api.create_symlink()
    prompt.input = old_input

    assert_eq(#events, 1, 'creating a symlink should emit one event')
    assert_eq(events[1].pattern, 'DoraActionCreate')
    assert_eq(events[1].data.to, root .. '/mylink')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Deleting emits DoraActionDelete with only `from`.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    touch(tmp .. '/gone.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local root = store.get().cwd
    set_cursor_pos('gone.txt')
    reset_events()
    api.delete()
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_remove()

    assert_eq(#events, 1, 'delete should emit exactly one event')
    assert_eq(events[1].pattern, 'DoraActionDelete')
    assert_eq(events[1].data.action, 'delete')
    assert_eq(events[1].data.from, root .. '/gone.txt')
    assert_eq(events[1].data.to, nil, 'delete should carry no `to`')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- A cut-and-paste emits DoraActionMove and a copy-and-paste emits
-- DoraActionCopy, each with the source and its landing path.
do
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    touch(tmp .. '/a.txt')
    touch(tmp .. '/b.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local root = store.get().cwd
    set_cursor_pos('a.txt')
    api.toggle_cut()
    set_cursor_pos('b.txt')
    api.toggle_copy()
    set_cursor_pos('dest')
    reset_events()
    api.paste_under()
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert_eq(#events, 2, 'a mixed paste should emit one event per op')
    local move_event = find_event('DoraActionMove')
    local copy_event = find_event('DoraActionCopy')
    assert(move_event, 'cut + paste should emit a Move event')
    assert_eq(move_event.data.action, 'move')
    assert_eq(move_event.data.from, root .. '/a.txt')
    assert_eq(move_event.data.to, root .. '/dest/a.txt')
    assert(copy_event, 'copy + paste should emit a Copy event')
    assert_eq(copy_event.data.action, 'copy')
    assert_eq(copy_event.data.from, root .. '/b.txt')
    assert_eq(copy_event.data.to, root .. '/dest/b.txt')

    api.quit()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Trashing emits DoraActionDelete, and restoring it (undo) emits
-- DoraActionCreate for the path brought back.
do
    local old_home = vim.env.HOME
    local old_data_home = vim.env.XDG_DATA_HOME
    local tmp = vim.fn.tempname()
    assert(vim.loop.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.loop.fs_mkdir(tmp .. '/home', tonumber('755', 8)))
    vim.env.HOME = tmp .. '/home'
    vim.env.XDG_DATA_HOME = tmp .. '/data'
    touch(tmp .. '/restore.txt')

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    local root = store.get().cwd
    set_cursor_pos('restore.txt')
    reset_events()
    api.trash()
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_remove()
    assert_eq(#events, 1, 'trash should emit one Delete event')
    assert_eq(events[1].pattern, 'DoraActionDelete')
    assert_eq(events[1].data.from, root .. '/restore.txt')

    reset_events()
    api.undo_trash()
    vim.api.nvim_feedkeys('y', 'xt', false)
    assert(fs.exists(tmp .. '/restore.txt'), 'undo should restore the trashed file')
    assert_eq(#events, 1, 'restoring should emit one Create event')
    assert_eq(events[1].pattern, 'DoraActionCreate')
    assert_eq(events[1].data.to, root .. '/restore.txt')

    api.quit()
    vim.env.HOME = old_home
    vim.env.XDG_DATA_HOME = old_data_home
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

vim.api.nvim_del_augroup_by_id(group)
