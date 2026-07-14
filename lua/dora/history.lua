-- Window-local browser history. Histories outlive individual dora buffers but
-- are discarded with the Neovim window that owns them.
local api = vim.api

local M = {}

---@class DoraHistoryEntry
---@field directory string
---@field hovered_path? string

---@class DoraHistory
---@field entries DoraHistoryEntry[]
---@field index integer

---@type table<integer, DoraHistory>
local window_histories = {}

api.nvim_create_autocmd('WinClosed', {
    group = api.nvim_create_augroup('dora.history', {clear=true}),
    callback = function(args)
        window_histories[tonumber(args.match)] = nil
    end,
})

---@param win integer
---@return DoraHistory
function M.get(win)
    local history = window_histories[win]
    if not history then
        history = {entries = {}, index = 0}
        window_histories[win] = history
    end
    return history
end

---@param win integer
function M.clear(win)
    local history = M.get(win)
    history.entries = {}
    history.index = 0
end

---@param history DoraHistory
---@return DoraHistoryEntry?
function M.current(history)
    return history.entries[history.index]
end

---@param history DoraHistory
---@param directory string
---@param hovered_path? string
---@return boolean changed
function M.visit(history, directory, hovered_path)
    local current = M.current(history)
    if current and current.directory == directory then
        if hovered_path ~= nil then
            current.hovered_path = hovered_path
        end
        return false
    end
    for i = #history.entries, history.index + 1, -1 do
        table.remove(history.entries, i)
    end
    history.entries[#history.entries+1] = {
        directory = directory,
        hovered_path = hovered_path,
    }
    history.index = #history.entries
    return true
end

---@param history DoraHistory
---@param directory string
---@param hovered_path? string
function M.update_current(history, directory, hovered_path)
    local current = M.current(history)
    if current and current.directory == directory then
        current.hovered_path = hovered_path
    end
end

-- Move one step through history, deleting invalid destinations along the way.
-- Deletions remain until traversal encounters them, so undo-trash has a chance
-- to restore a directory before it is discarded.
---@param history DoraHistory
---@param direction 1|-1
---@param is_valid fun(directory: string): boolean
---@return DoraHistoryEntry?
function M.traverse(history, direction, is_valid)
    assert(direction == -1 or direction == 1)
    while true do
        local target = history.index + direction
        if target < 1 or target > #history.entries then
            return nil
        end
        local entry = history.entries[target]
        if is_valid(entry.directory) then
            history.index = target
            return entry
        end
        table.remove(history.entries, target)
        if direction == -1 then
            -- Removing an entry before the current one shifts the current
            -- entry and its index left by one.
            history.index = history.index - 1
        end
    end
end

---@param path string
---@param old_path string
---@param new_path string
---@return string
local function rename_path(path, old_path, new_path)
    if path == old_path then
        return new_path
    end
    if vim.startswith(path, old_path .. '/') then
        return new_path .. path:sub(#old_path + 1)
    end
    return path
end

-- File moves matter too because an entry may hover the moved file.
---@param old_path string
---@param new_path string
function M.rename_subtree(old_path, new_path)
    for _, history in pairs(window_histories) do
        for _, entry in ipairs(history.entries) do
            entry.directory = rename_path(entry.directory, old_path, new_path)
            if entry.hovered_path then
                entry.hovered_path = rename_path(entry.hovered_path, old_path, new_path)
            end
        end
    end
end

return M
