-- Small general-purpose helpers: notifications, the async-op progress
-- spinner, path display for messages, and the register-copy helper behind
-- the yank_* actions.
local M = {}

local api = vim.api
local uv = vim.uv

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

local SPINNER_FRAMES = {'⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'}

-- Shows an updating, non-blocking progress line on the command line while an
-- async operation runs, and returns a function that stops it and clears the
-- line. Each tick updates a single native progress-message (see
-- :help progress-message), so ext-UIs and |Progress| autocmd consumers see
-- one running task instead of a stream of echoes. A timer drives the
-- animation so the spinner keeps moving even while a single large file copies
-- (which produces no per-file progress callbacks); `message` is re-evaluated
-- on every tick so it can report live progress.
---@param message fun(): string
---@return fun(failed?: boolean) stop
function M.start_spinner(message)
    -- Nothing to render to without an attached UI (e.g. headless tests).
    local timer = #api.nvim_list_uis() > 0 and uv.new_timer()
    if not timer then
        return function() end
    end
    local frame = 1
    -- Reused across ticks; carrying the returned id forward makes every echo
    -- update the same progress-message rather than create a new one.
    local progress = {kind = 'progress', source = 'dora', title = 'dora', status = 'running'}
    -- timer:stop() halts future ticks but cannot cancel a render that the timer
    -- has already scheduled onto the main loop. A fast operation (e.g. a
    -- directory rename, which finishes before the first tick fires) would
    -- otherwise let that stale render repaint the line after we clear it.
    local stopped = false
    timer:start(0, 100, vim.schedule_wrap(function()
        if stopped then
            return
        end
        progress.id = api.nvim_echo({{('dora: %s %s'):format(SPINNER_FRAMES[frame], message())}}, false, progress)
        frame = frame % #SPINNER_FRAMES + 1
    end))
    return function(failed)
        stopped = true
        timer:stop()
        timer:close()
        -- No tick fired, so there is no progress-message to conclude.
        if progress.id then
            progress.status = failed and 'failed' or 'success'
            api.nvim_echo({{''}}, false, progress)
        end
    end
end

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
