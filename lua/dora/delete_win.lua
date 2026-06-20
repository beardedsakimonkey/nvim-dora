local api = vim.api
local uv = vim.loop

local window = require'dora.window'
local fs = require'dora.fs'
local icons = require'dora.icons'
local config = require'dora'.config

local M = {}

local MAX_DELETE_PATHS = 10
local MAX_DELETE_WIDTH = 96
local RIGHT_PADDING = 1
local OVERWRITE_LABEL = ' (overwrites)'
local OPERATION_HL = {cut = 'DoraCut', copy = 'DoraCopy'}

---@class DoraDeleteConfirmItem
---@field display string
---@field icon_start_col? integer
---@field icon_end_col? integer
---@field icon_hl? string
---@field dir_start_col? integer
---@field dir_end_col? integer
---@field file_start_col integer
---@field file_end_col integer
---@field file_hl string
---@field overwrite? boolean
---@field operation? DoraPasteOperation

---@class DoraDeleteOptions
---@field anchor? DoraFloatAnchor
---@field action? string
---@field dest? string Destination directory shown beneath the file list
---@field base? string Show listed paths relative to this directory
---@field overwrites? table<string, boolean> Source paths that will replace an existing file
---@field operations? table<string, DoraPasteOperation> Source path -> cut/copy, shown as a colored bar

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

-- Byte length of the leading directory portion of a path, before its final
-- component. Trailing separators are ignored.
---@param path string
---@return integer
local function dir_prefix_len(path)
    return #fs.strip_trailing_sep(path) - #fs.basename(path)
end

---@param path string
---@param base? string
---@param overwrites? table<string, boolean>
---@param operations? table<string, DoraPasteOperation>
---@return DoraDeleteConfirmItem
local function item(path, base, overwrites, operations)
    local basename = fs.basename(path)
    -- Show the path relative to base, falling back to the absolute path for
    -- marks outside it (e.g. above the current root).
    local relative = base and (vim.fs.relpath(base, path) or path) or basename
    local dir_len = dir_prefix_len(relative)
    local hl = file_hl(path)
    local icon, icon_hl = icons.get(config.icons, fs.file_from_path(path), path)
    local icon_prefix = icon and icon .. ' ' or ''
    local display = relative
    if hl == 'DoraDirectory' then
        display = display .. '/'
    end
    display = icon_prefix .. display
    return {
        display = display,
        icon_start_col = icon and 0 or nil,
        icon_end_col = icon and #icon or nil,
        icon_hl = icon_hl or 'DoraIcon',
        dir_start_col = dir_len > 0 and #icon_prefix or nil,
        dir_end_col = dir_len > 0 and #icon_prefix + dir_len or nil,
        file_start_col = #icon_prefix + dir_len,
        file_end_col = #icon_prefix + dir_len + #basename,
        file_hl = hl,
        overwrite = overwrites and overwrites[path] or nil,
        operation = operations and operations[path] or nil,
    }
end

---@param paths string[]
---@param base? string
---@param overwrites? table<string, boolean>
---@param operations? table<string, DoraPasteOperation>
---@param limit integer Maximum number of paths to render before overflowing
---@return DoraDeleteConfirmItem[]
local function items(paths, base, overwrites, operations, limit)
    local ret = {}
    for i = 1, math.min(#paths, limit) do
        ret[#ret+1] = item(paths[i], base, overwrites, operations)
    end
    return ret
end

-- How many paths to list before overflowing into "... and N more". A
-- superimposed confirmation aligns one line per removed row, so it lists every
-- path that fits; it only overflows when the float (including its border)
-- genuinely cannot show them all. Other confirmations (paste, centered) keep
-- the fixed cap.
---@param anchor? DoraFloatAnchor
---@param count integer Number of paths to confirm
---@return integer
local function path_limit(anchor, count)
    local capacity = window.superimpose_capacity(anchor)
    if not capacity then
        return MAX_DELETE_PATHS
    end
    if count <= capacity then
        return count
    end
    -- Reserve the final visible row for the overflow line.
    return capacity - 1
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
---@param dest_item? DoraDeleteConfirmItem
---@return string[] rendered_lines
---@return integer? dest_row 0-indexed row of the destination
local function lines(confirm_items, overflow, dest_item)
    local ret = {}
    for _, confirm_item in ipairs(confirm_items) do
        local line = confirm_item.display
        if confirm_item.overwrite then
            line = line .. OVERWRITE_LABEL
        end
        ret[#ret+1] = line
    end
    if overflow > 0 then
        ret[#ret+1] = string.format('... and %d more', overflow)
    end
    local dest_row
    if dest_item then
        ret[#ret+1] = '↓'
        dest_row = #ret
        ret[#ret+1] = dest_item.display
    end
    return ret, dest_row
end

---@param buf integer
---@param ns integer
---@param row integer 0-indexed
---@param confirm_item DoraDeleteConfirmItem
local function render_item(buf, ns, row, confirm_item)
    if confirm_item.icon_start_col then
        api.nvim_buf_set_extmark(buf, ns, row, confirm_item.icon_start_col, {
            end_col = confirm_item.icon_end_col,
            hl_group = confirm_item.icon_hl,
            priority = 10000,
        })
    end
    if confirm_item.dir_start_col then
        api.nvim_buf_set_extmark(buf, ns, row, confirm_item.dir_start_col, {
            end_col = confirm_item.dir_end_col,
            hl_group = 'DoraFilterPath',
            priority = 10000,
        })
    end
    -- A cut/copy mark recolors the filename, matching how marked files appear
    -- in the tree.
    local name_hl = confirm_item.operation and OPERATION_HL[confirm_item.operation]
        or confirm_item.file_hl
    api.nvim_buf_set_extmark(buf, ns, row, confirm_item.file_start_col, {
        end_col = confirm_item.file_end_col,
        hl_group = name_hl,
        priority = 10000,
    })
end

---@param buf integer
---@param ns integer
---@param confirm_items DoraDeleteConfirmItem[]
---@param overflow integer
---@param dest_item? DoraDeleteConfirmItem
local function render(buf, ns, confirm_items, overflow, dest_item)
    local rendered_lines, dest_row = lines(confirm_items, overflow, dest_item)
    api.nvim_buf_set_lines(buf, 0, -1, false, rendered_lines)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, confirm_item in ipairs(confirm_items) do
        render_item(buf, ns, i - 1, confirm_item)
        if confirm_item.overwrite then
            api.nvim_buf_set_extmark(buf, ns, i - 1, #confirm_item.display, {
                end_col = #rendered_lines[i],
                hl_group = 'DoraOverwrite',
                priority = 10000,
            })
        end
    end
    if overflow > 0 then
        local row = #confirm_items
        api.nvim_buf_set_extmark(buf, ns, row, 0, {
            end_col = #rendered_lines[row + 1],
            hl_group = 'DoraMutedText',
        })
    end
    if dest_item and dest_row then
        render_item(buf, ns, dest_row, dest_item)
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
-- align with the rows they remove. The offset is the width of the directory
-- prefix shown before the basename (none for a bare basename), letting the icon
-- sit flush against the border like the rename prompt.
---@param anchor DoraFloatAnchor
---@param confirm_items DoraDeleteConfirmItem[]
---@return DoraFloatAnchor
local function superimpose_anchor(anchor, confirm_items)
    if anchor.superimpose == false then
        return anchor
    end
    local first = confirm_items[1]
    if not first then
        return anchor
    end
    local icon_len = first.icon_end_col and first.icon_end_col + 1 or 0
    local dir_prefix = first.display:sub(icon_len + 1, first.file_start_col)
    return vim.tbl_extend('force', anchor, {
        superimpose = true,
        col_offset = vim.fn.strdisplaywidth(dir_prefix),
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
    local base = opts.base
    local overwrites = opts.overwrites
    local operations = opts.operations
    -- Render the destination like a listed entry: relative to base, or by its
    -- own name when it is base itself.
    local dest_item = opts.dest and item(opts.dest, opts.dest ~= base and base or nil) or nil
    local max_paths = path_limit(opts.anchor, #paths)
    local confirm_items = items(paths, base, overwrites, operations, max_paths)
    local overflow = math.max(0, #paths - #confirm_items)
    local rendered_lines = lines(confirm_items, overflow, dest_item)
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
        confirm_items = items(paths, base, overwrites, operations, max_paths)
        rendered_lines = lines(confirm_items, overflow, dest_item)
        vim.bo[buf].modifiable = true
        render(buf, ns, confirm_items, overflow, dest_item)
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
    vim.o.guicursor = 'a:block-DoraHiddenCursor'
    vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:DoraPromptBorderInvalid'
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

    autocmds[#autocmds+1] = api.nvim_create_autocmd('CursorMoved', {
        buffer = buf,
        callback = function()
            if window.valid_win(win) then
                api.nvim_win_set_cursor(win, {1, 0})
            end
        end,
    })
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
