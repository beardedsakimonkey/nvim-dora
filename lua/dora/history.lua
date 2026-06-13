-- A per-buffer history of filesystem changes (create/rename/delete/paste) made
-- through dora, navigated with prev_change/next_change. Entries store the path
-- to jump to rather than a line number, so jumps survive the full-buffer
-- re-render that every dora mutation performs.

local M = {}

---@class DoraChangeEntry
---@field path string absolute path to reveal (a parent dir for deletions)

---@class DoraChangeHistory
---@field entries DoraChangeEntry[] oldest first
---@field index integer resting position; #entries + 1 means "after the newest"

---@return DoraChangeHistory
function M.new()
    return {entries = {}, index = 1}
end

-- Record a change at `path`, making it the newest entry and resetting the
-- cursor to the end. A path already in the list is moved rather than
-- duplicated so the history reads as a recency-ordered set.
---@param h DoraChangeHistory
---@param path string
function M.record(h, path)
    for i = #h.entries, 1, -1 do
        if h.entries[i].path == path then
            table.remove(h.entries, i)
        end
    end
    h.entries[#h.entries + 1] = {path = path}
    h.index = #h.entries + 1
end

-- Index reached by stepping from `from` in `dir` (-1 older, +1 newer), or nil
-- at either end. Pure: callers commit the move themselves once a target proves
-- reachable, so a stale entry can be dropped and the step retried.
---@param h DoraChangeHistory
---@param from integer
---@param dir integer
---@return integer?
function M.step(h, from, dir)
    if #h.entries == 0 then
        return nil
    end
    if dir < 0 then
        if from > #h.entries then
            return #h.entries
        end
        if from > 1 then
            return from - 1
        end
        return nil
    end
    if from < #h.entries then
        return from + 1
    end
    return nil
end

-- Remove the entry at `i`, keeping `index` pointing at the same logical spot.
---@param h DoraChangeHistory
---@param i integer
function M.remove(h, i)
    table.remove(h.entries, i)
    if h.index > i then
        h.index = h.index - 1
    end
end

return M
