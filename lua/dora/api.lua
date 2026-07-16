-- All user-facing actions. Every `M.*` function here can be bound by name in
-- the keymap config (dora/actions.lua holds the registry of built-ins) and
-- called directly via require'dora.api'. Actions read the current window's
-- DoraState from dora/store.lua, mutate it or the filesystem, and re-render
-- through dora/view.lua.
local fs = require'dora.fs'
local buffer = require'dora.buffer'
local help_win = require'dora.ui.help'
local history = require'dora.history'
local confirm_win = require'dora.ui.confirm'
local filter_win = require'dora.ui.filter'
local icons = require'dora.icons'
local info_win = require'dora.ui.info'
local keymaps = require'dora.keymaps'
local lsp = require'dora.lsp'
local preview_win = require'dora.ui.preview'
local prompt = require'dora.ui.prompt'
local store = require'dora.store'
local sorter = require'dora.sort'
local tree = require'dora.tree'
local util = require'dora.util'
local view = require'dora.view'
local config = require'dora'.config

local api = vim.api
local uv = vim.uv

local M = {}

-- Expanded directories are shared by all dora buffers and persist for the
-- lifetime of the session.
---@type table<string, true>
local global_expanded_dirs = {}

-- Cut/copy marks are shared by all dora buffers so a path marked in one window
-- can be pasted in another.
---@type table<string, DoraPasteOperation>
local global_marked_paths = {}

local PROMPT_WIDTH = 32

local SPINNER_FRAMES = {'⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'}

-- Shows an updating, non-blocking progress line on the command line while an
-- async operation runs, and returns a function that stops it and clears the
-- line. A timer drives the animation so the spinner keeps moving even while a
-- single large file copies (which produces no per-file progress callbacks);
-- `message` is re-evaluated on every tick so it can report live progress.
---@param message fun(): string
---@return fun() stop
local function start_spinner(message)
    -- Nothing to render to without an attached UI (e.g. headless tests).
    local timer = #api.nvim_list_uis() > 0 and uv.new_timer()
    if not timer then
        return function() end
    end
    local frame = 1
    -- timer:stop() halts future ticks but cannot cancel a render that the timer
    -- has already scheduled onto the main loop. A fast operation (e.g. a
    -- directory rename, which finishes before the first tick fires) would
    -- otherwise let that stale render repaint the line after we clear it.
    local stopped = false
    timer:start(0, 100, vim.schedule_wrap(function()
        if stopped then
            return
        end
        api.nvim_echo({{('dora: %s %s'):format(SPINNER_FRAMES[frame], message())}}, false, {})
        frame = frame % #SPINNER_FRAMES + 1
    end))
    return function()
        stopped = true
        timer:stop()
        timer:close()
        api.nvim_echo({{''}}, false, {})
    end
end

-- The root row stands for the browsed directory itself; actions that would
-- mutate or mark it refuse with a message rather than acting on the cwd.
---@param state DoraState
---@param action string
---@return boolean
local function refuse_root_row(state, action)
    local row = view.current_row(state)
    if row and row.is_root then
        util.warn(('Cannot %s the root directory'):format(action))
        return true
    end
    return false
end

-- Where the typed path resolves and what to prefill: add creates beside the
-- hovered row (inside its parent directory), add_under creates beneath a
-- hovered directory. add_under prefills the directory's own name — resolved
-- against its parent — so the prefill matches the row text exactly and the
-- prompt can superimpose over the row at any depth.
---@param state DoraState
---@param row DoraTreeRow?
---@param under_directory? boolean
---@return string base_dir
---@return string? initial_prompt
local function create_base(state, row, under_directory)
    -- On the root row both add actions create directly in the cwd; add_under
    -- gets there by prefilling the cwd's own name, superimposing over the
    -- root row like any other directory (unless the cwd is the filesystem
    -- root, which has no parent to resolve against).
    if not row or row.is_root then
        if under_directory and row and row.path and not fs.is_root(row.path) then
            return fs.get_parent_dir(row.path), fs.basename(row.path) .. '/'
        end
        return state.cwd, nil
    end
    if under_directory and row.type == 'directory' and row.path then
        return fs.get_parent_dir(row.path), fs.basename(row.path) .. '/'
    end
    -- Placeholder rows have no path of their own; create inside the
    -- directory that shows them.
    local parent = row.path and fs.get_parent_dir(row.path) or row.parent_path
    return parent or state.cwd, nil
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
    if view.active_filter(state) then
        local next_line = line + step
        if next_line < 1 or next_line > #state.rows then
            return nil
        end
        return state.rows[next_line].path and next_line or nil
    end
    for i = line + step, step > 0 and #state.rows or 1, step do
        if state.rows[i].parent_path == row.parent_path then
            return i
        end
    end
end

---@param step integer 1 for next, -1 for prev
local function move_sibling(step)
    local state = store.get()
    local line = api.nvim_win_get_cursor(0)[1]
    local row = state.rows[line]
    if not row or not row.parent_path then
        return
    end
    for _ = 1, vim.v.count1 do
        local target = sibling_line(state, line, step)
        if not target then
            break
        end
        line = target
    end
    view.move_to_line(state, line)
end

---@param state DoraState
---@param line integer
---@param step integer
---@return integer?
local function marked_line(state, line, step)
    for i = line + step, step > 0 and #state.rows or 1, step do
        local row = state.rows[i]
        if row.path and state.marked_paths[row.path] then
            return i
        end
    end
end

---@param step integer 1 for next mark, -1 for previous mark
local function move_to_mark(step)
    local state = store.get()
    local line = api.nvim_win_get_cursor(0)[1]
    for _ = 1, vim.v.count1 do
        local target = marked_line(state, line, step)
        if not target then
            break
        end
        line = target
    end
    view.move_to_line(state, line)
end

---@param path string
---@param selected string[]
---@return boolean
local function path_under_selected(path, selected)
    for _, selected_path in ipairs(selected) do
        if path == selected_path or vim.startswith(path, selected_path .. '/') then
            return true
        end
    end
    return false
end

---@class DoraMarkedPathEntry
---@field path string
---@field operation DoraPasteOperation

---@param state DoraState
---@return DoraMarkedPathEntry[]
local function marked_path_entries(state)
    local paths = vim.tbl_keys(state.marked_paths)
    table.sort(paths)
    local entries = {}
    local kept_paths = {}
    for _, path in ipairs(paths) do
        if not path_under_selected(path, kept_paths) then
            kept_paths[#kept_paths+1] = path
            entries[#entries+1] = {path = path, operation = state.marked_paths[path]}
        end
    end
    return entries
end

---@param state DoraState
---@return string? path
---@return string? error
local function current_path(state)
    local row = view.current_row(state)
    if not row then
        return nil, 'Empty filename'
    end
    if not row.path then
        return nil, 'No file selected'
    end
    return row.path
end

-- Anchors a float to the start of the hovered entry: the icon when icons are
-- enabled, otherwise the filename.
---@param row DoraTreeRow?
---@param opts? {line?: integer, superimpose?: boolean}
---@return DoraFloatAnchor?
local function current_name_anchor(row, opts)
    if not row or not row.name_start_col then
        return nil
    end
    local win = api.nvim_get_current_win()
    return {
        win = win,
        line = opts and opts.line or api.nvim_win_get_cursor(win)[1],
        col = row.icon_start_col or row.name_start_col,
        superimpose = opts and opts.superimpose,
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

-- Queue an <Esc> through the typeahead to leave visual mode once the current
-- mapping finishes. Fine for actions that stay in the dora buffer.
local function exit_visual_mode()
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
end

-- Leave visual mode right now (:normal! runs synchronously). Needed before an
-- action switches buffers or windows: a queued <Esc> would only fire after the
-- switch, in whatever buffer ends up current.
local function exit_visual_mode_now()
    vim.cmd.normal({args={api.nvim_replace_termcodes('<Esc>', true, false, true)}, bang=true})
end

-- Visual selections act on the entries inside the browsed directory; a root
-- row swept up in the selection is skipped.
---@param state DoraState
---@return DoraTreeRow[] rows
local function selected_rows(state)
    local start_line, end_line = visual_line_range()
    local rows = {}
    for line = start_line, end_line do
        local row = state.rows and state.rows[line] or nil
        if row and row.path and not row.is_root then
            rows[#rows+1] = row
        end
    end
    return rows
end

---@param state DoraState
---@return string[]? paths
---@return string? error
local function selected_non_overlapping_paths(state)
    local paths = {}
    for _, row in ipairs(selected_rows(state)) do
        if not path_under_selected(row.path, paths) then
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
    for marked_path in pairs(state.marked_paths) do
        state.marked_paths[marked_path] = nil
    end
end

---@param state DoraState
---@param path string
local function clear_marked_paths_under(state, path)
    local prefix = path .. '/'
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
    local old_prefix = old_path .. '/'
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
local function close_filter(state)
    state.filter_text = nil
    state.filter_preview = nil
    state.filter_editing = false
    state.filter_inverted = false
    local filter_window = state.filter_window
    state.filter_window = nil
    if filter_window then
        filter_window:close()
    end
end

-- Release everything a session holds besides its buffer: UI windows, the
-- listing cache and its watchers, and the store entry. Removing the store
-- entry first keeps the BufWipeout catch-all from running this a second time
-- when cleanup() deletes the buffer.
---@param state DoraState
local function release_state(state)
    close_filter(state)
    preview_win.close(state)
    view.clear_listings(state)
    view.stop_watches(state)
    store.remove(state.buf)
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
                view.update_tree_cursor_highlight(state)
                view.update_preview(state)
                -- Native motions like `gg` scroll to the top and reset the
                -- topfill spacer the filter float sits over, so restore it.
                if state.filter_window then
                    view.keep_filter_spacer(state.win)
                end
            end
        end,
    })
    -- Don't leak state if the buffer is wiped without going through cleanup(),
    -- e.g. by a user's :bwipeout
    api.nvim_create_autocmd('BufWipeout', {
        group = group,
        buffer = buf,
        callback = function(args)
            local ok, state = pcall(store.get, args.buf)
            if ok then
                if api.nvim_win_is_valid(state.win)
                        and api.nvim_win_get_buf(state.win) == state.buf then
                    local line = api.nvim_win_get_cursor(state.win)[1]
                    local row = state.rows and state.rows[line] or nil
                    history.update_current(state.history, state.cwd, row and row.path or nil)
                end
                release_state(state)
            end
        end,
    })
end

---@param state DoraState
local function cleanup(state)
    release_state(state)
    api.nvim_buf_delete(state.buf, {force=true})
end

---@param state DoraState
local function remember_hovered_file(state)
    local row = view.current_row(state)
    if row then
        state.hovered_files[state.cwd] = row.path or row.name
    end
    history.update_current(state.history, state.cwd, row and row.path or nil)
end

---@param state DoraState
---@param cursor_target? string
---@param or_top? boolean
local function restore_cursor(state, cursor_target, or_top)
    if cursor_target and view.set_cursor_path(state, cursor_target) then
        return
    end
    view.set_cursor_pos(state, cursor_target, or_top)
end

---@param state DoraState
---@param path string
---@param cursor_target? string
---@param or_top? boolean
local function change_cwd(state, path, cursor_target, or_top, traversing_history)
    if state.cwd ~= path then
        if not traversing_history then
            remember_hovered_file(state)
        end
        state.cwd = path
        if not traversing_history then
            history.visit(state.history, path, cursor_target)
        end
        -- Only rename when the cwd changed; create_buf_name() counts the
        -- current buffer as a collision, so renaming to the same cwd would
        -- append a spurious ' [1]' suffix.
        buffer.update_buf_name(state.cwd)
    end
    view.render(state)
    -- A committed filter persists across navigation, re-applying to the new
    -- directory. Show its results from the top so the first match isn't hidden
    -- behind the filter window.
    if view.active_filter(state) then
        view.scroll_filter_results_to_top(state.win)
        if traversing_history then
            restore_cursor(state, cursor_target, or_top)
        end
    else
        restore_cursor(state, cursor_target, or_top)
    end
    local row = view.current_row(state)
    history.update_current(state.history, state.cwd, row and row.path or nil)
end

function M.quit()
    local state = store.get()
    remember_hovered_file(state)
    if state.alt_buf then
        buffer.set_current_buf(state.alt_buf)
    end
    buffer.set_current_buf(state.origin_buf)
    cleanup(state)
end

function M.up_dir()
    local state = store.get()
    local cwd = state.cwd
    local target = cwd
    local cursor_child = cwd
    for _ = 1, vim.v.count1 do
        local parent_dir = fs.get_parent_dir(target)
        if parent_dir == target then
            break
        end
        state.expanded_dirs[target] = true
        cursor_child = target
        target = parent_dir
    end
    if target == cwd then
        return
    end
    remember_hovered_file(state)
    change_cwd(state, target, cursor_child, --[[or_top]]true)
end

function M.home_dir()
    local home = os.getenv'HOME'
    if not home or home == '' then
        util.err('$HOME is not set')
        return
    end
    local path, msg = fs.try_realpath(home)
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
    local cursor = state.hovered_files[path]
    if vim.startswith(state.cwd, path .. '/') then
        local child = state.cwd:sub(#path + 2):match('^[^/]+')
        cursor = child and vim.fs.joinpath(path, child) or cursor
    end
    change_cwd(state, path, cursor, --[[or_top]]true)
end

function M.parent_dir()
    local state = store.get()
    for _ = 1, vim.v.count1 do
        local row = view.current_row(state)
        if not row or not row.parent_path then
            return
        end
        local cursor = api.nvim_win_get_cursor(0)
        view.set_cursor_path(state, row.parent_path)
        if vim.deep_equal(api.nvim_win_get_cursor(0), cursor) then
            return
        end
    end
end

function M.next_sibling()
    move_sibling(1)
end

function M.prev_sibling()
    move_sibling(-1)
end

function M.next_paste_mark()
    move_to_mark(1)
end

function M.prev_paste_mark()
    move_to_mark(-1)
end

function M.help()
    help_win.open(config)
end

function M.filter()
    local state = store.get()
    local row = view.current_row(state)
    local cursor_path = row and row.path or nil
    local initial_text = state.filter_text or ''
    local origin_win = api.nvim_get_current_win()
    -- Captured so cancelling discards any invert toggles made while editing,
    -- the same way it discards the previewed text.
    local original_inverted = state.filter_inverted
    state.filter_preview = initial_text
    state.filter_editing = true
    view.render(state)
    view.scroll_filter_results_to_top(origin_win)

    local opts = {
        origin_win = origin_win,
        initial_text = initial_text,
        inverted = state.filter_inverted,
        on_change = function(text)
            state.filter_preview = text
            view.render(state)
            view.scroll_filter_results_to_top(origin_win)
        end,
        on_toggle_invert = function(inverted)
            state.filter_inverted = inverted
            view.render(state)
            view.scroll_filter_results_to_top(origin_win)
        end,
        on_confirm = function(text)
            state.filter_preview = nil
            state.filter_text = text ~= '' and text or nil
            state.filter_editing = false
            if not state.filter_text then
                state.filter_window = nil
                state.filter_inverted = false
            end
            view.render(state)
            view.set_cursor_pos(state, nil, --[[or_top]]true)
            if state.filter_text then
                view.scroll_filter_results_to_top(origin_win)
            end
            return state.filter_text ~= nil
        end,
        on_cancel = function()
            state.filter_preview = nil
            state.filter_editing = false
            state.filter_inverted = original_inverted
            if not state.filter_text then
                state.filter_window = nil
            end
            view.render(state)
            if not cursor_path or not view.set_cursor_path(state, cursor_path) then
                view.set_cursor_pos(state, nil, --[[or_top]]true)
            end
            if state.filter_text then
                view.reveal_filter_spacer(origin_win)
            end
            return state.filter_text
        end,
        on_close = function()
            state.filter_window = nil
            state.filter_preview = nil
            state.filter_editing = false
            if api.nvim_buf_is_valid(state.buf) then
                view.render(state)
                if not cursor_path or not view.set_cursor_path(state, cursor_path) then
                    view.set_cursor_pos(state, nil, --[[or_top]]true)
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
    local row = view.current_row(state)
    local cursor_path = row and row.path or nil
    close_filter(state)
    view.render(state)
    if not cursor_path or not view.set_cursor_path(state, cursor_path) then
        view.set_cursor_pos(state, nil, --[[or_top]]true)
    end
end

---@param direction 1|-1
local function traverse_history(direction)
    local state = store.get()
    remember_hovered_file(state)
    local entry = history.traverse(state.history, direction, fs.is_dir)
    if not entry then
        return
    end
    change_cwd(state, entry.directory, entry.hovered_path, --[[or_top]]true, --[[traversing_history]]true)
end

function M.history_back()
    traverse_history(-1)
end

function M.history_forward()
    traverse_history(1)
end

function M.file_info()
    local state = store.get()
    local row = view.current_row(state)
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    info_win.open(path, current_name_anchor(row))
end

function M.toggle_preview()
    local state = store.get()
    preview_win.toggle(state, view.current_row(state))
end

---@param cmd? DoraOpenCommand
function M.open(cmd)
    local state = store.get()
    local row = view.current_row(state)
    if not row or not row.path then
        return
    end
    -- fs_realpath also checks file existence
    local path, msg = fs.try_realpath(row.path)
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
            remember_hovered_file(state)
            buffer.set_current_buf(state.origin_buf)  -- update the altfile
            vim.cmd((cmd or 'edit') .. ' ' .. vim.fn.fnameescape(path))
            cleanup(state)
        end
    end
end

---@param state DoraState
---@param include_dirs boolean
---@return string[] paths
local function selected_paths(state, include_dirs)
    local paths = {}
    for _, row in ipairs(selected_rows(state)) do
        local path, msg = fs.try_realpath(row.path)
        if not path then
            util.err(msg)
        elseif include_dirs or not fs.is_dir(path) then
            paths[#paths+1] = path
        end
    end
    return paths
end

-- Directories are only included for window-creating commands: they open a new
-- dora session in the split/tab, whereas :edit-ing one would replace this
-- session mid-loop.
---@param cmd DoraOpenCommand
---@param stay boolean
local function open_selected(cmd, stay)
    local state = store.get()
    local paths = selected_paths(state, --[[include_dirs]]cmd ~= 'edit')
    if #paths == 0 then
        return
    end
    exit_visual_mode_now()
    if stay then
        local dora_win = api.nvim_get_current_win()
        for _, path in ipairs(paths) do
            vim.cmd(cmd .. ' ' .. vim.fn.fnameescape(path))
            if api.nvim_win_is_valid(dora_win) then
                api.nvim_set_current_win(dora_win)
            end
        end
        return
    end
    remember_hovered_file(state)
    buffer.set_current_buf(state.origin_buf)  -- update the altfile
    for _, path in ipairs(paths) do
        vim.cmd(cmd .. ' ' .. vim.fn.fnameescape(path))
    end
    cleanup(state)
end

function M.open_visual()
    open_selected('edit', false)
end

function M.open_split_visual()
    open_selected('split', false)
end

function M.open_vsplit_visual()
    open_selected('vsplit', false)
end

function M.open_tab_visual()
    open_selected('tabedit', false)
end

function M.open_split_stay_visual()
    open_selected('split', true)
end

function M.open_vsplit_stay_visual()
    open_selected('vsplit', true)
end

function M.open_tab_stay_visual()
    open_selected('tabedit', true)
end

---@param cmd DoraOpenCommand
local function open_stay(cmd)
    local state = store.get()
    local row = view.current_row(state)
    if not row or not row.path then
        return
    end
    -- fs_realpath also checks file existence
    local path, msg = fs.try_realpath(row.path)
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

function M.open_split_stay()
    open_stay('split')
end

function M.open_vsplit_stay()
    open_stay('vsplit')
end

function M.open_tab_stay()
    open_stay('tabedit')
end

function M.open_external()
    local state = store.get()
    local row = view.current_row(state)
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

function M.open_external_visual()
    local state = store.get()
    local rows = selected_rows(state)
    exit_visual_mode_now()
    if #rows == 0 then
        util.err('No files selected')
        return
    end
    for _, row in ipairs(rows) do
        if fs.exists(row.path) then
            local ok, err = pcall(vim.ui.open, row.path)
            if ok then
                util.info('Opening ' .. row.name)
            else
                util.err(('Could not open %s externally: %s'):format(row.name, tostring(err)))
            end
        end
    end
end

function M.fold_out()
    local state = store.get()
    local row = view.current_row(state)
    if not row or not row.path or row.type ~= 'directory' then
        return
    end
    -- The root's listing is always rendered, so mark it expanded up front;
    -- otherwise the first press would only record that and expand nothing.
    if row.is_root then
        state.expanded_dirs[row.path] = true
    end
    local changed = false
    for _ = 1, vim.v.count1 do
        if not tree.expand_next_level(state, row.path) then
            break
        end
        changed = true
    end
    if changed then
        view.render(state)
        view.set_cursor_path(state, row.path)
    end
end

function M.fold_out_recursive()
    local state = store.get()
    local row = view.current_row(state)
    if not row or not row.path or row.type ~= 'directory' then
        return
    end
    local changed = tree.expand_all_dirs(state, row.path)
    if changed then
        view.render(state)
        view.set_cursor_path(state, row.path)
    end
end

function M.fold_in()
    local state = store.get()
    local row = view.current_row(state)
    local path, target_depth = tree.collapse_target(state, row)
    if not row or not row.path or not path or not target_depth then
        return
    end
    local changed = false
    for _ = 1, vim.v.count1 do
        if not tree.collapse_deepest_visible_dirs(state, path, target_depth) then
            break
        end
        changed = true
        -- tree.collapse_deepest_visible_dirs reads state.tree_rows to find the deepest
        -- level, so refresh it between iterations before collapsing the next one.
        state.tree_rows = view.build_tree_rows(state)
    end
    if changed then
        view.render(state)
        if not view.set_cursor_path(state, row.path) then
            view.set_cursor_path(state, path)
        end
    end
end

function M.fold_in_recursive()
    local state = store.get()
    local row = view.current_row(state)
    if not row or not row.path or row.type ~= 'directory' then
        return
    end
    local changed = tree.clear_expanded_subtree(state, row.path)
    if changed then
        view.render(state)
        view.set_cursor_path(state, row.path)
    end
end

function M.close_dir()
    local state = store.get()
    local row = view.current_row(state)
    if not row or not row.path or row.type ~= 'directory' or row.is_root then
        return
    end
    -- Clear only this directory's entry so its subtree expansion is restored
    -- on the next expand.
    if state.expanded_dirs[row.path] then
        state.expanded_dirs[row.path] = nil
        view.render(state)
        view.set_cursor_path(state, row.path)
    end
end

---@param op fun(state: DoraState, path: string): boolean
local function visual_dir_rows_op(op)
    local state = store.get()
    local start_line, end_line = visual_line_range()
    local anchor_row = state.rows and state.rows[start_line] or nil
    local changed = false
    local first_path
    for line = start_line, end_line do
        local row = state.rows and state.rows[line] or nil
        if row and row.path and row.type == 'directory' and not row.is_root then
            first_path = first_path or row.path
            if op(state, row.path) then
                changed = true
            end
        end
    end
    exit_visual_mode()
    if changed then
        view.render(state)
        if not (anchor_row and anchor_row.path and view.set_cursor_path(state, anchor_row.path)) and first_path then
            view.set_cursor_path(state, first_path)
        end
    end
end

function M.fold_out_visual()
    visual_dir_rows_op(tree.expand_next_level)
end

function M.fold_out_recursive_visual()
    visual_dir_rows_op(tree.expand_all_dirs)
end

function M.fold_in_recursive_visual()
    visual_dir_rows_op(tree.clear_expanded_subtree)
end

function M.close_dir_visual()
    visual_dir_rows_op(function(state, path)
        if not state.expanded_dirs[path] then
            return false
        end
        state.expanded_dirs[path] = nil
        return true
    end)
end

function M.fold_in_visual()
    local state = store.get()
    local start_line, end_line = visual_line_range()
    local anchor_row = state.rows and state.rows[start_line] or nil
    local targets = {}
    local seen = {}
    for line = start_line, end_line do
        local row = state.rows and state.rows[line] or nil
        if not (row and row.is_root) then
            local path, target_depth = tree.collapse_target(state, row)
            if path and target_depth and not seen[path] then
                seen[path] = true
                targets[#targets+1] = {path = path, depth = target_depth}
            end
        end
    end
    -- Collapse targets are computed against the pre-collapse view, so nested
    -- and duplicate targets collapse a single level rather than compounding.
    local changed = false
    for _, target in ipairs(targets) do
        if tree.collapse_deepest_visible_dirs(state, target.path, target.depth) then
            changed = true
        end
    end
    exit_visual_mode()
    if changed then
        view.render(state)
        if not (anchor_row and anchor_row.path and view.set_cursor_path(state, anchor_row.path)) then
            view.set_cursor_path(state, targets[1].path)
        end
    end
end

local function render_marked_windows()
    store.each(function(state)
        if api.nvim_buf_is_valid(state.buf) then
            view.render(state)
        end
    end)
end

---@param operation DoraPasteOperation
local function toggle_marked_path(operation)
    local state = store.get()
    if refuse_root_row(state, operation) then
        return
    end
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
    render_marked_windows()
end

function M.toggle_cut()
    toggle_marked_path('cut')
end

function M.toggle_copy()
    toggle_marked_path('copy')
end

---@param operation DoraPasteOperation
local function toggle_marked_paths_visual(operation)
    local state = store.get()
    local start_line, end_line = visual_line_range()
    local found = false
    for line = start_line, end_line do
        local row = state.rows and state.rows[line] or nil
        if row and row.path and not row.is_root then
            found = true
            if state.marked_paths[row.path] == operation then
                state.marked_paths[row.path] = nil
            else
                state.marked_paths[row.path] = operation
            end
        end
    end
    if not found then
        util.err('No files selected')
        return
    end
    exit_visual_mode()
    render_marked_windows()
end

function M.toggle_cut_visual()
    toggle_marked_paths_visual('cut')
end

function M.toggle_copy_visual()
    toggle_marked_paths_visual('copy')
end

---@param operation DoraPasteOperation
local function clear_marks_for_operation(operation)
    local state = store.get()
    for marked_path, marked_operation in pairs(state.marked_paths) do
        if marked_operation == operation then
            state.marked_paths[marked_path] = nil
        end
    end
    render_marked_windows()
end

function M.clear_cut()
    clear_marks_for_operation('cut')
end

function M.clear_copy()
    clear_marks_for_operation('copy')
end

---@param state DoraState
---@param entries DoraMarkedPathEntry[]
---@param dest_dir string
---@param overwrite boolean Replace conflicting destinations instead of keeping both
local function paste_entries(state, entries, dest_dir, overwrite)
    if state.paste_in_progress then
        util.err('A paste is already in progress')
        return
    end
    if not fs.is_dir(dest_dir) then
        util.err(('%q is not a directory'):format(dest_dir))
        return
    end
    local ops = {}
    for _, entry in ipairs(entries) do
        ops[#ops + 1] = {is_move = entry.operation == 'cut', src = entry.path}
    end
    local planned_ops = fs.plan_paste(ops, dest_dir, state.cwd, overwrite)
    local move_changes = {}
    local move_changes_by_path = {}
    for _, op in ipairs(planned_ops) do
        if op.is_move and not op.skip then
            local change = lsp.file_rename(op.src, op.dest)
            move_changes[#move_changes+1] = change
            move_changes_by_path[op.src .. '\0' .. op.dest] = change
        end
    end
    lsp.will_rename(move_changes)
    -- Mute the cut rows while the paste moves them away (see view.render).
    -- Marks are shared across dora buffers, so the moving rows may be visible
    -- in windows other than the pasting one; mute them all.
    local moving_paths = {}
    for _, op in ipairs(planned_ops) do
        if op.is_move and not op.skip then
            moving_paths[op.src] = true
        end
    end
    if next(moving_paths) then
        store.each(function(other)
            if api.nvim_buf_is_valid(other.buf) then
                other.pasting_paths = moving_paths
                view.render(other)
            end
        end)
    end
    -- The copy runs off the main loop; keep the editor responsive and show a
    -- live spinner until it finishes.
    local progress = {files = 0, bytes = 0}
    local stop_spinner = start_spinner(function()
        return ('Pasting… %d items, %.1f MiB'):format(progress.files, progress.bytes / 1024 / 1024)
    end)
    state.paste_in_progress = true
    -- Drive the statusline's busy indicator.
    vim.o.busy = vim.o.busy + 1
    fs.paste_async(planned_ops, progress, overwrite, function(ok, result, completed)
        state.paste_in_progress = false
        store.each(function(other)
            other.pasting_paths = nil
        end)
        vim.o.busy = vim.o.busy - 1
        stop_spinner()
        local completed_moves = {}
        for _, op in ipairs(completed) do
            if op.is_move then
                completed_moves[#completed_moves+1] = move_changes_by_path[op.src .. '\0' .. op.dest]
                history.rename_subtree(op.src, op.dest)
            end
        end
        lsp.did_rename(completed_moves)
        if not ok then
            util.err(result)
            -- Rendered even though the paste failed, to unmute the cut rows
            -- everywhere; the marks survive, so a retry can still move them.
            store.each(function(other)
                if api.nvim_buf_is_valid(other.buf) then
                    view.render(other)
                end
            end)
            return
        end
        clear_marked_paths(state)
        -- Expand the destination so the pasted rows are visible.
        if dest_dir ~= state.cwd then
            state.expanded_dirs[dest_dir] = true
        end
        -- Refresh every other dora window too. A cut removes the source rows,
        -- and both cut and copy clear the marks (shared across all windows);
        -- without rescanning, other windows keep showing the moved files and
        -- stale cut/copy highlights until a manual reload.
        store.each(function(other)
            if other.buf ~= state.buf and api.nvim_buf_is_valid(other.buf) then
                view.clear_listings(other)
                view.render(other)
            end
        end)
        -- The user may have closed the dora window while the copy ran.
        if not api.nvim_buf_is_valid(state.buf) then
            return
        end
        view.clear_listings(state)
        view.render(state)
        view.set_cursor_path(state, result)
        local item_label = #entries == 1 and 'item' or 'items'
        util.info(('Pasted %d %s to %s'):format(#entries, item_label, util.display_path(dest_dir)))
    end)
end

---@param count integer
---@return string
local function paste_error_message(count)
    if count == 1 then
        return 'Cannot paste a directory into itself'
    end
    return string.format('Cannot paste %d directories into themselves', count)
end

---@param state DoraState
---@param row DoraTreeRow
---@param dest_dir string
---@param entries DoraMarkedPathEntry[]
local function paste_to_directory(state, row, dest_dir, entries)
    if not fs.is_dir(dest_dir) then
        util.err(('%q is not a directory'):format(dest_dir))
        return
    end
    local paste_paths = {}
    local renames = {}
    local operations = {}
    local has_conflict = false
    local error_count = 0
    local reserved_dests = {}
    for _, entry in ipairs(entries) do
        paste_paths[#paste_paths+1] = entry.path
        operations[entry.path] = entry.operation
        if fs.paste_into_self(entry.path, dest_dir, state.cwd) then
            error_count = error_count + 1
        end
        local entry_dest = vim.fs.joinpath(dest_dir, fs.basename(entry.path))
        if fs.exists(entry_dest) or reserved_dests[entry_dest] then
            has_conflict = true
            -- Reserve each previewed name so later entries see the same
            -- destinations that sequential paste execution will create.
            local target_path = fs.nonclobber_dest(entry_dest, reserved_dests)
            reserved_dests[target_path] = true
            local target = fs.basename(target_path)
            renames[entry.path] = target
        else
            reserved_dests[entry_dest] = true
        end
    end
    local opts = {
        anchor = current_name_anchor(row, {superimpose = false}),
        action = 'Paste',
        dest = dest_dir,
        base = state.cwd,
        operations = operations,
        expanded = state.expanded_dirs,
    }
    if error_count > 0 then
        opts.error = paste_error_message(error_count)
        confirm_win.show(paste_paths, function() end, opts)
        return
    end
    opts.renames = renames
    opts.allow_overwrite = has_conflict
    confirm_win.show(paste_paths, function(confirmed, overwrite)
        if confirmed and api.nvim_buf_is_valid(state.buf) then
            paste_entries(state, entries, dest_dir, overwrite)
        end
    end, opts)
end

---@param resolve_dest fun(row: DoraTreeRow): string?
local function paste_at(resolve_dest)
    local state = store.get()
    local entries = marked_path_entries(state)
    if #entries == 0 then
        util.err('Nothing to paste')
        return
    end
    local row = view.current_row(state)
    local dest_dir = row and resolve_dest(row)
    if not row or not dest_dir then
        util.err('No paste destination')
        return
    end
    paste_to_directory(state, row, dest_dir, entries)
end

function M.paste_under()
    paste_at(function(row) return row.type == 'directory' and row.path or row.parent_path end)
end

function M.paste()
    -- The root row has no siblings in view; pasting at it targets the cwd.
    paste_at(function(row) return row.is_root and row.path or row.parent_path end)
end

---@param reg? string
function M.yank_full_path(reg)
    local state = store.get()
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    util.copy_value(path, reg, reg == '+' and 'Yanked full path to clipboard' or 'Yanked full path')
end

function M.yank_full_path_clipboard()
    M.yank_full_path('+')
end

---@param reg? string
function M.yank_dir_path(reg)
    local state = store.get()
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    util.copy_value(fs.get_parent_dir(path), reg, reg == '+' and 'Yanked parent directory to clipboard' or 'Yanked parent directory')
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
    local row = view.current_row(state)
    ---@cast row -nil  -- current_path() returned a path, so there is a row
    local filename = fs.basename(path)
    util.copy_value(filename, reg, reg == '+' and 'Yanked filename to clipboard' or 'Yanked filename', {
        line = api.nvim_win_get_cursor(0)[1],
        start_col = row.name_end_col - #row.name,
    })
end

function M.yank_filename_clipboard()
    M.yank_filename('+')
end

---@param reg? string
function M.yank_name_stem(reg)
    local state = store.get()
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    local filename = fs.basename(path)
    local name = vim.fn.fnamemodify(filename, ':r')
    local message = reg == '+' and 'Yanked name without extension to clipboard' or 'Yanked name without extension'
    local row = view.current_row(state)
    ---@cast row -nil  -- current_path() returned a path, so there is a row
    util.copy_value(name, reg, message, {
        line = api.nvim_win_get_cursor(0)[1],
        start_col = row.name_end_col - #row.name,
    })
end

function M.yank_name_stem_clipboard()
    M.yank_name_stem('+')
end

-- Stack of trashes that can be undone, newest last. Each entry is the batch of
-- {original, trashed} pairs from a single trash action (one file, or several in
-- a visual selection). Shared across every dora window, like the system trash.
---@type {original: string, trashed: string}[][]
local trash_history = {}

---@param state DoraState
---@param paths string[]
---@param mode 'trash'|'delete'
---@param action string
---@param anchor? DoraFloatAnchor
local function remove_paths(state, paths, mode, action, anchor)
    confirm_win.show(paths, function(confirmed)
        if not confirmed or not api.nvim_buf_is_valid(state.buf) then
            return
        end
        if state.remove_in_progress then
            util.err('A removal is already in progress')
            return
        end
        -- The removal runs off the main loop, so a stalled syscall (a network
        -- mount, a macOS privacy consultation) or a large recursive delete
        -- doesn't freeze the editor with the confirmation still on screen.
        local results = {removed = {}, undo_batch = {}}
        local stop_spinner = start_spinner(function()
            return mode == 'trash' and 'Trashing…' or 'Deleting…'
        end)
        state.remove_in_progress = true
        -- Mute the doomed rows while the removal runs (see view.render).
        state.removing_paths = {}
        for _, path in ipairs(paths) do
            state.removing_paths[path] = true
        end
        view.render(state)
        -- Drive the statusline's busy indicator.
        vim.o.busy = vim.o.busy + 1
        fs.remove_async(paths, mode, results, function(ok, err)
            state.remove_in_progress = false
            state.removing_paths = nil
            vim.o.busy = vim.o.busy - 1
            stop_spinner()
            -- Files moved to the trash before a mid-batch failure are real, so
            -- keep them undoable even though the batch was cut short.
            if #results.undo_batch > 0 then
                trash_history[#trash_history+1] = results.undo_batch
            end
            for _, removed_path in ipairs(results.removed) do
                buffer.delete_buffers(removed_path)
            end
            -- The user may have closed the dora window while the removal ran.
            if api.nvim_buf_is_valid(state.buf) then
                if #results.removed > 0 then
                    for _, removed_path in ipairs(results.removed) do
                        clear_marked_paths_under(state, removed_path)
                    end
                    view.clear_listings(state)
                end
                -- Rendered even when nothing was removed, to unmute the rows.
                view.render(state)
            end
            if not ok then
                util.err(err)
            end
        end)
    end, {
        anchor = anchor,
        action = action,
        expanded = state.expanded_dirs,
    })
end

---@param mode 'trash'|'delete'
---@param action string
local function remove_path(mode, action)
    local state = store.get()
    if refuse_root_row(state, mode) then
        return
    end
    local row = view.current_row(state)
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    remove_paths(state, {path}, mode, action, current_name_anchor(row))
end

---@param mode 'trash'|'delete'
---@param action string
local function remove_visual_paths(mode, action)
    local state = store.get()
    local paths, msg = selected_non_overlapping_paths(state)
    if not paths then
        util.err(msg)
        return
    end
    -- Anchor the confirmation to the first selected row (paths[1] by
    -- construction) so its lines align with the rows they remove
    local anchor
    local start_line, end_line = visual_line_range()
    for line = start_line, end_line do
        local row = state.rows and state.rows[line] or nil
        if row and row.path then
            anchor = current_name_anchor(row, {line = line})
            break
        end
    end
    remove_paths(state, paths, mode, action, anchor)
end

function M.trash()
    remove_path('trash', 'Trash')
end

function M.delete()
    remove_path('delete', 'Delete')
end

function M.trash_visual()
    remove_visual_paths('trash', 'Trash')
end

function M.delete_visual()
    remove_visual_paths('delete', 'Delete')
end

-- Move every entry in `batch` back out of the trash to where it came from.
-- Entries whose trash file is gone (the trash was emptied) are reported and
-- skipped. Reveals the restored files and jumps to the first one in view.
---@param batch {original: string, trashed: string}[]
local function restore_trash(batch)
    local restored = {}
    local missing = 0
    for _, entry in ipairs(batch) do
        if not fs.exists(entry.trashed) then
            missing = missing + 1
        else
            local ok, result = pcall(fs.untrash, entry.trashed, entry.original)
            if not ok then
                util.err(result)
                break
            end
            restored[#restored+1] = result
        end
    end

    if #restored == 0 then
        if missing > 0 then
            util.err('Trashed files are no longer available')
        end
        return
    end

    local state = store.get()
    -- Reveal the restored files in the focused window, then rescan and redraw
    -- every dora window so none keep showing the gap the trash left behind.
    for _, path in ipairs(restored) do
        tree.expand_ancestors(state, path)
    end
    store.each(function(other)
        if api.nvim_buf_is_valid(other.buf) then
            view.clear_listings(other)
            view.render(other)
        end
    end)
    -- Jump to the first restored file that has a row in the focused window;
    -- restored[1] may have come from outside this window's cwd and have no row.
    for _, path in ipairs(restored) do
        if view.set_cursor_path(state, path) then
            break
        end
    end

    local label = #restored == 1 and 'item' or 'items'
    if missing > 0 then
        util.warn(('Restored %d %s, %d no longer in the trash'):format(#restored, label, missing))
    else
        util.info(('Restored %d %s'):format(#restored, label))
    end
end

-- Restore the most recent trash after a confirmation listing the files that
-- will be brought back. The newest batch is only pulled off the history once
-- confirmed, so cancelling leaves it undoable.
function M.undo_trash()
    local batch = trash_history[#trash_history]
    if not batch then
        util.err('No trash to undo')
        return
    end

    -- Preview each entry at the location it will be restored to (its original
    -- path); its own location is empty until then, so the confirmation takes the
    -- file type from the trashed copy that still exists.
    local paths = {}
    local types = {}
    for _, entry in ipairs(batch) do
        paths[#paths+1] = entry.original
        types[entry.original] = entry.trashed
    end

    local state = store.get()
    confirm_win.show(paths, function(confirmed)
        if not confirmed then
            return
        end
        -- Drop this batch wherever it sits in the history now that its restore is
        -- going ahead, so it can't be undone twice. The confirmation blocks other
        -- trashing, so in practice it is still the newest entry.
        for i = #trash_history, 1, -1 do
            if trash_history[i] == batch then
                table.remove(trash_history, i)
                break
            end
        end
        restore_trash(batch)
    end, {
        action = 'Undo trash',
        base = state.cwd,
        types = types,
        expanded = state.expanded_dirs,
    })
end

---@param prefill boolean
local function rename(prefill)
    local state = store.get()
    local row = view.current_row(state)
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    if row and row.is_root and fs.get_parent_dir(path) == path then
        util.warn('Cannot rename the filesystem root')
        return
    end
    local basename = fs.basename(path)
    ---@cast row -nil  -- current_path() returned a path, so there is a row
    local file_type = row.type
    ---@cast file_type DoraFileType  -- placeholder rows have no path
    -- The live icon tracks the typed name under the entry's existing type —
    -- rename cannot change it, so there is no trailing-slash rule like the
    -- add prompt's, and an expanded directory keeps its open icon.
    local expanded = row.is_root or file_type == 'directory' and state.expanded_dirs[path] or nil
    prompt.input({
        prompt = 'Rename',
        cwd = fs.get_parent_dir(path),
        initial_prompt = prefill and basename or '',
        width = math.max(PROMPT_WIDTH, #basename + 4),
        anchor = current_name_anchor(row, {superimpose = true}),
        icon = config.icons and function(input)
            return icons.get(config.icons, {name = input, type = file_type}, input, expanded)
        end or nil,
        validate = function(input)
            return fs.validate_rename(input, path)
        end,
        warn = function(_, dest)
            return fs.exists(dest) and not fs.same_file(path, dest)
        end,
    }, function(input, dest)
        if not input or not api.nvim_buf_is_valid(state.buf) then
            return
        end
        local function perform_rename()
            local change = lsp.file_rename(path, dest)
            lsp.will_rename({change})
            local ok, err = pcall(fs.rename, path, dest)
            if not ok then
                util.err(err)
                return
            end
            lsp.did_rename({change})
            tree.rename_expanded_subtree(state, path, dest)
            rename_marked_paths_under(state, path, dest)
            history.rename_subtree(path, dest)
            if path == state.cwd then
                -- Renaming the root retargets the session onto the new path:
                -- the cwd and the buffer named after it. The listings (and
                -- their watchers) are keyed under the old path and rebuild
                -- from the clear_listings below.
                state.cwd = dest
                api.nvim_buf_call(state.buf, function()
                    buffer.update_buf_name(dest)
                end)
            end
            view.clear_listings(state)
            view.render(state)
            view.set_cursor_path(state, dest)
        end
        if fs.exists(dest) and not fs.same_file(path, dest) then
            confirm_win.show({dest}, function(confirmed)
                if confirmed and api.nvim_buf_is_valid(state.buf) then
                    perform_rename()
                end
            end, {
                anchor = current_name_anchor(row),
                action = 'Overwrite',
                expanded = state.expanded_dirs,
            })
        else
            perform_rename()
        end
    end)
end

function M.rename()
    rename(true)
end

function M.rename_empty()
    rename(false)
end

-- Icon for the add prompt, tracking what the current input would create: a
-- trailing slash makes a directory, anything else a file named by the typed
-- basename.
---@param input string
---@return string? icon
---@return string? hl
local function create_icon(input)
    local name = vim.fs.basename(fs.strip_trailing_sep(input)) or ''
    local file_type = vim.endswith(input, '/') and 'directory' or 'file'
    return icons.get(config.icons, {name = name, type = file_type}, name, false)
end

---@param under_directory? boolean
local function create(under_directory)
    local state = store.get()
    local row = view.current_row(state)
    local base_dir, initial_prompt = create_base(state, row, under_directory)
    -- The add_under prefill is the hovered directory's own name, so the
    -- prompt overlays the row and typing continues it in place.
    prompt.input({
        prompt = 'Add file or folder',
        cwd = base_dir,
        width = PROMPT_WIDTH,
        initial_prompt = initial_prompt,
        anchor = current_name_anchor(row, {superimpose = initial_prompt ~= nil}),
        icon = config.icons and create_icon or nil,
        validate = function(input)
            return fs.validate_create(input, base_dir)
        end,
    }, function(input, path)
        if input and api.nvim_buf_is_valid(state.buf) then
            local ok, msg
            if vim.endswith(input, '/') then
                ok, msg = pcall(fs.create_dir, path)
            else
                ok, msg = pcall(fs.create_file, path)
            end
            if not ok then
                util.err(msg)
            else
                local cursor_path = fs.strip_trailing_sep(path)
                view.clear_listings(state)
                -- Deleting the root add_under prefill creates a sibling of
                -- the cwd: there is no row to reveal, and walking parents
                -- from outside the cwd would never reach it.
                if not vim.fs.relpath(state.cwd, cursor_path) then
                    view.render(state)
                    return
                end
                -- Reveal the new entry by expanding the directories above it,
                -- but leave the entry itself collapsed: `foo/bar/` expands
                -- `foo` so `bar` shows without expanding `bar`, and `foo/`
                -- expands nothing.
                local dir = fs.parent_dir(cursor_path)
                while dir ~= state.cwd do
                    state.expanded_dirs[dir] = true
                    dir = fs.parent_dir(dir)
                end
                view.render(state)
                while cursor_path ~= state.cwd and not view.set_cursor_path(state, cursor_path) do
                    cursor_path = fs.parent_dir(cursor_path)
                end
            end
        end
    end)
end

function M.add()
    create(false)
end

function M.add_under()
    create(true)
end

function M.create_symlink()
    local state = store.get()
    local row = view.current_row(state)
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    local target_dir = fs.parent_dir(path)
    local dir = vim.fs.relpath(state.cwd, target_dir)
    dir = (dir and dir ~= '.') and dir .. '/' or ''
    -- The prompt always creates a link, so the icon is the fixed symlink
    -- fallback rather than tracking the typed name.
    local icon, icon_hl = icons.get(config.icons, {name = vim.fs.basename(path), type = 'link'}, path)
    prompt.input({
        prompt = 'Add symlink',
        cwd = state.cwd,
        width = PROMPT_WIDTH,
        initial_prompt = dir,
        anchor = current_name_anchor(row),
        icon = icon,
        icon_hl = icon_hl,
        validate = function(input)
            return fs.validate_symlink(input, state.cwd)
        end,
    }, function(input, dest)
        if not input or not api.nvim_buf_is_valid(state.buf) then
            return
        end
        local ok, err = pcall(fs.create_symlink, path, dest)
        if not ok then
            util.err(err)
            return
        end
        view.clear_listings(state)
        view.render(state)
        view.set_cursor_path(state, dest)
    end)
end

function M.toggle_hidden_files()
    local state = store.get()
    local row = view.current_row(state)
    config.show_hidden_files = not config.show_hidden_files
    view.render(state)
    if not row or not row.path or not view.set_cursor_path(state, row.path) then
        view.set_cursor_pos(state, row and row.display_name or nil)
    end
    util.info(config.show_hidden_files and 'Showing hidden files' or 'Hiding hidden files')
end

---@param initial_prompt? string
function M.shell_cmd(initial_prompt)
    local state = store.get()
    local path, msg = current_path(state)
    if not path then
        util.err(msg)
        return
    end
    prompt.input({
        prompt = 'Shell command',
        initial_prompt = initial_prompt,
        cwd = state.cwd,
        width = PROMPT_WIDTH,
        anchor = current_name_anchor(view.current_row(state)),
        icon = config.icons and '' or nil,
        icon_hl = 'DoraMutedText',
    }, function(input)
        if not input or not api.nvim_buf_is_valid(state.buf) then
            return
        end
        local cmd = input .. ' ' .. vim.fn.shellescape(path) .. ' 2>&1'
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
        view.clear_listings(state)
        view.render(state)
    end)
end

---@param order DoraSortOrder
function M.sort_by(order)
    local state = store.get()
    local row = view.current_row(state)
    local path = row and row.path or nil
    config.sort_order = sorter.normalize_order(order)
    view.render(state)
    if path then
        view.set_cursor_path(state, path)
    end
end

-- Generate the parameterless wrappers (sort_by_name, sort_by_size_desc, ...)
-- that keymaps and the action registry refer to by name.
for _, order in ipairs({
    'name', 'name_desc', 'modified', 'modified_desc', 'created', 'created_desc',
    'size', 'size_desc', 'extension', 'extension_desc',
}) do
    M['sort_by_' .. order] = function() M.sort_by(order) end
end

function M.reload()
    local state = store.get()
    view.clear_listings(state)
    view.render(state)
    util.info('Reloaded')
end

-- Initialization --------------------------------------------------------------

---@param dir? string
---@return string
local function getcwd(dir)
    dir = dir or ''
    if dir ~= '' then return fs.realpath(dir) end
    -- `expand('%:p:h')` can be empty (unnamed buffers like `:enew`) or a
    -- non-filesystem path for special buffers (e.g. dora's own `dora://help`
    -- expands to `dora:`), so only trust it when it resolves to a real path;
    -- otherwise fall back to the cwd.
    local p = vim.fn.expand'%:p:h'
    local resolved = p ~= '' and fs.try_realpath(p) or nil
    return resolved or fs.normalize_sep(assert(uv.cwd()))
end

---@return string?
local function current_file_path()
    local p = vim.fn.expand'%:p'
    if p == '' then
        return nil
    end
    local resolved = fs.try_realpath(p)
    return resolved
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

    -- Same-window directory edits from Dora should navigate the existing
    -- session. Split-created directory edits should become separate sessions.
    local win = api.nvim_get_current_win()
    local prior_ok, prior_state = pcall(store.get, origin_buf)
    local reuse_prior = prior_ok and (not from_au or prior_state.win == win)
    if reuse_prior then
        local dir_buf = from_au and api.nvim_get_current_buf() or nil
        buffer.set_current_buf(origin_buf)
        if dir_buf and dir_buf ~= origin_buf and api.nvim_buf_is_valid(dir_buf) then
            api.nvim_buf_delete(dir_buf, {force=true})
        end
        local cwd = getcwd(dir)
        remember_hovered_file(prior_state)
        change_cwd(prior_state, cwd, prior_state.hovered_files[cwd], --[[or_top]]true)
        return
    end
    local alt_buf = (not from_au and has_altbuf) and vim.fn.bufnr'#' or nil
    local cwd = getcwd(dir)
    local origin_path = current_file_path()
    local origin_filename = vim.fn.expand'%:p:t' ---@type string?
    origin_filename = origin_filename ~= '' and origin_filename or nil
    local buf = buffer.create_buf(cwd)
    local ns = api.nvim_create_namespace('dora.' .. buf)
    local cursor_ns = api.nvim_create_namespace('dora/cursor.' .. buf)
    local state = {
        buf = buf,
        win = win,
        origin_buf = origin_buf,
        alt_buf = alt_buf,
        cwd = cwd,
        ns = ns,
        cursor_ns = cursor_ns,
        hovered_files = {},  -- map<realpath, cursor path/name>
        listings = {},  -- map<realpath, DoraListingEntry>
        watch_roots = {},  -- map<realpath, cancel fun> for recursive fs watches
        expanded_dirs = global_expanded_dirs,  -- map<realpath, true>
        tree_rows = {},
        rows = {},
        filter_text = nil,
        filter_preview = nil,
        filter_window = nil,
        filter_editing = false,
        filter_inverted = false,
        preview = nil,
        marked_paths = global_marked_paths,
        history = history.get(win),
    }
    keymaps.setup(buf, config)
    store.set(buf, state)
    setup_autocmds(buf)
    history.visit(state.history, cwd)
    view.render(state)
    if not origin_path or not view.set_cursor_path(state, origin_path) then
        local current_history = history.current(state.history)
        if not current_history or not current_history.hovered_path
                or not view.set_cursor_path(state, current_history.hovered_path) then
            view.set_cursor_pos(state, origin_filename)
        end
    end
    local row = view.current_row(state)
    history.update_current(state.history, state.cwd, row and row.path or nil)
end

return M
