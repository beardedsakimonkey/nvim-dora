local util = require'dora.util'

local M = {}

---@class DoraBookmarks
---@field paths table<string, string>
---@field previous_directory? string

---@param previous_directory? string
---@return DoraBookmarks
function M.new(previous_directory)
    return {
        paths = {},
        previous_directory = previous_directory,
    }
end

---@return string?
local function read_key()
    local key = vim.fn.getcharstr()
    if key == '' or key == '\027' then
        return nil
    end
    return key
end

---@param key string
---@return boolean ok
---@return string? message
local function validate_user_key(key)
    if vim.fn.strchars(key) ~= 1 then
        return false, 'Bookmark key must be one character'
    end
    if key == "'" then
        return false, "Bookmark ' is reserved for the previous directory"
    end
    return true, nil
end

---@param bookmarks DoraBookmarks
---@param directory string
function M.record_previous_directory(bookmarks, directory)
    bookmarks.previous_directory = directory
end

---@param bookmarks DoraBookmarks
---@param directory string
function M.set_current_directory(bookmarks, directory)
    local key = read_key()
    if not key then
        return
    end
    local ok, message = validate_user_key(key)
    if not ok then
        util.err(message)
        return
    end
    bookmarks.paths[key] = directory
    util.info(('Set bookmark %s to %s'):format(key, util.display_path(directory)))
end

---@param bookmarks DoraBookmarks
---@return string?
function M.read_jump_directory(bookmarks)
    local key = read_key()
    if not key then
        return nil
    end
    if vim.fn.strchars(key) ~= 1 then
        util.err('Bookmark key must be one character')
        return nil
    end
    if key == "'" then
        if not bookmarks.previous_directory then
            util.err('No previous directory')
            return nil
        end
        return bookmarks.previous_directory
    end
    local directory = bookmarks.paths[key]
    if not directory then
        util.err(('No bookmark %s'):format(key))
        return nil
    end
    return directory
end

---@param bookmarks DoraBookmarks
---@return DoraHelpRow[]
function M.help_rows(bookmarks)
    local rows = {}
    if bookmarks.previous_directory then
        rows[#rows+1] = {
            lhs = "''",
            desc = 'Last directory: ' .. util.display_path(bookmarks.previous_directory),
        }
    end

    local keys = {}
    for key in pairs(bookmarks.paths) do
        keys[#keys+1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        rows[#rows+1] = {
            lhs = "'" .. key,
            desc = util.display_path(bookmarks.paths[key]),
        }
    end
    return rows
end

return M
