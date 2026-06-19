local api = vim.api
local window = require'dora.window'

local M = {}

local NS = api.nvim_create_namespace('dora/prompt')

---@class DoraPromptOptions
---@field prompt? string
---@field initial_prompt? string
---@field cwd string
---@field width? integer
---@field anchor? DoraFloatAnchor
---@field icon? string Icon shown as virtual text before the input
---@field icon_hl? string
---@field validate fun(input: string): any

---@param opts DoraPromptOptions
---@return string?
local function icon_prefix(opts)
    return opts.icon and opts.icon .. ' ' or nil
end

---@param opts DoraPromptOptions
---@param width integer
---@return table
local function win_layout(opts, width)
    return window.layout({
        title = opts.prompt,
        width = width,
        height = 1,
        anchor = opts.anchor,
    })
end

---@class DoraPrompt
---@field opts DoraPromptOptions
---@field cb fun(input?: string, result?: any)
---@field origin_win integer
---@field width integer
---@field autocmds integer[]
---@field input_buf integer
---@field input_win integer
---@field closed? boolean
---@field is_valid? boolean
---@field valid_result? any
---@field initial_prompt string
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
    local hl
    if self:get_input() == self.initial_prompt then
        hl = 'DoraPromptBorder'
    else
        hl = ok and 'DoraPromptBorderValid' or 'DoraPromptBorderInvalid'
    end
    if window.valid_win(self.input_win) then
        vim.wo[self.input_win].winhighlight = 'NormalFloat:Normal,FloatBorder:' .. hl
    end
end

function Prompt:confirm()
    local input = self:get_input()
    if input == self.initial_prompt then
        self:close()
        return
    end
    self:validate()
    if not self.is_valid then
        return
    end
    self:close()
    self.cb(input, self.valid_result)
end

function Prompt:cancel()
    if self.closed then
        return
    end
    self:close()
    self.cb(nil)
end

function Prompt:relayout()
    if window.valid_win(self.input_win) then
        api.nvim_win_set_config(self.input_win, win_layout(self.opts, self.width))
        self:validate()
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

---@param opts DoraPromptOptions
---@param cb fun(input?: string, result?: any)
---@return DoraPrompt
function M.input(opts, cb)
    local self = setmetatable({
        opts = opts,
        cb = cb,
        origin_win = api.nvim_get_current_win(),
        width = opts.width or 64,
        autocmds = {},
    }, {__index = Prompt})

    self.initial_prompt = opts.initial_prompt or ''
    if #self.initial_prompt > 0 then
        self.width = math.max(self.width, #self.initial_prompt + 4)
    end
    local prefix = icon_prefix(opts)
    if prefix then
        self.width = self.width + vim.fn.strdisplaywidth(prefix)
    end
    self.input_buf = api.nvim_create_buf(false, true)
    vim.bo[self.input_buf].buftype = 'nofile'
    vim.bo[self.input_buf].bufhidden = 'wipe'

    self.input_win = api.nvim_open_win(self.input_buf, true, win_layout(opts, self.width))
    vim.wo[self.input_win].winhighlight = 'NormalFloat:Normal,FloatBorder:DoraPromptBorder'

    api.nvim_buf_set_lines(self.input_buf, 0, -1, false, {self.initial_prompt})
    if prefix then
        api.nvim_buf_set_extmark(self.input_buf, NS, 0, 0, {
            virt_text = {{prefix, opts.icon_hl or 'DoraIcon'}},
            virt_text_pos = 'inline',
            right_gravity = false,
        })
    end
    api.nvim_win_set_cursor(self.input_win, {1, #self.initial_prompt})

    keymap(self.input_buf, 'n', '<Esc>', function() self:cancel() end)
    keymap(self.input_buf, 'n', 'q',     function() self:cancel() end)
    keymap(self.input_buf, {'i', 'n'}, '<C-c>', function() self:cancel() end)
    keymap(self.input_buf, {'i', 'n'}, '<CR>', function() self:confirm() end)

    self.autocmds[#self.autocmds+1] = api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
        buffer = self.input_buf,
        callback = function() self:validate() end,
    })
    self.autocmds[#self.autocmds+1] = api.nvim_create_autocmd('VimResized', {
        callback = function() self:relayout() end,
    })
    self.autocmds[#self.autocmds+1] = api.nvim_create_autocmd('WinLeave', {
        buffer = self.input_buf,
        callback = function() self:cancel() end,
    })
    self.autocmds[#self.autocmds+1] = api.nvim_create_autocmd('WinClosed', {
        callback = function(args)
            if tonumber(args.match) == self.input_win then
                self:cancel()
            end
        end,
    })

    api.nvim_set_option_value('filetype', 'dora-prompt', {buf = self.input_buf})
    vim.cmd'startinsert!'
    return self
end

return M
