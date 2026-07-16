-- Registry mapping each dora buffer to its DoraState: the per-window session
-- state every other module reads and mutates. States are created by
-- api.initialize() and removed when their buffer is wiped.
local M = {}

---@alias DoraPasteOperation 'copy'|'cut'

---@class DoraState
---@field buf integer
---@field win integer
---@field origin_buf integer
---@field alt_buf? integer
---@field cwd string
---@field ns integer
---@field cursor_ns integer
---@field show_hidden_files boolean
---@field sort_order DoraSortOrder
---@field hovered_files table<string, string> directory path -> cursor path/name
---@field listings table<string, DoraListingEntry>
---@field watch_roots table<string, fun()> recursive fs-watch root -> cancel (see view.lua)
---@field expanded_dirs table<string, true>
---@field tree_rows DoraTreeRow[]
---@field rows DoraTreeRow[]
---@field filter_text? string
---@field filter_preview? string
---@field filter_window? DoraFilterWindow
---@field filter_editing boolean
---@field filter_inverted boolean when true, the filter keeps non-matching rows
---@field marked_paths table<string, DoraPasteOperation>
---@field paste_in_progress? boolean Guards against starting a second async paste while one runs
---@field remove_in_progress? boolean Guards against starting a second async trash/delete while one runs
---@field removing_paths? table<string, true> Paths of the in-flight trash/delete; their rows render muted
---@field pasting_paths? table<string, true> Cut sources of the in-flight paste; set on every dora buffer (marks are shared), their rows render muted
---@field preview? DoraPreviewWindow
---@field history DoraHistory

---@type table<integer, DoraState>
local buf_states = {}

---@param buf integer
---@param state DoraState
function M.set(buf, state)
    buf_states[buf] = state
end

---@param buf integer
function M.remove(buf)
    buf_states[buf] = nil
end

---@param buf? integer
---@return DoraState
function M.get(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    assert(buf ~= -1)
    local state = assert(buf_states[buf])
    return state
end

---Call `fn` for every live dora state, in no particular order.
---@param fn fun(state: DoraState)
function M.each(fn)
    for _, state in pairs(buf_states) do
        fn(state)
    end
end

return M
