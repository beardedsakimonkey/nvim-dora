-- The filter input float pinned to the top of a dora window; reports edits,
-- confirm, and cancel back to the filter action through callbacks.
local window = require'dora.ui.window'

local api = vim.api

local M = {}

local FILTER_WIDTH = 32
local FILTER_PREFIX = 'Filter›'
local FILTER_PREFIX_INVERTED = 'Filter!›'
-- Leading space puts a gap between the prompt's `›` and the hint.
local INVERT_PLACEHOLDER = ' <c-i> to invert'

---@class DoraFilterWindowOptions
---@field origin_win integer
---@field initial_text string
---@field inverted boolean
---@field on_change fun(text: string)
---@field on_toggle_invert fun(inverted: boolean)
---@field on_confirm fun(text: string): boolean
---@field on_cancel fun(): string?
---@field on_close fun()

---@class DoraFilterWindow
---@field opts DoraFilterWindowOptions
---@field buf integer
---@field win integer
---@field ns integer
---@field inverted boolean
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
    -- Span the full width of the origin (dora) window so the prompt always
    -- matches it, including after a resize (driven by the WinResized autocmd).
    -- Falls back to FILTER_WIDTH only when the origin window is gone.
    local width = FILTER_WIDTH
    if window.valid_win(self.opts.origin_win) then
        width = api.nvim_win_get_width(self.opts.origin_win)
    end
    return {
        relative = 'win',
        win = self.opts.origin_win,
        anchor = 'NW',
        row = 0,
        col = 0,
        width = math.max(1, width),
        height = 1,
        border = 'none',
        style = 'minimal',
        noautocmd = true,
    }
end

function FilterWindow:render_prefix()
    if not window.valid_buf(self.buf) then
        return
    end
    api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
    local prefix = self.inverted and FILTER_PREFIX_INVERTED or FILTER_PREFIX
    api.nvim_buf_set_extmark(self.buf, self.ns, 0, 0, {
        virt_text = {{prefix, 'DoraInfoLabel'}},
        virt_text_pos = 'inline',
        right_gravity = false,
    })
    -- While the input is empty, show a placeholder hint as ghost text after the
    -- cursor (right_gravity keeps it to the right of the prompt and the caret).
    if self:get_input() == '' then
        api.nvim_buf_set_extmark(self.buf, self.ns, 0, 0, {
            virt_text = {{INVERT_PLACEHOLDER, 'DoraMutedText'}},
            virt_text_pos = 'inline',
            right_gravity = true,
        })
    end
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
    self:render_prefix()
    if window.valid_win(self.win) then
        api.nvim_win_set_cursor(self.win, {1, col or #text})
    end
    self.opts.on_change(text)
end

---@param text string
function FilterWindow:set_display(text)
    if not window.valid_buf(self.buf) then
        return
    end
    vim.bo[self.buf].modifiable = true
    api.nvim_buf_set_lines(self.buf, 0, -1, false, {text})
    self:render_prefix()
end

function FilterWindow:toggle_invert()
    if self.closed then
        return
    end
    self.inverted = not self.inverted
    self:render_prefix()
    self.opts.on_toggle_invert(self.inverted)
end

function FilterWindow:relayout()
    if window.valid_win(self.win) and window.valid_win(self.opts.origin_win) then
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

function FilterWindow:lock()
    vim.cmd'stopinsert'
    vim.bo[self.buf].modifiable = false
    if window.valid_win(self.opts.origin_win) then
        pcall(api.nvim_set_current_win, self.opts.origin_win)
    end
end

---@param opts DoraFilterWindowOptions
function FilterWindow:edit(opts)
    self.opts = opts
    self.inverted = opts.inverted
    self:set_display(opts.initial_text)
    self:focus()
end

function FilterWindow:confirm()
    local input = self:get_input()
    self:lock()
    if self.opts.on_confirm(input) then
        self:set_display(input)
        vim.bo[self.buf].modifiable = false
    else
        self:close()
    end
end

function FilterWindow:cancel()
    self:lock()
    local locked_text = self.opts.on_cancel()
    if locked_text then
        self:set_display(locked_text)
        vim.bo[self.buf].modifiable = false
    else
        self:close()
    end
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
        inverted = opts.inverted,
        autocmds = {},
        closed = false,
    }, {__index = FilterWindow})

    self.buf = api.nvim_create_buf(false, true)
    self.ns = api.nvim_create_namespace('dora/filter.' .. self.buf)
    vim.bo[self.buf].buftype = 'nofile'
    vim.bo[self.buf].bufhidden = 'wipe'
    self.win = api.nvim_open_win(self.buf, true, self:layout())
    vim.wo[self.win].winhighlight = 'NormalFloat:Normal'
    vim.wo[self.win].cursorline = false

    keymap(self.buf, {'i', 'n'}, '<CR>', function() self:confirm() end)
    keymap(self.buf, {'i', 'n'}, '<Esc>', function() self:cancel() end)
    keymap(self.buf, {'i', 'n'}, '<C-c>', function() self:cancel() end)
    keymap(self.buf, {'i', 'n'}, '<C-i>', function() self:toggle_invert() end)
    -- Readline-style caret motion: insert-mode <C-a>/<C-e> aren't line motions by
    -- default (<C-a> reinserts text, <C-e> copies the char below), so map them to
    -- jump to the start/end of the input like a shell prompt.
    keymap(self.buf, 'i', '<C-a>', function()
        if window.valid_win(self.win) then
            api.nvim_win_set_cursor(self.win, {1, 0})
        end
    end)
    keymap(self.buf, 'i', '<C-e>', function()
        if window.valid_win(self.win) then
            api.nvim_win_set_cursor(self.win, {1, #self:get_input()})
        end
    end)

    self.autocmds[#self.autocmds+1] = api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
        buffer = self.buf,
        callback = function()
            if not self.closed then
                -- Refresh so the empty-state placeholder appears/disappears.
                self:render_prefix()
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
            if self.closed then
                return
            end
            local closed_win = tonumber(args.match)
            -- The filter float is anchored to (and meaningless without) the
            -- origin window, so tear it down whether the float itself or its
            -- origin window — e.g. `:q`ing dora — is what closed.
            if closed_win ~= self.win and closed_win ~= self.opts.origin_win then
                return
            end
            self.closed = true
            self:clear_autocmds()
            vim.schedule(function()
                -- A no-op when the float is what closed; closes the orphaned
                -- float when the origin window closed out from under it.
                window.close(self.buf, self.win)
                self.opts.on_close()
            end)
        end,
    })

    self:edit(opts)
    return self
end

return M
