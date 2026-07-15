-- View engine for dora buffers: the per-directory listing cache (with
-- filesystem watchers), tree/filter row building, rendering (buffer text +
-- extmarks), and cursor placement onto rendered rows. Nothing here is a
-- user-facing action; those live in dora/api.lua and call into this module.
local buffer = require'dora.buffer'
local fs = require'dora.fs'
local icons = require'dora.icons'
local preview_win = require'dora.ui.preview'
local sorter = require'dora.sort'
local util = require'dora.util'
local config = require'dora'.config

local api = vim.api
local uv = vim.uv

local M = {}

M.EMPTY_LABEL = '(empty)'
local NOT_PERMITTED_LABEL = '(not permitted)'
local TREE_VERTICAL = '│'

---@class DoraTreeSegment
---@field parent_path string
---@field start_col integer
---@field end_col integer

---@class DoraTreeRow
---@field name string
---@field display_name string
---@field path? string
---@field parent_path? string
---@field type DoraFileType|'placeholder'
---@field depth integer
---@field is_root? boolean the synthetic cwd row shown when config.show_root is set
---@field tree_prefix_len integer
---@field tree_continuation_segments DoraTreeSegment[]
---@field tree_connector_start_col? integer
---@field icon? string
---@field icon_start_col? integer
---@field icon_end_col? integer
---@field icon_hl? string
---@field name_start_col? integer
---@field name_end_col? integer
---@field directory_suffix_col? integer
---@field filter_directory_start_col? integer
---@field filter_directory_end_col? integer
---@field filter_match_start_col? integer
---@field filter_match_end_col? integer

---@class DoraListingEntry
---@field raw DoraFile[]? unfiltered listing; nil when the listing failed
---@field files DoraFile[] filtered and sorted files
---@field placeholder_label string?
---@field show_hidden boolean
---@field sort_order DoraSortOrder
---@field unwatch fun()?

---@param msg any
---@return boolean
local function is_permission_error(msg)
    msg = tostring(msg)
    return msg:match('EPERM') ~= nil
        or msg:lower():match('operation not permitted') ~= nil
        or msg:lower():match('permission denied') ~= nil
end

---@param state DoraState
---@param all_files DoraFile[]
---@param dir string
---@return DoraFile[]
local function filter_and_sort(state, all_files, dir)
    local files = vim.tbl_filter(function(file)
        if state.show_hidden_files then
            return true
        else
            return not config.is_hidden_file(file, all_files, dir)
        end
    end, all_files)
    sorter.files(files, state.sort_order)
    return files
end

-- Watch for external changes so the cached listing doesn't go stale: the
-- first change drops the cache entry, and the rescan on the following
-- render starts a new watch.
---@param state DoraState
---@param dir string
---@return fun()? unwatch
local function watch_directory(state, dir)
    return fs.watch_dir(dir, function()
        if state.listings[dir] then
            state.listings[dir] = nil
            if api.nvim_buf_is_valid(state.buf) then
                M.render(state)
            end
        end
    end)
end

-- Drop all cached listings and their watchers; the next render rescans.
---@param state DoraState
function M.clear_listings(state)
    for dir, entry in pairs(state.listings) do
        if entry.unwatch then
            entry.unwatch()
        end
        state.listings[dir] = nil
    end
end

-- One uncached directory scan: the raw listing plus its filtered and sorted
-- view per the state's settings, with failures mapped to the same placeholder
-- labels the tree shows. visible_files caches this; the preview window calls
-- it directly for point-in-time snapshots.
---@param state DoraState
---@param dir string
---@return DoraFile[]? raw unfiltered listing; nil when the listing failed
---@return DoraFile[] files filtered and sorted
---@return string? placeholder_label
function M.scan_directory(state, dir)
    local ok, all_files = pcall(fs.list, dir)
    if not ok then
        if is_permission_error(all_files) then
            return nil, {}, NOT_PERMITTED_LABEL
        end
        util.warn(tostring(all_files))
        return nil, {}, nil
    end
    return all_files, filter_and_sort(state, all_files, dir), nil
end

---@param state DoraState
---@param dir string
---@return DoraFile[] files
---@return string? placeholder_label
function M.visible_files(state, dir)
    local entry = state.listings[dir]
    if entry then
        if entry.show_hidden ~= state.show_hidden_files or entry.sort_order ~= state.sort_order then
            -- Only the view settings changed; refilter and resort the
            -- listing we already have instead of rescanning.
            if entry.raw then
                entry.files = filter_and_sort(state, entry.raw, dir)
            end
            entry.show_hidden = state.show_hidden_files
            entry.sort_order = state.sort_order
        end
        return entry.files, entry.placeholder_label
    end
    local raw, files, placeholder_label = M.scan_directory(state, dir)
    entry = {
        raw = raw,
        files = files,
        placeholder_label = placeholder_label,
        show_hidden = state.show_hidden_files,
        sort_order = state.sort_order,
        unwatch = watch_directory(state, dir),
    }
    state.listings[dir] = entry
    return entry.files, entry.placeholder_label
end

---@param state DoraState
---@param path string
---@return string
function M.relative_child_path(state, path)
    return assert(vim.fs.relpath(state.cwd, path))
end

---@param state DoraState
---@return DoraTreeRow[]
function M.build_tree_rows(state)
    local rows = {}
    local tree_indent = math.max(1, math.floor(config.tree_indent))
    -- At indent 1 the connector fills the whole column, so no room for the
    -- usual space between it and the icon/name.
    local connector_suffix = tree_indent == 1 and '' or string.rep('─', tree_indent - 2) .. ' '
    local tree_continuation = TREE_VERTICAL .. string.rep(' ', tree_indent - 1)
    local tree_spacer = string.rep(' ', tree_indent)

    ---@param dir string
    ---@param prefix string
    ---@param depth integer
    ---@param continuation_segments DoraTreeSegment[]
    local function add_dir(dir, prefix, depth, continuation_segments)
        local files, placeholder_label = M.visible_files(state, dir)
        if depth > 0 and (#files == 0 or placeholder_label) then
            placeholder_label = placeholder_label or M.EMPTY_LABEL
            local tree_prefix = prefix .. '└' .. connector_suffix
            rows[#rows+1] = {
                name = placeholder_label,
                display_name = tree_prefix .. placeholder_label,
                path = nil,
                parent_path = dir,
                type = 'placeholder',
                depth = depth,
                tree_prefix_len = #tree_prefix,
                tree_continuation_segments = vim.list_slice(continuation_segments),
                tree_connector_start_col = #prefix,
                name_start_col = #tree_prefix,
                name_end_col = #tree_prefix + #placeholder_label,
            }
            return
        end
        for i, file in ipairs(files) do
            local is_last = i == #files
            local connector = depth == 0
                and ''
                or (is_last and '└' or '├') .. connector_suffix
            local child_prefix = depth == 0
                and ''
                or prefix .. (is_last and tree_spacer or tree_continuation)
            local child_continuation_segments = continuation_segments
            if depth > 0 then
                child_continuation_segments = vim.list_slice(continuation_segments)
                if not is_last then
                    child_continuation_segments[#child_continuation_segments+1] = {
                        parent_path = dir,
                        start_col = #prefix,
                        end_col = #prefix + #TREE_VERTICAL,
                    }
                end
            end
            local path = vim.fs.joinpath(dir, file.name)
            local tree_prefix = prefix .. connector
            local expanded = file.type == 'directory' and state.expanded_dirs[path] or nil
            local icon, icon_hl = icons.get(config.icons, file, path, expanded)
            local icon_prefix = icon and icon .. ' ' or ''
            local display_name = tree_prefix .. icon_prefix .. file.name
            local directory_suffix_col
            if file.type == 'directory' then
                directory_suffix_col = #display_name
                display_name = display_name .. '/'
            end
            rows[#rows+1] = {
                name = file.name,
                display_name = display_name,
                path = path,
                parent_path = dir,
                type = file.type,
                depth = depth,
                tree_prefix_len = #tree_prefix,
                tree_continuation_segments = vim.list_slice(continuation_segments),
                tree_connector_start_col = depth > 0 and #prefix or nil,
                icon = icon,
                icon_start_col = icon and #tree_prefix or nil,
                icon_end_col = icon and #tree_prefix + #icon or nil,
                icon_hl = icon_hl or 'DoraIcon',
                name_start_col = #tree_prefix + #icon_prefix,
                name_end_col = #tree_prefix + #icon_prefix + #file.name,
                directory_suffix_col = directory_suffix_col,
            }
            if expanded then
                add_dir(path, child_prefix, depth + 1, child_continuation_segments)
            end
        end
    end

    if config.show_root then
        -- Synthetic row for the browsed directory itself; its listing renders
        -- beneath it at depth 1, so children get tree connectors.
        local name = vim.fs.basename(state.cwd)
        if name == '' then
            name = '/'
        end
        local icon, icon_hl = icons.get(config.icons, {name = name, type = 'directory'}, state.cwd, true)
        local icon_prefix = icon and icon .. ' ' or ''
        local display_name = icon_prefix .. name
        local directory_suffix_col
        if name ~= '/' then
            directory_suffix_col = #display_name
            display_name = display_name .. '/'
        end
        rows[#rows+1] = {
            name = name,
            display_name = display_name,
            path = state.cwd,
            type = 'directory',
            depth = 0,
            is_root = true,
            tree_prefix_len = 0,
            tree_continuation_segments = {},
            icon = icon,
            icon_start_col = icon and 0 or nil,
            icon_end_col = icon and #icon or nil,
            icon_hl = icon_hl or 'DoraIcon',
            name_start_col = #icon_prefix,
            name_end_col = #icon_prefix + #name,
            directory_suffix_col = directory_suffix_col,
        }
        add_dir(state.cwd, '', 1, {})
    else
        add_dir(state.cwd, '', 0, {})
    end
    return rows
end

---@param state DoraState
---@return string?
function M.active_filter(state)
    local filter = state.filter_preview
    if filter == nil then
        filter = state.filter_text
    end
    return filter ~= '' and filter or nil
end

---@param state DoraState
---@param tree_rows DoraTreeRow[]
---@return DoraTreeRow[]
local function build_filtered_rows(state, tree_rows)
    local filter = M.active_filter(state)
    if not filter then
        return tree_rows
    end

    local rows = {}
    -- The filter is a Vim regex, so users can anchor (e.g. `lua$`), use
    -- character classes, etc. vim.regex is always case-sensitive regardless of
    -- 'ignorecase', so prepend `\c` to keep matching case-insensitive by
    -- default; a `\C` in the user's own pattern still wins to force case.
    local ok, regex = pcall(vim.regex, '\\c' .. filter)
    if not ok then
        -- Incomplete or invalid pattern (common while typing); show nothing.
        return rows
    end
    local inverted = state.filter_inverted
    for _, row in ipairs(tree_rows) do
        local matched, match_start, match_end = false, nil, nil
        if row.path then
            -- Match the lowered name so Unicode case folding (e.g. 'İ' → 'i',
            -- which `\c` alone does not do) still matches, then map the lowered
            -- byte offsets back to the original name's bytes via character
            -- indices, which tolower() preserves even when byte lengths change.
            local lowered_name = vim.fn.tolower(row.name)
            local lowered_start, lowered_end = regex:match_str(lowered_name)
            if lowered_start then
                matched = true
                local char_start = vim.fn.charidx(lowered_name, lowered_start)
                local matched_chars = vim.fn.strchars(lowered_name:sub(lowered_start + 1, lowered_end))
                match_start = vim.fn.byteidx(row.name, char_start)
                match_end = vim.fn.byteidx(row.name, char_start + matched_chars)
            end
        end
        -- Keep matching rows; when inverted, keep the non-matching rows instead
        -- (which have no basename span to highlight). The root row is skipped:
        -- filter results are already cwd-relative paths.
        if row.path and not row.is_root and matched ~= inverted then
            local relative_path = M.relative_child_path(state, row.path)
            local icon_prefix = row.icon and row.icon .. ' ' or ''
            local display_name = icon_prefix .. relative_path
            local basename_start_col = #icon_prefix + #relative_path - #row.name
            local directory_suffix_col
            if row.type == 'directory' then
                directory_suffix_col = #display_name
                display_name = display_name .. '/'
            end
            rows[#rows+1] = {
                name = row.name,
                display_name = display_name,
                path = row.path,
                parent_path = row.parent_path,
                type = row.type,
                depth = row.depth,
                tree_prefix_len = 0,
                tree_continuation_segments = {},
                icon = row.icon,
                icon_start_col = row.icon and 0 or nil,
                icon_end_col = row.icon and #row.icon or nil,
                icon_hl = row.icon_hl,
                name_start_col = #icon_prefix,
                name_end_col = #icon_prefix + #relative_path,
                directory_suffix_col = directory_suffix_col,
                filter_directory_start_col = basename_start_col > #icon_prefix and #icon_prefix or nil,
                filter_directory_end_col = basename_start_col > #icon_prefix and basename_start_col or nil,
                filter_match_start_col = match_start and basename_start_col + match_start or nil,
                filter_match_end_col = match_end and basename_start_col + match_end or nil,
            }
        end
    end
    return rows
end

---@param state DoraState
local function prune_deleted_marked_paths(state)
    for marked_path in pairs(state.marked_paths) do
        if not fs.exists(marked_path) then
            state.marked_paths[marked_path] = nil
        end
    end
end

---@param state DoraState
function M.update_tree_cursor_highlight(state)
    local buf, ns = state.buf, state.cursor_ns
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if M.active_filter(state) or api.nvim_get_current_buf() ~= buf then
        return
    end
    local row_nr = api.nvim_win_get_cursor(0)[1]
    local row = state.rows and state.rows[row_nr] or nil
    if not row or not row.parent_path then
        return
    end
    for i, sibling in ipairs(state.rows) do
        for _, segment in ipairs(sibling.tree_continuation_segments) do
            if segment.parent_path == row.parent_path then
                api.nvim_buf_set_extmark(buf, ns, i - 1, segment.start_col, {
                    end_col = segment.end_col,
                    hl_group = 'DoraTreeActive',
                    priority = 10001,
                })
            end
        end
        if sibling.parent_path == row.parent_path and sibling.tree_connector_start_col then
            api.nvim_buf_set_extmark(buf, ns, i - 1, sibling.tree_connector_start_col, {
                end_col = sibling.tree_prefix_len,
                hl_group = 'DoraTreeActive',
                priority = 10001,
            })
        end
    end
end

-- Refresh an open preview to the hovered row. Called from the cursor motion
-- autocmds and from every render: navigation can put a different row under a
-- cursor that doesn't move, which fires no CursorMoved.
---@param state DoraState
function M.update_preview(state)
    if not state.preview then
        return
    end
    -- The window showing state.buf, which isn't the current window when a
    -- render comes from an async callback or another dora window's action.
    local win = vim.fn.bufwinid(state.buf)
    if win == -1 then
        return
    end
    local line = api.nvim_win_get_cursor(win)[1]
    preview_win.update(state, state.rows and state.rows[line] or nil)
end

---@param state DoraState
function M.render(state)
    local buf, ns = state.buf, state.ns
    prune_deleted_marked_paths(state)
    local tree_rows = M.build_tree_rows(state)
    local rows = build_filtered_rows(state, tree_rows)
    state.tree_rows = tree_rows
    state.rows = rows
    buffer.set_lines(buf, vim.tbl_map(function(f)
        return f.display_name
    end, rows))
    -- Add virttext and highlights
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if state.filter_editing or state.filter_window then
        api.nvim_buf_set_extmark(buf, ns, 0, 0, {
            virt_lines = {{{'', 'Normal'}}},
            virt_lines_above = true,
        })
    end
    for i, file in ipairs(rows) do
        local path = file.path
        ---@cast path string  -- only placeholder rows lack a path, and they don't reach the fs calls below
        local virttext, hl
        if file.type == 'placeholder' then
            hl = 'DoraTree'
        else
            local file_type = file.type
            ---@cast file_type DoraFileType  -- 'placeholder' is handled above
            hl, virttext = icons.decoration(file_type, path)
            if file.type == 'directory' then
                -- The tree embeds the '/' in the row text itself
                -- (directory_suffix_col), not as virt text.
                virttext = nil
            elseif file.type == 'link' then
                local link = uv.fs_readlink(path)
                local target = link and fs.display_symlink_target(path, link) or nil
                virttext = virttext .. ' → ' .. (target and util.display_path(target) or '???')
            end
        end
        api.nvim_buf_set_extmark(buf, ns, i-1, 0, {
            end_col = #file.display_name,
            hl_group = hl,
            priority = 100,  -- Below vim.highlight.on_yank's default priority.
        })
        if virttext then
            api.nvim_buf_set_extmark(buf, ns, i-1, #file.display_name, {
                virt_text = {{virttext, 'DoraVirtText'}},
                virt_text_pos = 'overlay',
                hl_mode = 'combine',
            })
        end
        if file.tree_prefix_len > 0 then
            api.nvim_buf_set_extmark(buf, ns, i-1, 0, {
                end_col = file.tree_prefix_len,
                hl_group = 'DoraTree',
                priority = 10000,
            })
        end
        if file.icon_start_col then
            api.nvim_buf_set_extmark(buf, ns, i-1, file.icon_start_col, {
                end_col = file.icon_end_col,
                hl_group = file.icon_hl,
                priority = 10000,
            })
        end
        if file.directory_suffix_col then
            api.nvim_buf_set_extmark(buf, ns, i-1, file.directory_suffix_col, {
                end_col = #file.display_name,
                hl_group = 'DoraVirtText',
                priority = 10000,
            })
        end
        if file.filter_directory_start_col then
            api.nvim_buf_set_extmark(buf, ns, i-1, file.filter_directory_start_col, {
                end_col = file.filter_directory_end_col,
                hl_group = 'DoraFilterPath',
                priority = 10000,
            })
        end
        if file.filter_match_start_col then
            api.nvim_buf_set_extmark(buf, ns, i-1, file.filter_match_start_col, {
                end_col = file.filter_match_end_col,
                hl_group = 'DoraFilterMatch',
                priority = 10001,
            })
        end
        local mark_operation = path and state.marked_paths[path] or nil
        if mark_operation then
            local sign_hl = 'DoraCopy'
            if mark_operation == 'cut' then
                sign_hl = 'DoraCut'
            end
            api.nvim_buf_set_extmark(buf, ns, i-1, 0, {
                sign_text = '▌',
                sign_hl_group = sign_hl,
            })
            api.nvim_buf_set_extmark(buf, ns, i-1, file.name_start_col, {
                end_col = file.name_end_col,
                hl_group = sign_hl,
                priority = 10000,
            })
        end
    end
    M.update_tree_cursor_highlight(state)
    M.update_preview(state)
    -- Rewriting the buffer drops the window's topfill, which is what reveals the
    -- filter float's spacer line. Restore it here (a no-op unless scrolled to the
    -- top, where the spacer lives) so render callers don't each have to.
    if state.filter_editing or state.filter_window then
        M.keep_filter_spacer(state.win)
    end
end

---@param state DoraState
---@return DoraTreeRow?
function M.current_row(state)
    local row = api.nvim_win_get_cursor(0)[1]
    return state.rows and state.rows[row] or nil
end

---@param state DoraState
---@param path string
---@return boolean
function M.set_cursor_path(state, path)
    if vim.endswith(path, '/') then
        path = path:sub(1, -2)
    end
    -- Target the window showing state.buf, not the current window: when called
    -- from an async paste callback the user may have moved focus elsewhere, and
    -- a row index into state.rows is out of range for some other buffer.
    local win = api.nvim_get_current_win()
    if api.nvim_win_get_buf(win) ~= state.buf then
        win = vim.fn.bufwinid(state.buf)
    end
    for i, row in ipairs(state.rows or {}) do
        if row.path == path then
            if win ~= -1 and api.nvim_win_is_valid(win) then
                -- Keep the column so tree edits (folds, renames, pastes) don't
                -- yank the cursor back to the start of the line.
                local col = api.nvim_win_get_cursor(win)[2]
                api.nvim_win_set_cursor(win, {i, col})
                M.update_tree_cursor_highlight(state)
            end
            return true
        end
    end
    return false
end

---@param state DoraState
---@param pattern string?
---@param or_top? boolean
function M.set_cursor_pos(state, pattern, or_top)
    local line = or_top and 1 or nil
    if pattern then
        for i, row in ipairs(state.rows or {}) do
            -- The root row shares its name with the cwd's basename, which can
            -- shadow a same-named entry the pattern is actually after.
            if not row.is_root
                    and (row.display_name == pattern
                        or row.name == pattern
                        or row.name .. '/' == pattern) then
                line = i
                break
            end
        end
    end
    if line then
        api.nvim_win_set_cursor(0, {line, 0})
    end
    M.update_tree_cursor_highlight(state)
end

---@param state DoraState
---@param line integer
function M.move_to_line(state, line)
    if line < 1 or line > #state.rows then
        return
    end
    api.nvim_win_set_cursor(0, {line, 0})
    M.update_tree_cursor_highlight(state)
end

---@param win integer
function M.reveal_filter_spacer(win)
    if not api.nvim_win_is_valid(win) then
        return
    end
    api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        view.topline = 1
        view.topfill = 1
        vim.fn.winrestview(view)
    end)
end

---@param win integer
function M.scroll_filter_results_to_top(win)
    if not api.nvim_win_is_valid(win) then
        return
    end
    api.nvim_win_set_cursor(win, {1, 0})
    M.reveal_filter_spacer(win)
end

-- Re-show the spacer's filler line after a re-render cleared it, without
-- moving the user's scroll position. The spacer only exists above the first
-- line, so there is nothing to restore unless results are scrolled to the top.
---@param win integer
function M.keep_filter_spacer(win)
    if not api.nvim_win_is_valid(win) then
        return
    end
    api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        if view.topline == 1 then
            view.topfill = 1
            vim.fn.winrestview(view)
        end
    end)
end

return M
