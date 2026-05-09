local api = vim.api
local uv = vim.loop

local window = require'dirtree.window'
local fs = require'dirtree.fs'
local util = require'dirtree.util'

local M = {}

local MAX_DELETE_PATHS = 10
local MAX_DELETE_WIDTH = 96
local LINE_PREFIX = ' '
local LINE_PREFIX_LEN = #LINE_PREFIX
local RIGHT_PADDING = 1
local ELLIPSIS = '…'
local ELLIPSIS_WIDTH = vim.fn.strdisplaywidth(ELLIPSIS)

---@class DirtreeDeleteConfirmItem
---@field display string
---@field file_start_col integer
---@field file_end_col integer
---@field file_hl string
---@field directory_suffix_col? integer

---@param path string
---@return string
local function file_hl(path)
    if uv.fs_readlink(path) then
        return 'DirtreeSymlink'
    end
    local stat = uv.fs_stat(path)
    if stat and stat.type == 'directory' then
        return 'DirtreeDirectory'
    end
    if uv.fs_access(path, 'X') then
        return 'DirtreeExecutable'
    end
    return 'DirtreeFile'
end

---@param path string
---@param cwd string
---@return string
local function relative_display_path(path, cwd)
    if cwd == util.sep and vim.startswith(path, util.sep) then
        return path:sub(2)
    end
    local cwd_prefix = cwd .. util.sep
    if vim.startswith(path, cwd_prefix) then
        return path:sub(#cwd_prefix + 1)
    end
    return util.display_path(path)
end

---@return integer
local function max_display_width()
    local float_width = math.min(MAX_DELETE_WIDTH, math.max(20, vim.o.columns - 4))
    return math.max(0, float_width - LINE_PREFIX_LEN - RIGHT_PADDING)
end

---@param display string
---@param basename string
---@param max_width integer
---@return string display
---@return integer file_start_col
local function truncate_display_path(display, basename, max_width)
    if #display <= max_width then
        return display, math.max(0, #display - #basename)
    end
    if max_width <= ELLIPSIS_WIDTH then
        return display:sub(#display - max_width + 1), 0
    end
    local suffix_len = max_width - ELLIPSIS_WIDTH
    if #basename <= suffix_len then
        local truncated = ELLIPSIS .. display:sub(#display - suffix_len + 1)
        return truncated, math.max(0, #truncated - #basename)
    end
    local truncated = ELLIPSIS .. basename:sub(#basename - suffix_len + 1)
    return truncated, #ELLIPSIS
end

---@param path string
---@param cwd string
---@param max_width integer
---@return DirtreeDeleteConfirmItem
local function item(path, cwd, max_width)
    local display = relative_display_path(path, cwd)
    local basename = fs.basename(path)
    local directory_suffix_col
    local hl = file_hl(path)
    if hl == 'DirtreeDirectory' then
        max_width = max_width - #util.sep
    end
    local file_start_col
    display, file_start_col = truncate_display_path(display, basename, max_width)
    if hl == 'DirtreeDirectory' then
        directory_suffix_col = #display
        display = display .. util.sep
    end
    return {
        display = display,
        file_start_col = file_start_col,
        file_end_col = directory_suffix_col or #display,
        file_hl = hl,
        directory_suffix_col = directory_suffix_col,
    }
end

---@param paths string[]
---@param cwd string
---@param max_width integer
---@return DirtreeDeleteConfirmItem[]
local function items(paths, cwd, max_width)
    local ret = {}
    for i = 1, math.min(#paths, MAX_DELETE_PATHS) do
        ret[#ret+1] = item(paths[i], cwd, max_width)
    end
    return ret
end

---@param count integer
---@return string
local function title(count)
    if count == 1 then
        return 'Delete?'
    end
    return string.format('Delete %d %s?', count, count == 1 and 'file' or 'files')
end

---@param confirm_items DirtreeDeleteConfirmItem[]
---@param overflow integer
---@return string[]
local function lines(confirm_items, overflow)
    local ret = {}
    for _, confirm_item in ipairs(confirm_items) do
        ret[#ret+1] = LINE_PREFIX .. confirm_item.display
    end
    if overflow > 0 then
        ret[#ret+1] = string.format('%sand %d more…', LINE_PREFIX, overflow)
    end
    return ret
end

---@param buf integer
---@param ns integer
---@param confirm_items DirtreeDeleteConfirmItem[]
---@param overflow integer
local function render(buf, ns, confirm_items, overflow)
    local rendered_lines = lines(confirm_items, overflow)
    api.nvim_buf_set_lines(buf, 0, -1, false, rendered_lines)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, confirm_item in ipairs(confirm_items) do
        local line_prefix_len = LINE_PREFIX_LEN
        local path_start_col = line_prefix_len
        local file_start_col = line_prefix_len + confirm_item.file_start_col
        local file_end_col = line_prefix_len + confirm_item.file_end_col
        if path_start_col < file_start_col then
            api.nvim_buf_set_extmark(buf, ns, i - 1, path_start_col, {
                end_col = file_start_col,
                hl_group = 'DirtreeDeletePath',
            })
        end
        api.nvim_buf_set_extmark(buf, ns, i - 1, file_start_col, {
            end_col = file_end_col,
            hl_group = confirm_item.file_hl,
            priority = 10000,
        })
        if confirm_item.directory_suffix_col then
            local suffix_col = line_prefix_len + confirm_item.directory_suffix_col
            api.nvim_buf_set_extmark(buf, ns, i - 1, suffix_col, {
                end_col = file_end_col + 1,
                hl_group = 'DirtreeVirtText',
                priority = 10000,
            })
        end
    end
    if overflow > 0 then
        local row = #rendered_lines - 1
        api.nvim_buf_set_extmark(buf, ns, row, LINE_PREFIX_LEN, {
            end_col = #rendered_lines[#rendered_lines],
            hl_group = 'DirtreeDeleteMore',
        })
    end
end

---@param confirm_title string
---@param rendered_lines string[]
---@return integer
local function width(confirm_title, rendered_lines)
    local max_width = #confirm_title
    for _, line in ipairs(rendered_lines) do
        max_width = math.max(max_width, #line)
    end
    return math.max(32, math.min(MAX_DELETE_WIDTH, max_width + RIGHT_PADDING))
end

---@param paths string[]
---@param cwd string
---@param cb fun(confirmed: boolean)
function M.delete(paths, cwd, cb)
    if #paths == 0 then
        cb(false)
        return
    end
    local confirm_items = items(paths, cwd, max_display_width())
    local overflow = math.max(0, #paths - #confirm_items)
    local rendered_lines = lines(confirm_items, overflow)
    local confirm_title = title(#paths)
    local origin_win = api.nvim_get_current_win()
    local guicursor = vim.o.guicursor
    local autocmds = {}
    local closed = false
    local buf = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace('dirtree/delete_win.' .. buf)

    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = true
    local function refresh()
        confirm_items = items(paths, cwd, max_display_width())
        rendered_lines = lines(confirm_items, overflow)
        vim.bo[buf].modifiable = true
        render(buf, ns, confirm_items, overflow)
        vim.bo[buf].modifiable = false
    end

    refresh()
    vim.bo[buf].modifiable = false

    local function layout()
        return window.centered_layout({
            title = confirm_title,
            width = width(confirm_title, rendered_lines),
            height = #rendered_lines,
            border_hl = 'DirtreePromptBorderInvalid',
        })
    end

    local win = api.nvim_open_win(buf, true, layout())
    vim.o.guicursor = 'a:block-DirtreeDeleteCursor'
    vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:DirtreePromptBorderInvalid,Cursor:DirtreeDeleteCursor'
    vim.wo[win].wrap = false

    local function finish(confirmed)
        if closed then
            return
        end
        closed = true
        for _, au in ipairs(autocmds) do
            pcall(api.nvim_del_autocmd, au)
        end
        vim.o.guicursor = guicursor
        window.close(buf, win)
        if window.valid_win(origin_win) then
            pcall(api.nvim_set_current_win, origin_win)
        end
        cb(confirmed)
    end

    for _, lhs in ipairs({'y', 'Y'}) do
        vim.keymap.set('n', lhs, function() finish(true) end, {buffer = buf, silent = true, nowait = true})
    end
    for _, lhs in ipairs({'n', 'N', 'q', '<Esc>', '<C-c>'}) do
        vim.keymap.set('n', lhs, function() finish(false) end, {buffer = buf, silent = true, nowait = true})
    end

    autocmds[#autocmds+1] = api.nvim_create_autocmd('VimResized', {
        callback = function()
            if window.valid_win(win) then
                refresh()
                api.nvim_win_set_config(win, layout())
            end
        end,
    })
    autocmds[#autocmds+1] = api.nvim_create_autocmd('WinClosed', {
        callback = function(args)
            if tonumber(args.match) == win then
                finish(false)
            end
        end,
    })
end

return M
