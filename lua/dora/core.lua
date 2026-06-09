local fs = require'dora.fs'
local icons = require'dora.icons'
local bookmarks = require'dora.bookmarks'
local help_win = require'dora.help_win'
local delete_win = require'dora.delete_win'
local filter_win = require'dora.filter_win'
local info_win = require'dora.info_win'
local keymaps = require'dora.keymaps'
local prompt = require'dora.prompt'
local store = require'dora.store'
local sorter = require'dora.sort'
local util = require'dora.util'
local config = require'dora'.config

local api = vim.api
local uv = vim.loop

local M = {}

local PROMPT_WIDTH = 32
local PREVIOUS_DIRECTORY_VAR = 'dora_previous_directory'
local EXPANDED_DIRECTORIES_VAR = 'dora_expanded_directories'
local EMPTY_LABEL = '(empty)'
local NOT_PERMITTED_LABEL = '(not permitted)'
local TREE_VERTICAL = '│'

---@alias DoraCwdScope 'window'|'tab'|'global'
---@alias DoraPasteOperation 'copy'|'cut'

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

---@class DoraCwdRestore
---@field cwd string
---@field scope DoraCwdScope

---@class DoraState
---@field buf integer
---@field win integer
---@field origin_buf integer
---@field alt_buf? integer
---@field cwd string
---@field sync_local_cwd boolean
---@field cwd_restore? DoraCwdRestore
---@field ns integer
---@field cursor_ns integer
---@field show_hidden_files boolean
---@field sort_order DoraSortOrder
---@field hovered_files table<string, string>
---@field expanded_dirs table<string, true>
---@field tree_rows DoraTreeRow[]
---@field rows DoraTreeRow[]
---@field filter_text? string
---@field filter_preview? string
---@field filter_window? DoraFilterWindow
---@field filter_editing boolean
---@field marked_paths table<string, DoraPasteOperation>
---@field bookmarks DoraBookmarks

-- Render ----------------------------------------------------------------------

---@param msg any
---@return boolean
local function is_permission_error(msg)
    msg = tostring(msg)
    return msg:match('EPERM') ~= nil
        or msg:lower():match('operation not permitted') ~= nil
        or msg:lower():match('permission denied') ~= nil
end

---@param state DoraState
---@param dir string
---@return DoraFile[] files
---@return string? placeholder_label
local function visible_files(state, dir)
    local ok, all_files = pcall(fs.list, dir)
    if not ok then
        if is_permission_error(all_files) then
            return {}, NOT_PERMITTED_LABEL
        end
        util.warn(tostring(all_files))
        return {}, nil
    end
    local files = vim.tbl_filter(function(file)
        if state.show_hidden_files then
            return true
        else
            return not config.is_file_hidden(file, all_files, dir)
        end
    end, all_files)
    sorter.files(files, state.sort_order)
    return files, nil
end

---@param segments DoraTreeSegment[]
---@return DoraTreeSegment[]
local function copy_tree_segments(segments)
    local ret = {}
    for _, segment in ipairs(segments) do
        ret[#ret+1] = segment
    end
    return ret
end

---@param state DoraState
---@param path string
---@return string
local function relative_child_path(state, path)
    if state.cwd == util.sep then
        return path:sub(2)
    end
    return path:sub(#state.cwd + 2)
end

---@param state DoraState
---@return DoraTreeRow[]
local function build_tree_rows(state)
    local rows = {}
    local tree_indent = math.max(2, math.floor(config.tree_indent))
    local connector_suffix = string.rep('─', tree_indent - 2) .. ' '
    local tree_continuation = TREE_VERTICAL .. string.rep(' ', tree_indent - 1)
    local tree_spacer = string.rep(' ', tree_indent)

    ---@param dir string
    ---@param prefix string
    ---@param depth integer
    ---@param continuation_segments DoraTreeSegment[]
    local function add_dir(dir, prefix, depth, continuation_segments)
        local files, placeholder_label = visible_files(state, dir)
        if depth > 0 and (#files == 0 or placeholder_label) then
            placeholder_label = placeholder_label or EMPTY_LABEL
            local tree_prefix = prefix .. '└' .. connector_suffix
            rows[#rows+1] = {
                name = placeholder_label,
                display_name = tree_prefix .. placeholder_label,
                path = nil,
                parent_path = dir,
                type = 'placeholder',
                depth = depth,
                tree_prefix_len = #tree_prefix,
                tree_continuation_segments = copy_tree_segments(continuation_segments),
                tree_connector_start_col = #prefix,
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
                child_continuation_segments = copy_tree_segments(continuation_segments)
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
            local icon, icon_hl = icons.get(config.icons, file, path)
            local icon_prefix = icon and icon .. ' ' or ''
            local display_name = tree_prefix .. icon_prefix .. file.name
            local directory_suffix_col
            if file.type == 'directory' then
                directory_suffix_col = #display_name
                display_name = display_name .. util.sep
            end
            rows[#rows+1] = {
                name = file.name,
                display_name = display_name,
                path = path,
                parent_path = dir,
                type = file.type,
                depth = depth,
                tree_prefix_len = #tree_prefix,
                tree_continuation_segments = copy_tree_segments(continuation_segments),
                tree_connector_start_col = depth > 0 and #prefix or nil,
                icon = icon,
                icon_start_col = icon and #tree_prefix or nil,
                icon_end_col = icon and #tree_prefix + #icon or nil,
                icon_hl = icon_hl or 'DoraIcon',
                name_start_col = #tree_prefix + #icon_prefix,
                name_end_col = #tree_prefix + #icon_prefix + #file.name,
                directory_suffix_col = directory_suffix_col,
            }
            if file.type == 'directory' and state.expanded_dirs[path] then
                add_dir(path, child_prefix, depth + 1, child_continuation_segments)
            end
        end
    end

    add_dir(state.cwd, '', 0, {})
    return rows
end

---@param state DoraState
---@return string?
local function active_filter(state)
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
    local filter = active_filter(state)
    if not filter then
        return tree_rows
    end

    local rows = {}
    local needle = vim.fn.tolower(filter)
    for _, row in ipairs(tree_rows) do
        local match_index = vim.fn.stridx(vim.fn.tolower(row.name), needle)
        if row.path and match_index >= 0 then
            local relative_path = relative_child_path(state, row.path)
            local icon_prefix = row.icon and row.icon .. ' ' or ''
            local display_name = icon_prefix .. relative_path
            local basename_start_col = #icon_prefix + #relative_path - #row.name
            local directory_suffix_col
            if row.type == 'directory' then
                directory_suffix_col = #display_name
                display_name = display_name .. util.sep
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
                filter_match_start_col = basename_start_col + match_index,
                filter_match_end_col = basename_start_col + match_index + #filter,
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
local function update_tree_cursor_highlight(state)
    local buf, ns = state.buf, state.cursor_ns
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if active_filter(state) or api.nvim_get_current_buf() ~= buf then
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


---@param state DoraState
local function render(state)
    local buf, ns = state.buf, state.ns
    prune_deleted_marked_paths(state)
    local tree_rows = build_tree_rows(state)
    local rows = build_filtered_rows(state, tree_rows)
    state.tree_rows = tree_rows
    state.rows = rows
    util.set_lines(buf, vim.tbl_map(function(f)
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
        local virttext, hl
        if file.type == 'directory' then
            virttext, hl = nil, 'DoraDirectory'
        elseif file.type == 'placeholder' then
            virttext, hl = nil, 'DoraTree'
        elseif file.type == 'link' then
            local link = uv.fs_readlink(path)
            virttext = '@ → ' .. (link and util.display_path(link) or '???')
            hl = 'DoraSymlink'
        elseif uv.fs_access(path, 'X') then
            virttext, hl = '*', 'DoraExecutable'
        else
            virttext, hl = nil, 'DoraFile'
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
    update_tree_cursor_highlight(state)
end

---@param state DoraState
---@return DoraTreeRow?
local function current_row(state)
    local row = api.nvim_win_get_cursor(0)[1]
    return state.rows and state.rows[row] or nil
end

---@param state DoraState
---@param path string
---@return boolean
local function set_cursor_path(state, path)
    if vim.endswith(path, util.sep) then
        path = path:sub(1, -2)
    end
    for i, row in ipairs(state.rows or {}) do
        if row.path == path then
            api.nvim_win_set_cursor(0, {i, 0})
            update_tree_cursor_highlight(state)
            return true
        end
    end
    return false
end

---@param state DoraState
---@param pattern string?
---@param or_top? boolean
local function set_cursor_pos(state, pattern, or_top)
    local line = or_top and 1 or nil
    if pattern then
        for i, row in ipairs(state.rows or {}) do
            if row.display_name == pattern
                    or row.name == pattern
                    or row.name .. util.sep == pattern then
                line = i
                break
            end
        end
    end
    if line then
        api.nvim_win_set_cursor(0, {line, 0})
    end
    update_tree_cursor_highlight(state)
end

---@param state DoraState
---@param row DoraTreeRow?
---@param under_directory? boolean
---@return string?
local function create_parent_default(state, row, under_directory)
    if not row or not row.path then
        return nil
    end
    if under_directory and row.type == 'directory' then
        return relative_child_path(state, row.path) .. util.sep
    end
    local parent = fs.get_parent_dir(row.path)
    if parent == state.cwd then
        return nil
    end
    return relative_child_path(state, parent) .. util.sep
end

---@param state DoraState
---@param row DoraTreeRow?
---@return string?
---@return integer?
local function collapse_target(state, row)
    if not row or not row.path then
        return nil
    end
    if row.type == 'directory' then
        return row.path, row.depth
    end
    local parent = fs.get_parent_dir(row.path)
    if parent == state.cwd then
        return nil
    end
    for _, candidate in ipairs(state.tree_rows or {}) do
        if candidate.path == parent then
            return parent, candidate.depth
        end
    end
end

---@param path string
---@param prefix string
---@return integer?
local function relative_dir_depth(path, prefix)
    if not vim.startswith(path, prefix .. util.sep) then
        return nil
    end
    local rest = path:sub(#prefix + 2)
    return select(2, rest:gsub(util.sep, '')) + 1
end

---@param row DoraTreeRow
---@param path string
---@return boolean
local function row_under_path(row, path)
    if row.path then
        return row.path == path or vim.startswith(row.path, path .. util.sep)
    end
    return row.parent_path == path or vim.startswith(row.parent_path or '', path .. util.sep)
end

---@param state DoraState
---@param line integer
local function move_to_line(state, line)
    if line < 1 or line > #state.rows then
        return
    end
    api.nvim_win_set_cursor(0, {line, 0})
    update_tree_cursor_highlight(state)
end

---@param state DoraState
---@param line integer
---@param step integer
---@return integer?
local function sibling_line(state, line, step)
    local row = state.rows[line]
    if not row or not row.path then
        return nil
    end
    if active_filter(state) then
        local next_line = line + step
        if next_line < 1 then
            return #state.rows
        elseif next_line > #state.rows then
            return 1
        end
        return state.rows[next_line].path and next_line or nil
    end
    for i = line + step, step > 0 and #state.rows or 1, step do
        if state.rows[i].parent_path == row.parent_path then
            return i
        end
    end
    for i = step > 0 and 1 or #state.rows, line - step, step do
        if state.rows[i].parent_path == row.parent_path then
            return i
        end
    end
end

---@param state DoraState
---@param line integer
---@param step integer
---@return integer?
local function sibling_edge_line(state, line, step)
    local row = state.rows[line]
    if not row or not row.path then
        return nil
    end
    if active_filter(state) then
        return step > 0 and #state.rows or 1
    end
    for i = step > 0 and #state.rows or 1, line, -step do
        if state.rows[i].parent_path == row.parent_path then
            return i
        end
    end
end

---@param state DoraState
local function move_to_next_sibling(state)
    local line = api.nvim_win_get_cursor(0)[1]
    local row = state.rows[line]
    if not row or not row.parent_path then
        return
    end
    local next_line = sibling_line(state, line, 1)
    if next_line then
        move_to_line(state, next_line)
    end
end

---@param state DoraState
local function move_to_prev_sibling(state)
    local line = api.nvim_win_get_cursor(0)[1]
    local row = state.rows[line]
    if not row or not row.parent_path then
        return
    end
    local prev_line = sibling_line(state, line, -1)
    if prev_line then
        move_to_line(state, prev_line)
    end
end

---@param state DoraState
local function move_to_last_sibling(state)
    local line = api.nvim_win_get_cursor(0)[1]
    local row = state.rows[line]
    if not row or not row.parent_path then
        return
    end
    local last_line = sibling_edge_line(state, line, 1)
    if last_line then
        move_to_line(state, last_line)
    end
end

---@param state DoraState
local function move_to_first_sibling(state)
    local line = api.nvim_win_get_cursor(0)[1]
    local row = state.rows[line]
    if not row or not row.parent_path then
        return
    end
    local first_line = sibling_edge_line(state, line, -1)
    if first_line then
        move_to_line(state, first_line)
    end
end

---@class DoraMarkedPathEntry
---@field path string
---@field operation DoraPasteOperation

---@param state DoraState
---@return DoraMarkedPathEntry[]
local function marked_path_entries(state)
    local entries = {}
    for path, operation in pairs(state.marked_paths) do
        entries[#entries+1] = {path = path, operation = operation}
    end
    table.sort(entries, function(a, b) return a.path < b.path end)
    return entries
end

---@param state DoraState
---@return string? path
---@return string? error
local function current_path(state)
    local row = current_row(state)
    if not row then
        return nil, 'Empty filename'
    end
    if not row.path then
        return nil, 'No file selected'
    end
    return row.path
end

---@param row DoraTreeRow?
---@return {win: integer, line: integer, col: integer}?
local function current_name_anchor(row)
    if not row or not row.name_start_col then
        return nil
    end
    local win = api.nvim_get_current_win()
    return {
        win = win,
        line = api.nvim_win_get_cursor(win)[1],
        col = row.name_start_col,
    }
end

---@return integer start_line
---@return integer end_line
local function visual_line_range()
    local mode = api.nvim_get_mode().mode
    local in_visual = mode == 'v' or mode == 'V' or mode == '\022'
    local start_line = in_visual and api.nvim_win_get_cursor(0)[1] or vim.fn.line("'<")
    local end_line = in_visual and vim.fn.getpos('v')[2] or vim.fn.line("'>")
    if start_line > end_line then
        start_line, end_line = end_line, start_line
    end
    return start_line, end_line
end

---@param path string
---@param selected string[]
---@return boolean
local function path_under_selected(path, selected)
    for _, selected_path in ipairs(selected) do
        if path == selected_path or vim.startswith(path, selected_path .. util.sep) then
            return true
        end
    end
    return false
end

---@param state DoraState
---@return string[]? paths
---@return string? error
local function visual_paths(state)
    local start_line, end_line = visual_line_range()
    local paths = {}
    for line = start_line, end_line do
        local row = state.rows and state.rows[line] or nil
        if row and row.path and not path_under_selected(row.path, paths) then
            paths[#paths+1] = row.path
        end
    end
    if #paths == 0 then
        return nil, 'No files selected'
    end
    return paths, nil
end

---@param state DoraState
local function clear_marked_paths(state)
    state.marked_paths = {}
end

---@param state DoraState
---@param path string
local function clear_marked_paths_under(state, path)
    local prefix = path .. util.sep
    for marked_path in pairs(state.marked_paths) do
        if marked_path == path or vim.startswith(marked_path, prefix) then
            state.marked_paths[marked_path] = nil
        end
    end
end

---@param state DoraState
---@param old_path string
---@param new_path string
local function rename_marked_paths_under(state, old_path, new_path)
    local old_prefix = old_path .. util.sep
    local updated = {}
    for marked_path, operation in pairs(state.marked_paths) do
        if marked_path == old_path then
            updated[new_path] = operation
            state.marked_paths[marked_path] = nil
        elseif vim.startswith(marked_path, old_prefix) then
            updated[new_path .. marked_path:sub(#old_path + 1)] = operation
            state.marked_paths[marked_path] = nil
        end
    end
    for marked_path, operation in pairs(updated) do
        state.marked_paths[marked_path] = operation
    end
end

---@param state DoraState
---@param path string
---@return boolean changed
local function expand_next_level(state, path)
    if not state.expanded_dirs[path] then
        state.expanded_dirs[path] = true
        return true
    end

    local frontier = {}
    local frontier_depth

    ---@param dir string
    ---@param depth integer
    local function visit(dir, depth)
        for _, file in ipairs(visible_files(state, dir)) do
            if file.type == 'directory' then
                local child_path = vim.fs.joinpath(dir, file.name)
                if state.expanded_dirs[child_path] then
                    visit(child_path, depth + 1)
                elseif not frontier_depth or depth < frontier_depth then
                    frontier_depth = depth
                    frontier = {child_path}
                elseif depth == frontier_depth then
                    frontier[#frontier+1] = child_path
                end
            end
        end
    end

    visit(path, 1)
    for _, dir in ipairs(frontier) do
        state.expanded_dirs[dir] = true
    end
    return #frontier > 0
end

---@param state DoraState
---@param path string
---@return boolean changed
local function expand_all_dirs(state, path)
    local changed = not state.expanded_dirs[path]
    state.expanded_dirs[path] = true
    for _, file in ipairs(visible_files(state, path)) do
        if file.type == 'directory' then
            local child_path = vim.fs.joinpath(path, file.name)
            if expand_all_dirs(state, child_path) then
                changed = true
            end
        end
    end
    return changed
end

---@param state DoraState
---@param path string
---@return boolean changed
local function clear_expanded_subtree(state, path)
    local prefix = path .. util.sep
    local changed = false
    for expanded_path in pairs(state.expanded_dirs) do
        if expanded_path == path or vim.startswith(expanded_path, prefix) then
            state.expanded_dirs[expanded_path] = nil
            changed = true
        end
    end
    return changed
end

---@param state DoraState
---@param path string
---@param target_depth integer
---@return boolean changed
local function collapse_deepest_visible_dirs(state, path, target_depth)
    local max_depth = 0
    for _, row in ipairs(state.tree_rows or {}) do
        if row_under_path(row, path) then
            max_depth = math.max(max_depth, row.depth - target_depth)
        end
    end
    if max_depth < 1 then
        return false
    end

    local collapse_depth = max_depth - 1
    local collapsed = {}
    if collapse_depth == 0 then
        if state.expanded_dirs[path] then
            collapsed[#collapsed+1] = path
        end
    else
        for expanded_path in pairs(state.expanded_dirs) do
            if relative_dir_depth(expanded_path, path) == collapse_depth then
                collapsed[#collapsed+1] = expanded_path
            end
        end
    end
    for _, expanded_path in ipairs(collapsed) do
        state.expanded_dirs[expanded_path] = nil
    end
    return #collapsed > 0
end

---@param state DoraState
---@param old_path string
---@param new_path string
local function rename_expanded_subtree(state, old_path, new_path)
    local old_prefix = old_path .. util.sep
    local updated = {}
    for expanded_path in pairs(state.expanded_dirs) do
        if expanded_path == old_path then
            updated[new_path] = true
            state.expanded_dirs[expanded_path] = nil
        elseif vim.startswith(expanded_path, old_prefix) then
            updated[new_path .. expanded_path:sub(#old_path + 1)] = true
            state.expanded_dirs[expanded_path] = nil
        end
    end
    for expanded_path in pairs(updated) do
        state.expanded_dirs[expanded_path] = true
    end
end

---@param buf integer
local function setup_autocmds(buf)
    local group = api.nvim_create_augroup('dora.cursor.' .. buf, {clear=true})
    api.nvim_create_autocmd({'BufEnter', 'CursorMoved', 'CursorMovedI'}, {
        group = group,
        buffer = buf,
        callback = function(args)
            local ok, state = pcall(store.get, args.buf)
            if ok then
                update_tree_cursor_highlight(state)
            end
        end,
    })
end

---@param state DoraState
local function close_filter(state)
    state.filter_text = nil
    state.filter_preview = nil
    state.filter_editing = false
    local filter_window = state.filter_window
    state.filter_window = nil
    if filter_window then
        filter_window:close()
    end
end

---@param state DoraState
local function save_previous_directory(state)
    if api.nvim_win_is_valid(state.win) and state.bookmarks.previous_directory then
        api.nvim_win_set_var(state.win, PREVIOUS_DIRECTORY_VAR, state.bookmarks.previous_directory)
    end
end

---@param state DoraState
local function save_expanded_directories(state)
    if not api.nvim_win_is_valid(state.win) then
        return
    end
    local directories = vim.tbl_keys(state.expanded_dirs)
    table.sort(directories)
    api.nvim_win_set_var(state.win, EXPANDED_DIRECTORIES_VAR, directories)
end

---@param win integer
---@return string?
local function load_previous_directory(win)
    local ok, directory = pcall(api.nvim_win_get_var, win, PREVIOUS_DIRECTORY_VAR)
    return ok and type(directory) == 'string' and directory or nil
end

---@param win integer
---@return table<string, true>
local function load_expanded_directories(win)
    local ok, directories = pcall(api.nvim_win_get_var, win, EXPANDED_DIRECTORIES_VAR)
    if not ok or type(directories) ~= 'table' then
        return {}
    end
    local expanded_dirs = {}
    for _, directory in ipairs(directories) do
        if type(directory) == 'string' then
            expanded_dirs[directory] = true
        end
    end
    return expanded_dirs
end

---@param state DoraState
local function cleanup(state)
    close_filter(state)
    save_previous_directory(state)
    save_expanded_directories(state)
    api.nvim_buf_delete(state.buf, {force=true})
    store.remove(state.buf)
end

---@return DoraCwdScope
local function get_cwd_scope()
    if vim.fn.haslocaldir(0, 0) == 1 then
        return 'window'
    elseif vim.fn.haslocaldir(-1, 0) == 1 then
        return 'tab'
    else
        return 'global'
    end
end

---@return DoraCwdRestore
local function save_cwd()
    return {
        cwd = vim.fn.getcwd(0, 0),
        scope = get_cwd_scope(),
    }
end

---@param scope DoraCwdScope
---@return 'lcd'|'tcd'|'cd'
local function cd_cmd(scope)
    return ({
        window = 'lcd',
        tab = 'tcd',
        global = 'cd',
    })[scope]
end

---@param scope DoraCwdScope
---@param cwd string
local function set_cwd(scope, cwd)
    vim.cmd(('sil %s %s'):format(cd_cmd(scope), vim.fn.fnameescape(cwd)))
end

---@param state DoraState
local function sync_local_cwd(state)
    if state.sync_local_cwd then
        local ok, msg = pcall(set_cwd, 'window', state.cwd)
        if not ok then
            util.warn(msg)
        end
    end
end

---@param state DoraState
local function restore_cwd(state)
    if state.cwd_restore then
        local restore = assert(state.cwd_restore)
        local ok, msg = pcall(set_cwd, restore.scope, restore.cwd)
        state.cwd_restore = nil
        if not ok then
            util.warn(msg)
        end
    end
end

---@param state DoraState
local function remember_hovered_file(state)
    local row = current_row(state)
    if row then
        state.hovered_files[state.cwd] = row.name
    end
end

---@param state DoraState
---@param path string
---@param cursor_pattern? string
---@param or_top? boolean
local function change_cwd(state, path, cursor_pattern, or_top)
    if state.cwd ~= path then
        bookmarks.record_previous_directory(state.bookmarks, state.cwd)
        close_filter(state)
    end
    state.cwd = path
    render(state)
    util.update_buf_name(state.cwd)
    sync_local_cwd(state)
    set_cursor_pos(state, cursor_pattern, or_top)
end

function M.quit()
    local state = store.get()
    restore_cwd(state)
    if state.alt_buf then
        util.set_current_buf(state.alt_buf)
    end
    util.set_current_buf(state.origin_buf)
    cleanup(state)
end

function M.up_dir()
    local state = store.get()
    local cwd = state.cwd
    local parent_dir = fs.get_parent_dir(state.cwd)
    if parent_dir == cwd then
        return
    end
    remember_hovered_file(state)
    state.expanded_dirs[cwd] = true
    change_cwd(state, parent_dir, fs.basename(cwd), --[[or_top]]true)
end

function M.home_dir()
    local home = os.getenv'HOME'
    if not home or home == '' then
        util.err('$HOME is not set')
        return
    end
    local path, msg = uv.fs_realpath(home)
    if not path then
        util.err(msg)
        return
    end
    if not fs.is_dir(path) then
        util.err(('%q is not a directory'):format(home))
        return
    end
    local state = store.get()
    remember_hovered_file(state)
    change_cwd(state, path, state.hovered_files[path], --[[or_top]]true)
end

function M.parent_dir()
    local state = store.get()
    local row = current_row(state)
    if not row or not row.parent_path then
        return
    end
    set_cursor_path(state, row.parent_path)
end

function M.next_sibling()
    move_to_next_sibling(store.get())
end

function M.prev_sibling()
    move_to_prev_sibling(store.get())
end

function M.last_sibling()
    move_to_last_sibling(store.get())
end

function M.first_sibling()
    move_to_first_sibling(store.get())
end

function M.help()
    local ok, state = pcall(store.get)
    help_win.open(config, ok and bookmarks.help_rows(state.bookmarks) or nil)
end

---@param win integer
local function scroll_filter_results_to_top(win)
    if not api.nvim_win_is_valid(win) then
        return
    end
    api.nvim_win_set_cursor(win, {1, 0})
    api.nvim_win_call(win, function()
        vim.cmd'normal! zt'
        local view = vim.fn.winsaveview()
        view.topfill = 1
        vim.fn.winrestview(view)
    end)
end

---@param win integer
local function reveal_filter_spacer(win)
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

function M.filter()
    local state = store.get()
    local row = current_row(state)
    local cursor_path = row and row.path or nil
    local initial_text = state.filter_text or ''
    local origin_win = api.nvim_get_current_win()
    state.filter_preview = initial_text
    state.filter_editing = true
    render(state)
    scroll_filter_results_to_top(origin_win)

    local opts = {
        origin_win = origin_win,
        initial_text = initial_text,
        on_change = function(text)
            state.filter_preview = text
            render(state)
            scroll_filter_results_to_top(origin_win)
        end,
        on_confirm = function(text)
            state.filter_preview = nil
            state.filter_text = text ~= '' and text or nil
            state.filter_editing = false
            if not state.filter_text then
                state.filter_window = nil
            end
            render(state)
            set_cursor_pos(state, nil, --[[or_top]]true)
            if state.filter_text then
                scroll_filter_results_to_top(origin_win)
            end
            return state.filter_text ~= nil
        end,
        on_cancel = function()
            state.filter_preview = nil
            state.filter_editing = false
            if not state.filter_text then
                state.filter_window = nil
            end
            render(state)
            if not cursor_path or not set_cursor_path(state, cursor_path) then
                set_cursor_pos(state, nil, --[[or_top]]true)
            end
            if state.filter_text then
                reveal_filter_spacer(origin_win)
            end
            return state.filter_text
        end,
        on_close = function()
            state.filter_window = nil
            state.filter_preview = nil
            state.filter_editing = false
            if api.nvim_buf_is_valid(state.buf) then
                render(state)
                if not cursor_path or not set_cursor_path(state, cursor_path) then
                    set_cursor_pos(state, nil, --[[or_top]]true)
                end
            end
        end,
    }

    if state.filter_window then
        state.filter_window:edit(opts)
    else
        state.filter_window = filter_win.open(opts)
    end
end

function M.clear_filter()
    local state = store.get()
    local row = current_row(state)
    local cursor_path = row and row.path or nil
    close_filter(state)
    render(state)
    if not cursor_path or not set_cursor_path(state, cursor_path) then
        set_cursor_pos(state, nil, --[[or_top]]true)
    end
end

function M.set_bookmark()
    local state = store.get()
    bookmarks.set_current_directory(state.bookmarks, state.cwd)
end

function M.jump_bookmark()
    local state = store.get()
    local path = bookmarks.read_jump_directory(state.bookmarks)
    if not path then
        return
    end
    local realpath, msg = uv.fs_realpath(path)
    if not realpath then
        util.err(msg)
        return
    end
    if not fs.is_dir(realpath) then
        util.err(('%q is not a directory'):format(path))
        return
    end
    remember_hovered_file(state)
    change_cwd(state, realpath, state.hovered_files[realpath], --[[or_top]]true)
end

function M.info()
    local state = store.get()
    local row = current_row(state)
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    info_win.open(path, current_name_anchor(row))
end

---@param cmd? DoraOpenCommand
function M.open(cmd)
    local state = store.get()
    local row = current_row(state)
    if not row or not row.path then
        return
    end
    -- fs_realpath also checks file existence
    local path, msg = uv.fs_realpath(row.path)
    if not path then
        util.err(msg)
    else
        if fs.is_dir(path) then
            if cmd then
                vim.cmd(cmd .. ' ' .. vim.fn.fnameescape(path))
            else
                remember_hovered_file(state)
                change_cwd(state, path, state.hovered_files[path], --[[or_top]]true)
            end
        else
            restore_cwd(state)
            util.set_current_buf(state.origin_buf)  -- update the altfile
            vim.cmd((cmd or 'edit') .. ' ' .. vim.fn.fnameescape(path))
            cleanup(state)
        end
    end
end

---@param cmd DoraOpenCommand
local function open_keep(cmd)
    local state = store.get()
    local row = current_row(state)
    if not row or not row.path then
        return
    end
    -- fs_realpath also checks file existence
    local path, msg = uv.fs_realpath(row.path)
    if not path then
        util.err(msg)
        return
    end
    local dora_win = api.nvim_get_current_win()
    vim.cmd(cmd .. ' ' .. vim.fn.fnameescape(path))
    if api.nvim_win_is_valid(dora_win) then
        api.nvim_set_current_win(dora_win)
    end
end

function M.open_split()
    M.open('split')
end

function M.open_vsplit()
    M.open('vsplit')
end

function M.open_tab()
    M.open('tabedit')
end

function M.open_split_keep()
    open_keep('split')
end

function M.open_vsplit_keep()
    open_keep('vsplit')
end

function M.open_tab_keep()
    open_keep('tabedit')
end

function M.follow_symlink()
    local state = store.get()
    local row = current_row(state)
    if not row or row.type ~= 'link' or not row.path then
        return
    end
    -- fs_realpath resolves the symlink and checks target existence.
    local path, msg = uv.fs_realpath(row.path)
    if not path then
        util.err(msg)
        return
    end
    if fs.is_dir(path) then
        remember_hovered_file(state)
        change_cwd(state, path, state.hovered_files[path], --[[or_top]]true)
        return
    end
    restore_cwd(state)
    util.set_current_buf(state.origin_buf)  -- update the altfile
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    cleanup(state)
end

function M.open_external()
    local state = store.get()
    local row = current_row(state)
    if not row or not row.path or not fs.exists(row.path) then
        return
    end
    local ok, err = pcall(vim.ui.open, row.path)
    if ok then
        util.info('Opening ' .. row.name)
    else
        util.err('Could not open externally: ' .. tostring(err))
    end
end

function M.expand()
    local state = store.get()
    local row = current_row(state)
    if not row or not row.path or row.type ~= 'directory' then
        return
    end
    local changed = expand_next_level(state, row.path)
    if changed then
        render(state)
        set_cursor_pos(state, row.display_name)
    end
end

function M.expand_recursive()
    local state = store.get()
    local row = current_row(state)
    if not row or not row.path or row.type ~= 'directory' then
        return
    end
    local changed = expand_all_dirs(state, row.path)
    if changed then
        render(state)
        set_cursor_pos(state, row.display_name)
    end
end

function M.collapse()
    local state = store.get()
    local row = current_row(state)
    local path, target_depth = collapse_target(state, row)
    if not path or not target_depth then
        return
    end
    local changed = collapse_deepest_visible_dirs(state, path, target_depth)
    if changed then
        render(state)
        if not set_cursor_path(state, row.path) then
            set_cursor_path(state, path)
        end
    end
end

function M.collapse_recursive()
    local state = store.get()
    local row = current_row(state)
    if not row or not row.path or row.type ~= 'directory' then
        return
    end
    local changed = clear_expanded_subtree(state, row.path)
    if changed then
        render(state)
        set_cursor_pos(state, row.display_name)
    end
end

function M.clear_marks()
    M.clear_paste_operation()
end

---@param operation DoraPasteOperation
local function toggle_marked_path(operation)
    local state = store.get()
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    if state.marked_paths[path] == operation then
        state.marked_paths[path] = nil
    else
        state.marked_paths[path] = operation
    end
    render(state)
end

function M.cut()
    toggle_marked_path('cut')
end

function M.copy()
    toggle_marked_path('copy')
end

function M.clear_paste_operation()
    local state = store.get()
    clear_marked_paths(state)
    render(state)
end

---@param state DoraState
---@param entries DoraMarkedPathEntry[]
---@param dest_dir string
---@param dest_path string
local function paste_entries(state, entries, dest_dir, dest_path)
    local ok, msg = pcall(function()
        assert(fs.is_dir(dest_dir), ('%q is not a directory'):format(dest_dir))
        for _, entry in ipairs(entries) do
            fs.copy_or_move(entry.operation == 'cut', entry.path, dest_dir, state.cwd)
        end
    end)
    if not ok then
        util.err(msg)
        return
    end
    clear_marked_paths(state)
    render(state)
    set_cursor_path(state, dest_path)
end

---@param state DoraState
---@param row DoraTreeRow
---@param dest_dir string
---@param entries DoraMarkedPathEntry[]
local function paste_to_directory(state, row, dest_dir, entries)
    local dest_path = vim.fs.joinpath(dest_dir, fs.basename(entries[1].path))
    local overwrite_paths = {}
    local seen_overwrite_paths = {}
    local ok, msg = pcall(function()
        assert(fs.is_dir(dest_dir), ('%q is not a directory'):format(dest_dir))
        for _, entry in ipairs(entries) do
            local entry_dest = vim.fs.joinpath(dest_dir, fs.basename(entry.path))
            local dest_stat = uv.fs_lstat(entry_dest)
            if dest_stat and dest_stat.type ~= 'directory' and not seen_overwrite_paths[entry_dest] then
                overwrite_paths[#overwrite_paths+1] = entry_dest
                seen_overwrite_paths[entry_dest] = true
            end
        end
    end)
    if not ok then
        util.err(msg)
        return
    end
    if #overwrite_paths == 0 then
        paste_entries(state, entries, dest_dir, dest_path)
        return
    end
    delete_win.delete(overwrite_paths, state.cwd, function(confirmed)
        if confirmed then
            paste_entries(state, entries, dest_dir, dest_path)
        end
    end, {
        anchor = current_name_anchor(row),
        action = 'Overwrite',
    })
end

function M.paste()
    local state = store.get()
    local entries = marked_path_entries(state)
    if #entries == 0 then
        util.err('Nothing to paste')
        return
    end
    local row = current_row(state)
    if not row or row.type ~= 'directory' or not row.path then
        util.err('No directory selected')
        return
    end
    paste_to_directory(state, row, row.path, entries)
end

function M.paste_parent()
    local state = store.get()
    local entries = marked_path_entries(state)
    if #entries == 0 then
        util.err('Nothing to paste')
        return
    end
    local row = current_row(state)
    if not row or not row.parent_path then
        util.err('No paste destination')
        return
    end
    paste_to_directory(state, row, row.parent_path, entries)
end

---@param value string
---@param reg? string
---@param message string
local function copy_value(value, reg, message)
    -- Trigger a real yank so TextYankPost autocmds see vim.v.event.
    pcall(vim.cmd, reg == '+' and [[normal! "+yy]] or [[normal! yy]])
    local ok, err = pcall(vim.fn.setreg, reg or '"', value, 'c')
    if not ok then
        util.err(err)
        return
    end
    util.info(('%s: %s'):format(message, value))
end

---@param reg? string
function M.yank_file_path(reg)
    local state = store.get()
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    copy_value(path, reg, reg == '+' and 'Yanked file path to clipboard' or 'Yanked file path')
end

function M.yank_file_path_clipboard()
    M.yank_file_path('+')
end

---@param reg? string
function M.yank_dir_path(reg)
    local state = store.get()
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    copy_value(fs.get_parent_dir(path), reg, reg == '+' and 'Yanked directory path to clipboard' or 'Yanked directory path')
end

function M.yank_dir_path_clipboard()
    M.yank_dir_path('+')
end

---@param reg? string
function M.yank_filename(reg)
    local state = store.get()
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    copy_value(fs.basename(path), reg, reg == '+' and 'Yanked filename to clipboard' or 'Yanked filename')
end

function M.yank_filename_clipboard()
    M.yank_filename('+')
end

---@param reg? string
function M.yank_basename(reg)
    local state = store.get()
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    local filename = fs.basename(path)
    local message = reg == '+' and 'Yanked basename to clipboard' or 'Yanked basename'
    copy_value(vim.fn.fnamemodify(filename, ':r'), reg, message)
end

function M.yank_basename_clipboard()
    M.yank_basename('+')
end

---@param state DoraState
---@param paths string[]
---@param operation fun(path: string)
---@param action string
---@param anchor? {win: integer, line: integer, col: integer}
local function remove_paths(state, paths, operation, action, anchor)
    delete_win.delete(paths, state.cwd, function(confirmed)
        if not confirmed then
            return
        end
        local removed_paths = {}
        for _, path in ipairs(paths) do
            local ok, result = pcall(operation, path)
            if not ok then
                if #removed_paths > 0 then
                    for _, removed_path in ipairs(removed_paths) do
                        clear_marked_paths_under(state, removed_path)
                    end
                    render(state)
                end
                util.err(result)
                return
            end
            if result ~= false then
                removed_paths[#removed_paths+1] = path
            end
        end
        if #removed_paths > 0 then
            for _, removed_path in ipairs(removed_paths) do
                clear_marked_paths_under(state, removed_path)
            end
            render(state)
        end
    end, {
        anchor = anchor,
        action = action,
    })
end

---@param operation fun(path: string)
---@param action string
local function remove_path(operation, action)
    local state = store.get()
    local row = current_row(state)
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    remove_paths(state, {path}, operation, action, current_name_anchor(row))
end

---@param operation fun(path: string)
---@param action string
local function remove_visual_paths(operation, action)
    local state = store.get()
    local row = current_row(state)
    local paths, msg = visual_paths(state)
    if not paths then
        util.err(msg)
        return
    end
    remove_paths(state, paths, operation, action, current_name_anchor(row))
end

function M.trash()
    remove_path(fs.trash, 'Trash')
end

function M.delete()
    remove_path(fs.delete, 'Delete')
end

function M.trash_visual()
    remove_visual_paths(fs.trash, 'Trash')
end

function M.delete_visual()
    remove_visual_paths(fs.delete, 'Delete')
end

function M.rename()
    local state = store.get()
    local row = current_row(state)
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    prompt.input({
        prompt = 'Rename to',
        cwd = fs.get_parent_dir(path),
        initial_prompt = fs.basename(path),
        width = PROMPT_WIDTH,
        anchor = current_name_anchor(row),
        validate = function(input)
            return fs.validate_rename(input, path)
        end,
    }, function(input, dest)
        if not input then
            return
        end
        local ok, err = pcall(fs.copy_or_move, true, path, dest, state.cwd)
        if not ok then
            util.err(err)
            return
        end
        rename_expanded_subtree(state, path, dest)
        rename_marked_paths_under(state, path, dest)
        render(state)
        set_cursor_path(state, dest)
    end)
end

---@param under_directory? boolean
local function create(under_directory)
    local state = store.get()
    local row = current_row(state)
    prompt.input({
        prompt = 'Add file or folder',
        cwd = state.cwd,
        width = PROMPT_WIDTH,
        initial_prompt = create_parent_default(state, row, under_directory),
        anchor = current_name_anchor(row),
        validate = function(input)
            return fs.validate_create(input, state.cwd)
        end,
    }, function(input, path)
        if input then
            local ok, msg
            if vim.endswith(input, util.sep) then
                ok, msg = pcall(fs.create_dir, path)
            else
                ok, msg = pcall(fs.create_file, path)
            end
            if not ok then
                util.err(msg)
            else
                local cursor_path = fs.strip_trailing_sep(path)
                render(state)
                while cursor_path ~= state.cwd and not set_cursor_path(state, cursor_path) do
                    cursor_path = fs.parent_dir(cursor_path)
                end
                if cursor_path ~= state.cwd and fs.is_dir(cursor_path) and expand_all_dirs(state, cursor_path) then
                    render(state)
                    set_cursor_path(state, cursor_path)
                end
            end
        end
    end)
end

function M.create()
    create(false)
end

function M.create_under()
    create(true)
end

function M.toggle_hidden_files()
    local state = store.get()
    local row = current_row(state)
    local hovered_file = row and row.display_name or nil
    state.show_hidden_files = not state.show_hidden_files
    render(state)
    set_cursor_pos(state, hovered_file)
end

function M.shell_cmd()
    local state = store.get()
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    prompt.input({
        prompt = 'Shell command',
        cwd = state.cwd,
        width = PROMPT_WIDTH,
        anchor = current_name_anchor(current_row(state)),
        validate = function() return true end,
    }, function(input)
        if not input then
            return
        end
        local cmd = input .. ' ' .. vim.fn.fnameescape(path) .. ' 2>&1'
        local ok, result = pcall(vim.fn.system, cmd)
        if not ok then
            util.err(tostring(result))
        elseif vim.v.shell_error ~= 0 then
            util.err(result or '(command failed)')
        else
            if result and result ~= '' then
                util.info(result:gsub('%s+$', ''))
            end
        end
        render(state)
    end)
end

---@param order DoraSortOrder
function M.sort_by(order)
    local state = store.get()
    local row = current_row(state)
    local path = row and row.path or nil
    state.sort_order = sorter.normalize_order(order)
    render(state)
    if path then
        set_cursor_path(state, path)
    end
end

function M.sort_by_name()
    M.sort_by('name')
end

function M.sort_by_name_reverse()
    M.sort_by('name_reverse')
end

function M.sort_by_modified()
    M.sort_by('modified')
end

function M.sort_by_modified_reverse()
    M.sort_by('modified_reverse')
end

function M.sort_by_created()
    M.sort_by('created')
end

function M.sort_by_created_reverse()
    M.sort_by('created_reverse')
end

function M.sort_by_size()
    M.sort_by('size')
end

function M.sort_by_size_reverse()
    M.sort_by('size_reverse')
end

function M.sort_by_extension()
    M.sort_by('extension')
end

function M.sort_by_extension_reverse()
    M.sort_by('extension_reverse')
end

function M.reload()
    render(store.get())
end

-- Initialization --------------------------------------------------------------

---@param dir? string
---@return string
local function getcwd(dir)
    dir = dir or ''
    if dir ~= '' then return fs.realpath(vim.fn.expand(dir)) end
    local p = vim.fn.expand'%:p:h'
    if p ~= '' then return fs.realpath(p) end
    -- `expand('%')` can be empty if in an unnamed buffer, like `:enew`, so
    -- fallback to the cwd.
    return assert(uv.cwd())
end

-- Handler for the :Dora command
---@param dir? string
---@param from_au? boolean
function M.initialize(dir, from_au)
    -- If we're executing from the BufEnter autocmd, the current buffer has
    -- already changed, so the origin_buf is actually the altbuf, and we don't
    -- know what the origin-buf's altbuf is.
    local has_altbuf = vim.fn.bufexists(0) ~= 0
    local origin_buf = (from_au and has_altbuf)
        and vim.fn.bufnr'#'
        or api.nvim_get_current_buf()
    local alt_buf = (not from_au and has_altbuf) and vim.fn.bufnr'#' or nil
    local win = api.nvim_get_current_win()
    local cwd = getcwd(dir)
    local origin_filename = vim.fn.expand'%:p:t'
    origin_filename = origin_filename ~= '' and origin_filename or nil
    local sync = config.sync_local_cwd
    local cwd_restore = sync and save_cwd() or nil
    local buf = util.create_buf(cwd)
    local ns = api.nvim_create_namespace('dora.' .. buf)
    local cursor_ns = api.nvim_create_namespace('dora/cursor.' .. buf)
    local state = {
        buf = buf,
        win = win,
        origin_buf = origin_buf,
        alt_buf = alt_buf,
        cwd = cwd,
        sync_local_cwd = sync,
        cwd_restore = cwd_restore,
        ns = ns,
        cursor_ns = cursor_ns,
        show_hidden_files = config.show_hidden_files,
        sort_order = sorter.normalize_order(config.sort_order),
        hovered_files = {},  -- map<realpath, filename>
        expanded_dirs = load_expanded_directories(win),  -- map<realpath, true>
        tree_rows = {},
        rows = {},
        filter_text = nil,
        filter_preview = nil,
        filter_window = nil,
        filter_editing = false,
        marked_paths = {},  -- map<path, DoraPasteOperation>
        bookmarks = bookmarks.new(load_previous_directory(win)),
    }
    keymaps.setup(buf, config)
    store.set(buf, state)
    setup_autocmds(buf)
    sync_local_cwd(state)
    render(state)
    set_cursor_pos(state, origin_filename)
end

return M
