if vim.g.loaded_dirtree then
    return
end
vim.g.loaded_dirtree = 1

vim.cmd 'hi default link DirtreeFile                Normal'
vim.cmd 'hi default link DirtreeDirectory           Directory'
vim.cmd 'hi default link DirtreeSymlink             Constant'
vim.cmd 'hi default link DirtreeExecutable          Function'
vim.cmd 'hi default link DirtreeTree                NonText'
vim.cmd 'hi default link DirtreeTreeActive          Directory'
vim.cmd 'hi default link DirtreeVirtText            NonText'
vim.cmd 'hi default link DirtreePromptBorder        NormalFloat'
vim.cmd 'hi default link DirtreePromptBorderValid   DiagnosticOk'
vim.cmd 'hi default link DirtreePromptBorderInvalid DiagnosticError'
vim.cmd 'hi default link DirtreeDeleteMore          NonText'
vim.cmd 'hi default link DirtreeDeleteCursor        Normal'
vim.cmd 'hi default link DirtreeSelectionSign       Special'
vim.cmd 'hi default link DirtreeCutSign             DiagnosticError'
vim.cmd 'hi default link DirtreeCopySign            DiagnosticOk'
vim.cmd 'hi default link DirtreeSelectionFile       Special'
vim.cmd 'hi default link DirtreeHelpHeader          Title'
vim.cmd 'hi default link DirtreeHelpKey             Label'
vim.cmd 'hi default link DirtreeHelpDesc            Special'
vim.cmd 'hi default link DirtreeKeymapHintArrow     NonText'
vim.cmd 'hi default link DirtreeInfoLabel           Label'
vim.cmd 'hi default link DirtreeInfoValue           Special'

vim.api.nvim_create_user_command('Dirtree', function(o)
    require'dirtree'.dirtree(o.args)
end, {bar=true, nargs='?', complete='dir'})

local function buf_has_var(buf, var_name)
    local ok, ret = pcall(vim.api.nvim_buf_get_var, buf, var_name)
    return ok and ret or false
end

-- Automatically open Dirtree when editing a directory
vim.api.nvim_create_autocmd('BufEnter', {
    group = vim.api.nvim_create_augroup('dirtree', {}),
    callback = function()
        local path = vim.fn.expand('%')
        if not buf_has_var(0, 'is_dirtree') and vim.fn.isdirectory(path) == 1 then
            require'dirtree'.dirtree('', true)
        end
    end,
})
