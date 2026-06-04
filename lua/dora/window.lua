local api = vim.api

local M = {}

---@param win integer?
---@return boolean
function M.valid_win(win)
    return win ~= nil and api.nvim_win_is_valid(win)
end

---@param buf integer?
---@return boolean
function M.valid_buf(buf)
    return buf ~= nil and api.nvim_buf_is_valid(buf)
end

---@return string?
function M.border()
    return vim.o.winborder == '' and 'rounded' or nil
end

---@class DoraFloatLayoutOptions
---@field title? string
---@field title_pos? 'left'|'center'|'right'
---@field width integer
---@field height integer
---@field min_width? integer

---@class DoraAnchoredFloatLayoutOptions: DoraFloatLayoutOptions
---@field win integer
---@field line integer
---@field col integer

---@param opts DoraFloatLayoutOptions
---@return table
---Returns a config for vim.api.nvim_win_set_config()
function M.centered_layout(opts)
    local width = math.min(opts.width, math.max(opts.min_width or 20, vim.o.columns - 4))
    local height = math.min(opts.height, math.max(1, vim.o.lines - 4))
    local title = opts.title and (' ' .. opts.title .. ' ') or nil
    return {
        relative = 'editor',
        anchor = 'NW',
        row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
        col = math.floor((vim.o.columns - width) / 2),
        width = width,
        height = height,
        border = M.border(),
        title = title,
        title_pos = title and (opts.title_pos or 'left') or nil,
        style = 'minimal',
        noautocmd = true,
    }
end

---@param opts DoraAnchoredFloatLayoutOptions
---@return table
---Anchored to cursor
function M.anchored_layout(opts)
    if not M.valid_win(opts.win) then
        return M.centered_layout(opts)
    end
    local pos = vim.fn.screenpos(opts.win, opts.line, opts.col + 1)
    if pos.row == 0 or pos.col == 0 then
        return M.centered_layout(opts)
    end
    local anchor_col = math.max(0, pos.col - 1)
    local width = math.min(opts.width, math.max(opts.min_width or 20, vim.o.columns - 2))
    local col = math.min(anchor_col, math.max(0, vim.o.columns - width - 2))
    local height = math.min(opts.height, math.max(1, vim.o.lines - 4))
    local title = opts.title and (' ' .. opts.title .. ' ') or nil
    return {
        relative = 'editor',
        anchor = 'NW',
        row = math.max(0, pos.row),
        col = col,
        width = width,
        height = height,
        border = M.border(),
        title = title,
        title_pos = title and (opts.title_pos or 'left') or nil,
        style = 'minimal',
        noautocmd = true,
    }
end

---@param buf integer?
---@param win integer?
function M.close(buf, win)
    if M.valid_win(win) then
        pcall(api.nvim_win_close, win, true)
    end
    if M.valid_buf(buf) then
        pcall(api.nvim_buf_delete, buf, {force = true})
    end
end

return M
