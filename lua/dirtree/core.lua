local fs = require'dirtree.fs'
local help_win = require'dirtree.help_win'
local delete_win = require'dirtree.delete_win'
local info_win = require'dirtree.info_win'
local keymaps = require'dirtree.keymaps'
local prompt = require'dirtree.prompt'
local store = require'dirtree.store'
local sorter = require'dirtree.sort'
local util = require'dirtree.util'
local config = require'dirtree'.config

local api = vim.api
local uv = vim.loop

local M = {}

local PROMPT_WIDTH = 32
local EMPTY_LABEL = '(empty)'
local NOT_PERMITTED_LABEL = '(not permitted)'
local TREE_VERTICAL = '│'
local TREE_CONTINUATION = TREE_VERTICAL .. '   '
local TREE_SPACER = '    '

---@alias DirtreeCwdScope 'window'|'tab'|'global'
---@alias DirtreePasteOperation 'copy'|'cut'

---@class DirtreeTreeSegment
---@field parent_path string
---@field start_col integer
---@field end_col integer

---@class DirtreeTreeRow
---@field name string
---@field display_name string
---@field path? string
---@field parent_path? string
---@field type DirtreeFileType|'placeholder'
---@field depth integer
---@field tree_prefix_len integer
---@field tree_continuation_segments DirtreeTreeSegment[]
---@field tree_connector_start_col? integer
---@field name_start_col? integer
---@field name_end_col? integer
---@field directory_suffix_col? integer

---@class DirtreeCwdRestore
---@field cwd string
---@field scope DirtreeCwdScope

---@class DirtreeState
---@field buf integer
---@field origin_buf integer
---@field alt_buf? integer
---@field cwd string
---@field sync_local_cwd boolean
---@field cwd_restore? DirtreeCwdRestore
---@field ns integer
---@field cursor_ns integer
---@field show_hidden_files boolean
---@field sort_order DirtreeSortOrder
---@field hovered_files table<string, string>
---@field expanded_dirs table<string, true>
---@field rows DirtreeTreeRow[]
---@field paste_operations table<string, DirtreePasteOperation>

-- Render ----------------------------------------------------------------------

---@param msg any
---@return boolean
local function is_permission_error(msg)
    msg = tostring(msg)
    return msg:match('EPERM') ~= nil
        or msg:lower():match('operation not permitted') ~= nil
        or msg:lower():match('permission denied') ~= nil
end

---@param state DirtreeState
---@param dir string
---@return DirtreeFile[] files
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

---@param segments DirtreeTreeSegment[]
---@return DirtreeTreeSegment[]
local function copy_tree_segments(segments)
    local ret = {}
    for _, segment in ipairs(segments) do
        ret[#ret+1] = segment
    end
    return ret
end

---@param state DirtreeState
---@return DirtreeTreeRow[]
local function build_tree_rows(state)
    local rows = {}

    ---@param dir string
    ---@param prefix string
    ---@param depth integer
    ---@param continuation_segments DirtreeTreeSegment[]
    local function add_dir(dir, prefix, depth, continuation_segments)
        local files, placeholder_label = visible_files(state, dir)
        if depth > 0 and (#files == 0 or placeholder_label) then
            placeholder_label = placeholder_label or EMPTY_LABEL
            local tree_prefix = prefix .. '└── '
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
            local connector = depth == 0 and '' or (is_last and '└── ' or '├── ')
            local child_prefix = depth == 0 and '' or prefix .. (is_last and TREE_SPACER or TREE_CONTINUATION)
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
            local path = util.join_path(dir, file.name)
            local tree_prefix = prefix .. connector
            local display_name = tree_prefix .. file.name
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
                name_start_col = #tree_prefix,
                name_end_col = #tree_prefix + #file.name,
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

local update_tree_cursor_highlight

---@param state DirtreeState
local function render(state)
    local buf, ns = state.buf, state.ns
    local rows = build_tree_rows(state)
    state.rows = rows
    util.set_lines(buf, vim.tbl_map(function(f)
        return f.display_name
    end, rows))
    -- Add virttext and highlights
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, file in ipairs(rows) do
        local path = file.path
        local virttext, hl
        if file.type == 'directory' then
            virttext, hl = nil, 'DirtreeDirectory'
        elseif file.type == 'placeholder' then
            virttext, hl = nil, 'DirtreeTree'
        elseif file.type == 'link' then
            local link = uv.fs_readlink(path)
            virttext = '@ → ' .. (link and util.display_path(link) or '???')
            hl = 'DirtreeSymlink'
        elseif uv.fs_access(path, 'X') then
            virttext, hl = '*', 'DirtreeExecutable'
        else
            virttext, hl = nil, 'DirtreeFile'
        end
        api.nvim_buf_set_extmark(0, ns, i-1, 0, {
            end_col = #file.display_name,
            hl_group = hl,
            priority = 100,  -- Below vim.highlight.on_yank's default priority.
        })
        if virttext then
            api.nvim_buf_set_extmark(0, ns, i-1, #file.display_name, {
                virt_text = {{virttext, 'DirtreeVirtText'}},
                virt_text_pos = 'overlay',
                hl_mode = 'combine',
            })
        end
        if file.tree_prefix_len > 0 then
            api.nvim_buf_set_extmark(0, ns, i-1, 0, {
                end_col = file.tree_prefix_len,
                hl_group = 'DirtreeTree',
                priority = 10000,
            })
        end
        if file.directory_suffix_col then
            api.nvim_buf_set_extmark(0, ns, i-1, file.directory_suffix_col, {
                end_col = #file.display_name,
                hl_group = 'DirtreeVirtText',
                priority = 10000,
            })
        end
        local paste_operation = path and state.paste_operations[path] or nil
        if paste_operation then
            local sign_hl = 'DirtreeCopySign'
            if paste_operation == 'cut' then
                sign_hl = 'DirtreeCutSign'
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

---@param state DirtreeState
function update_tree_cursor_highlight(state)
    local buf, ns = state.buf, state.cursor_ns
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if api.nvim_get_current_buf() ~= buf then
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
                    hl_group = 'DirtreeTreeActive',
                    priority = 10001,
                })
            end
        end
        if sibling.parent_path == row.parent_path and sibling.tree_connector_start_col then
            api.nvim_buf_set_extmark(buf, ns, i - 1, sibling.tree_connector_start_col, {
                end_col = sibling.tree_prefix_len,
                hl_group = 'DirtreeTreeActive',
                priority = 10001,
            })
        end
    end
end

---@param state DirtreeState
---@return DirtreeTreeRow?
local function current_row(state)
    local row = api.nvim_win_get_cursor(0)[1]
    return state.rows and state.rows[row] or nil
end

---@param state DirtreeState
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

---@param state DirtreeState
---@param pattern string?
---@param or_top? boolean
local function set_cursor_pos(state, pattern, or_top)
    util.set_cursor_pos(pattern, or_top)
    update_tree_cursor_highlight(state)
end

---@param state DirtreeState
---@param row DirtreeTreeRow?
---@return string?
local function create_default(state, row)
    if not row or not row.path then
        return nil
    end
    local relative = row.path:sub(#state.cwd + 2)
    if row.type ~= 'directory' then
        relative = relative:sub(1, -(#row.name + 2))
    end
    if relative == '' then
        return nil
    end
    return relative .. util.sep
end

---@param state DirtreeState
---@param row DirtreeTreeRow?
---@return string?
local function create_parent_default(state, row)
    if not row or not row.path then
        return nil
    end
    local parent = fs.get_parent_dir(row.path)
    if parent == state.cwd then
        return nil
    end
    return parent:sub(#state.cwd + 2) .. util.sep
end

---@param state DirtreeState
---@param row DirtreeTreeRow?
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
    for _, candidate in ipairs(state.rows or {}) do
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

---@param row DirtreeTreeRow
---@param path string
---@return boolean
local function row_under_path(row, path)
    if row.path then
        return row.path == path or vim.startswith(row.path, path .. util.sep)
    end
    return row.parent_path == path or vim.startswith(row.parent_path or '', path .. util.sep)
end

---@param state DirtreeState
---@param line integer
local function move_to_line(state, line)
    if line < 1 or line > #state.rows then
        return
    end
    api.nvim_win_set_cursor(0, {line, 0})
    update_tree_cursor_highlight(state)
end

---@param state DirtreeState
---@param line integer
---@param step integer
---@return integer?
local function sibling_line(state, line, step)
    local row = state.rows[line]
    if not row then
        return nil
    end
    for i = line + step, step > 0 and #state.rows or 1, step do
        if state.rows[i].parent_path == row.parent_path then
            return i
        end
    end
end

---@param state DirtreeState
---@param line integer
---@param step integer
---@return integer?
local function sibling_edge_line(state, line, step)
    local row = state.rows[line]
    if not row then
        return nil
    end
    for i = step > 0 and #state.rows or 1, line, -step do
        if state.rows[i].parent_path == row.parent_path then
            return i
        end
    end
end

---@param state DirtreeState
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

---@param state DirtreeState
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

---@param state DirtreeState
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

---@param state DirtreeState
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

---@class DirtreePasteOperationEntry
---@field path string
---@field operation DirtreePasteOperation

---@param state DirtreeState
---@return DirtreePasteOperationEntry[]
local function paste_operation_entries(state)
    local entries = {}
    for path, operation in pairs(state.paste_operations) do
        entries[#entries+1] = {path = path, operation = operation}
    end
    table.sort(entries, function(a, b) return a.path < b.path end)
    return entries
end

---@param state DirtreeState
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

---@param row DirtreeTreeRow?
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

---@param state DirtreeState
local function clear_paste_operations(state)
    state.paste_operations = {}
end

---@param state DirtreeState
---@param path string
local function clear_paste_operations_under(state, path)
    local prefix = path .. util.sep
    for marked_path in pairs(state.paste_operations) do
        if marked_path == path or vim.startswith(marked_path, prefix) then
            state.paste_operations[marked_path] = nil
        end
    end
end

---@param state DirtreeState
---@param old_path string
---@param new_path string
local function rename_paste_operations_under(state, old_path, new_path)
    local old_prefix = old_path .. util.sep
    local updated = {}
    for marked_path, operation in pairs(state.paste_operations) do
        if marked_path == old_path then
            updated[new_path] = operation
            state.paste_operations[marked_path] = nil
        elseif vim.startswith(marked_path, old_prefix) then
            updated[new_path .. marked_path:sub(#old_path + 1)] = operation
            state.paste_operations[marked_path] = nil
        end
    end
    for marked_path, operation in pairs(updated) do
        state.paste_operations[marked_path] = operation
    end
end

---@param state DirtreeState
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
                local child_path = util.join_path(dir, file.name)
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

---@param state DirtreeState
---@param path string
---@return boolean changed
local function expand_all_dirs(state, path)
    local changed = not state.expanded_dirs[path]
    state.expanded_dirs[path] = true
    for _, file in ipairs(visible_files(state, path)) do
        if file.type == 'directory' then
            local child_path = util.join_path(path, file.name)
            if expand_all_dirs(state, child_path) then
                changed = true
            end
        end
    end
    return changed
end

---@param state DirtreeState
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

---@param state DirtreeState
---@param path string
---@param target_depth integer
---@return boolean changed
local function collapse_deepest_visible_dirs(state, path, target_depth)
    local max_depth = 0
    for _, row in ipairs(state.rows or {}) do
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

---@param state DirtreeState
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
    local group = api.nvim_create_augroup('dirtree.cursor.' .. buf, {clear=true})
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

---@param state DirtreeState
local function cleanup(state)
    api.nvim_buf_delete(state.buf, {force=true})
    store.remove(state.buf)
end

---@return DirtreeCwdScope
local function get_cwd_scope()
    if vim.fn.haslocaldir(0, 0) == 1 then
        return 'window'
    elseif vim.fn.haslocaldir(-1, 0) == 1 then
        return 'tab'
    else
        return 'global'
    end
end

---@return DirtreeCwdRestore
local function save_cwd()
    return {
        cwd = vim.fn.getcwd(0, 0),
        scope = get_cwd_scope(),
    }
end

---@param scope DirtreeCwdScope
---@return 'lcd'|'tcd'|'cd'
local function cd_cmd(scope)
    return ({
        window = 'lcd',
        tab = 'tcd',
        global = 'cd',
    })[scope]
end

---@param scope DirtreeCwdScope
---@param cwd string
local function set_cwd(scope, cwd)
    vim.cmd(('sil %s %s'):format(cd_cmd(scope), vim.fn.fnameescape(cwd)))
end

---@param state DirtreeState
local function sync_local_cwd(state)
    if state.sync_local_cwd then
        local ok, msg = pcall(set_cwd, 'window', state.cwd)
        if not ok then
            util.warn(msg)
        end
    end
end

---@param state DirtreeState
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
    local row = current_row(state)
    if row then
        state.hovered_files[state.cwd] = row.name
    end
    state.expanded_dirs[cwd] = true
    state.cwd = parent_dir
    render(state)
    util.update_buf_name(state.cwd)
    sync_local_cwd(state)
    set_cursor_pos(state, fs.basename(cwd), --[[or_top]]true)
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
    local row = current_row(state)
    if row then
        state.hovered_files[state.cwd] = row.name
    end
    state.cwd = path
    render(state)
    util.update_buf_name(state.cwd)
    sync_local_cwd(state)
    set_cursor_pos(state, state.hovered_files[path], --[[or_top]]true)
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
    help_win.open(config)
end

function M.info()
    local state = store.get()
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    info_win.open(path)
end

---@param cmd? DirtreeOpenCommand
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
                state.cwd = path
                render(state)
                util.update_buf_name(state.cwd)
                sync_local_cwd(state)
                local hovered_file = state.hovered_files[path]
                set_cursor_pos(state, hovered_file, --[[or_top]]true)
            end
        else
            restore_cwd(state)
            util.set_current_buf(state.origin_buf)  -- update the altfile
            vim.cmd((cmd or 'edit') .. ' ' .. vim.fn.fnameescape(path))
            cleanup(state)
        end
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

function M.expand_or_open()
    local state = store.get()
    local row = current_row(state)
    if not row or not row.path then
        return
    end
    if row.type == 'directory' then
        M.expand()
    else
        M.open()
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

function M.clear_selection()
    M.clear_paste_operation()
end

---@param operation DirtreePasteOperation
local function toggle_paste_operation(operation)
    local state = store.get()
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    if state.paste_operations[path] == operation then
        state.paste_operations[path] = nil
    else
        state.paste_operations[path] = operation
    end
    render(state)
end

function M.cut()
    toggle_paste_operation('cut')
end

function M.copy()
    toggle_paste_operation('copy')
end

function M.clear_paste_operation()
    local state = store.get()
    clear_paste_operations(state)
    render(state)
end

function M.paste()
    local state = store.get()
    local entries = paste_operation_entries(state)
    if #entries == 0 then
        util.err('Nothing to paste')
        return
    end
    local row = current_row(state)
    local dest_dir = row and row.parent_path or nil
    if not dest_dir then
        util.err('No paste destination')
        return
    end
    local dest_path = util.join_path(dest_dir, fs.basename(entries[1].path))
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
    clear_paste_operations(state)
    render(state)
    set_cursor_path(state, dest_path)
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
    util.info(message)
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

function M.delete()
    local state = store.get()
    local row = current_row(state)
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    delete_win.delete({path}, state.cwd, function(confirmed)
        if not confirmed then
            return
        end
        local ok, err = pcall(fs.delete, path)
        if not ok then
            util.err(err)
            return
        end
        clear_paste_operations_under(state, path)
        render(state)
    end, {
        anchor = current_name_anchor(row),
    })
end

local function move()
    local state = store.get()
    local row = current_row(state)
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    local prompt_label = 'Move to'
    prompt.input({
        prompt = prompt_label,
        cwd = state.cwd,
        default = create_default(state, row),
        width = PROMPT_WIDTH,
        anchor = current_name_anchor(row),
        validate = function(input)
            return fs.resolve_copy_or_move_dest(path, input, state.cwd)
        end,
    }, function(input, dest)
        if not input then
            return
        end
        local ok, msg = pcall(fs.copy_or_move, true, path, input, state.cwd)
        if not ok then
            util.err(msg)
        else
            rename_paste_operations_under(state, path, dest)
            render(state)
            set_cursor_pos(state, fs.basename(dest))
        end
    end)
end

function M.move() move() end

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
        default = fs.basename(path),
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
        rename_paste_operations_under(state, path, dest)
        render(state)
        set_cursor_path(state, dest)
    end)
end

function M.create()
    local state = store.get()
    local row = current_row(state)
    prompt.input({
        prompt = 'Add file or folder',
        cwd = state.cwd,
        width = PROMPT_WIDTH,
        default = create_parent_default(state, row),
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
                render(state)
                set_cursor_path(state, path)
            end
        end
    end)
end

function M.toggle_hidden_files()
    local state = store.get()
    local row = current_row(state)
    local hovered_file = row and row.display_name or nil
    state.show_hidden_files = not state.show_hidden_files
    render(state)
    set_cursor_pos(state, hovered_file)
end

---@param order DirtreeSortOrder
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

-- Handler for the :Dirtree command
---@param dir? string
---@param from_au? boolean
function M.dirtree(dir, from_au)
    -- If we're executing from the BufEnter autocmd, the current buffer has
    -- already changed, so the origin_buf is actually the altbuf, and we don't
    -- know what the origin-buf's altbuf is.
    local has_altbuf = vim.fn.bufexists(0) ~= 0
    local origin_buf = (from_au and has_altbuf)
        and vim.fn.bufnr'#'
        or api.nvim_get_current_buf()
    local alt_buf = (not from_au and has_altbuf) and vim.fn.bufnr'#' or nil
    local cwd = getcwd(dir)
    local origin_filename = vim.fn.expand'%:p:t'
    origin_filename = origin_filename ~= '' and origin_filename or nil
    local sync = config.sync_local_cwd
    local cwd_restore = sync and save_cwd() or nil
    local buf = util.create_buf(cwd)
    local ns = api.nvim_create_namespace('dirtree.' .. buf)
    local cursor_ns = api.nvim_create_namespace('dirtree/cursor.' .. buf)
    local state = {
        buf = buf,
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
        expanded_dirs = {},  -- map<realpath, true>
        rows = {},
        paste_operations = {},  -- map<path, DirtreePasteOperation>
    }
    keymaps.setup(buf, config)
    store.set(buf, state)
    setup_autocmds(buf)
    sync_local_cwd(state)
    render(state)
    set_cursor_pos(state, origin_filename)
end

return M
