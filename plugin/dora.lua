-- Plugin entry point: defines the Dora highlight groups, the :Dora command,
-- and the auto-open autocmd for directory buffers. Requires no dora module
-- until a command or autocmd fires, keeping startup cost near zero.
if vim.g.loaded_dora then
    return
end
vim.g.loaded_dora = 1

local api = vim.api
local augroup = api.nvim_create_augroup('dora', {})

vim.cmd 'hi default link DoraFile                Normal'
vim.cmd 'hi default link DoraDirectory           Directory'
vim.cmd 'hi default link DoraSymlink             Constant'
vim.cmd 'hi default link DoraExecutable          Function'
vim.cmd 'hi default link DoraFifo                Type'
vim.cmd 'hi default link DoraSocket              PreProc'
vim.cmd 'hi default link DoraDevice              Type'
vim.cmd 'hi default link DoraTree                NonText'
vim.cmd 'hi default link DoraTreeActive          Directory'
vim.cmd 'hi default link DoraVirtText            NonText'
vim.cmd 'hi default link DoraIcon                Special'
vim.cmd 'hi default link DoraCut                 DiagnosticError'
vim.cmd 'hi default link DoraCopy                DiagnosticOk'
vim.cmd 'hi default link DoraWarn                DiagnosticWarn'
vim.cmd 'hi default link DoraError               DiagnosticError'
vim.cmd 'hi default link DoraFilterMatch         Special'
vim.cmd 'hi default link DoraFilterPath          Comment'
vim.cmd 'hi default link DoraPromptBorder        FloatBorder'
vim.cmd 'hi default link DoraPromptBorderValid   DoraPromptBorder'
vim.cmd 'hi default link DoraPromptBorderInvalid DoraPromptBorder'
vim.cmd 'hi default link DoraPromptBorderWarn    DoraPromptBorder'
vim.cmd 'hi default link DoraInfoLabel           Label'
vim.cmd 'hi default link DoraInfoValue           Special'
vim.cmd 'hi default link DoraHelpSection         Title'
vim.cmd 'hi default link DoraMutedText           NonText'
vim.cmd 'hi default link DoraKeymapHintMnemonic  Underlined'

local function setup_highlights()
    local function set_hl_foreground(name, fg_group)
        if api.nvim_get_hl(0, {name = name}).link == 'DoraPromptBorder' then
            local hl = api.nvim_get_hl(0, {name = fg_group, link = false})
            api.nvim_set_hl(0, name, {fg = hl.fg, update = true})
        end
    end
    set_hl_foreground('DoraPromptBorderValid', 'DiagnosticOk')
    set_hl_foreground('DoraPromptBorderInvalid', 'DiagnosticError')
    set_hl_foreground('DoraPromptBorderWarn', 'DiagnosticWarn')
    api.nvim_set_hl(0, 'DoraHiddenCursor', {blend = 100, default = true})
    api.nvim_set_hl(0, 'DoraBold', {bold = true, default = true})
    api.nvim_set_hl(0, 'DoraUnderline', {underline = true, default = true})
end

setup_highlights()

api.nvim_create_autocmd('ColorScheme', {
    group = augroup,
    callback = function() setup_highlights() end,
})

api.nvim_create_user_command('Dora', function(o)
    require'dora.api'.initialize(o.args ~= '' and vim.fn.expand(o.args) or '')
end, {bar=true, nargs='?', complete='dir'})

-- Duplicated from dora/buffer.lua so startup stays require-free.
local function buf_has_var(buf, var_name)
    local ok, ret = pcall(api.nvim_buf_get_var, buf, var_name)
    return ok and ret or false
end

-- Automatically open Dora when editing a directory
api.nvim_create_autocmd('BufEnter', {
    group = augroup,
    callback = function()
        local disable_auto_open = vim.g.dora_disable_auto_open
        if disable_auto_open and disable_auto_open ~= 0 then
            return
        end
        local path = vim.fn.expand('%')
        if vim.startswith(path, '~') then
            -- `:edit ~` names the buffer with a literal `~`, which
            -- isdirectory() does not expand.
            path = vim.fn.fnamemodify(path, ':p')
        end
        if not buf_has_var(0, 'is_dora') and vim.fn.isdirectory(path) == 1 then
            require'dora.api'.initialize(path, true)
        end
    end,
})
