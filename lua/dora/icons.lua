-- File icon lookup with pluggable providers (nvim-web-devicons or mini.icons)
-- and built-in fallbacks for directories, symlinks, and special file types
-- (fifos, sockets, and devices). Also the shared name-highlight and ls -F
-- marker classification (M.decoration) used by the tree view, directory
-- previews, and confirmation windows.
local M = {}

local uv = vim.uv

local devicons
local devicons_loaded = false

---@return table?
local function get_devicons()
    if not devicons_loaded then
        local ok, mod = pcall(require, 'nvim-web-devicons')
        devicons = ok and mod or nil
        devicons_loaded = true
    end
    return devicons
end

---@return table?
local function get_mini_icons()
    local global = rawget(_G, 'MiniIcons')
    if type(global) == 'table' and type(global.get) == 'function' then
        return global
    end
    return nil
end

---@param icon any
---@param hl any
---@return string? icon
---@return string? hl
local function normalize(icon, hl)
    if type(icon) ~= 'string' or icon == '' then
        return nil, nil
    end
    if type(hl) ~= 'string' then
        hl = nil
    end
    return icon, hl
end

-- Special file types always take these fixed icons, never a provider icon:
-- providers match by name and extension, which is meaningless for e.g. a
-- fifo named `log.txt`. Fifos and sockets also carry their ls -F marker.
---@type table<string, {icon: string, hl: string, marker?: string}>
M.special_types = {
    fifo = {icon = '󰟥', hl = 'DoraFifo', marker = '|'},
    socket = {icon = '󰐧', hl = 'DoraSocket', marker = '='},
    char = {icon = '󰆍', hl = 'DoraDevice'},
    block = {icon = '󰋊', hl = 'DoraDevice'},
}

-- Name highlight and trailing ls -F type marker for an entry, shared by the
-- tree view, directory previews, and confirmation windows: '/' directories,
-- '@' symlinks (the tree appends the resolved target), '|' fifos, '=' sockets,
-- and '*' executables. Devices and plain files carry no marker.
---@param file_type DoraFileType
---@param path string Checked for the executable bit on regular files
---@return string hl
---@return string? marker
function M.decoration(file_type, path)
    if file_type == 'directory' then
        return 'DoraDirectory', '/'
    elseif file_type == 'link' then
        return 'DoraSymlink', '@'
    end
    local special = M.special_types[file_type]
    if special then
        return special.hl, special.marker
    end
    if uv.fs_access(path, 'X') then
        return 'DoraExecutable', '*'
    end
    return 'DoraFile'
end

---@param file DoraFile
---@param expanded? boolean
---@return string icon
---@return string hl
local function fallback(file, expanded)
    if file.type == 'directory' then
        return expanded and '' or '', 'DoraDirectory'
    elseif file.type == 'link' then
        return '', 'DoraSymlink'
    end
    local special = M.special_types[file.type]
    if special then
        return special.icon, special.hl
    end
    return '', 'DoraIcon'
end

---@param file DoraFile
---@param path string
---@param expanded? boolean
---@return string icon
---@return string hl
local function web_devicon(file, path, expanded)
    if file.type ~= 'file' then
        return fallback(file, expanded)
    end

    local provider = get_devicons()
    if provider and type(provider.get_icon) == 'function' then
        local icon, hl = normalize(provider.get_icon(file.name, vim.fn.fnamemodify(path, ':e'), {default = true}))
        if icon then
            return icon, hl or 'DoraIcon'
        end
    end

    return fallback(file)
end

---@param file DoraFile
---@param path string
---@return string icon
---@return string hl
local function mini_icon(file, path)
    if file.type ~= 'file' and file.type ~= 'directory' then
        return fallback(file)
    end

    local provider = get_mini_icons()
    if provider then
        local category = file.type == 'directory' and 'directory' or 'file'
        local icon, hl = normalize(provider.get(category, path))
        if icon then
            return icon, hl or 'DoraIcon'
        end
    end

    return fallback(file)
end

---@param provider DoraIconConfig
---@param file DoraFile
---@param path string
---@param expanded? boolean whether an expanded directory icon should be used
---@return string? icon
---@return string? hl
function M.get(provider, file, path, expanded)
    if provider == false or provider == nil then
        return nil, nil
    elseif provider == true or provider == 'nvim-web-devicons' then
        return web_devicon(file, path, expanded)
    elseif provider == 'mini.icons' then
        return mini_icon(file, path)
    end
    return nil, nil
end

return M
