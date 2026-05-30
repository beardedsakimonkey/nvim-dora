local api = vim.api
local window = require'dirtree.window'

local M = {}

---@class DirtreePromptOptions
---@field prompt? string
---@field cwd string
---@field default? string
---@field width? integer
---@field anchor? {win: integer, line: integer, col: integer}
---@field validate fun(input: string): any

---@param opts DirtreePromptOptions
---@param width integer
---@return table
local function win_layout(opts, width)
    local layout_opts = {
        title = opts.prompt,
        width = width,
        height = 1,
        border_hl = 'DirtreePromptBorder',
    }
    if opts.anchor then
        return window.anchored_layout(vim.tbl_extend('force', layout_opts, opts.anchor))
    end
    return window.centered_layout(layout_opts)
end

---@class DirtreePrompt
---@field opts DirtreePromptOptions
---@field cb fun(input?: string, result?: any)
---@field origin_win integer
---@field width integer
---@field autocmds integer[]
---@field input_buf integer
---@field input_win integer
---@field closed? boolean
---@field is_valid? boolean
---@field valid_result? any
local Prompt = {}

function Prompt:close()
    if self.closed then
        return
    end
    self.closed = true
    for _, au in ipairs(self.autocmds) do
        pcall(api.nvim_del_autocmd, au)
    end
    window.close(self.input_buf, self.input_win)
    if window.valid_win(self.origin_win) then
        pcall(api.nvim_set_current_win, self.origin_win)
    end
    vim.cmd'stopinsert'
end

---@return string
function Prompt:get_input()
    return api.nvim_buf_get_lines(self.input_buf, 0, 1, false)[1] or ''
end

---@param input string
---@param col integer
function Prompt:set_input(input, col)
    api.nvim_buf_set_lines(self.input_buf, 0, 1, false, {input})
    api.nvim_win_set_cursor(self.input_win, {1, col})
end

function Prompt:validate()
    local ok, result = pcall(self.opts.validate, self:get_input())
    self.is_valid = ok
    self.valid_result = ok and result or nil
    local hl = ok and 'DirtreePromptBorderValid' or 'DirtreePromptBorderInvalid'
    if window.valid_win(self.input_win) then
        local cfg = api.nvim_win_get_config(self.input_win)
        cfg.border = window.border(hl)
        api.nvim_win_set_config(self.input_win, cfg)
    end
end

function Prompt:redraw()
    self:validate()
end

function Prompt:confirm()
    self:validate()
    if not self.is_valid then
        return
    end
    local input = self:get_input()
    self:close()
    self.cb(input, self.valid_result)
end

function Prompt:cancel()
    self:close()
    self.cb(nil)
end

function Prompt:escape_insert()
    if self:get_input() == '' then
        self:cancel()
        return
    end
    vim.cmd'stopinsert'
end

function Prompt:escape_insert_keys()
    vim.schedule(function()
        if not self.closed and window.valid_buf(self.input_buf) and self:get_input() == '' then
            self:cancel()
        end
    end)
    return '<C-\\><C-n>'
end

function Prompt:relayout()
    if window.valid_win(self.input_win) then
        api.nvim_win_set_config(self.input_win, win_layout(self.opts, self.width))
        self:redraw()
    end
end

---@param buf integer
---@param mode string|string[]
---@param lhs string
---@param rhs string|function
---@param opts? table
local function keymap(buf, mode, lhs, rhs, opts)
    opts = vim.tbl_extend('force', {buffer = buf, silent = true, nowait = true}, opts or {})
    vim.keymap.set(mode, lhs, rhs, opts)
end

---@param opts DirtreePromptOptions
---@param cb fun(input?: string, result?: any)
---@return DirtreePrompt
function M.input(opts, cb)
    local self = setmetatable({
        opts = opts,
        cb = cb,
        origin_win = api.nvim_get_current_win(),
        width = opts.width or 64,
        autocmds = {},
    }, {__index = Prompt})

    self.input_buf = api.nvim_create_buf(false, true)
    vim.bo[self.input_buf].buftype = 'nofile'
    vim.bo[self.input_buf].bufhidden = 'wipe'

    self.input_win = api.nvim_open_win(self.input_buf, true, win_layout(opts, self.width))
    vim.wo[self.input_win].winhighlight = 'NormalFloat:Normal,FloatBorder:DirtreePromptBorder'

    api.nvim_buf_set_lines(self.input_buf, 0, -1, false, {opts.default or ''})
    api.nvim_win_set_cursor(self.input_win, {1, #(opts.default or '')})

    keymap(self.input_buf, 'i', '<Esc>', function() return self:escape_insert_keys() end, {expr = true, replace_keycodes = true})
    keymap(self.input_buf, 'n', '<Esc>', function() self:cancel() end)
    keymap(self.input_buf, 'n', 'q', function() self:cancel() end)
    keymap(self.input_buf, {'i', 'n'}, '<C-c>', function() self:cancel() end)
    keymap(self.input_buf, {'i', 'n'}, '<CR>', function() self:confirm() end)

    self.autocmds[#self.autocmds+1] = api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
        buffer = self.input_buf,
        callback = function() self:redraw() end,
    })
    self.autocmds[#self.autocmds+1] = api.nvim_create_autocmd('VimResized', {
        callback = function() self:relayout() end,
    })
    self.autocmds[#self.autocmds+1] = api.nvim_create_autocmd('WinClosed', {
        callback = function(args)
            if tonumber(args.match) == self.input_win then
                self:cancel()
            end
        end,
    })

    self:redraw()
    vim.cmd'startinsert!'
    return self
end

return M
