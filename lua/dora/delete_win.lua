local api = vim.api
local uv = vim.loop

local window = require'dora.window'
local fs = require'dora.fs'
local icons = require'dora.icons'
local config = require'dora'.config

local M = {}

local MAX_DELETE_PATHS = 10
local MAX_DELETE_WIDTH = 96
local LINE_PREFIX = ' '
local LINE_PREFIX_LEN = #LINE_PREFIX
local RIGHT_PADDING = 1

---@class DoraDeleteConfirmItem
---@field display string
---@field icon_start_col? integer
---@field icon_end_col? integer
---@field icon_hl? string
---@field file_start_col integer
---@field file_end_col integer
---@field file_hl string

---@class DoraDeleteOptions
---@field anchor? DoraFloatAnchor
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
---@return DoraDeleteConfirmItem
local function item(path)
    local basename = fs.basename(path)
    local hl = file_hl(path)
    local icon, icon_hl = icons.get(config.icons, fs.file_from_path(path), path)
    local icon_prefix = icon and icon .. ' ' or ''
    local display = basename
    if hl == 'DoraDirectory' then
        display = display .. '/'
    end
    display = icon_prefix .. display
    return {
        display = display,
        icon_start_col = icon and 0 or nil,
        icon_end_col = icon and #icon or nil,
        icon_hl = icon_hl or 'DoraIcon',
        file_start_col = #icon_prefix,
        file_end_col = #icon_prefix + #basename,
        file_hl = hl,
    }
end

---@param paths string[]
---@return DoraDeleteConfirmItem[]
local function items(paths)
    local ret = {}
    for i = 1, math.min(#paths, MAX_DELETE_PATHS) do
        ret[#ret+1] = item(paths[i])
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
        if confirm_item.icon_start_col then
            api.nvim_buf_set_extmark(buf, ns, i - 1, LINE_PREFIX_LEN + confirm_item.icon_start_col, {
                end_col = LINE_PREFIX_LEN + confirm_item.icon_end_col,
                hl_group = confirm_item.icon_hl,
                priority = 10000,
            })
        end
        local file_start_col = LINE_PREFIX_LEN + confirm_item.file_start_col
        local file_end_col   = LINE_PREFIX_LEN + confirm_item.file_end_col
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
            hl_group = 'DoraMutedText',
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

---@param win integer
---@return DoraFloatAnchor
local function cursor_anchor(win)
    local cursor = api.nvim_win_get_cursor(win)
    return {
        win = win,
        line = cursor[1],
        col = cursor[2],
    }
end

-- Superimposes the first item's basename onto the anchor cell, so the lines
-- align with the rows they remove
---@param anchor DoraFloatAnchor
---@param confirm_items DoraDeleteConfirmItem[]
---@return DoraFloatAnchor
local function superimpose_anchor(anchor, confirm_items)
    local first = confirm_items[1]
    if not first then
        return anchor
    end
    local prefix = (LINE_PREFIX .. first.display):sub(1, LINE_PREFIX_LEN + first.file_start_col)
    return vim.tbl_extend('force', anchor, {
        superimpose = true,
        col_offset = vim.fn.strdisplaywidth(prefix),
    })
end

---@param paths string[]
---@param cb fun(confirmed: boolean)
---@param opts? DoraDeleteOptions
function M.delete(paths, cb, opts)
    if #paths == 0 then
        cb(false)
        return
    end
    opts = opts or {}
    local confirm_items = items(paths)
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
        confirm_items = items(paths)
        rendered_lines = lines(confirm_items, overflow)
        vim.bo[buf].modifiable = true
        render(buf, ns, confirm_items, overflow)
        vim.bo[buf].modifiable = false
    end

    refresh()
    vim.bo[buf].modifiable = false

    local function layout()
        return window.layout({
            title = confirm_title,
            width = get_width(confirm_title, rendered_lines),
            height = #rendered_lines,
            anchor = opts.anchor and superimpose_anchor(opts.anchor, confirm_items)
                or cursor_anchor(origin_win),
        })
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
    autocmds[#autocmds+1] = api.nvim_create_autocmd('WinLeave', {
        buffer = buf,
        callback = function() finish(false) end,
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
