local api = vim.api
local fs = require'dirtree.fs'
local util = require'dirtree.util'
local window = require'dirtree.window'

local M = {}

---@class DirtreeBulkRenameChange
---@field src string
---@field dest string
---@field src_rel string
---@field dest_rel string

---@class DirtreeBulkRenameOpenOptions
---@field cwd string
---@field paths string[]
---@field on_success fun(changes: DirtreeBulkRenameChange[])

---@class DirtreeBulkRenameEntry: DirtreeBulkRenameChange
---@field changed boolean
---@field temp? string

---@param path string
---@param prefix string
---@return boolean
local function is_descendant(path, prefix)
    return vim.startswith(path, prefix .. util.sep)
end

---@param path string
---@param dir string
---@return boolean
local function is_path_in_dir(path, dir)
    return path == dir or is_descendant(path, dir)
end

---@param cwd string
---@param path string
---@return string
local function relative_path(cwd, path)
    assert(vim.startswith(path, cwd .. util.sep), ('%q is not below %q'):format(path, cwd))
    return path:sub(#cwd + 2)
end

---@param cwd string
---@param rel string
---@return string
local function absolute_path(cwd, rel)
    assert(rel ~= '', 'Line cannot be empty')
    assert(rel:sub(1, 1) ~= util.sep, 'Bulk rename paths must be relative')
    assert(not vim.endswith(rel, util.sep), 'Bulk rename paths cannot end with a separator')
    local parts = vim.split(rel, util.sep, {plain = true})
    for _, part in ipairs(parts) do
        assert(part ~= '', 'Bulk rename paths cannot contain empty segments')
        assert(part ~= '.' and part ~= '..', 'Bulk rename paths cannot contain . or ..')
    end
    return util.join_path(cwd, rel)
end

---@param src string
---@param base string
---@param used table<string, true>
---@return string
local function temp_path(src, base, used)
    local parent = fs.parent_dir(src)
    for i = 1, 1000 do
        local path = util.join_path(parent, ('.dirtree-bulk-rename-%s-%d'):format(base, i))
        if not used[path] and not fs.exists(path) then
            used[path] = true
            return path
        end
    end
    error('Could not allocate temporary rename path')
end

---@param entries DirtreeBulkRenameEntry[]
local function validate_directory_conflicts(entries)
    for _, entry in ipairs(entries) do
        if fs.is_dir(entry.src) then
            assert(not is_descendant(entry.dest, entry.src), ('Cannot move %q into itself'):format(entry.src_rel))
            for _, other in ipairs(entries) do
                if other ~= entry then
                    assert(not is_descendant(other.src, entry.src),
                        ('Cannot bulk rename %q and its descendant %q'):format(entry.src_rel, other.src_rel))
                    assert(not is_descendant(other.dest, entry.src),
                        ('Destination %q is inside original directory %q'):format(other.dest_rel, entry.src_rel))
                    assert(not is_descendant(other.dest, entry.dest),
                        ('Destination %q is inside renamed directory %q'):format(other.dest_rel, entry.dest_rel))
                end
            end
        end
    end
end

---@param cwd string
---@param paths string[]
---@param lines string[]
---@return DirtreeBulkRenameEntry[]
local function build_entries(cwd, paths, lines)
    assert(#lines == #paths, ('Expected %d lines, found %d'):format(#paths, #lines))
    local cwd_real = fs.realpath(cwd)
    local entries = {}
    local dests = {}
    local changed_sources = {}

    for i, src in ipairs(paths) do
        local src_rel = relative_path(cwd, src)
        local dest_rel = lines[i]
        local dest = absolute_path(cwd, dest_rel)
        assert(not dests[dest], ('Duplicate destination %q'):format(dest_rel))
        dests[dest] = true
        local changed = src ~= dest
        if changed then
            changed_sources[src] = true
        end
        entries[#entries+1] = {
            src = src,
            dest = dest,
            src_rel = src_rel,
            dest_rel = dest_rel,
            changed = changed,
        }
    end

    for _, entry in ipairs(entries) do
        if entry.changed then
            local parent = fs.parent_dir(entry.dest)
            assert(fs.exists(parent), ('%q does not exist'):format(parent))
            assert(fs.is_dir(parent), ('%q is not a directory'):format(parent))
            assert(is_path_in_dir(fs.realpath(parent), cwd_real), 'Destination parent must stay under the dirtree root')
            assert(not fs.exists(entry.dest) or changed_sources[entry.dest],
                ('%q already exists'):format(entry.dest_rel))
        end
    end

    validate_directory_conflicts(entries)
    return entries
end

---@param entries DirtreeBulkRenameEntry[]
---@return DirtreeBulkRenameChange[]
local function apply_entries(entries)
    local changes = vim.tbl_filter(function(entry)
        return entry.changed
    end, entries)
    if #changes == 0 then
        return {}
    end

    local used_temps = {}
    for _, entry in ipairs(changes) do
        entry.temp = temp_path(entry.src, tostring(vim.loop.hrtime()), used_temps)
    end

    local done = {}
    local ok, err = pcall(function()
        for _, entry in ipairs(changes) do
            fs.rename(entry.src, entry.temp)
            done[#done+1] = {src = entry.src, dest = entry.temp}
        end
        for _, entry in ipairs(changes) do
            fs.rename(entry.temp, entry.dest)
            done[#done+1] = {src = entry.temp, dest = entry.dest}
        end
    end)
    if not ok then
        for i = #done, 1, -1 do
            local step = done[i]
            if fs.exists(step.dest) and not fs.exists(step.src) then
                pcall(fs.rename, step.dest, step.src)
            end
        end
        error(err)
    end

    return vim.tbl_map(function(entry)
        return {
            src = entry.src,
            dest = entry.dest,
            src_rel = entry.src_rel,
            dest_rel = entry.dest_rel,
        }
    end, changes)
end

---@param win integer
---@param buf integer
---@param origin_win integer
local function close(win, buf, origin_win)
    if window.valid_buf(buf) then
        vim.bo[buf].modified = false
    end
    if window.valid_win(win) then
        pcall(api.nvim_win_close, win, true)
    end
    if window.valid_buf(buf) then
        pcall(api.nvim_buf_delete, buf, {force = true})
    end
    if window.valid_win(origin_win) then
        pcall(api.nvim_set_current_win, origin_win)
    end
end

---@param opts DirtreeBulkRenameOpenOptions
function M.open(opts)
    local origin_win = api.nvim_get_current_win()
    local buf = api.nvim_create_buf(false, false)
    vim.bo[buf].buftype = 'acwrite'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype = 'dirtree-bulk-rename'
    vim.bo[buf].swapfile = false
    api.nvim_buf_set_name(buf, ('dirtree-bulk-rename://%d'):format(buf))
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.tbl_map(function(path)
        return relative_path(opts.cwd, path)
    end, opts.paths))
    vim.bo[buf].modified = false

    vim.cmd'botright vertical split'
    local win = api.nvim_get_current_win()
    api.nvim_win_set_buf(win, buf)

    local group = api.nvim_create_augroup(('dirtree.bulk_rename.%d'):format(buf), {clear = true})
    local group_deleted = false
    local function delete_group()
        if not group_deleted then
            group_deleted = true
            pcall(api.nvim_del_augroup_by_id, group)
        end
    end
    api.nvim_create_autocmd('BufWriteCmd', {
        group = group,
        buffer = buf,
        callback = function()
            local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
            local ok, result = pcall(function()
                return apply_entries(build_entries(opts.cwd, opts.paths, lines))
            end)
            if not ok then
                util.err(result)
                return
            end
            delete_group()
            close(win, buf, origin_win)
            opts.on_success(result)
        end,
    })
    api.nvim_create_autocmd('BufWipeout', {
        group = group,
        buffer = buf,
        callback = delete_group,
    })
end

return M
