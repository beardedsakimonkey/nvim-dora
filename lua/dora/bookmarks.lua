local util = require'dora.util'

local M = {}

---@class DoraBookmark
---@field directory string
---@field hovered_path? string

---@type table<string, DoraBookmark>
local global_paths = {}

---@class DoraBookmarks
---@field paths table<string, DoraBookmark>
---@field previous_directory? DoraBookmark

---@param previous_directory? DoraBookmark
---@return DoraBookmarks
function M.new(previous_directory)
    return {
        paths = global_paths,
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
---@param hovered_path? string
function M.record_previous_directory(bookmarks, directory, hovered_path)
    bookmarks.previous_directory = {directory = directory, hovered_path = hovered_path}
end

---@param bookmarks DoraBookmarks
---@param directory string
---@param hovered_path? string
function M.set_current_directory(bookmarks, directory, hovered_path)
    local key = read_key()
    if not key then
        return
    end
    local ok, message = validate_user_key(key)
    if not ok then
        util.err(message)
        return
    end
    bookmarks.paths[key] = {directory = directory, hovered_path = hovered_path}
    util.info(('Set bookmark %s to %s'):format(key, util.display_path(directory)))
end

---@param bookmarks DoraBookmarks
---@param key string?
---@return string? directory
---@return string? hovered_path
function M.resolve_jump_directory(bookmarks, key)
    if not key or key == '\027' then
        return nil
    end
    if vim.fn.strchars(key) ~= 1 then
        util.err('Bookmark key must be one character')
        return nil
    end
    if key == "'" then
        local previous = bookmarks.previous_directory
        if not previous then
            util.err('No previous directory')
            return nil
        end
        return previous.directory, previous.hovered_path
    end
    local bookmark = bookmarks.paths[key]
    if not bookmark then
        util.err(('No bookmark %s'):format(key))
        return nil
    end
    return bookmark.directory, bookmark.hovered_path
end

---@param bookmarks DoraBookmarks
---@return string? directory
---@return string? hovered_path
function M.read_jump_directory(bookmarks)
    return M.resolve_jump_directory(bookmarks, read_key())
end

---@param bookmarks DoraBookmarks
---@return DoraHelpRow[]
function M.help_rows(bookmarks)
    local rows = {{
        lhs = "''",
        desc = 'Jump to previous directory',
    }}

    local keys = {}
    for key in pairs(bookmarks.paths) do
        keys[#keys+1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        rows[#rows+1] = {
            lhs = "'" .. key,
            desc = util.display_path(bookmarks.paths[key].directory),
        }
    end
    return rows
end

return M
