local window = require'dora.window'

local api = vim.api

local M = {}

local FILTER_WIDTH = 32

---@class DoraFilterWindowOptions
---@field origin_win integer
---@field initial_text string
---@field on_change fun(text: string)
---@field on_confirm fun(text: string)
---@field on_cancel fun()
---@field on_close fun()

---@class DoraFilterWindow
---@field opts DoraFilterWindowOptions
---@field buf integer
---@field win integer
---@field autocmds integer[]
---@field closed boolean
local FilterWindow = {}

function FilterWindow:clear_autocmds()
    for _, autocmd in ipairs(self.autocmds) do
        pcall(api.nvim_del_autocmd, autocmd)
    end
    self.autocmds = {}
end

---@return table
function FilterWindow:layout()
    return window.top_center_layout({
        win = self.opts.origin_win,
        title = 'Filter',
        width = FILTER_WIDTH,
        height = 1,
    })
end

---@return string
function FilterWindow:get_input()
    if not window.valid_buf(self.buf) then
        return ''
    end
    return api.nvim_buf_get_lines(self.buf, 0, 1, false)[1] or ''
end

---@param text string
---@param col? integer
function FilterWindow:set_input(text, col)
    if not window.valid_buf(self.buf) then
        return
    end
    vim.bo[self.buf].modifiable = true
    api.nvim_buf_set_lines(self.buf, 0, -1, false, {text})
    if window.valid_win(self.win) then
        api.nvim_win_set_cursor(self.win, {1, col or #text})
    end
    self.opts.on_change(text)
end

function FilterWindow:relayout()
    if window.valid_win(self.win) then
        api.nvim_win_set_config(self.win, self:layout())
    end
end

function FilterWindow:focus()
    if self.closed or not window.valid_win(self.win) then
        return
    end
    vim.bo[self.buf].modifiable = true
    api.nvim_set_current_win(self.win)
    api.nvim_win_set_cursor(self.win, {1, #self:get_input()})
    vim.cmd'startinsert!'
end

function FilterWindow:confirm()
    local input = self:get_input()
    self:close()
    self.opts.on_confirm(input)
end

function FilterWindow:cancel()
    self:close()
    self.opts.on_cancel()
end

function FilterWindow:close()
    if self.closed then
        return
    end
    self.closed = true
    self:clear_autocmds()
    vim.cmd'stopinsert'
    if window.valid_win(self.opts.origin_win) then
        pcall(api.nvim_set_current_win, self.opts.origin_win)
    end
    window.close(self.buf, self.win)
end

---@param buf integer
---@param mode string|string[]
---@param lhs string
---@param rhs function
local function keymap(buf, mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, {buffer = buf, silent = true, nowait = true})
end

---@param opts DoraFilterWindowOptions
---@return DoraFilterWindow
function M.open(opts)
    local self = setmetatable({
        opts = opts,
        autocmds = {},
        closed = false,
    }, {__index = FilterWindow})

    self.buf = api.nvim_create_buf(false, true)
    vim.bo[self.buf].buftype = 'nofile'
    vim.bo[self.buf].bufhidden = 'wipe'
    self.win = api.nvim_open_win(self.buf, true, self:layout())
    vim.wo[self.win].winhighlight = 'NormalFloat:Normal,FloatBorder:DoraPromptBorder'
    vim.wo[self.win].cursorline = false

    keymap(self.buf, {'i', 'n'}, '<CR>', function() self:confirm() end)
    keymap(self.buf, {'i', 'n'}, '<Esc>', function() self:cancel() end)
    keymap(self.buf, {'i', 'n'}, '<C-c>', function() self:cancel() end)

    self.autocmds[#self.autocmds+1] = api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
        buffer = self.buf,
        callback = function()
            if not self.closed then
                self.opts.on_change(self:get_input())
            end
        end,
    })
    self.autocmds[#self.autocmds+1] = api.nvim_create_autocmd({'VimResized', 'WinResized'}, {
        callback = function()
            if not self.closed then
                self:relayout()
            end
        end,
    })
    self.autocmds[#self.autocmds+1] = api.nvim_create_autocmd('WinClosed', {
        callback = function(args)
            if not self.closed and tonumber(args.match) == self.win then
                self.closed = true
                self:clear_autocmds()
                vim.schedule(self.opts.on_close)
            end
        end,
    })

    self:set_input(opts.initial_text)
    self:focus()
    return self
end

return M
