-- Single-line floating input prompt (rename, add, symlink, shell command)
-- with live validation reflected in the border color.
local api = vim.api
local window = require'dora.ui.window'
local config = require'dora'.config
local util = require'dora.util'

local M = {}

local NS = api.nvim_create_namespace('dora/prompt')

---@class DoraPromptOptions
---@field prompt? string
---@field initial_prompt? string
---@field cwd string
---@field width? integer
---@field anchor? DoraFloatAnchor
---@field icon? string|fun(input: string): string?, string? Icon shown as virtual text before the input; a function receives the current input and is re-resolved as it changes, returning the icon and its highlight
---@field icon_hl? string Highlight for a string icon (function icons return their own)
---@field validate? fun(input: string): any When omitted, any input is accepted and the border keeps its normal color
---@field warn? fun(input: string, result: any): boolean? Called for valid, non-initial input; when it returns true the border uses the warn color instead of the valid color

---@param opts DoraPromptOptions
---@param input string
---@return string? icon
---@return string? hl
local function resolve_icon(opts, input)
    local icon = opts.icon
    if type(icon) == 'function' then
        return icon(input)
    end
    return icon, opts.icon_hl
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
---@field invalid_reason? string
---@field initial_prompt string
---@field icon_extmark? integer
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
    if not self.opts.validate then
        self.is_valid = true
        return
    end
    local ok, result = pcall(self.opts.validate, self:get_input())
    self.is_valid = ok
    self.valid_result = ok and result or nil
    -- Strip the "file:line: " prefix assert() adds to its message
    self.invalid_reason = not ok and (tostring(result):gsub('^.-:%d+: ', '')) or nil
    local hl
    if self:get_input() == self.initial_prompt then
        hl = 'DoraPromptBorder'
    elseif not ok then
        hl = 'DoraPromptBorderInvalid'
    elseif self.opts.warn and self.opts.warn(self:get_input(), result) then
        hl = 'DoraPromptBorderWarn'
    else
        hl = 'DoraPromptBorderValid'
    end
    if window.valid_win(self.input_win) then
        vim.wo[self.input_win].winhighlight = 'NormalFloat:Normal,FloatBorder:' .. hl
    end
end

function Prompt:update_icon()
    local icon, hl = resolve_icon(self.opts, self:get_input())
    if not icon then
        if self.icon_extmark then
            api.nvim_buf_del_extmark(self.input_buf, NS, self.icon_extmark)
            self.icon_extmark = nil
        end
        return
    end
    self.icon_extmark = api.nvim_buf_set_extmark(self.input_buf, NS, 0, 0, {
        id = self.icon_extmark,
        virt_text = {{icon .. ' ', hl or 'DoraIcon'}},
        virt_text_pos = 'inline',
        right_gravity = false,
    })
end

function Prompt:confirm()
    local input = self:get_input()
    if input == self.initial_prompt then
        self:close()
        return
    end
    self:validate()
    if not self.is_valid then
        util.err(self.invalid_reason or 'Invalid input')
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
    local initial_icon = resolve_icon(opts, self.initial_prompt)
    if initial_icon then
        self.width = self.width + vim.fn.strdisplaywidth(initial_icon .. ' ')
    end
    self.input_buf = api.nvim_create_buf(false, true)
    vim.bo[self.input_buf].buftype = 'nofile'
    vim.bo[self.input_buf].bufhidden = 'wipe'

    self.input_win = api.nvim_open_win(self.input_buf, true, win_layout(opts, self.width))
    vim.wo[self.input_win].winhighlight = 'NormalFloat:Normal,FloatBorder:DoraPromptBorder'

    api.nvim_buf_set_lines(self.input_buf, 0, -1, false, {self.initial_prompt})
    self:update_icon()
    api.nvim_win_set_cursor(self.input_win, {1, #self.initial_prompt})

    keymap(self.input_buf, 'n', '<Esc>', function() self:cancel() end)
    keymap(self.input_buf, 'n', 'q',     function() self:cancel() end)
    if config.prompt_insert_esc_closes then
        keymap(self.input_buf, 'i', '<Esc>', function() self:cancel() end)
    end
    keymap(self.input_buf, {'i', 'n'}, '<C-c>', function() self:cancel() end)
    keymap(self.input_buf, {'i', 'n'}, '<CR>', function() self:confirm() end)

    self.autocmds[#self.autocmds+1] = api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
        buffer = self.input_buf,
        callback = function()
            self:validate()
            if type(opts.icon) == 'function' then
                self:update_icon()
            end
        end,
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
