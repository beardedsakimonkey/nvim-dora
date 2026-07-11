-- Native LSP workspace file-operation integration for renames and moves.
local h = dofile('scripts/tests/helpers.lua')
local dora_lsp = require'dora.lsp'
local fs = h.fs
local api = h.api
local prompt = h.prompt
local store = h.store
local config = h.config
local assert_eq = h.assert_eq
local touch = h.touch
local set_cursor_pos = h.set_cursor_pos
local wait_for_paste = h.wait_for_paste

local original_get_clients = vim.lsp.get_clients
local original_apply_workspace_edit = vim.lsp.util.apply_workspace_edit

---@param filters table[]
---@param calls table[]
---@param opts? {workspace_edit?: table, on_request?: fun(params: table), on_notify?: fun(params: table)}
local function fake_client(filters, calls, opts)
    opts = opts or {}
    local client = {
        offset_encoding = 'utf-16',
        server_capabilities = {
            workspace = {
                fileOperations = {
                    willRename = {filters = filters},
                    didRename = {filters = filters},
                },
            },
        },
    }
    function client:request_sync(method, params, timeout)
        calls[#calls+1] = {kind = 'request', method = method, params = params, timeout = timeout}
        if opts.on_request then opts.on_request(params) end
        return opts.workspace_edit and {result = opts.workspace_edit} or nil
    end
    function client:notify(method, params)
        calls[#calls+1] = {kind = 'notify', method = method, params = params}
        if opts.on_notify then opts.on_notify(params) end
        return true
    end
    return client
end

local function restore_lsp()
    vim.lsp.get_clients = original_get_clients
    vim.lsp.util.apply_workspace_edit = original_apply_workspace_edit
end

-- A direct rename requests and applies edits before touching the filesystem,
-- then notifies the server before emitting Dora's extension event.
do
    local tmp = vim.fn.tempname()
    assert(vim.uv.fs_mkdir(tmp, tonumber('755', 8)))
    local from, to = tmp .. '/alpha.lua', tmp .. '/beta.lua'
    touch(from)
    local real_tmp = fs.realpath(tmp)
    local lsp_from, lsp_to = real_tmp .. '/alpha.lua', real_tmp .. '/beta.lua'

    local calls = {}
    local workspace_edit = {changes = {}}
    local client = fake_client({{scheme = 'file', pattern = {glob = '**/*.lua', matches = 'file'}}}, calls, {
        workspace_edit = workspace_edit,
        on_request = function()
            assert(fs.exists(from), 'willRenameFiles should run before the source is moved')
            assert(not fs.exists(to), 'willRenameFiles should run before the destination exists')
        end,
        on_notify = function()
            assert(not fs.exists(from), 'didRenameFiles should run after the source is moved')
            assert(fs.exists(to), 'didRenameFiles should run after the destination exists')
        end,
    })
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.lsp.get_clients = function(opts)
        assert(opts.method == 'workspace/willRenameFiles' or opts.method == 'workspace/didRenameFiles')
        return {client}
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.lsp.util.apply_workspace_edit = function(edit, encoding)
        calls[#calls+1] = {kind = 'apply', edit = edit, encoding = encoding}
        assert(fs.exists(from), 'workspace edits should be applied before the filesystem rename')
    end

    local group = vim.api.nvim_create_augroup('dora_lsp_rename_order_test', {clear = true})
    vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'DoraActionRename',
        callback = function() calls[#calls+1] = {kind = 'event'} end,
    })

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('alpha.lua')
    local old_input = prompt.input
    ---@diagnostic disable-next-line: duplicate-set-field
    prompt.input = function(opts, cb) cb('beta.lua', opts.validate('beta.lua')) end
    api.rename()
    prompt.input = old_input

    assert_eq(#calls, 4)
    assert_eq(calls[1].kind, 'request')
    assert_eq(calls[1].method, 'workspace/willRenameFiles')
    assert_eq(calls[1].timeout, 1000)
    assert_eq(calls[1].params.files[1].oldUri, vim.uri_from_fname(lsp_from))
    assert_eq(calls[1].params.files[1].newUri, vim.uri_from_fname(lsp_to))
    assert_eq(calls[2].kind, 'apply')
    assert_eq(calls[2].edit, workspace_edit)
    assert_eq(calls[2].encoding, 'utf-16')
    assert_eq(calls[3].kind, 'notify')
    assert_eq(calls[3].method, 'workspace/didRenameFiles')
    assert_eq(calls[4].kind, 'event')

    api.quit()
    vim.api.nvim_del_augroup_by_id(group)
    restore_lsp()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Each client receives only paths matching its static or dynamic registration
-- filters, and Dora's private file/folder field is not leaked into LSP params.
do
    local tmp = vim.fn.tempname()
    assert(vim.uv.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.uv.fs_mkdir(tmp .. '/dir', tonumber('755', 8)))
    touch(tmp .. '/one.lua')
    touch(tmp .. '/two.txt')
    local files = {
        dora_lsp.file_rename(tmp .. '/one.lua', tmp .. '/renamed.lua'),
        dora_lsp.file_rename(tmp .. '/two.txt', tmp .. '/renamed.txt'),
        dora_lsp.file_rename(tmp .. '/dir', tmp .. '/renamed-dir'),
    }
    local lua_calls, text_calls = {}, {}
    local lua_client = fake_client({
        {scheme = 'file', pattern = {glob = '**/*.lua', matches = 'file'}},
        {scheme = 'file', pattern = {glob = '**', matches = 'folder'}},
    }, lua_calls)
    local text_client = fake_client({}, text_calls)
    text_client.server_capabilities.workspace.fileOperations = {}
    text_client.dynamic_capabilities = {
        get = function(_, method)
            assert_eq(method, 'workspace/willRenameFiles')
            return {{registerOptions = {filters = {
                {scheme = 'file', pattern = {glob = '**/*.TXT', matches = 'file', options = {ignoreCase = true}}},
            }}}}
        end,
    }
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.lsp.get_clients = function() return {lua_client, text_client} end

    dora_lsp.will_rename(files)
    assert_eq(#lua_calls, 1)
    assert_eq(#lua_calls[1].params.files, 2)
    assert_eq(lua_calls[1].params.files[1].oldUri, files[1].oldUri)
    assert_eq(lua_calls[1].params.files[2].oldUri, files[3].oldUri)
    assert_eq(lua_calls[1].params.files[1].fs_type, nil)
    assert_eq(#text_calls, 1)
    assert_eq(#text_calls[1].params.files, 1)
    assert_eq(text_calls[1].params.files[1].oldUri, files[2].oldUri)

    restore_lsp()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- Cut/paste moves are one batched LSP rename operation, including moves across
-- directories which mini.files currently leaves out of its integration.
do
    local tmp = vim.fn.tempname()
    assert(vim.uv.fs_mkdir(tmp, tonumber('755', 8)))
    assert(vim.uv.fs_mkdir(tmp .. '/dest', tonumber('755', 8)))
    local from_a, from_b = tmp .. '/a.lua', tmp .. '/b.lua'
    local to_a, to_b = tmp .. '/dest/a(1).lua', tmp .. '/dest/b.lua'
    touch(from_a)
    touch(from_b)
    touch(tmp .. '/dest/a.lua')
    local real_tmp = fs.realpath(tmp)
    local lsp_from_a, lsp_from_b = real_tmp .. '/a.lua', real_tmp .. '/b.lua'
    local lsp_to_a, lsp_to_b = real_tmp .. '/dest/a(1).lua', real_tmp .. '/dest/b.lua'

    local calls = {}
    local client = fake_client({{pattern = {glob = '**/*.lua'}}}, calls, {
        on_request = function(params)
            assert_eq(#params.files, 2)
            assert(fs.exists(from_a) and fs.exists(from_b), 'batch willRenameFiles should precede every move')
        end,
        on_notify = function(params)
            assert_eq(#params.files, 2)
            assert(fs.exists(to_a) and fs.exists(to_b), 'batch didRenameFiles should follow every move')
        end,
    })
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.lsp.get_clients = function() return {client} end

    vim.cmd('Dora ' .. vim.fn.fnameescape(tmp))
    set_cursor_pos('a.lua')
    api.toggle_cut()
    set_cursor_pos('b.lua')
    api.toggle_cut()
    set_cursor_pos('dest')
    api.paste_under()
    vim.api.nvim_feedkeys('y', 'xt', false)
    wait_for_paste()

    assert_eq(#calls, 2)
    assert_eq(calls[1].kind, 'request')
    assert_eq(calls[1].params.files[1].oldUri, vim.uri_from_fname(lsp_from_a))
    assert_eq(calls[1].params.files[1].newUri, vim.uri_from_fname(lsp_to_a))
    assert_eq(calls[1].params.files[2].oldUri, vim.uri_from_fname(lsp_from_b))
    assert_eq(calls[1].params.files[2].newUri, vim.uri_from_fname(lsp_to_b))
    assert_eq(calls[2].kind, 'notify')

    api.quit()
    restore_lsp()
    assert_eq(vim.fn.delete(tmp, 'rf'), 0)
end

-- A zero timeout disables both client discovery and protocol messages.
do
    local old_timeout = config.lsp_timeout
    config.lsp_timeout = 0
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.lsp.get_clients = function() error('disabled LSP integration should not discover clients') end
    local file = dora_lsp.file_rename('/tmp/old.lua', '/tmp/new.lua')
    dora_lsp.will_rename({file})
    dora_lsp.did_rename({file})
    config.lsp_timeout = old_timeout
    restore_lsp()
end
