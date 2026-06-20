local M = {}

local api = vim.api

---@param buf integer
---@param var_name string
---@return any
local function buf_has_var(buf, var_name)
    local ok, ret = pcall(api.nvim_buf_get_var, buf, var_name)
    return ok and ret or false
end

---@param cwd string
---@return string
local function create_buf_name(cwd)
    local loaded_bufs = {}
    for _, buf in ipairs(vim.fn.getbufinfo()) do
        -- Don't filter out hidden buffers; that leads to occasional errors.
        if buf.loaded == 1 then
            table.insert(loaded_bufs, buf.name)
        end
    end
    local new_name = cwd
    local i = 0
    while vim.tbl_contains(loaded_bufs, new_name) do
        i = i + 1
        new_name = cwd .. ' ' .. i
    end
    return new_name
end

---@param cwd string
---@return integer buf
function M.create_buf(cwd)
    local existing_buf = vim.fn.bufnr('^' .. cwd .. '$')
    local buf
    if existing_buf ~= -1 then
        if buf_has_var(existing_buf, 'is_dora') then
            if #vim.fn.win_findbuf(existing_buf) > 0 then
                -- A live dora session is already showing this path in another
                -- window. Give the new buffer a unique (but not `:cd`able) name
                -- so the two windows stay isolated.
                buf = api.nvim_create_buf(false, true)
                api.nvim_buf_set_name(buf, create_buf_name(cwd))
            else
                -- The existing dora buffer is an orphan left behind by a closed
                -- session (e.g. its window was `:q`d, which hides rather than
                -- deletes the buffer). Wipe it so the new session can take the
                -- clean, `:cd`able name instead of a needlessly id'd one. The
                -- wipe fires BufWipeout, which tears down the stale session.
                pcall(api.nvim_buf_delete, existing_buf, {force=true})
                buf = api.nvim_create_buf(false, true)
                api.nvim_buf_set_name(buf, cwd)
            end
        else
            -- If buffer exists and it's not a dora buffer, reuse it. This can
            -- happen when launching nvim with a directory arg.
            buf = existing_buf
            -- Canonicalize the buffer name when launching nvim with a directory
            -- arg.
            if api.nvim_get_current_buf() == existing_buf then
                vim.cmd('sil file ' .. vim.fn.fnameescape(cwd))
            end
        end
    else
        -- Buffer doesn't exist yet, so create it
        buf = api.nvim_create_buf(false, true)
        api.nvim_buf_set_name(buf, cwd)
    end
    assert(buf ~= 0)
    api.nvim_buf_set_var(buf, 'is_dora', true)
    -- Triggers BufEnter
    api.nvim_set_current_buf(buf)
    -- Triggers ftplugin, so must get called after setting the current buffer
    api.nvim_set_option_value('filetype', 'dora', {buf = buf})
    return buf
end

---@param name string
function M.delete_buffers(name)
    for _, buf in pairs(vim.fn.getbufinfo()) do
        if buf.name == name then
            pcall(api.nvim_buf_delete, buf.bufnr, {})
        end
    end
end

---@param cwd string
function M.update_buf_name(cwd)
    local old_name = vim.fn.bufname()
    local new_name = create_buf_name(cwd)
    vim.cmd('sil keepalt file ' .. vim.fn.fnameescape(new_name))
    -- Renaming a buffer creates a new buffer with the old name. Delete it.
    M.delete_buffers(old_name)
end

---@param buf integer
function M.set_current_buf(buf)
    if vim.fn.bufexists(buf) ~= 0 then
        vim.cmd('sil! keepj buffer' .. buf)
    end
end

---@param buf integer
---@param lines string[]
function M.set_lines(buf, lines)
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

---@param old_name string
---@param new_name string
function M.rename_buffers(old_name, new_name)
    -- If we're clobbering an existing file for which we have a buffer, delete
    -- the buffer first
    if vim.fn.bufexists(new_name) ~= 0 then
        M.delete_buffers(new_name)
    end
    for _, buf in pairs(vim.fn.getbufinfo()) do
        if buf.name == old_name then
            api.nvim_buf_set_name(buf.bufnr, new_name)
            api.nvim_buf_call(buf.bufnr, function() vim.cmd 'sil! w!' end)
        end
    end
end

---@param path string
---@return string
function M.display_path(path)
    local home = os.getenv'HOME'
    if home and home ~= '' and (path == home or vim.startswith(path, home .. '/')) then
        return '~' .. path:sub(#home + 1)
    end
    return path
end

---@param msg any
function M.err(msg)  vim.notify('dora: ' .. msg, vim.log.levels.ERROR) end
---@param msg any
function M.warn(msg) vim.notify('dora: ' .. msg, vim.log.levels.WARN) end
---@param msg any
function M.info(msg) vim.notify('dora: ' .. msg, vim.log.levels.INFO) end

---@class DoraYankRange
---@field line integer
---@field start_col integer

---@param value string
---@param reg? string
---@param message string
---@param range? DoraYankRange
function M.copy_value(value, reg, message, range)
    -- Trigger a real yank so TextYankPost autocmds see vim.v.event.
    if range then
        local win = api.nvim_get_current_win()
        local cursor = api.nvim_win_get_cursor(win)
        local last_char = vim.fn.byteidx(value, vim.fn.strchars(value) - 1)
        local ok, err = pcall(function()
            api.nvim_win_set_cursor(win, {range.line, range.start_col})
            vim.cmd'normal! v'
            api.nvim_win_set_cursor(win, {range.line, range.start_col + last_char})
            vim.cmd(reg == '+' and [[normal! "+y]] or [[normal! y]])
        end)
        pcall(api.nvim_win_set_cursor, win, cursor)
        if not ok then
            M.err(err)
            return
        end
    else
        pcall(vim.cmd --[[@as function]], reg == '+' and [[normal! "+yy]] or [[normal! yy]])
    end

    local ok, err = pcall(vim.fn.setreg, reg or '"', value, 'c')
    if not ok then
        M.err(err)
        return
    end
    M.info(('%s: %s'):format(message, value))
end

---@param str string
---@return string
function M.trim_start(str)
    return (str:gsub('^%s*', ''))
end

return M
