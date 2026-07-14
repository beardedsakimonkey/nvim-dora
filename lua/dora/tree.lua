-- Operations on the expansion state of the tree (state.expanded_dirs): which
-- directories the fold actions open and close, and how that set follows
-- renames and restores. These mutate state only; callers re-render afterwards.
local fs = require'dora.fs'
local view = require'dora.view'

local M = {}

---@param state DoraState
---@param row DoraTreeRow?
---@return string?
---@return integer?
function M.collapse_target(state, row)
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
    if not vim.startswith(path, prefix .. '/') then
        return nil
    end
    local rest = path:sub(#prefix + 2)
    return select(2, rest:gsub('/', '')) + 1
end

---@param row DoraTreeRow
---@param path string
---@return boolean
local function row_under_path(row, path)
    if row.path then
        return row.path == path or vim.startswith(row.path, path .. '/')
    end
    return row.parent_path == path or vim.startswith(row.parent_path or '', path .. '/')
end

---@param state DoraState
---@param path string
---@return boolean changed
function M.expand_next_level(state, path)
    if not state.expanded_dirs[path] then
        state.expanded_dirs[path] = true
        return true
    end

    local frontier = {}
    local frontier_depth

    ---@param dir string
    ---@param depth integer
    local function visit(dir, depth)
        for _, file in ipairs(view.visible_files(state, dir)) do
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
function M.expand_all_dirs(state, path)
    local changed = not state.expanded_dirs[path]
    state.expanded_dirs[path] = true
    for _, file in ipairs(view.visible_files(state, path)) do
        if file.type == 'directory' then
            local child_path = vim.fs.joinpath(path, file.name)
            if M.expand_all_dirs(state, child_path) then
                changed = true
            end
        end
    end
    return changed
end

---@param state DoraState
---@param path string
---@return boolean changed
function M.clear_expanded_subtree(state, path)
    local prefix = path .. '/'
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
function M.collapse_deepest_visible_dirs(state, path, target_depth)
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
        -- The browsed root's listing is always rendered (its row, when shown,
        -- is not collapsible), so folding in stops above it.
        if path ~= state.cwd and state.expanded_dirs[path] then
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
function M.rename_expanded_subtree(state, old_path, new_path)
    local old_prefix = old_path .. '/'
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

-- Expand every ancestor of `path` up to state.cwd so a row for it can be
-- rendered, e.g. after restoring a file into a collapsed directory. Paths
-- outside the window's cwd have no row to reveal, so they are left alone.
---@param state DoraState
---@param path string
function M.expand_ancestors(state, path)
    local prefix = state.cwd == '/' and '/' or state.cwd .. '/'
    if not vim.startswith(path, prefix) then
        return
    end
    local dir = fs.parent_dir(path)
    while dir and dir ~= state.cwd and #dir > #state.cwd do
        state.expanded_dirs[dir] = true
        local parent = fs.parent_dir(dir)
        if parent == dir then
            break
        end
        dir = parent
    end
end

return M
