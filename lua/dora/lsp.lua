-- Native LSP workspace file-operation integration. File renames and moves use
-- the same RenameFiles protocol messages: `willRenameFiles` may return edits
-- which must be applied before touching the filesystem, while `didRenameFiles`
-- is sent only after the operation succeeds.
local config = require'dora'.config

local M = {}
local iswin = vim.uv.os_uname().sysname:match('Windows') ~= nil

---@param path string
---@return string
local function fname_to_uri(path)
    if iswin then
        -- Avoid `C://...`, which has glob-matching issues in some servers.
        path = path:gsub('^(%a)://([^/])', '%1:/%2')
    end
    return vim.uri_from_fname(path)
end

---@param uri string
---@return string
local function uri_to_fname(uri)
    local path = vim.uri_to_fname(uri)
    -- LSP registration globs conventionally use `/` on every platform.
    return iswin and (path:gsub('\\', '/')) or path
end

---@class DoraLspFileRename
---@field oldUri string
---@field newUri string
---@field fs_type 'file'|'folder' Used only while applying server filters

---@param from string
---@param to string
---@return DoraLspFileRename
function M.file_rename(from, to)
    return {
        oldUri = fname_to_uri(from),
        newUri = fname_to_uri(to),
        fs_type = vim.fn.isdirectory(from) == 1 and 'folder' or 'file',
    }
end

---@param uri string
---@param scheme? string
---@return boolean
local function scheme_matches(uri, scheme)
    return scheme == nil or vim.startswith(uri, scheme .. ':')
end

---@param file DoraLspFileRename
---@param expected? 'file'|'folder'
---@return boolean
local function type_matches(file, expected)
    return expected == nil or file.fs_type == expected
end

---@param filter lsp.FileOperationFilter
---@return fun(file: DoraLspFileRename): boolean
local function make_filter(filter)
    local pattern = filter.pattern or {}
    local ignore_case = pattern.options and pattern.options.ignoreCase or false
    local adjust_case = ignore_case and string.lower or function(value) return value end
    local glob = adjust_case(pattern.glob or '**')
    local glob_lpeg = vim.glob.to_lpeg(glob)
    return function(file)
        local path = adjust_case(uri_to_fname(file.oldUri))
        return scheme_matches(file.oldUri, filter.scheme)
            and type_matches(file, pattern.matches)
            and glob_lpeg:match(path) ~= nil
    end
end

---@param client vim.lsp.Client
---@param method string
---@param capability 'willRename'|'didRename'
---@return lsp.FileOperationFilter[]
local function client_filters(client, method, capability)
    local options = {}
    -- Dynamic registrations take precedence over the static server capability,
    -- matching `Client:supports_method()` in Neovim.
    local dynamic = client.dynamic_capabilities
        and client.dynamic_capabilities:get(method)
    if dynamic then
        for _, registration in ipairs(dynamic) do
            options[#options+1] = registration.registerOptions or {}
        end
    else
        local static = vim.tbl_get(client.server_capabilities, 'workspace', 'fileOperations', capability)
        if static then
            options[1] = static
        end
    end

    local filters = {}
    for _, registration_options in ipairs(options) do
        vim.list_extend(filters, registration_options.filters or {})
    end
    return filters
end

---@param client vim.lsp.Client
---@param method string
---@param capability 'willRename'|'didRename'
---@param files DoraLspFileRename[]
---@return lsp.RenameFilesParams
local function client_params(client, method, capability, files)
    local filter_configs = client_filters(client, method, capability)
    local filters = vim.tbl_map(make_filter, filter_configs)
    local params = {files = {}}
    for _, file in ipairs(files) do
        -- An empty filter list is a useful fallback for servers which advertise
        -- file operations without the required registration filters.
        local matches = #filters == 0
        for _, filter in ipairs(filters) do
            matches = matches or filter(file)
        end
        if matches then
            params.files[#params.files+1] = {
                oldUri = file.oldUri,
                newUri = file.newUri,
            }
        end
    end
    return params
end

---@param capability 'willRename'|'didRename'
---@param files DoraLspFileRename[]
local function rename_hook(capability, files)
    if config.lsp_timeout == 0 or #files == 0 then
        return
    end
    local method = 'workspace/' .. capability .. 'Files'
    for _, client in ipairs(vim.lsp.get_clients({method = method})) do
        local params = client_params(client, method, capability, files)
        if capability == 'didRename' then
            client:notify(method, params)
        else
            local response = client:request_sync(method, params, config.lsp_timeout)
            if response and response.result then
                vim.lsp.util.apply_workspace_edit(response.result, client.offset_encoding)
            end
        end
    end
end

---@param files DoraLspFileRename[]
function M.will_rename(files)
    rename_hook('willRename', files)
end

---@param files DoraLspFileRename[]
function M.did_rename(files)
    rename_hook('didRename', files)
end

return M
