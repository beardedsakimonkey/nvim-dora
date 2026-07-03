-- Small general-purpose helpers: notifications, path display for messages,
-- and the register-copy helper behind the yank_* actions.
local M = {}

local api = vim.api

---@param path string
---@return string
function M.display_path(path)
    local home = os.getenv'HOME'
    if home and home ~= '' and (path == home or vim.startswith(path, home .. '/')) then
        return '~' .. path:sub(#home + 1)
    end
    return path
end

---@param msg any
function M.err(msg)  vim.notify('dora: ' .. msg, vim.log.levels.ERROR) end
---@param msg any
function M.warn(msg) vim.notify('dora: ' .. msg, vim.log.levels.WARN) end
---@param msg any
function M.info(msg) vim.notify('dora: ' .. msg, vim.log.levels.INFO) end

---@class DoraYankRange
---@field line integer
---@field start_col integer

---@param value string
---@param reg? string
---@param message string
---@param range? DoraYankRange
function M.copy_value(value, reg, message, range)
    -- Trigger a real yank so TextYankPost autocmds see vim.v.event.
    if range then
        local win = api.nvim_get_current_win()
        local cursor = api.nvim_win_get_cursor(win)
        local last_char = vim.fn.byteidx(value, vim.fn.strchars(value) - 1)
        local ok, err = pcall(function()
            api.nvim_win_set_cursor(win, {range.line, range.start_col})
            vim.cmd'normal! v'
            api.nvim_win_set_cursor(win, {range.line, range.start_col + last_char})
            vim.cmd(reg == '+' and [[normal! "+y]] or [[normal! y]])
        end)
        pcall(api.nvim_win_set_cursor, win, cursor)
        if not ok then
            M.err(err)
            return
        end
    else
        pcall(vim.cmd --[[@as function]], reg == '+' and [[normal! "+yy]] or [[normal! yy]])
    end

    local ok, err = pcall(vim.fn.setreg, reg or '"', value, 'c')
    if not ok then
        M.err(err)
        return
    end
    M.info(('%s: %s'):format(message, value))
end

---@param str string
---@return string
function M.trim_start(str)
    return (str:gsub('^%s*', ''))
end

return M
