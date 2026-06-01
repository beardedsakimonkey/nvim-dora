local api = vim.api
local uv = vim.loop

local window = require'dora.window'
local fs = require'dora.fs'
local util = require'dora.util'

local M = {}

local MAX_DELETE_PATHS = 10
local MAX_DELETE_WIDTH = 96
local LINE_PREFIX = ' '
local LINE_PREFIX_LEN = #LINE_PREFIX
local RIGHT_PADDING = 1

---@class DoraDeleteConfirmItem
---@field display string
---@field file_start_col integer
---@field file_end_col integer
---@field file_hl string

---@class DoraDeleteOptions
---@field anchor? {win: integer, line: integer, col: integer}
---@field action? string

---@param path string
---@return string
local function file_hl(path)
    if uv.fs_readlink(path) then
        return 'DoraSymlink'
    end
    local stat = uv.fs_stat(path)
    if stat and stat.type == 'directory' then
        return 'DoraDirectory'
    end
    if uv.fs_access(path, 'X') then
        return 'DoraExecutable'
    end
    return 'DoraFile'
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

---@param path string
---@param cwd string
---@return DoraDeleteConfirmItem
local function item(path, cwd)
    local display = relative_display_path(path, cwd)
    local basename = fs.basename(path)
    local hl = file_hl(path)
    local file_start_col = math.max(0, #display - #basename)
    local file_end_col = #display
    if hl == 'DoraDirectory' then
        display = display .. util.sep
    end
    return {
        display = display,
        file_start_col = file_start_col,
        file_end_col = file_end_col,
        file_hl = hl,
    }
end

---@param paths string[]
---@param cwd string
---@return DoraDeleteConfirmItem[]
local function items(paths, cwd)
    local ret = {}
    for i = 1, math.min(#paths, MAX_DELETE_PATHS) do
        ret[#ret+1] = item(paths[i], cwd)
    end
    return ret
end

---@param count integer
---@param action? string
---@return string
local function get_title(count, action)
    action = action or 'Delete'
    if count == 1 then
        return action .. '?'
    end
    return string.format('%s %d files?', action, count)
end

---@param confirm_items DoraDeleteConfirmItem[]
---@param overflow integer
---@return string[]
local function lines(confirm_items, overflow)
    local ret = {}
    for _, confirm_item in ipairs(confirm_items) do
        ret[#ret+1] = LINE_PREFIX .. confirm_item.display
    end
    if overflow > 0 then
        ret[#ret+1] = string.format('%s... and %d more', LINE_PREFIX, overflow)
    end
    return ret
end

---@param buf integer
---@param ns integer
---@param confirm_items DoraDeleteConfirmItem[]
---@param overflow integer
local function render(buf, ns, confirm_items, overflow)
    local rendered_lines = lines(confirm_items, overflow)
    api.nvim_buf_set_lines(buf, 0, -1, false, rendered_lines)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, confirm_item in ipairs(confirm_items) do
        local line_prefix_len = LINE_PREFIX_LEN
        local file_start_col = line_prefix_len + confirm_item.file_start_col
        local file_end_col = line_prefix_len + confirm_item.file_end_col
        api.nvim_buf_set_extmark(buf, ns, i - 1, file_start_col, {
            end_col = file_end_col,
            hl_group = confirm_item.file_hl,
            priority = 10000,
        })
    end
    if overflow > 0 then
        local row = #rendered_lines - 1
        api.nvim_buf_set_extmark(buf, ns, row, LINE_PREFIX_LEN, {
            end_col = #rendered_lines[#rendered_lines],
            hl_group = 'DoraDeleteMore',
        })
    end
end

---@param confirm_title string
---@param rendered_lines string[]
---@return integer
local function get_width(confirm_title, rendered_lines)
    local max_width = #confirm_title
    for _, line in ipairs(rendered_lines) do
        max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
    end
    return math.max(32, math.min(MAX_DELETE_WIDTH, max_width + RIGHT_PADDING))
end

---@param opts DoraAnchoredFloatLayoutOptions
---@return table
local function anchored_layout(opts)
    if not window.valid_win(opts.win) then
        return window.centered_layout(opts)
    end
    local pos = vim.fn.screenpos(opts.win, opts.line, opts.col + 1)
    if pos.row == 0 or pos.col == 0 then
        return window.centered_layout(opts)
    end
    local anchor_col = math.max(0, pos.col - 1)
    local width = math.min(opts.width, math.max(opts.min_width or 20, vim.o.columns - 2))
    local col = math.min(anchor_col, math.max(0, vim.o.columns - width - 2))
    local height = math.min(opts.height, math.max(1, vim.o.lines - 4))
    local title = opts.title and (' ' .. opts.title .. ' ') or nil
    return {
        relative = 'editor',
        anchor = 'NW',
        row = math.max(0, pos.row),
        col = col,
        width = width,
        height = height,
        border = window.border(opts.border_hl or 'DoraPromptBorder'),
        title = title,
        title_pos = title and (opts.title_pos or 'left') or nil,
        style = 'minimal',
        noautocmd = true,
    }
end

---@param paths string[]
---@param cwd string
---@param cb fun(confirmed: boolean)
---@param opts? DoraDeleteOptions
function M.delete(paths, cwd, cb, opts)
    if #paths == 0 then
        cb(false)
        return
    end
    opts = opts or {}
    local confirm_items = items(paths, cwd)
    local overflow = math.max(0, #paths - #confirm_items)
    local rendered_lines = lines(confirm_items, overflow)
    local confirm_title = get_title(#paths, opts.action)
    local origin_win = api.nvim_get_current_win()
    local guicursor = vim.o.guicursor
    local autocmds = {}
    local closed = false
    local buf = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace('dora/delete_win.' .. buf)

    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = true
    local function refresh()
        confirm_items = items(paths, cwd)
        rendered_lines = lines(confirm_items, overflow)
        vim.bo[buf].modifiable = true
        render(buf, ns, confirm_items, overflow)
        vim.bo[buf].modifiable = false
    end

    refresh()
    vim.bo[buf].modifiable = false

    local function layout()
        local layout_opts = {
            title = confirm_title,
            width = get_width(confirm_title, rendered_lines),
            height = #rendered_lines,
            border_hl = 'DoraPromptBorderInvalid',
        }
        if opts.anchor then
            return anchored_layout(vim.tbl_extend('force', layout_opts, opts.anchor))
        end
        return window.centered_layout(layout_opts)
    end

    local win = api.nvim_open_win(buf, true, layout())
    vim.o.guicursor = 'a:block-Normal'
    vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:DoraPromptBorderInvalid,Cursor:Normal'
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

    for _, lhs in ipairs({'y', 'Y', '<CR>'}) do
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
