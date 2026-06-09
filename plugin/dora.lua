if vim.g.loaded_dora then
    return
end
vim.g.loaded_dora = 1

vim.cmd 'hi default link DoraFile                Normal'
vim.cmd 'hi default link DoraDirectory           Directory'
vim.cmd 'hi default link DoraSymlink             Constant'
vim.cmd 'hi default link DoraExecutable          Function'
vim.cmd 'hi default link DoraTree                NonText'
vim.cmd 'hi default link DoraTreeActive          Directory'
vim.cmd 'hi default link DoraVirtText            NonText'
vim.cmd 'hi default link DoraIcon                Special'
vim.cmd 'hi default link DoraCut                 DiagnosticError'
vim.cmd 'hi default link DoraCopy                DiagnosticOk'
vim.cmd 'hi default link DoraFilterMatch         Special'
vim.cmd 'hi default link DoraFilterPath          Comment'
vim.cmd 'hi default link DoraPromptBorder        FloatBorder'
vim.cmd 'hi default link DoraPromptBorderValid   DiagnosticOk'
vim.cmd 'hi default link DoraPromptBorderInvalid DiagnosticError'
vim.cmd 'hi default link DoraInfoLabel           Label'
vim.cmd 'hi default link DoraInfoValue           Special'
vim.cmd 'hi default link DoraHelpSection         Title'
vim.cmd 'hi default link DoraDeleteMore          NonText'
vim.cmd 'hi default link DoraKeymapHintArrow     NonText'

vim.api.nvim_create_user_command('Dora', function(o)
    require'dora.core'.initialize(o.args)
end, {bar=true, nargs='?', complete='dir'})

local function buf_has_var(buf, var_name)
    local ok, ret = pcall(vim.api.nvim_buf_get_var, buf, var_name)
    return ok and ret or false
end

-- Automatically open Dora when editing a directory
vim.api.nvim_create_autocmd('BufEnter', {
    group = vim.api.nvim_create_augroup('dora', {}),
    callback = function()
        local path = vim.fn.expand('%')
        if not buf_has_var(0, 'is_dora') and vim.fn.isdirectory(path) == 1 then
            require'dora.core'.initialize('', true)
        end
    end,
})
