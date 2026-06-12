local file = assert(vim.env.DORA_TEST_FILE, 'DORA_TEST_FILE is not set')
local ok, err = xpcall(function()
    dofile(file)
end, debug.traceback)

if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd.cquit()
end
